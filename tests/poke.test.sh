# shellcheck shell=bash
# Claude Code re-runs the status line the moment statusLine.command changes.
# claude-acct uses that to refresh the row right after a click instead of polling.

install_it() { "$ROOT/install.sh" >/dev/null; }
cmd() { jq -r .statusLine.command "$HOME/.claude/settings.json"; }

test_poke_always_changes_the_command_and_never_repeats_a_value() {
  install_it
  local base a b c
  base=$(cmd)
  ca_lib ca_settings_poke; a=$(cmd)
  ca_lib ca_settings_poke; b=$(cmd)
  ca_lib ca_settings_poke; c=$(cmd)
  assert_contains "$a" "$base --tick "
  # every poke is a new value, so two pokes in quick succession can never add up
  # to "no change" for Claude Code's content-comparing settings watcher
  [ "$a" != "$b" ] && [ "$b" != "$c" ] && [ "$a" != "$c" ] || fail "pokes repeated a value: $a / $b / $c"
  assert_eq "$(printf '%s' "$c" | grep -c -- '--tick')" "1"
}

test_poke_changes_nothing_else_in_settings() {
  mkdir -p "$HOME/.claude"
  printf '{"model":"opus","env":{"X":"y"},"statusLine":{"type":"command","command":"old","padding":1}}' \
    >"$HOME/.claude/settings.json"
  install_it
  chmod 600 "$HOME/.claude/settings.json"
  ca_lib ca_settings_poke
  assert_eq "$(jq -r .model "$HOME/.claude/settings.json")" "opus"
  assert_eq "$(jq -r .env.X "$HOME/.claude/settings.json")" "y"
  assert_eq "$(jq -r .statusLine.padding "$HOME/.claude/settings.json")" "1"
  assert_eq "$(jq -r .statusLine.refreshInterval "$HOME/.claude/settings.json")" "10"
  assert_eq "$(ca_lib ca_file_mode "$HOME/.claude/settings.json" 644)" "600"
}

test_poke_leaves_a_foreign_status_line_alone() {
  mkdir -p "$HOME/.claude"
  printf '{"statusLine":{"type":"command","command":"my-own-bar"}}' >"$HOME/.claude/settings.json"
  ca_lib ca_settings_poke
  assert_eq "$(cmd)" "my-own-bar"
}

test_poke_without_settings_creates_nothing() {
  ca_lib ca_settings_poke
  assert_fails test -e "$HOME/.claude/settings.json"
}

test_the_tick_argument_is_ignored_by_the_status_line() {
  cc_login alice
  ca save >/dev/null
  assert_contains "$(printf '{}' | ca statusline --tick 2 | row_accounts)" "● alice@example.com"
}

test_a_click_pokes_the_status_line() {
  install_it
  cc_login alice
  ca save >/dev/null
  cc_login bob
  ca save >/dev/null
  local before
  before=$(cmd)
  ca open-url "http://claude-acct.localhost/use/33084eab"
  [ "$(cmd)" != "$before" ] || fail "switching by click did not poke the status line"
  before=$(cmd)
  ca open-url "http://claude-acct.localhost/collapse"
  [ "$(cmd)" != "$before" ] || fail "collapsing did not poke the status line"
}

test_reinstall_and_uninstall_cope_with_a_ticked_command() {
  mkdir -p "$HOME/.claude"
  printf '{"statusLine":{"type":"command","command":"echo hi"}}' >"$HOME/.claude/settings.json"
  install_it
  ca_lib ca_settings_poke
  assert_contains "$(cmd)" "--tick 1"
  install_it
  assert_not_contains "$(cmd)" "--tick"
  assert_eq "$(jq -r .originals.statusLine.command "$XDG_DATA_HOME/claude-acct/install.json")" "echo hi"
  ca_lib ca_settings_poke
  "$ROOT/uninstall.sh" >/dev/null
  assert_eq "$(cmd)" "echo hi"
}

test_doctor_accepts_a_ticked_command() {
  install_it
  cc_login alice
  ca save >/dev/null
  ca_lib ca_settings_poke
  assert_contains "$(ca doctor || true)" "ok    status line installed"
}

