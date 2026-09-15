# shellcheck shell=bash

# Answers the fake curl gives, keyed by the account's access token.
usage_reply() {  # usage_reply <token> <5h percent> <5h resets ISO|null> <7d percent> <7d resets ISO|null> [http code]
  mkdir -p "$T/curl"
  jq -n --argjson a "$2" --arg b "$3" --argjson c "$4" --arg d "$5" '{
    five_hour: {utilization: $a, resets_at: (if $b == "null" then null else $b end)},
    seven_day: {utilization: $c, resets_at: (if $d == "null" then null else $d end)},
    seven_day_opus: null}' >"$T/curl/$1.json"
  printf '%s' "${6:-200}" >"$T/curl/$1.code"
  export FAKE_CURL_DIR="$T/curl"
}

two_accounts() {
  cc_login alice
  ca save >/dev/null
  cc_login bob
  ca save >/dev/null
}

iso() { # iso <seconds from now>
  local t=$(( $(date +%s) + $1 ))
  if date -u -r "$t" '+%Y-%m-%dT%H:%M:%S+00:00' 2>/dev/null; then :; else date -u -d "@$t" '+%Y-%m-%dT%H:%M:%S+00:00'; fi
}

test_normalize_converts_percent_and_iso_timestamps() {
  local out
  out=$(printf '%s' '{"five_hour":{"utilization":6.0,"resets_at":"2026-09-13T23:20:00.216731+00:00"},
                      "seven_day":{"utilization":10.0,"resets_at":"2026-09-19T16:00:00Z"}}' |
    ca_lib ca_usage_normalize)
  assert_eq "$(printf '%s' "$out" | jq -c '[.five_hour.used_percentage, .five_hour.resets_at]')" "[6,1789341600]"
  assert_eq "$(printf '%s' "$out" | jq -c '[.seven_day.used_percentage, .seven_day.resets_at]')" "[10,1789833600]"
}

test_normalize_keeps_a_window_that_has_not_started() {
  local out
  out=$(printf '%s' '{"five_hour":{"utilization":0.0,"resets_at":null},"seven_day":null}' | ca_lib ca_usage_normalize)
  assert_eq "$(printf '%s' "$out" | jq -c '.five_hour')" '{"used_percentage":0,"resets_at":null}'
  assert_eq "$(printf '%s' "$out" | jq -c '.seven_day')" "null"
}

test_normalize_rejects_junk() {
  assert_fails ca_lib ca_usage_normalize <<<'not json'
  assert_fails ca_lib ca_usage_normalize <<<'{"error":{"type":"authentication_error"}}'
}

test_refresh_stores_limits_for_every_account() {
  two_accounts
  usage_reply at-alice 12 "$(iso 9000)" 30 "$(iso 302400)"
  usage_reply at-bob 45 "$(iso 3600)" 60 "$(iso 86400)"
  ca refresh >/dev/null
  local rl
  rl=$(ca_lib ca_rl_read)
  assert_eq "$(printf '%s' "$rl" | jq -r '.accounts["33084eab"].five_hour.used_percentage')" "12"
  assert_eq "$(printf '%s' "$rl" | jq -r '.accounts["a1eeea2a"].seven_day.used_percentage')" "60"
  assert_eq "$(printf '%s' "$rl" | jq -r '.accounts["33084eab"].source')" "api"
}

test_refreshed_limits_show_for_every_account_in_the_row() {
  two_accounts
  usage_reply at-alice 12 "$(iso 9000)" 30 "$(iso 302400)"
  usage_reply at-bob 45 "$(iso 19800)" 60 "$(iso 388800)"
  ca refresh >/dev/null
  local out
  out=$(printf '{}' | ca statusline | sed -e "s/$(printf '\033')]8;;[^$(printf '\007')]*$(printf '\007')//g")
  assert_contains "$out" "alice@example.com 5h 12%↻2h · 7d 30%↻3d"
  assert_contains "$out" "● bob@example.com 5h 45%↻5h · 7d 60%↻4d"
}

test_window_that_has_not_started_shows_zero_without_a_countdown() {
  two_accounts
  usage_reply at-alice 0 null 0 "$(iso 302400)"
  usage_reply at-bob 0 null 0 null
  ca refresh >/dev/null
  local out
  out=$(printf '{}' | ca statusline | sed -e "s/$(printf '\033')]8;;[^$(printf '\007')]*$(printf '\007')//g")
  assert_contains "$out" "alice@example.com 5h 0% · 7d 0%↻3d"
}

