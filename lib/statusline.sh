# shellcheck shell=bash
# The status line: the user's own status line (if any), the row of accounts, and
# a second row with the controls.
#
# Claude Code runs this every second, so the whole thing is one jq pass over the
# files it needs; bash only prints the result and writes state when it changed.

CA_URL_BASE=http://claude-acct.localhost
CA_ORANGE_RGB='38;2;217;119;87'  # the Anthropic orange
CA_ORANGE_256='38;5;173'         # closest xterm-256 colour, for terminals without truecolor

ca_ui_path() { printf '%s/ui.json' "$(ca_data_dir)"; }

ca_ui_read() {
  if [ -f "$(ca_ui_path)" ]; then cat "$(ca_ui_path)"; else printf '{}'; fi
}

ca_ui_set_collapsed() {  # ca_ui_set_collapsed <true|false>
  local new
  new=$(ca_ui_read | jq -c --argjson v "$1" '.collapsed = $v') || return 1
  ca_ensure_data_dir && printf '%s\n' "$new" | ca_write_atomic "$(ca_ui_path)" 600 && ca_settings_poke
}

ca_ui_set_hint() {  # ca_ui_set_hint <name> <true|false>: show or hide a hint row for good
  local new
  # shellcheck disable=SC2016  # a jq filter: its $names are jq variables
  new=$(ca_ui_read | jq -c --arg n "$1" --argjson v "$2" '.hints[$n] = $v') || return 1
  ca_ensure_data_dir && printf '%s\n' "$new" | ca_write_atomic "$(ca_ui_path)" 600 && ca_settings_poke
}

# Escape sequences for the active account, empty when colour is unwanted or unsupported.
# Nothing else is styled: the terminal shows what is clickable when the mouse is over it.
ca_style() {  # ca_style <active|off>
  local esc
  esc=$(printf '\033')
  if [ -n "${NO_COLOR:-}" ] || [ "${TERM:-}" = dumb ]; then return 0; fi
  case "$1" in
    active)
      case "${COLORTERM:-}" in
        truecolor | 24bit) printf '%s[1;%sm' "$esc" "$CA_ORANGE_RGB" ;;
        *) printf '%s[1;%sm' "$esc" "$CA_ORANGE_256" ;;
      esac ;;
    off) printf '%s[0m' "$esc" ;;
  esac
}

