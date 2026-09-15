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
  # the active account s name and limits are one link, with the marker just before it
  assert_contains "$out" "● ${ESC}]8;;http://claude-acct.localhost/use/a1eeea2a${BEL}bob@example.com 5h 24%↻2h · 7d 5%↻3d${ESC}]8;;${BEL}"
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
  # the colour opens before the marker and the link starts after it: Claude Code
  # writes a cell s link before its colour, and JediTerm keeps the style a link
  # started with, so this is the order that keeps the link orange there
  assert_contains "$out" "${esc}[1;38;2;217;119;87m● ${esc}]8;;http://claude-acct.localhost/use/a1eeea2a${BEL}bob@example.com 5h 24%↻2h · 7d 5%↻3d${esc}]8;;${BEL}${esc}[0m"
  # no underline anywhere, and the inactive account carries no SGR at all
  assert_not_contains "$out" "${esc}[4m"
  assert_contains "$out" "${BEL}alice@example.com${esc}]8;;"
}

test_falls_back_to_256_colours_without_truecolor() {
  two_accounts
  unset NO_COLOR
  assert_contains "$(printf '{}' | COLORTERM='' ca statusline)" "$(esc_ch)[1;38;5;173m● $(esc_ch)]8;;"
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

test_leftovers_are_recognised_by_their_windows_even_when_never_recorded() {
  two_accounts
  local now r5 r7
  now=$(date +%s); r5=$((now + 9000)); r7=$((now + 302400))
  # bob s windows are known from the endpoint; his numbers changed right before the
  # click, so no status line ever recorded that last signature
  # shellcheck disable=SC2016  # a jq filter: its $names are jq variables
  ca_lib ca_rl_update '.accounts["a1eeea2a"] = {five_hour: {used_percentage: 30, resets_at: $r5}, seven_day: {used_percentage: 20, resets_at: $r7}, fetchedAt: $now, source: "api"}' \
    --argjson r5 "$r5" --argjson r7 "$r7" --argjson now "$now" >/dev/null
  ca use alice@example.com >/dev/null
  # the session and the endpoint round the same reset time a second apart
  session 33 $((r5 - 1)) 28 $((r7 + 1)) | ca statusline >/dev/null
  assert_eq "$(ca_lib ca_rl_read | jq -r '.accounts["33084eab"].five_hour // "none"')" "none"
  # alice s own windows differ: hers are recorded
  session 2 $((now + 19800)) 1 $((now + 388800)) | ca statusline >/dev/null
  assert_eq "$(ca_lib ca_rl_read | jq -r '.accounts["33084eab"].five_hour.used_percentage')" "2"
}

test_a_quick_switch_back_and_forth_files_nothing_under_the_wrong_account() {
  two_accounts
  local now
  now=$(date +%s)
  session 33 $((now + 9000)) 28 $((now + 302400)) | ca statusline >/dev/null   # bob s own numbers
  ca use alice@example.com >/dev/null
  session 33 $((now + 9000)) 28 $((now + 302400)) | ca statusline >/dev/null   # still bob s
  ca use bob@example.com >/dev/null
  session 33 $((now + 9000)) 28 $((now + 302400)) | ca statusline >/dev/null
  assert_eq "$(ca_lib ca_rl_read | jq -r '.accounts["33084eab"].five_hour // "none"')" "none"
  assert_eq "$(ca_lib ca_rl_read | jq -r '.accounts["a1eeea2a"].five_hour.used_percentage')" "33"
}

test_a_login_by_hand_is_a_switch_too() {
  two_accounts
  local now
  now=$(date +%s)
  session 40 $((now + 9000)) 12 $((now + 302400)) | ca statusline >/dev/null   # bob s numbers
  cc_login alice   # /login by hand: nothing recorded a switch
  session 40 $((now + 9000)) 12 $((now + 302400)) | ca statusline >/dev/null   # still bob s
  assert_eq "$(ca_lib ca_rl_read | jq -r '.accounts["33084eab"].five_hour // "none"')" "none"
  session 3 $((now + 12000)) 1 $((now + 400000)) | ca statusline >/dev/null
  assert_eq "$(ca_lib ca_rl_read | jq -r '.accounts["33084eab"].five_hour.used_percentage')" "3"
  assert_eq "$(ca_lib ca_rl_read | jq -r '.accounts["a1eeea2a"].five_hour.used_percentage')" "40"
}

test_only_the_previous_account_s_last_numbers_count_as_leftovers() {
  two_accounts
  local now
  now=$(date +%s)
  # bob once showed 0/0, but the numbers it left behind are 50/10
  printf '{"rate_limits":{"five_hour":{"used_percentage":0,"resets_at":null},"seven_day":{"used_percentage":0,"resets_at":null}}}' |
    ca statusline >/dev/null
  session 50 $((now + 9000)) 10 $((now + 302400)) | ca statusline >/dev/null
  ca use alice@example.com >/dev/null
  # the first numbers after the switch are bob s leftovers (50/10) ...
  session 50 $((now + 9000)) 10 $((now + 302400)) | ca statusline >/dev/null
  assert_eq "$(ca_lib ca_rl_read | jq -r '.accounts["33084eab"].five_hour // "none"')" "none"
  # ... and the very same 0/0 bob once showed is, when it comes next, alice s own
  printf '{"rate_limits":{"five_hour":{"used_percentage":0,"resets_at":null},"seven_day":{"used_percentage":0,"resets_at":null}}}' |
    ca statusline >/dev/null
  assert_eq "$(ca_lib ca_rl_read | jq -r '.accounts["33084eab"].five_hour.used_percentage')" "0"
}

seven_day_only() {  # seven_day_only <7d %> <7d resets_at>: a session that has no 5h window
  jq -cn --argjson c "$1" --argjson d "$2" '{rate_limits: {seven_day: {used_percentage: $c, resets_at: $d}}}'
}

three_accounts() {  # alice, bob, carol; bob active
  two_accounts
  cc_login carol
  ca save >/dev/null
  ca use bob@example.com >/dev/null
}

test_leftovers_of_an_account_left_several_switches_ago_are_recognised() {
  three_accounts
  local now carol
  now=$(date +%s)
  carol=$(ca_lib ca_index_find carol@example.com)
  session 5 $((now + 6600)) 44 $((now + 400000)) | ca statusline >/dev/null   # bob s own numbers
  ca use alice@example.com >/dev/null
  session 5 $((now + 6600)) 44 $((now + 400000)) | ca statusline >/dev/null   # no response since: still bob s
  ca use carol@example.com >/dev/null
  session 5 $((now + 6600)) 44 $((now + 400000)) | ca statusline >/dev/null   # and still bob s
  assert_eq "$(ca_lib ca_rl_read | jq -r --arg id "$carol" '.accounts[$id].five_hour // "none"')" "none"
}

test_another_session_s_older_numbers_are_recognised_by_the_window_they_share() {
  two_accounts
  local now r5 r7
  now=$(date +%s); r5=$((now + 6600)); r7=$((now + 400000))
  # two open sessions: one last heard from bob before his 5h window started, the
  # other just now, and the other one s numbers are the last recorded
  seven_day_only 42 "$r7" | ca statusline >/dev/null
  session 5 "$r5" 44 "$r7" | ca statusline >/dev/null
  ca use alice@example.com >/dev/null
  seven_day_only 42 "$r7" | ca statusline >/dev/null   # the first session, still bob s
  assert_eq "$(ca_lib ca_rl_read | jq -r '.accounts["33084eab"].seven_day // "none"')" "none"
}

test_a_window_that_has_reset_since_does_not_hide_whose_leftovers_they_are() {
  three_accounts
  local now carol
  now=$(date +%s)
  carol=$(ca_lib ca_index_find carol@example.com)
  # a session last heard from bob while his previous 5h window was running ...
  session 70 $((now - 600)) 44 $((now + 400000)) | ca statusline >/dev/null
  # ... and the endpoint has seen his new one since
  # shellcheck disable=SC2016  # a jq filter: its $names are jq variables
  ca_lib ca_rl_update '.accounts["a1eeea2a"] += {five_hour: {used_percentage: 3, resets_at: $r5}, fetchedAt: $now, source: "api"}' \
    --argjson r5 $((now + 17400)) --argjson now "$now" >/dev/null
  ca use alice@example.com >/dev/null
  session 70 $((now - 600)) 44 $((now + 400000)) | ca statusline >/dev/null   # no response since: still bob s
  ca use carol@example.com >/dev/null
  session 70 $((now - 600)) 44 $((now + 400000)) | ca statusline >/dev/null   # and still bob s
  assert_eq "$(ca_lib ca_rl_read | jq -r --arg id "$carol" '.accounts[$id].seven_day // "none"')" "none"
}