test_refresh_reports_an_account_whose_token_no_longer_works() {
  two_accounts
  usage_reply at-alice 12 "$(iso 9000)" 30 "$(iso 302400)"
  # bob has no canned answer, so the fake curl replies 401
  local out
  out=$(ca refresh 2>&1 || true)
  assert_contains "$out" "bob@example.com: login expired"
  assert_contains "$out" "alice@example.com"
  assert_eq "$(ca_lib ca_rl_read | jq -r '.accounts["33084eab"].five_hour.used_percentage')" "12"
}

test_refresh_survives_a_network_failure() {
  two_accounts
  export FAKE_CURL_DIR=/nonexistent
  ca refresh >/dev/null 2>&1 || true
  assert_contains "$(printf '{}' | ca statusline)" "bob@example.com"
}

test_switching_refreshes_all_accounts() {
  two_accounts
  usage_reply at-alice 12 "$(iso 9000)" 30 "$(iso 302400)"
  usage_reply at-bob 45 "$(iso 19800)" 60 "$(iso 388800)"
  CA_USAGE_SYNC=1 ca use alice@example.com >/dev/null
  assert_eq "$(ca_lib ca_rl_read | jq -r '.accounts["a1eeea2a"].five_hour.used_percentage')" "45"
}

test_switching_does_not_refetch_what_was_just_fetched() {
  two_accounts
  usage_reply at-alice 12 "$(iso 9000)" 30 "$(iso 302400)"
  usage_reply at-bob 45 "$(iso 19800)" 60 "$(iso 388800)"
  ca refresh >/dev/null
  : >"$FAKE_LOG"
  CA_USAGE_SYNC=1 ca use alice@example.com >/dev/null
  assert_eq "$(grep -c '^curl url=' "$FAKE_LOG" || true)" "0"
}

test_explicit_refresh_always_refetches() {
  two_accounts
  usage_reply at-alice 12 "$(iso 9000)" 30 "$(iso 302400)"
  usage_reply at-bob 45 "$(iso 19800)" 60 "$(iso 388800)"
  ca refresh >/dev/null
  : >"$FAKE_LOG"
  ca refresh >/dev/null
  assert_eq "$(grep -c '^curl url=' "$FAKE_LOG" || true)" "2"
}

test_refresh_link_in_the_row_triggers_a_refresh() {
  two_accounts
  usage_reply at-alice 12 "$(iso 9000)" 30 "$(iso 302400)"
  usage_reply at-bob 45 "$(iso 19800)" 60 "$(iso 388800)"
  assert_contains "$(printf '{}' | ca statusline)" "http://claude-acct.localhost/refresh"
  ca open-url "http://claude-acct.localhost/refresh"
  assert_eq "$(ca_lib ca_rl_read | jq -r '.accounts["33084eab"].five_hour.used_percentage')" "12"
}

test_the_token_never_reaches_the_process_list() {
  two_accounts
  usage_reply at-alice 12 "$(iso 9000)" 30 "$(iso 302400)"
  usage_reply at-bob 45 "$(iso 19800)" 60 "$(iso 388800)"
  ca refresh >/dev/null
  # It has to arrive somehow, but through curl's stdin config, never through argv.
  assert_contains "$(grep '^curl url=' "$FAKE_LOG")" "token=at-alice"
  assert_not_contains "$(grep '^curl argv=' "$FAKE_LOG")" "at-alice"
}

test_the_status_line_does_not_wipe_what_the_endpoint_reported() {
  two_accounts
  usage_reply at-alice 12 "$(iso 9000)" 30 "$(iso 302400)"
  usage_reply at-bob 45 "$(iso 19800)" 60 "$(iso 388800)"
  ca refresh >/dev/null
  local now
  now=$(date +%s)
  # bob s own windows: the same ones the endpoint reported for him
  jq -cn --argjson a 7 --argjson b "$((now + 19800))" --argjson c 8 --argjson d "$((now + 388800))" \
    '{rate_limits: {five_hour: {used_percentage: $a, resets_at: $b}, seven_day: {used_percentage: $c, resets_at: $d}}}' |
    ca statusline >/dev/null
  local entry
  entry=$(ca_lib ca_rl_read | jq -c '.accounts["a1eeea2a"]')
  assert_eq "$(printf '%s' "$entry" | jq -r '.five_hour.used_percentage')" "7"
  assert_eq "$(printf '%s' "$entry" | jq -r '.source')" "session"
  assert_eq "$(printf '%s' "$entry" | jq -r '.fetchedAt > 0')" "true"
}