# The jq program. Inputs: $session (raw text), $index, $rl, $ui, $inst, $gc (each a
# one-element array from --slurpfile or a fallback), $now, $columns, $auto_seconds,
# $base, $s_active, $s_off, $jb_engine (the JetBrains terminal engine, or "").
# Output, one string per line: the user's own status line command as a JSON string,
# 1/0 whether a background round is due, the active account's new limits entry
# as JSON (or "-" when nothing changed), the active account's id (or empty),
# then the rows to print (none when logged out).
# shellcheck disable=SC2016  # a jq program: the $names are jq variables, not shell
CA_STATUSLINE_JQ='
  def dur: if . < 3600 then "\(. / 60 | floor)m" elif . < 86400 then "\(. / 3600 | floor)h" else "\(. / 86400 | floor)d" end;
  # The same reset time as the session and the endpoint each round it: a second apart.
  def near($a; $b): (if $a > $b then $a - $b else $b - $a end) <= 5;
  # A window is known by its reset time, which does not move while it runs.
  def running($w): ($w | type) == "object" and ($w.resets_at | type) == "number" and $w.resets_at > $now;
  # At least one window runs on both sides, and every window that does resets at the same time.
  def same_windows($a; $b):
    [("five_hour", "seven_day") as $k | select(running($a[$k]) and running($b[$k])) | near($a[$k].resets_at; $b[$k].resets_at)]
    | length > 0 and all;
  # OSC 8 hyperlink: ESC ] 8 ; ; url BEL text ESC ] 8 ; ; BEL
  def link($url; $text): ([27] | implode) as $esc | ([7] | implode) as $bel
    | $esc + "]8;;" + $url + $bel + $text + $esc + "]8;;" + $bel;
  # A window with no resets_at has not started yet, so its 0% is true with no countdown.
  # One whose reset has passed is stale: better to show nothing than a wrong number.
  def window($name; $w):
    if ($w | type) == "object" and ($w.used_percentage | type) == "number"
       and ($w.resets_at == null or $w.resets_at > $now)
    then "\($name) \($w.used_percentage | floor)%"
         + (if $w.resets_at == null then "" else "↻\($w.resets_at - $now | dur)" end)
    else empty end;
  def limits($src):
    if ($src | type) == "object" and ($src.fetchedAt | type) == "number" and ($now - $src.fetchedAt) > $stale_seconds
    then " ?"   # last heard from too long ago to be true; Claude Code drops cached usage after an hour too
    else [window("5h"; $src.five_hour), window("7d"; $src.seven_day)]
         | if length > 0 then " " + join(" · ") else "" end end;
  def name($a; $short): if $short then (($a.label | .[0:3]) + "…") else $a.label end;
  # Both spellings of the row: plain to measure against the terminal, styled to print.
  # Name and limits are one link; the active account is one orange run, with its
  # marker just before the link rather than inside it: Claude Code writes a cell s
  # link before its colour, and JediTerm (JetBrains) copies the style current when
  # a link starts and keeps it, so the link inherits the marker s orange this way
  # and would keep grey the other way.
  def row($rows; $short):
    [$rows[]
      | (name(.; $short) + limits(.src)) as $body
      | {plain: ((if .is_active then "● " else "" end) + $body),
         styled: (if .is_active then $s_active + "● " + link("\($base)/use/\(.id)"; $body) + $s_off
                  else link("\($base)/use/\(.id)"; $body) end)}]
    | {plain: (map(.plain) | join("  │  ")), styled: (map(.styled) | join("  │  "))};

  ($session | try fromjson catch {} | if type == "object" then . else {} end) as $s
  | $index[0] as $idx | ($rl[0] | .accounts = (.accounts // {})) as $rl0
  | $ui[0] as $ui0 | $inst[0] as $inst0 | $gc[0] as $gc0
  | ($inst0.originals.statusLine
     | if type == "object" and .type == "command" then (.command // "") else "" end
     | if test("claude-acct.*statusline") then "" else . end) as $orig
  | ($gc0.oauthAccount // null) as $acct
  | (if ($acct | type) == "object" and ($acct.accountUuid | type) == "string"
        and ($acct.organizationUuid | type) == "string"
     then "\($acct.accountUuid):\($acct.organizationUuid)" else null end) as $key
  | ([$idx.accounts[] | select(.key == $key) | .id] | .[0]) as $active

  # The session only ever reports the active account s limits, and after a switch it
  # keeps showing the numbers of the account it last got a response for, which can
  # be several switches back; another open session can show still older numbers of
  # that account. Such leftovers are told apart by what the other accounts are known
  # to have: the numbers the previous account last showed, or a window of any other
  # account (its last numbers may have gone unrecorded, but its windows do not move).
  # A window that has reset since tells nothing either way. Reset times are rounded
  # (minutes for 5h, the hour for 7d), so two accounts started close together can
  # coincide; the new account s numbers then stay unrecorded until the windows part,
  # and the row shows the endpoint s numbers meanwhile.
  # The previous account is the one a switch left, or the one the last status line
  # saw active: a /login by hand is a switch too.
  | ($s.rate_limits // null) as $lim
  | ([$rl0.switch.from, $rl0.lastActive] | map(select(. != null and . != $active)) | unique) as $prevs
  | (if $active == null or ($lim | type) != "object" then {status: "none", entry: null}
     else
       "\($lim.five_hour.resets_at // "")|\($lim.five_hour.used_percentage // "")|\($lim.seven_day.resets_at // "")|\($lim.seven_day.used_percentage // "")" as $sig
       | if any($prevs[]; $sig == ($rl0.accounts[.].lastSig // ""))
            or any($rl0.accounts | to_entries[] | select(.key != $active); same_windows($lim; .value))
         then {status: "stale", entry: null}
         elif ($rl0.accounts[$active].lastSig // "") == $sig then {status: "live", entry: null}
         else {status: "live",
               entry: {five_hour: ($lim.five_hour // null), seven_day: ($lim.seven_day // null),
                       observedAt: $now, fetchedAt: $now, source: "session", lastSig: $sig}}
         end
     end) as $obs
  | (if $obs.entry != null or ($active != null and $active != $rl0.lastActive)
     then {entry: $obs.entry, lastActive: (if $active != $rl0.lastActive then $active else null end)} else null end) as $patch
  | (if $obs.entry then ($rl0 | .accounts[$active] = ((.accounts[$active] // {}) + $obs.entry)) else $rl0 end) as $rlnow
  | (($now - ($rl0.auto.at // 0)) >= $auto_seconds) as $due

  | [$idx.accounts[]
      | . + {is_active: (.id == $active),
             src: (if .id == $active and $obs.status == "live" then $lim else $rlnow.accounts[.id] end)}] as $rows
  | (if $ui0.collapsed == true then true
     elif $ui0.collapsed == false then false
     # Auto: shorten only when the full row would not fit. 2 columns of headroom
     # keep it clear of the edge, and 0 means the width is unknown.
     elif $columns > 0 and (row($rows; false).plain | length) > ($columns - 2) then true
     else false end) as $short

  | ($orig | @json), (if $due then "1" else "0" end), (if $patch then ($patch | tojson) else "-" end), ($active // ""),
    (if $key == null then empty else
       row($rows; $short).styled,
       ([link("\($base)/" + (if $short then "expand" else "collapse" end);
              if $short then "⤢ expand" else "⤡ collapse" end),
         (if $active == null then link("\($base)/save"; "＋ save") else empty end),
         link("\($base)/refresh"; "↻ limits")]
        | join("   ")),
       # A third row for the reworked JetBrains engine, until the user hides it.
       (if $jb_engine == "reworked" and $ui0.hints.jetbrains != false then
          ("⚠ this JetBrains terminal engine opens links only with Ctrl+click (with a context menu on macOS); "
           + "Settings › Tools › Terminal › Terminal engine › Classic makes them click normally") as $long
          | (if $columns > 0 and ($long | length) + 12 > $columns
             then "⚠ links here need Ctrl+click; set Terminal engine › Classic" else $long end)
            + "   " + link("\($base)/hint/jetbrains/off"; "✕ hide")
        else empty end)
     end)
'

# ca_link_base: where the links point. VS Code opens terminal links itself; once
# its extension is set up, the links go through that instead (see vscode.sh).
ca_link_base() {
  if [ "${TERM_PROGRAM:-}" = vscode ] && [ -n "$(ca_vscode_version)" ]; then
    printf '%s' "$CA_VSCODE_URL_BASE"
  else
    printf '%s' "$CA_URL_BASE"
  fi
}

ca_cmd_statusline() {
  local input now data out orig due patch active rows
  input=$(cat)
  now=$(date +%s)
  data=$(ca_data_dir)
  # When this run read its state: a switch that finishes later knows it was missed.
  [ -d "$data" ] && ca_now_ms >"$data/statusline.at" 2>/dev/null
  # A file that does not exist yet is the same as its empty default.
  set --
  for spec in "index|$data/accounts.json|{\"accounts\":[]}" "rl|$data/ratelimits.json|{}" \
    "ui|$data/ui.json|{}" "inst|$data/install.json|{}" "gc|$(ca_global_config_path)|{}"; do
    name=${spec%%|*}; rest=${spec#*|}; path=${rest%|*}; fallback=${rest##*|}
    if [ -f "$path" ]; then set -- "$@" --slurpfile "$name" "$path"
    else set -- "$@" --argjson "$name" "[$fallback]"; fi
  done
  out=$(jq -rn "$@" --arg session "$input" --argjson now "$now" --argjson columns "${COLUMNS:-0}" \
    --argjson auto_seconds "$CA_USAGE_AUTO_SECONDS" --argjson stale_seconds "$CA_RL_STALE_SECONDS" \
    --arg base "$(ca_link_base)" --arg s_active "$(ca_style active)" --arg s_off "$(ca_style off)" \
    --arg jb_engine "$(ca_jetbrains_engine)" \
    "$CA_STATUSLINE_JQ" 2>/dev/null) || return 0
  { IFS= read -r orig; IFS= read -r due; IFS= read -r patch; IFS= read -r active; rows=$(cat); } <<EOF
$out
EOF
  if [ "$orig" != '""' ]; then
    # Decoded here so a command spanning several lines cannot shift the fields above.
    orig=$(printf '%s' "$orig" | jq -r . 2>/dev/null) || orig=""
    if [ -n "$orig" ]; then
      out=$(printf '%s\n' "$input" | sh -c "$orig" 2>/dev/null || true)
      [ -z "$out" ] || printf '%s\n' "$out"
    fi
  fi
  [ -z "$rows" ] || printf '%s\n' "$rows"
  if [ "$patch" != "-" ] && [ -n "$active" ] && printf '%s' "$patch" | jq -e . >/dev/null 2>&1; then
    # shellcheck disable=SC2016  # a jq filter: its $names are jq variables
    ca_rl_update '(if $p.entry then .accounts[$id] = ((.accounts[$id] // {}) + $p.entry) else . end)
                  | (if $p.lastActive then .lastActive = $p.lastActive else . end)' \
      --arg id "$active" --argjson p "$patch" >/dev/null 2>&1 || true
  fi
  # Keep the numbers current even while the user is idle waiting for a reset.
  [ "$due" != 1 ] || ca_usage_maybe_refresh
}
