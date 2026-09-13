# shellcheck shell=bash
# Real limits for every saved account.
#
# Claude Code reports rate limits only for the account it is logged in as, and
# only after that session's first response. The same numbers come from the
# endpoint Claude Code itself calls, which answers for whichever account's token
# is presented — so one read-only GET per saved account fills in the whole row.
#
# The numbers are refreshed on a switch, on the refresh link, on `claude-acct
# refresh`, and at most every five minutes from the status line — the same
# interval Claude Code caches them for. These are read-only lookups: no prompt is
# sent and no quota is consumed.

CA_USAGE_URL='https://api.anthropic.com/api/oauth/usage?at_wall=1&skip_spend=1'
CA_USAGE_TIMEOUT=6
# shellcheck disable=SC2034  # used by accounts.sh
CA_USAGE_FRESH_SECONDS=60   # a switch reuses an answer this new instead of asking again
CA_USAGE_AUTO_SECONDS=300   # Claude Code's own cache for these numbers is 5 minutes too

ca_usage_normalize() {  # stdin: endpoint response -> {five_hour, seven_day} in the cache's shape
  jq -ce '
    def window:
      if type == "object" and (.utilization | type) == "number" then
        {used_percentage: (.utilization | floor),
         resets_at: (if (.resets_at | type) == "string"
                     then (.resets_at | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601?)
                     else null end)}
      else null end;
    select(type == "object" and (has("five_hour") or has("seven_day")))
    | {five_hour: (.five_hour | window), seven_day: (.seven_day | window)}
    | select(.five_hour != null or .seven_day != null)' 2>/dev/null
}

# ca_usage_get <access-token>: prints the normalized limits, or one of the
# failure words (expired, unreachable, unexpected) on stderr and fails.
ca_usage_get() {
  local reply code body
  # The url and headers go in on stdin (curl -K -) so the token stays out of argv.
  reply=$(printf 'url = "%s"\nheader = "Authorization: Bearer %s"\nheader = "anthropic-beta: %s"\nheader = "Content-Type: application/json"\n' \
    "$CA_USAGE_URL" "$1" "oauth-2025-04-20" |
    curl -sS -K - --max-time "$CA_USAGE_TIMEOUT" -w '\n%{http_code}' 2>/dev/null) || {
    echo unreachable >&2
    return 1
  }
  code=$(printf '%s' "$reply" | tail -n 1)
  body=$(printf '%s' "$reply" | sed '$d')
  case "$code" in
    200) printf '%s' "$body" | ca_usage_normalize || { echo unexpected >&2; return 1; } ;;
    401 | 403) echo expired >&2; return 1 ;;
    *) echo unreachable >&2; return 1 ;;
  esac
}

ca_usage_token() {  # ca_usage_token <id>: that account's access token
  local active
  active=$(ca_active_id 2>/dev/null || true)
  if [ "$1" = "$active" ] && ca_store_present; then
    ca_store_read | jq -r '.claudeAiOauth.accessToken // empty'
  else
    ca_vault_get "$1" | jq -r '.claudeAiOauth.accessToken // empty'
  fi
}