test_the_status_line_refreshes_by_itself_every_five_minutes() {
  two_accounts
  usage_reply at-alice 12 "$(iso 9000)" 30 "$(iso 302400)"
  usage_reply at-bob 45 "$(iso 19800)" 60 "$(iso 388800)"
  printf '{}' | CLAUDE_ACCT_AUTO_REFRESH=1 CA_USAGE_SYNC=1 ca statusline >/dev/null
  assert_eq "$(ca_lib ca_rl_read | jq -r '.accounts["33084eab"].five_hour.used_percentage')" "12"

  # A second run right away must not ask again.
  : >"$FAKE_LOG"
  printf '{}' | CLAUDE_ACCT_AUTO_REFRESH=1 CA_USAGE_SYNC=1 ca statusline >/dev/null
  assert_eq "$(grep -c '^curl url=' "$FAKE_LOG" || true)" "0"

  # Five minutes later it does, even though the session did nothing in between:
  # waiting for a reset is exactly when the countdown has to keep moving.
  local rl
  rl=$(ca_lib ca_rl_read | jq -c '.auto.at -= 301')
  printf '%s\n' "$rl" >"$XDG_DATA_HOME/claude-acct/ratelimits.json"
  printf '{}' | CLAUDE_ACCT_AUTO_REFRESH=1 CA_USAGE_SYNC=1 ca statusline >/dev/null
  assert_eq "$(grep -c '^curl url=' "$FAKE_LOG" || true)" "2"
}

test_auto_refresh_can_be_turned_off() {
  two_accounts
  usage_reply at-alice 12 "$(iso 9000)" 30 "$(iso 302400)"
  usage_reply at-bob 45 "$(iso 19800)" 60 "$(iso 388800)"
  : >"$FAKE_LOG"
  printf '{}' | CLAUDE_ACCT_AUTO_REFRESH=0 CA_USAGE_SYNC=1 ca statusline >/dev/null
  assert_eq "$(grep -c '^curl url=' "$FAKE_LOG" || true)" "0"
}

test_the_status_line_does_not_wait_for_the_network() {
  two_accounts
  usage_reply at-alice 12 "$(iso 9000)" 30 "$(iso 302400)"
  usage_reply at-bob 45 "$(iso 19800)" 60 "$(iso 388800)"
  local start elapsed
  start=$(date +%s)
  printf '{}' | FAKE_CURL_SLEEP=5 CLAUDE_ACCT_AUTO_REFRESH=1 CA_USAGE_SYNC=0 ca statusline >/dev/null
  elapsed=$(( $(date +%s) - start ))
  [ "$elapsed" -lt 3 ] || fail "the status line waited ${elapsed}s for a background refresh"
  wait 2>/dev/null || true
}

test_a_background_refresh_pokes_the_status_line_once_it_has_numbers() {
  "$ROOT/install.sh" >/dev/null
  two_accounts
  usage_reply at-alice 12 "$(iso 9000)" 30 "$(iso 302400)"
  usage_reply at-bob 45 "$(iso 19800)" 60 "$(iso 388800)"
  local before
  before=$(jq -r .statusLine.command "$HOME/.claude/settings.json")
  printf '{}' | CLAUDE_ACCT_AUTO_REFRESH=1 CA_USAGE_SYNC=1 ca statusline >/dev/null
  [ "$(jq -r .statusLine.command "$HOME/.claude/settings.json")" != "$before" ] ||
    fail "a refresh that stored new numbers did not poke the status line"

  # A refresh that stored nothing (every token rejected) keeps quiet.
  before=$(jq -r .statusLine.command "$HOME/.claude/settings.json")
  export FAKE_CURL_DIR=/nonexistent
  jq -c '.auto.at -= 301' "$XDG_DATA_HOME/claude-acct/ratelimits.json" >"$T/rl" &&
    mv "$T/rl" "$XDG_DATA_HOME/claude-acct/ratelimits.json"
  printf '{}' | CLAUDE_ACCT_AUTO_REFRESH=1 CA_USAGE_SYNC=1 ca statusline >/dev/null
  assert_eq "$(jq -r .statusLine.command "$HOME/.claude/settings.json")" "$before"
}

