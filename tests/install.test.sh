# shellcheck shell=bash

install_it() { "$ROOT/install.sh" >/dev/null; }
settings_json() { cat "$HOME/.claude/settings.json"; }
state_json() { cat "$XDG_DATA_HOME/claude-acct/install.json"; }

test_install_copies_app_and_links_command() {
  install_it
  assert_eq "$("$HOME/.local/bin/claude-acct" version)" "$(cat "$ROOT/VERSION")"
  [ -x "$XDG_DATA_HOME/claude-acct/app/bin/claude-acct-browser" ]
}

test_install_sets_status_line_and_browser() {
  install_it
  local app="$XDG_DATA_HOME/claude-acct/app"
  assert_eq "$(settings_json | jq -r .statusLine.command)" "'$app/bin/claude-acct' statusline"
  assert_eq "$(settings_json | jq -r .statusLine.refreshInterval)" "10"
  assert_eq "$(settings_json | jq -r .env.BROWSER)" "$app/bin/claude-acct-browser"
  assert_eq "$(settings_json | jq -r .env.FORCE_HYPERLINK)" "1"
}

test_install_keeps_settings_and_records_originals() {
  mkdir -p "$HOME/.claude"
  printf '{"model":"opus","statusLine":{"type":"command","command":"echo hi","padding":1,"refreshInterval":10},"env":{"BROWSER":"firefox","X":"y"}}' \
    >"$HOME/.claude/settings.json"
  install_it
  assert_eq "$(settings_json | jq -r .model)" "opus"
  assert_eq "$(settings_json | jq -r .env.X)" "y"
  assert_eq "$(settings_json | jq -r .statusLine.padding)" "1"
  assert_eq "$(state_json | jq -r .originals.statusLine.command)" "echo hi"
  assert_eq "$(state_json | jq -r .originals.env.BROWSER)" "firefox"
}

test_reinstall_keeps_originals() {
  mkdir -p "$HOME/.claude"
  printf '{"statusLine":{"type":"command","command":"echo hi"}}' >"$HOME/.claude/settings.json"
  install_it
  install_it
  assert_eq "$(state_json | jq -r .originals.statusLine.command)" "echo hi"
}

test_uninstall_restores_previous_settings() {
  mkdir -p "$HOME/.claude"
  printf '{"model":"opus","statusLine":{"type":"command","command":"echo hi"},"env":{"BROWSER":"firefox"}}' \
    >"$HOME/.claude/settings.json"
  local before
  before=$(jq -S . "$HOME/.claude/settings.json")
  install_it
  "$ROOT/uninstall.sh" >/dev/null
  assert_eq "$(jq -S . "$HOME/.claude/settings.json")" "$before"
  assert_fails test -e "$HOME/.local/bin/claude-acct"
}

test_uninstall_removes_keys_that_were_not_there() {
  install_it
  "$HOME/.local/bin/claude-acct" uninstall >/dev/null
  assert_eq "$(jq -c . "$HOME/.claude/settings.json")" "{}"
}

test_uninstall_keeps_accounts_unless_purged() {
  install_it
  cc_login alice
  ca save >/dev/null
  "$ROOT/uninstall.sh" >/dev/null
  assert_eq "$(ca_lib ca_vault_get 33084eab | jq -r .claudeAiOauth.refreshToken)" "rt-alice"
  install_it
  "$ROOT/uninstall.sh" --purge >/dev/null
  assert_fails ca_lib ca_vault_get 33084eab
  assert_fails test -d "$XDG_DATA_HOME/claude-acct"
}

test_install_respects_claude_config_dir() {
  export CLAUDE_CONFIG_DIR="$HOME/cc"
  install_it
  assert_eq "$(jq -r .env.FORCE_HYPERLINK "$HOME/cc/settings.json")" "1"
}

test_install_refuses_invalid_settings() {
  mkdir -p "$HOME/.claude"
  printf '{oops' >"$HOME/.claude/settings.json"
  assert_fails "$ROOT/install.sh"
  assert_eq "$(cat "$HOME/.claude/settings.json")" "{oops"
}

test_installed_status_line_command_runs_from_a_path_with_spaces() {
  export XDG_DATA_HOME="$T/data dir"
  install_it
  cc_login alice
  local cmd
  cmd=$(settings_json | jq -r .statusLine.command)
  assert_contains "$(printf '{}' | sh -c "$cmd")" "＋ save"
}

test_a_sub_second_refresh_interval_is_raised_to_one() {
  mkdir -p "$HOME/.claude"
  printf '{"statusLine":{"type":"command","command":"echo hi","refreshInterval":0}}' >"$HOME/.claude/settings.json"
  install_it
  assert_eq "$(settings_json | jq -r .statusLine.refreshInterval)" "1"
}

test_a_reinstall_after_the_user_changed_the_browser_keeps_the_first_originals() {
  mkdir -p "$HOME/.claude"
  printf '{"env":{"BROWSER":"firefox"}}' >"$HOME/.claude/settings.json"
  install_it
  jq '.env.BROWSER = "chromium"' "$HOME/.claude/settings.json" >"$T/s" && mv "$T/s" "$HOME/.claude/settings.json"
  install_it
  assert_eq "$(state_json | jq -r .originals.env.BROWSER)" "firefox"
  assert_eq "$(state_json | jq -r '.originals.env.FORCE_HYPERLINK // "absent"')" "absent"
  "$ROOT/uninstall.sh" >/dev/null
  assert_eq "$(jq -c .env "$HOME/.claude/settings.json")" '{"BROWSER":"firefox"}'
}

test_install_keeps_other_status_line_keys() {
  mkdir -p "$HOME/.claude"
  printf '{"statusLine":{"type":"command","command":"echo hi","hideVimModeIndicator":true,"padding":2}}' >"$HOME/.claude/settings.json"
  install_it
  assert_eq "$(settings_json | jq -c '[.statusLine.hideVimModeIndicator, .statusLine.padding]')" "[true,2]"
  assert_contains "$(settings_json | jq -r .statusLine.command)" "claude-acct"
}

test_install_remembers_the_shell_browser() {
  BROWSER="$HOME/my-browser" install_it
  assert_eq "$(state_json | jq -r .shellBrowser)" "$HOME/my-browser"
  # shellcheck disable=SC2016  # the script expands these when it runs
  printf '#!/bin/sh\necho "shell-browser $*" >>"$FAKE_LOG"\n' >"$HOME/my-browser"; chmod +x "$HOME/my-browser"
  BROWSER="$XDG_DATA_HOME/claude-acct/app/bin/claude-acct-browser" ca open-url "https://example.com"
  assert_contains "$(cat "$FAKE_LOG")" "shell-browser https://example.com"
}
