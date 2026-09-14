# shellcheck shell=bash

two_accounts() {
  cc_login alice
  ca save >/dev/null
  cc_login bob
  ca save >/dev/null
}

session() {  # session <5h %> <5h resets_at> <7d %> <7d resets_at>
  jq -cn --argjson a "$1" --argjson b "$2" --argjson c "$3" --argjson d "$4" \
    '{rate_limits: {five_hour: {used_percentage: $a, resets_at: $b}, seven_day: {used_percentage: $c, resets_at: $d}}}'
}

ESC=$(printf '\033')
BEL=$(printf '\007')

strip_links() { strip_style; }

test_row_lists_accounts_with_links_and_live_limits() {
  two_accounts
  local now out
  now=$(date +%s)
  out=$(session 24 $((now + 9000)) 5 $((now + 302400)) | ca statusline)
  assert_contains "$out" "${ESC}]8;;http://claude-acct.localhost/use/33084eab${BEL}alice@example.com${ESC}]8;;${BEL}"
  # the active account s whole segment, limits included, is one link
  assert_contains "$out" "${ESC}]8;;http://claude-acct.localhost/use/a1eeea2a${BEL}● bob@example.com 5h 24%↻2h · 7d 5%↻3d${ESC}]8;;${BEL}"
  assert_eq "$(printf '%s' "$out" | row_accounts)" \
    "alice@example.com  │  ● bob@example.com 5h 24%↻2h · 7d 5%↻3d"
  assert_not_contains "$(printf '%s' "$out" | row_controls)" "＋"
}

test_limits_stick_to_the_account_that_produced_them() {
  two_accounts
  local now out
  now=$(date +%s)
  session 80 $((now + 3600)) 30 $((now + 86400)) | ca statusline >/dev/null
  ca use alice@example.com >/dev/null
  out=$(session 80 $((now + 3600)) 30 $((now + 86400)) | ca statusline | strip_links)
  assert_contains "$out" "● alice@example.com  │"
  assert_contains "$out" "bob@example.com 5h 80%↻"
  out=$(session 3 $((now + 19800)) 1 $((now + 500000)) | ca statusline | strip_links)
  assert_contains "$out" "● alice@example.com 5h 3%↻5h · 7d 1%↻5d"
  assert_contains "$out" "bob@example.com 5h 80%↻"
}

test_expired_windows_are_hidden() {
  two_accounts
  local now
  now=$(date +%s)
  session 90 $((now - 10)) 40 $((now - 10)) | ca statusline >/dev/null
  ca use alice@example.com >/dev/null
  assert_not_contains "$(printf '{}' | ca statusline | strip_links)" "90%"
}

test_unsaved_active_account_offers_save() {
  cc_login alice
  assert_contains "$(printf '{}' | ca statusline | strip_links)" "＋ save"
}

test_prints_nothing_when_logged_out() {
  assert_eq "$(printf '{}' | ca statusline)" ""
}

test_runs_the_original_status_line_first() {
  cc_login alice
  ca save >/dev/null
  mkdir -p "$XDG_DATA_HOME/claude-acct"
  printf '{"originals":{"statusLine":{"type":"command","command":"jq -r .model.display_name"}}}' \
    >"$XDG_DATA_HOME/claude-acct/install.json"
  local out
  out=$(printf '{"model":{"display_name":"Opus"}}' | ca statusline)
  assert_eq "$(printf '%s\n' "$out" | strip_style | head -n 1)" "Opus"
  assert_contains "$(printf '%s\n' "$out" | row_accounts)" "● alice@example.com"
}

test_survives_garbage_input() {
  cc_login alice
  ca save >/dev/null
  assert_contains "$(printf 'not json' | ca statusline | strip_links)" "● alice@example.com"
}

test_active_account_keeps_its_last_known_limits_when_the_session_is_quiet() {
  two_accounts
  local now out
  now=$(date +%s)
  session 42 $((now + 9000)) 7 $((now + 302400)) | ca statusline >/dev/null
  # A new session reports no limits until its first response: show what we know.
  out=$(printf '{}' | ca statusline | strip_links)
  assert_contains "$out" "● bob@example.com 5h 42%↻2h · 7d 7%↻3d"
}