test_the_background_round_keeps_the_saved_copy_of_the_active_account_current() {
  two_accounts
  # Claude Code rotated bob s tokens while bob was in use; /login elsewhere would drop them
  cc_refresh bob2
  printf '{}' | CLAUDE_ACCT_AUTO_REFRESH=1 CA_USAGE_SYNC=1 ca statusline >/dev/null
  assert_eq "$(ca_lib ca_vault_get a1eeea2a | jq -r .claudeAiOauth.refreshToken)" "rt-bob2"
  assert_contains "$(cat "$XDG_DATA_HOME/claude-acct/claude-acct.log")" "sync a1eeea2a"
  # unchanged tokens are left alone
  jq -c '.auto.at -= 301' "$XDG_DATA_HOME/claude-acct/ratelimits.json" >"$T/rl" && mv "$T/rl" "$XDG_DATA_HOME/claude-acct/ratelimits.json"
  printf '{}' | CLAUDE_ACCT_AUTO_REFRESH=1 CA_USAGE_SYNC=1 ca statusline >/dev/null
  assert_eq "$(grep -c 'sync a1eeea2a' "$XDG_DATA_HOME/claude-acct/claude-acct.log")" "1"
}

test_the_background_round_does_not_touch_an_unsaved_active_account() {
  cc_login alice
  ca save >/dev/null
  cc_login carol
  printf '{}' | CLAUDE_ACCT_AUTO_REFRESH=1 CA_USAGE_SYNC=1 ca statusline >/dev/null
  assert_fails ca_lib ca_vault_get "$(ca_lib ca_account_id acc-carol:org-carol)"
  assert_not_contains "$(cat "$XDG_DATA_HOME/claude-acct/claude-acct.log")" "sync"
}

test_refresh_reports_an_account_whose_saved_copy_has_no_access_token() {
  two_accounts
  usage_reply at-bob 45 "$(iso 19800)" 60 "$(iso 388800)"
  ca_lib ca_vault_get 33084eab | jq -c 'del(.claudeAiOauth.accessToken)' | ca_lib ca_vault_put 33084eab
  assert_contains "$(ca refresh 2>&1 || true)" "alice@example.com: login expired"
}

test_turning_lookups_off_keeps_the_token_re_save() {
  two_accounts
  cc_refresh bob2
  : >"$FAKE_LOG"
  printf '{}' | CLAUDE_ACCT_AUTO_REFRESH=0 CA_USAGE_SYNC=1 ca statusline >/dev/null
  assert_eq "$(grep -c '^curl url=' "$FAKE_LOG" || true)" "0"
  assert_eq "$(ca_lib ca_vault_get a1eeea2a | jq -r .claudeAiOauth.refreshToken)" "rt-bob2"
}

# The fake token endpoint answers renew_<refresh token>.json; the vault fixture s
# tokens expire far in the future, so these tests expire them first.
expire_vault() {  # expire_vault <id>
  ca_lib ca_vault_get "$1" | jq -c '.claudeAiOauth.expiresAt = 1' | ca_lib ca_vault_put "$1"
}
renew_reply() {  # renew_reply <old refresh token> <new suffix>
  mkdir -p "$T/curl"; export FAKE_CURL_DIR="$T/curl"
  jq -n --arg s "$2" '{access_token: ("at-" + $s), refresh_token: ("rt-" + $s), expires_in: 28800,
                       scope: "user:inference user:profile", token_type: "Bearer"}' >"$T/curl/renew_$1.json"
}

test_an_expired_saved_login_is_renewed_before_its_limits_are_asked_for() {
  two_accounts
  expire_vault 33084eab
  renew_reply rt-alice alice-new
  usage_reply at-alice-new 12 "$(iso 9000)" 30 "$(iso 302400)"
  usage_reply at-bob 45 "$(iso 19800)" 60 "$(iso 388800)"
  ca refresh >/dev/null 2>&1
  local rec
  rec=$(ca_lib ca_vault_get 33084eab)
  assert_eq "$(printf '%s' "$rec" | jq -r .claudeAiOauth.accessToken)" "at-alice-new"
  assert_eq "$(printf '%s' "$rec" | jq -r .claudeAiOauth.refreshToken)" "rt-alice-new"
  [ "$(printf '%s' "$rec" | jq -r .claudeAiOauth.expiresAt)" -gt "$(( $(date +%s) * 1000 ))" ] || fail "expiresAt not moved forward"
  assert_eq "$(ca_lib ca_rl_read | jq -r '.accounts["33084eab"].five_hour.used_percentage')" "12"
  assert_contains "$(cat "$XDG_DATA_HOME/claude-acct/claude-acct.log")" "token renewed 33084eab"
  # the new tokens were filed before the usage call used them
  local renew_at use_at
  renew_at=$(grep -n 'renew rt=rt-alice' "$FAKE_LOG" | head -1 | cut -d: -f1)
  use_at=$(grep -n 'token=at-alice-new' "$FAKE_LOG" | head -1 | cut -d: -f1)
  if [ -z "$renew_at" ] || [ -z "$use_at" ] || [ "$renew_at" -ge "$use_at" ]; then
    fail "renewal ($renew_at) did not precede use ($use_at)"
  fi
}