# ca_usage_refresh [--if-older-than N] [id ...]: ask the endpoint for each account
# and store what comes back. Accounts are asked in parallel. Prints one line per
# account that could not be read. Never fails the caller.
ca_usage_refresh() {
  local max_age=0 ids="" id token dir now line status merged
  CA_USAGE_STORED=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --if-older-than) max_age=$2; shift 2 ;;
      *) ids="$ids $1"; shift ;;
    esac
  done
  [ -n "$ids" ] || ids=$(ca_index_read | jq -r '.accounts[].id')
  [ -n "$ids" ] || return 0
  command -v curl >/dev/null 2>&1 || return 0

  now=$(date +%s)
  dir=$(mktemp -d "${TMPDIR:-/tmp}/claude-acct-usage.XXXXXX") || return 0
  for id in $ids; do
    if [ "$max_age" -gt 0 ] &&
      [ "$(ca_rl_read | jq -r --arg id "$id" --argjson now "$now" \
        '(($now - (.accounts[$id].fetchedAt // 0)) | tostring)')" -lt "$max_age" ]; then
      continue
    fi
    token=$(ca_usage_token "$id") || token=""
    if [ -z "$token" ]; then
      printf 'expired\n' >"$dir/$id.err"
      continue
    fi
    (ca_usage_get "$token" >"$dir/$id.json" 2>"$dir/$id.err") &
  done
  wait

  for id in $ids; do
    [ -f "$dir/$id.json" ] || continue
    if [ -s "$dir/$id.json" ]; then
      merged=$(printf '%s\n%s\n' "$(ca_rl_read)" "$(cat "$dir/$id.json")" |
        jq -cs --arg aid "$id" --argjson now "$now" '
          .[0] as $state | .[1] as $new
          | $state
          | .accounts[$aid] = (($state.accounts[$aid] // {}) + $new + {fetchedAt: $now, source: "api"})' 2>/dev/null) ||
        merged=""
      [ -z "$merged" ] || { printf '%s\n' "$merged" | ca_write_atomic "$(ca_rl_path)" 600 && CA_USAGE_STORED=1; } || true
    else
      status=$(head -n 1 "$dir/$id.err" 2>/dev/null)
      case "$status" in
        expired) line="login expired — switch to it once, or /login again" ;;
        unexpected) line="the endpoint answered in a shape claude-acct does not know" ;;
        *) line="could not be reached" ;;
      esac
      printf '%s: %s\n' "$(ca_index_label "$id")" "$line"
    fi
  done
  rm -rf "$dir"
}

ca_cmd_refresh() {  # refresh [account ...]
  local ids="" arg id problems
  for arg in "$@"; do
    id=$(ca_index_find "$arg") || exit 1
    ids="$ids $id"
  done
  ca_ensure_data_dir
  # shellcheck disable=SC2086  # ids is a space-separated list of ids by construction
  problems=$(ca_usage_refresh $ids)
  [ -z "$problems" ] || printf '%s\n' "$problems" >&2
  ca_settings_poke
  ca_cmd_list
}

# ca_usage_maybe_refresh: called from the status line. Asks for the numbers again
# at most every CA_USAGE_AUTO_SECONDS, in a detached process so the status line
# never waits for the network. Idle sessions are refreshed too, because waiting
# for a limit to reset is exactly when the countdown matters.
# Set CLAUDE_ACCT_AUTO_REFRESH=0 to turn this off.
ca_usage_maybe_refresh() {
  local now last lock new
  [ "${CLAUDE_ACCT_AUTO_REFRESH:-1}" = 0 ] && return 0
  now=$(date +%s)
  last=$(ca_rl_read | jq -r '.auto.at // 0' 2>/dev/null) || return 0
  [ "$((now - last))" -ge "$CA_USAGE_AUTO_SECONDS" ] || return 0

  lock="$(ca_data_dir)/auto.lock"
  if [ -d "$lock" ] && [ -n "$(find "$lock" -maxdepth 0 -mmin +2 2>/dev/null)" ]; then
    rmdir "$lock" 2>/dev/null || true
  fi
  ca_ensure_data_dir
  # Several sessions run a status line at once; only the one that takes the lock asks.
  mkdir "$lock" 2>/dev/null || return 0
  # Claim the slot before fetching, so a slow answer does not let the others pile on.
  new=$(ca_rl_read | jq -c --argjson now "$now" '.auto = {at: $now}' 2>/dev/null) &&
    printf '%s\n' "$new" | ca_write_atomic "$(ca_rl_path)" 600

  # Once new numbers are stored, poke the status line so they show up right away.
  # The same round keeps the vault copy of the active account current.
  if [ "${CA_USAGE_SYNC:-0}" = 1 ]; then
    ca_usage_refresh >/dev/null 2>&1 || true
    [ "${CA_USAGE_STORED:-0}" = 1 ] && ca_settings_poke
    (ca_lock; ca_sync_active) >/dev/null 2>&1 || true
    rmdir "$lock" 2>/dev/null || true
  else
    (ca_usage_refresh >/dev/null 2>&1; [ "${CA_USAGE_STORED:-0}" = 1 ] && ca_settings_poke
     (ca_lock; ca_sync_active) >/dev/null 2>&1 || true
     rmdir "$lock" 2>/dev/null || true) >/dev/null 2>&1 </dev/null &
  fi
  return 0
}