mtime() { stat -f %Fm "$1" 2>/dev/null || stat -c %.9Y "$1"; }

test_a_switch_pokes_before_touching_the_credentials() {
  install_it
  cc_login alice
  ca save >/dev/null
  cc_login bob
  ca save >/dev/null
  ca use alice@example.com >/dev/null
  local poke creds
  poke=$(mtime "$HOME/.claude/settings.json")
  if [ "$CLAUDE_ACCT_PLATFORM" = Darwin ]; then
    creds=$(mtime "$FAKE_KEYCHAIN_DIR/$(printf 'Claude Code-credentials' | xxd -p | tr -d '\n')__$(printf tester | xxd -p | tr -d '\n')")
  else
    creds=$(mtime "$HOME/.claude/.credentials.json")
  fi
  awk -v p="$poke" -v c="$creds" 'BEGIN { exit !(p < c) }' ||
    fail "the poke ($poke) came after the credential write ($creds)"
}

test_a_switch_pokes_once_when_no_status_line_drew_meanwhile() {
  install_it
  cc_login alice
  ca save >/dev/null
  cc_login bob
  ca save >/dev/null
  printf '0' >"$XDG_DATA_HOME/claude-acct/statusline.at"
  local before after
  before=$(grep -c ' poke$' "$XDG_DATA_HOME/claude-acct/claude-acct.log")
  ca use alice@example.com >/dev/null
  after=$(grep -c ' poke$' "$XDG_DATA_HOME/claude-acct/claude-acct.log")
  assert_eq "$((after - before))" "1"
}

test_a_switch_pokes_again_when_a_status_line_drew_the_old_state() {
  install_it
  cc_login alice
  ca save >/dev/null
  cc_login bob
  ca save >/dev/null
  # a status line "in the future" stands for one that ran between the poke and the switch
  printf '9999999999999' >"$XDG_DATA_HOME/claude-acct/statusline.at"
  local before after
  before=$(grep -c ' poke$' "$XDG_DATA_HOME/claude-acct/claude-acct.log")
  ca use alice@example.com >/dev/null
  after=$(grep -c ' poke$' "$XDG_DATA_HOME/claude-acct/claude-acct.log")
  assert_eq "$((after - before))" "2"
}

test_the_status_line_records_when_it_read_its_state() {
  cc_login alice
  ca save >/dev/null
  printf '{}' | ca statusline >/dev/null
  local at
  at=$(cat "$XDG_DATA_HOME/claude-acct/statusline.at")
  [ "$at" -gt 1700000000000 ] || fail "statusline.at is not a millisecond timestamp: $at"
}

test_a_click_pokes_exactly_once_and_before_any_read() {
  install_it
  cc_login alice
  ca save >/dev/null
  cc_login bob
  ca save >/dev/null
  printf '0' >"$XDG_DATA_HOME/claude-acct/statusline.at"
  local before after
  before=$(grep -c ' poke$' "$XDG_DATA_HOME/claude-acct/claude-acct.log")
  : >"$FAKE_LOG"
  ca open-url "http://claude-acct.localhost/use/33084eab"
  after=$(grep -c ' poke$' "$XDG_DATA_HOME/claude-acct/claude-acct.log")
  assert_eq "$((after - before))" "1"
  assert_eq "$(live_rt)" "rt-alice"
  # the poke happened before the first Keychain access of the switch
  local poke creds
  poke=$(mtime "$HOME/.claude/settings.json")
  if [ "$CLAUDE_ACCT_PLATFORM" = Darwin ]; then
    creds=$(mtime "$FAKE_KEYCHAIN_DIR/$(printf 'Claude Code-credentials' | xxd -p | tr -d '\n')__$(printf tester | xxd -p | tr -d '\n')")
  else
    creds=$(mtime "$HOME/.claude/.credentials.json")
  fi
  awk -v p="$poke" -v c="$creds" 'BEGIN { exit !(p < c) }' || fail "the poke ($poke) came after the credential write ($creds)"
}