test_a_login_that_can_no_longer_be_renewed_is_reported_and_left_alone() {
  two_accounts
  expire_vault 33084eab          # no renew_ answer prepared: the endpoint says invalid_grant
  usage_reply at-bob 45 "$(iso 19800)" 60 "$(iso 388800)"
  assert_contains "$(ca refresh 2>&1 || true)" "alice@example.com: login expired"
  assert_eq "$(ca_lib ca_vault_get 33084eab | jq -r .claudeAiOauth.refreshToken)" "rt-alice"
}

test_the_active_account_is_never_renewed_by_claude_acct() {
  two_accounts
  cc_store_get | jq -c '.claudeAiOauth.expiresAt = 1' | cc_store_put   # bob s live token looks expired
  renew_reply rt-bob bob-new
  usage_reply at-bob 45 "$(iso 19800)" 60 "$(iso 388800)"
  usage_reply at-alice 12 "$(iso 9000)" 30 "$(iso 302400)"
  ca refresh >/dev/null 2>&1
  assert_not_contains "$(cat "$FAKE_LOG")" "renew rt=rt-bob"
  assert_eq "$(live_rt)" "rt-bob"
}

test_renewal_can_be_turned_off() {
  two_accounts
  expire_vault 33084eab
  renew_reply rt-alice alice-new
  usage_reply at-bob 45 "$(iso 19800)" 60 "$(iso 388800)"
  local out
  out=$(CLAUDE_ACCT_TOKEN_REFRESH=0 ca refresh 2>&1 || true)
  assert_contains "$out" "alice@example.com: login expired"
  assert_not_contains "$(cat "$FAKE_LOG")" "renew rt="
}

test_the_refresh_token_never_reaches_the_process_list() {
  two_accounts
  expire_vault 33084eab
  renew_reply rt-alice alice-new
  usage_reply at-alice-new 12 "$(iso 9000)" 30 "$(iso 302400)"
  ca refresh >/dev/null 2>&1
  assert_contains "$(grep '^curl renew' "$FAKE_LOG")" "rt=rt-alice"
  assert_not_contains "$(grep '^curl argv=' "$FAKE_LOG")" "rt-alice"
}

test_a_throttled_login_is_told_apart_from_an_unreachable_endpoint() {
  two_accounts
  usage_reply at-alice 12 "$(iso 9000)" 30 "$(iso 302400)" 429
  assert_contains "$(ca refresh 2>&1 || true)" "alice@example.com: Anthropic is throttling"
}

test_numbers_older_than_an_hour_show_as_unknown() {
  two_accounts
  usage_reply at-alice 12 "$(iso 9000)" 30 "$(iso 302400)"
  usage_reply at-bob 45 "$(iso 19800)" 60 "$(iso 388800)"
  ca refresh >/dev/null
  ca_lib ca_rl_update '.accounts["33084eab"].fetchedAt -= 3601' >/dev/null
  local out
  out=$(printf '{}' | ca statusline | strip_style)
  assert_contains "$out" "alice@example.com ?"
  assert_contains "$out" "● bob@example.com 5h 45%"
}

test_a_connection_that_stalls_once_is_tried_again() {
  two_accounts
  usage_reply at-alice 12 "$(iso 9000)" 30 "$(iso 302400)"
  usage_reply at-bob 45 "$(iso 19800)" 60 "$(iso 388800)"
  : >"$T/curl/at-alice.stall"
  ca refresh >/dev/null 2>&1
  assert_eq "$(ca_lib ca_rl_read | jq -r '.accounts["33084eab"].five_hour.used_percentage')" "12"
  assert_eq "$(grep -c 'token=at-alice' "$FAKE_LOG" || true)" "2"
  assert_eq "$(grep -c 'token=at-bob' "$FAKE_LOG" || true)" "1"
}