test_every_account_shows_its_reset_countdown() {
  two_accounts
  local now out
  now=$(date +%s)
  session 42 $((now + 9000)) 7 $((now + 302400)) | ca statusline >/dev/null
  ca use alice@example.com >/dev/null
  session 5 $((now + 19800)) 2 $((now + 388800)) | ca statusline >/dev/null
  out=$(session 5 $((now + 19800)) 2 $((now + 388800)) | ca statusline | strip_links)
  assert_contains "$out" "● alice@example.com 5h 5%↻5h · 7d 2%↻4d"
  assert_contains "$out" "bob@example.com 5h 42%↻2h · 7d 7%↻3d"
}

test_the_whole_active_segment_is_bold_and_orange_and_nothing_else_is_styled() {
  two_accounts
  unset NO_COLOR
  local now out esc
  now=$(date +%s)
  esc=$(esc_ch)
  out=$(session 24 $((now + 9000)) 5 $((now + 302400)) | COLORTERM=truecolor ca statusline)
  assert_contains "$out" "${esc}[1;38;2;217;119;87m● bob@example.com 5h 24%↻2h · 7d 5%↻3d${esc}[0m"
  # no underline anywhere, and the inactive account carries no SGR at all
  assert_not_contains "$out" "${esc}[4m"
  assert_contains "$out" "${BEL}alice@example.com${esc}]8;;"
}

test_falls_back_to_256_colours_without_truecolor() {
  two_accounts
  unset NO_COLOR
  assert_contains "$(printf '{}' | COLORTERM='' ca statusline)" "$(esc_ch)[1;38;5;173m● bob@example.com"
}

test_colour_is_dropped_when_the_terminal_does_not_want_it() {
  two_accounts
  local out
  out=$(printf '{}' | NO_COLOR=1 ca statusline)
  assert_not_contains "$out" "$(esc_ch)[1;"
  assert_contains "$out" "bob@example.com"
}

test_a_narrow_terminal_shortens_the_names_by_itself() {
  two_accounts
  assert_contains "$(printf '{}' | COLUMNS=40 ca statusline | row_accounts)" "● bob…"
  assert_contains "$(printf '{}' | COLUMNS=200 ca statusline | row_accounts)" "● bob@example.com"
}

test_collapse_and_expand_override_the_width() {
  two_accounts
  ca open-url "http://claude-acct.localhost/collapse"
  assert_contains "$(printf '{}' | COLUMNS=200 ca statusline | row_accounts)" "● bob…"
  assert_contains "$(printf '{}' | COLUMNS=200 ca statusline | row_controls)" "⤢ expand"
  ca open-url "http://claude-acct.localhost/expand"
  assert_contains "$(printf '{}' | COLUMNS=40 ca statusline | row_accounts)" "● bob@example.com"
  assert_contains "$(printf '{}' | COLUMNS=40 ca statusline | row_controls)" "⤡ collapse"
}

test_the_controls_are_on_their_own_row() {
  two_accounts
  local controls
  controls=$(printf '{}' | ca statusline | row_controls)
  assert_contains "$controls" "⤡ collapse"
  assert_contains "$controls" "↻ limits"
  # a saved active account needs no save button
  assert_not_contains "$controls" "＋"
  assert_not_contains "$controls" "bob@example.com"
}

test_a_multi_line_original_status_line_runs_intact() {
  cc_login alice
  ca save >/dev/null
  mkdir -p "$XDG_DATA_HOME/claude-acct"
  jq -n '{originals: {statusLine: {type: "command", command: "echo first\necho second"}}}' \
    >"$XDG_DATA_HOME/claude-acct/install.json"
  local out
  out=$(printf '{}' | ca statusline | strip_style)
  assert_eq "$(printf '%s\n' "$out" | sed -n 1,2p | tr '\n' ' ')" "first second "
  assert_contains "$(printf '%s\n' "$out" | row_accounts)" "● alice@example.com"
  # nothing of the command leaked into the state files
  [ ! -f "$XDG_DATA_HOME/claude-acct/ratelimits.json" ] || jq -e . "$XDG_DATA_HOME/claude-acct/ratelimits.json" >/dev/null
}

test_the_original_status_line_gets_a_newline_terminated_input() {
  cc_login alice
  ca save >/dev/null
  mkdir -p "$XDG_DATA_HOME/claude-acct"
  jq -n '{originals: {statusLine: {type: "command", command: "set -e; read -r line; echo \"got ${#line}\""}}}' \
    >"$XDG_DATA_HOME/claude-acct/install.json"
  assert_eq "$(printf '{"a":1}' | ca statusline | strip_style | head -n 1)" "got 7"
}
