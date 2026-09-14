# shellcheck shell=bash

healthy_setup() {
  "$ROOT/install.sh" >/dev/null
  cc_login alice
  ca save >/dev/null
  jq '.tui = "fullscreen"' "$HOME/.claude/settings.json" >"$T/s" && mv "$T/s" "$HOME/.claude/settings.json"
}

test_doctor_reports_a_healthy_setup() {
  healthy_setup
  local out
  out=$(TERM_PROGRAM=WarpTerminal ca doctor)
  assert_contains "$out" "ok    credentials:"
  assert_contains "$out" "ok    active account is saved: alice@example.com"
  assert_contains "$out" "ok    status line installed"
  assert_contains "$out" "ok    link handler installed"
  assert_contains "$out" "ok    fullscreen rendering is on"
  assert_contains "$out" "ok    terminal WarpTerminal: plain click"
  assert_not_contains "$out" "FAIL"
}

test_doctor_fails_without_install() {
  cc_login alice
  local rc=0 out
  out=$(ca doctor) || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "FAIL  status line not installed"
}

test_doctor_warns_about_overrides_and_unsaved_account() {
  "$ROOT/install.sh" >/dev/null
  cc_login alice
  local out
  out=$(ANTHROPIC_API_KEY=x ca doctor || true)
  assert_contains "$out" "ANTHROPIC_API_KEY"
  assert_contains "$out" "active account is not saved"
}

test_doctor_flags_unexpected_credentials() {
  "$ROOT/install.sh" >/dev/null
  cc_login alice
  cc_store_get | jq -c '.claudeAiOauth = "weird"' | cc_store_put
  assert_contains "$(ca doctor || true)" "FAIL  credentials"
}

test_doctor_warns_about_a_project_status_line() {
  healthy_setup
  mkdir -p .claude
  printf '{"statusLine":{"type":"command","command":"echo"}}' >.claude/settings.json
  assert_contains "$(ca doctor || true)" "sets its own statusLine"
}

test_doctor_does_not_mistake_user_settings_for_project_settings() {
  healthy_setup
  cd "$HOME" || return 1
  assert_not_contains "$(ca doctor || true)" "sets its own statusLine"
}

test_doctor_calls_a_logged_out_store_logged_out_not_broken() {
  "$ROOT/install.sh" >/dev/null
  cc_login alice
  ca save >/dev/null
  cc_store_get | jq -c 'del(.claudeAiOauth, .trustedDeviceToken)' | cc_store_put
  jq 'del(.oauthAccount)' "$(gc_path)" >"$T/g" && mv "$T/g" "$(gc_path)"
  local out
  out=$(ca doctor || true)
  assert_contains "$out" "warn  credentials"
  assert_contains "$out" "logged out"
  assert_not_contains "$out" "FAIL  credentials"
}

test_doctor_tells_a_jetbrains_terminal_which_browser_to_set() {
  "$ROOT/install.sh" --no-vscode >/dev/null
  local out
  out=$(TERMINAL_EMULATOR=JetBrains-JediTerm ca doctor 2>&1 || true)
  assert_contains "$out" "claude-acct jetbrains-setup"
  assert_contains "$out" "$ROOT/bin/claude-acct-browser"   # the command runs from the repo in tests
  local opts
  if [ "$CLAUDE_ACCT_PLATFORM" = Darwin ]; then
    opts="$HOME/Library/Application Support/JetBrains/PhpStorm2025.3/options"
  else
    opts="$HOME/.config/JetBrains/PhpStorm2025.3/options"
  fi
  mkdir -p "$opts"
  printf '<application><component name="GeneralSettings"><option name="browserPath" value="%s" /><option name="defaultBrowserPolicy" value="ALTERNATIVE" /></component></application>\n' \
    "$XDG_DATA_HOME/claude-acct/app/bin/claude-acct-browser" >"$opts/ide.general.local.xml"
  out=$(env TERMINAL_EMULATOR=JetBrains-JediTerm PROCESS_LAUNCHED_BY_CW=1 PROCESS_LAUNCHED_BY_Q=1 "$ROOT/bin/claude-acct" doctor 2>&1 || true)
  assert_contains "$out" "terminal JetBrains (reworked engine)"
  out=$(TERMINAL_EMULATOR=JetBrains-JediTerm ca doctor 2>&1 || true)
  assert_contains "$out" "terminal JetBrains (classic engine): click"
}