test_a_gateway_error_is_tried_once_more_then_reported() {
  two_accounts
  usage_reply at-alice 12 "$(iso 9000)" 30 "$(iso 302400)" 502
  usage_reply at-bob 45 "$(iso 19800)" 60 "$(iso 388800)"
  local out
  out=$(ca refresh 2>&1 >/dev/null)
  assert_contains "$out" "alice@example.com: could not be reached"
  assert_eq "$(grep -c 'token=at-alice' "$FAKE_LOG" || true)" "2"
  assert_eq "$(ca_lib ca_rl_read | jq -r '.accounts["a1eeea2a"].five_hour.used_percentage')" "45"
}

test_a_stalled_renewal_is_tried_again() {
  two_accounts
  expire_vault 33084eab
  renew_reply rt-alice alice-new
  : >"$T/curl/renew_rt-alice.stall"
  usage_reply at-alice-new 12 "$(iso 9000)" 30 "$(iso 302400)"
  usage_reply at-bob 45 "$(iso 19800)" 60 "$(iso 388800)"
  ca refresh >/dev/null 2>&1
  assert_eq "$(ca_lib ca_vault_get 33084eab | jq -r .claudeAiOauth.accessToken)" "at-alice-new"
  assert_eq "$(ca_lib ca_rl_read | jq -r '.accounts["33084eab"].five_hour.used_percentage')" "12"
  assert_eq "$(grep -c 'renew rt=rt-alice' "$FAKE_LOG" || true)" "2"
}

test_the_round_command_does_the_background_work() {
  two_accounts
  usage_reply at-alice 12 "$(iso 9000)" 30 "$(iso 302400)"
  usage_reply at-bob 45 "$(iso 19800)" 60 "$(iso 388800)"
  local lock="$XDG_DATA_HOME/claude-acct/auto.lock"
  mkdir -p "$lock"
  CLAUDE_ACCT_AUTO_REFRESH=1 ca round auto "$lock"
  assert_eq "$(ca_lib ca_rl_read | jq -r '.accounts["33084eab"].five_hour.used_percentage')" "12"
  assert_fails test -d "$lock"
  assert_fails ca round 2>/dev/null
}

test_a_throttled_renewal_is_left_alone_for_a_while() {
  two_accounts
  expire_vault 33084eab
  renew_reply rt-alice alice-new
  printf 429 >"$T/curl/renew_rt-alice.code"
  usage_reply at-bob 45 "$(iso 19800)" 60 "$(iso 388800)"
  local out
  out=$(ca refresh 2>&1 >/dev/null)
  assert_contains "$out" "alice@example.com: Anthropic is throttling"
  assert_eq "$(grep -c 'renew rt=rt-alice' "$FAKE_LOG" || true)" "1"   # not tried again at once
  # nor in the next round, even though the endpoint would answer now
  rm "$T/curl/renew_rt-alice.code"
  ca refresh >/dev/null 2>&1
  assert_eq "$(grep -c 'renew rt=rt-alice' "$FAKE_LOG" || true)" "1"
  # once the wait is over, it is
  ca_lib ca_rl_update '.accounts["33084eab"].renewAfter = 1' >/dev/null
  usage_reply at-alice-new 12 "$(iso 9000)" 30 "$(iso 302400)"
  ca refresh >/dev/null 2>&1
  assert_eq "$(grep -c 'renew rt=rt-alice' "$FAKE_LOG" || true)" "2"
  assert_eq "$(ca_lib ca_rl_read | jq -r '.accounts["33084eab"].five_hour.used_percentage')" "12"
}

test_requests_say_who_they_are() {
  # Anthropic s edge answers a nameless client with 429 whatever it asks
  two_accounts
  expire_vault 33084eab
  renew_reply rt-alice alice-new
  usage_reply at-alice-new 12 "$(iso 9000)" 30 "$(iso 302400)"
  usage_reply at-bob 45 "$(iso 19800)" 60 "$(iso 388800)"
  ca refresh >/dev/null 2>&1
  assert_eq "$(grep -c '^curl ua=claude-acct/[0-9]' "$FAKE_LOG" || true)" "3"   # one renewal, two lookups
  assert_eq "$(grep -c '^curl ua=' "$FAKE_LOG" || true)" "3"
}
