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
# $auto_enabled, $base, $s_active, $s_off.
# Output, one string per line: the user's own status line command as a JSON string,
# 1/0 whether a background limits refresh is due, the updated ratelimits state as
# JSON (or "-" when unchanged), then the rows to print (none when logged out).
# shellcheck disable=SC2016  # a jq program: the $names are jq variables, not shell
CA_STATUSLINE_JQ='
  def dur: if . < 3600 then "\(. / 60 | floor)m" elif . < 86400 then "\(. / 3600 | floor)h" else "\(. / 86400 | floor)d" end;
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
    [window("5h"; $src.five_hour), window("7d"; $src.seven_day)]
    | if length > 0 then " " + join(" · ") else "" end;
  def name($a; $short): if $short then (($a.label | .[0:3]) + "…") else $a.label end;
  # Both spellings of the row: plain to measure against the terminal, styled to print.
  # The whole segment — marker, name and limits — is one link, and for the active
  # account one orange run.
  def row($rows; $short):
    [$rows[]
      | ((if .is_active then "● " else "" end) + name(.; $short) + limits(.src)) as $text
      | {plain: $text,
         styled: link("\($base)/use/\(.id)"; (if .is_active then $s_active + $text + $s_off else $text end))}]
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

  # The session only ever reports the active account s limits, and for a moment after
  # a switch they are still the previous account s. Every account remembers the
  # signatures of numbers it has shown, so leftovers can be recognised.
  | ($s.rate_limits // null) as $lim
  | (if $active == null or ($lim | type) != "object" then {status: "none", state: null}
     else
       "\($lim.five_hour.resets_at // "")|\($lim.five_hour.used_percentage // "")|\($lim.seven_day.resets_at // "")|\($lim.seven_day.used_percentage // "")" as $sig
       | ($rl0.accounts[$active].sigs // []) as $mine
       | if any($rl0.accounts | to_entries[] | select(.key != $active) | .value.sigs[]?; . == $sig)
         then {status: "stale", state: null}
         elif ($mine | .[0]) == $sig then {status: "live", state: null}
         else {status: "live", state: ($rl0 | .accounts[$active] = (($rl0.accounts[$active] // {}) + {
                 five_hour: ($lim.five_hour // null), seven_day: ($lim.seven_day // null),
                 observedAt: $now, fetchedAt: $now, source: "session",
                 sigs: ([$sig] + ($mine | map(select(. != $sig))) | .[:20])}))}
         end
     end) as $obs
  | ($obs.state // $rl0) as $rlnow
  | ($auto_enabled == 1 and ($now - ($rl0.auto.at // 0)) >= $auto_seconds) as $due

  | [$idx.accounts[]
      | . + {is_active: (.id == $active),
             src: (if .id == $active and $obs.status == "live" then $lim else $rlnow.accounts[.id] end)}] as $rows
  | (if $ui0.collapsed == true then true
     elif $ui0.collapsed == false then false
     # Auto: shorten only when the full row would not fit. 2 columns of headroom
     # keep it clear of the edge, and 0 means the width is unknown.
     elif $columns > 0 and (row($rows; false).plain | length) > ($columns - 2) then true
     else false end) as $short

  | ($orig | @json), (if $due then "1" else "0" end), (if $obs.state then ($obs.state | tojson) else "-" end),
    (if $key == null then empty else
       row($rows; $short).styled,
       ([link("\($base)/" + (if $short then "expand" else "collapse" end);
              if $short then "⤢ expand" else "⤡ collapse" end),
         (if $active == null then link("\($base)/save"; "＋ save") else empty end),
         link("\($base)/refresh"; "↻ limits")]
        | join("   "))
     end)
'

ca_cmd_statusline() {
  local input now data out orig due state rows
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
    --argjson auto_seconds "$CA_USAGE_AUTO_SECONDS" \
    --argjson auto_enabled "$([ "${CLAUDE_ACCT_AUTO_REFRESH:-1}" = 0 ] && echo 0 || echo 1)" \
    --arg base "$CA_URL_BASE" --arg s_active "$(ca_style active)" --arg s_off "$(ca_style off)" \
    "$CA_STATUSLINE_JQ" 2>/dev/null) || return 0
  { IFS= read -r orig; IFS= read -r due; IFS= read -r state; rows=$(cat); } <<EOF
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
  if [ "$state" != "-" ] && printf '%s' "$state" | jq -e . >/dev/null 2>&1; then
    { ca_ensure_data_dir && printf '%s\n' "$state" | ca_write_atomic "$data/ratelimits.json" 600; } 2>/dev/null || true
  fi
  # Keep the numbers current even while the user is idle waiting for a reset.
  [ "$due" != 1 ] || ca_usage_maybe_refresh
}
