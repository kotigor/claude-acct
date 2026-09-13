# shellcheck shell=bash
# Last known rate limits per account. Claude Code reports limits only for the
# active login, and right after a switch a session keeps showing the previous
# account's numbers until its next response. Each account remembers the
# signatures of numbers it has shown, so those leftovers can be recognised.

ca_rl_path() { printf '%s/ratelimits.json' "$(ca_data_dir)"; }

ca_rl_read() {
  if [ -f "$(ca_rl_path)" ]; then cat "$(ca_rl_path)"; else printf '{"accounts":{}}'; fi
}

# ca_rl_observe <active-id> <now>; session JSON on stdin.
# Prints live (limits belong to the active account), stale (another account's) or none.
ca_rl_observe() {
  local result state
  result=$(printf '%s\n%s\n' "$(ca_rl_read)" "$(cat)" | jq -cs --arg id "$1" --argjson now "$2" '
    .[0] as $s | (.[1].rate_limits // null) as $rl
    | if ($rl | type) != "object" then {status: "none"}
      else
        "\($rl.five_hour.resets_at // "")|\($rl.five_hour.used_percentage // "")|\($rl.seven_day.resets_at // "")|\($rl.seven_day.used_percentage // "")" as $sig
        | ($s.accounts[$id].sigs // []) as $mine
        | if any($s.accounts | to_entries[] | select(.key != $id) | .value.sigs[]?; . == $sig) then {status: "stale"}
          elif ($mine | .[0]) == $sig then {status: "live"}
          else {status: "live", state: ($s | .accounts[$id] = (($s.accounts[$id] // {}) + {
                  five_hour: ($rl.five_hour // null), seven_day: ($rl.seven_day // null),
                  observedAt: $now, fetchedAt: $now, source: "session",
                  sigs: ([$sig] + ($mine | map(select(. != $sig))) | .[:20])}))}
          end
      end' 2>/dev/null) || { echo none; return 0; }
  state=$(printf '%s' "$result" | jq -c '.state // empty')
  if [ -n "$state" ]; then
    { ca_ensure_data_dir && printf '%s\n' "$state" | ca_write_atomic "$(ca_rl_path)" 600; } || true
  fi
  printf '%s' "$result" | jq -r .status
}

ca_rl_remove() {  # ca_rl_remove <id>
  local new
  [ -f "$(ca_rl_path)" ] || return 0
  new=$(ca_rl_read | jq -c --arg id "$1" 'del(.accounts[$id])') || return 1
  printf '%s\n' "$new" | ca_write_atomic "$(ca_rl_path)" 600
}
