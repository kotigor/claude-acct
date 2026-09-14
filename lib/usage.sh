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
CA_USAGE_CONNECT_TIMEOUT=4
CA_USAGE_TIMEOUT=8
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
# failure words (expired, throttled, unreachable, unexpected) on stderr and fails.
# A connection that stalls, or a gateway hiccup, is tried once more.
ca_usage_get() {
  local reply code body attempt=0
  while :; do
    attempt=$((attempt + 1))
    # The url and headers go in on stdin (curl -K -) so the token stays out of argv.
    if reply=$(printf 'url = "%s"\nheader = "Authorization: Bearer %s"\nheader = "anthropic-beta: %s"\nheader = "Content-Type: application/json"\nheader = "User-Agent: %s"\n' \
        "$CA_USAGE_URL" "$1" "oauth-2025-04-20" "$(ca_user_agent)" |
        curl -sS -K - --connect-timeout "$CA_USAGE_CONNECT_TIMEOUT" --max-time "$CA_USAGE_TIMEOUT" \
          -w '\n%{http_code}' 2>/dev/null); then
      code=$(printf '%s' "$reply" | tail -n 1)
      body=$(printf '%s' "$reply" | sed '$d')
      case "$code" in
        200) printf '%s' "$body" | ca_usage_normalize || { echo unexpected >&2; return 1; }; return 0 ;;
        401 | 403) echo expired >&2; return 1 ;;
        429) echo throttled >&2; return 1 ;;   # also what an expired token gets
      esac
    fi
    [ "$attempt" -lt 2 ] || { echo unreachable >&2; return 1; }
  done
}

# ca_usage_token <id>: that account's access token, renewing a saved account's
# expired login first. Prints the failure word on stderr and fails otherwise.
ca_usage_token() {
  local active record why attempt=0
  active=$(ca_active_id 2>/dev/null || true)
  if [ "$1" = "$active" ] && ca_store_present; then
    ca_store_read | jq -r '.claudeAiOauth.accessToken // empty'
    return
  fi
  record=$(ca_vault_get "$1") || { echo expired >&2; return 1; }
  if ca_oauth_expired "$record"; then
    # A stalled connection is tried once more; the lock is free in between.
    until why=$(ca_oauth_renew_vault "$1" 2>&1 >/dev/null); do
      attempt=$((attempt + 1))
      if [ "$why" != unreachable ] || [ "$attempt" -ge 2 ]; then
        case "$why" in invalid_grant | disabled | active) echo expired >&2 ;; *) echo "${why:-unreachable}" >&2 ;; esac
        return 1
      fi
    done
    record=$(ca_vault_get "$1") || { echo expired >&2; return 1; }
  fi
  printf '%s' "$record" | jq -r '.claudeAiOauth.accessToken // empty'
}

# ca_usage_refresh [--if-older-than N] [id ...]: ask the endpoint for each account
# and store what comes back. Accounts are asked in parallel. Prints one line per
# account that could not be read. Never fails the caller.
ca_usage_refresh() {
  local max_age=0 ids="" id token dir now line status
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
    # Each account on its own, so a renewal holds nobody else up. Renewals take
    # the command lock one at a time, network call included, so one may queue.
    (
      # shellcheck disable=SC2034  # read by ca_lock (util.sh)
      CA_LOCK_TRIES=300
      if token=$(ca_usage_token "$id" 2>"$dir/$id.err") && [ -n "$token" ]; then
        ca_usage_get "$token" >"$dir/$id.json" 2>"$dir/$id.err"
      else
        [ -s "$dir/$id.err" ] || printf 'expired\n' >"$dir/$id.err"
        : >"$dir/$id.json"  # an empty answer, so the report below sees this account
      fi
    ) &
  done
  wait

  for id in $ids; do
    [ -f "$dir/$id.json" ] || continue
    if [ -s "$dir/$id.json" ]; then
      # shellcheck disable=SC2016  # a jq filter: its $names are jq variables
      if ca_rl_update '.accounts[$aid] = ((.accounts[$aid] // {}) + $new + {fetchedAt: $now, source: "api"})' \
        --arg aid "$id" --argjson new "$(cat "$dir/$id.json")" --argjson now "$now" 2>/dev/null; then
        CA_USAGE_STORED=1
      fi
    else
      status=$(head -n 1 "$dir/$id.err" 2>/dev/null)
      case "$status" in
        expired) line="login expired — /login to it again, then click ＋ save" ;;
        throttled) line="Anthropic is throttling this login's requests; trying again later" ;;
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

# claude-acct round auto <lock-dir> | round switch: the background work, as a
# process of its own so that the lock it takes names a pid that lives as long as
# the lock is held. Not in the usage text; nothing to call by hand.
ca_cmd_round() {
  case "${1:-}${2:+ x}" in
    "auto x") ca_usage_round "$2" ;;
    switch) ca_usage_refresh --if-older-than "$CA_USAGE_FRESH_SECONDS" >/dev/null 2>&1 || true ;;
    *) ca_die "usage: claude-acct round auto <lock-dir> | round switch" ;;
  esac
}

# ca_usage_round: one background round — the limits of every account (unless
# CLAUDE_ACCT_AUTO_REFRESH=0 turns the network lookups off) and, always, the
# saved copy of the active account's tokens.
ca_usage_round() {  # ca_usage_round <lock-dir>
  if [ "${CLAUDE_ACCT_AUTO_REFRESH:-1}" != 0 ]; then
    ca_usage_refresh >/dev/null 2>&1 || true
    [ "${CA_USAGE_STORED:-0}" = 1 ] && ca_settings_poke
  fi
  (ca_lock; ca_sync_active) >/dev/null 2>&1 || true
  rmdir "$1" 2>/dev/null || true
  return 0
}

# ca_usage_maybe_refresh: called from the status line. Runs a round at most
# every CA_USAGE_AUTO_SECONDS, in a detached process so the status line never
# waits for the network. Idle sessions get their round too, because waiting for
# a limit to reset is exactly when the countdown matters.
ca_usage_maybe_refresh() {
  local now last lock
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
  # shellcheck disable=SC2016  # a jq filter: its $names are jq variables
  ca_rl_update '.auto = {at: $now}' --argjson now "$now" >/dev/null 2>&1 || true

  if [ "${CA_USAGE_SYNC:-0}" = 1 ]; then
    ca_usage_round "$lock"
  else
    "$(ca_self)" round auto "$lock" >/dev/null 2>&1 </dev/null &
  fi
  return 0
}
