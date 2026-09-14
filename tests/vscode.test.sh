# shellcheck shell=bash

install_it() { "$ROOT/install.sh" --no-vscode >/dev/null; }
state_json() { cat "$XDG_DATA_HOME/claude-acct/install.json"; }

test_vscode_setup_builds_and_installs_the_extension() {
  install_it
  export FAKE_VSIX_COPY="$T/ext.vsix"
  ca vscode-setup >/dev/null
  assert_contains "$(cat "$FAKE_LOG")" "code argv=--install-extension"
  [ -f "$T/ext.vsix" ] || fail "the vsix was not handed to the code command"
  local listing
  listing=$(unzip -l "$T/ext.vsix")
  assert_contains "$listing" "extension.vsixmanifest"
  assert_contains "$listing" "[Content_Types].xml"
  assert_contains "$listing" "extension/package.json"
  assert_contains "$listing" "extension/extension.js"
  assert_eq "$(unzip -p "$T/ext.vsix" extension/package.json | jq -r '.publisher + "." + .name + " " + .version')" \
    "kotigor.claude-acct $(cat "$ROOT/VERSION")"
  assert_eq "$(state_json | jq -r .vscode.version)" "$(cat "$ROOT/VERSION")"
}

test_the_status_line_links_through_the_extension_in_vs_code_once_set_up() {
  install_it
  cc_login alice
  ca save >/dev/null
  local out
  out=$(printf '{}' | TERM_PROGRAM=vscode ca statusline)
  assert_contains "$out" "http://claude-acct.localhost/use/33084eab"
  ca vscode-setup >/dev/null
  out=$(printf '{}' | TERM_PROGRAM=vscode ca statusline)
  assert_contains "$out" "vscode://kotigor.claude-acct/use/33084eab"
  assert_contains "$out" "vscode://kotigor.claude-acct/refresh"
  assert_not_contains "$out" "claude-acct.localhost"
  # every other terminal keeps the http links
  out=$(printf '{}' | ca statusline)
  assert_contains "$out" "http://claude-acct.localhost/use/33084eab"
  assert_not_contains "$out" "vscode://"
}

test_a_reinstall_keeps_the_vs_code_setup() {
  install_it
  ca vscode-setup >/dev/null
  install_it
  assert_eq "$(state_json | jq -r .vscode.version)" "$(cat "$ROOT/VERSION")"
}

test_uninstall_removes_the_extension_it_installed() {
  install_it
  ca uninstall >/dev/null
  assert_not_contains "$(cat "$FAKE_LOG")" "uninstall-extension"
  install_it
  ca vscode-setup >/dev/null
  ca uninstall >/dev/null
  assert_contains "$(cat "$FAKE_LOG")" "code argv=--uninstall-extension kotigor.claude-acct"
}

test_vscode_setup_without_the_code_command_says_what_to_do() {
  install_it
  local out rc=0
  out=$(CLAUDE_ACCT_CODE_CLI=/nonexistent/code ca vscode-setup 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "vscode-setup succeeded without a code command"
  assert_contains "$out" "code command was not found"
  assert_eq "$(state_json | jq -r '.vscode // "none"')" "none"
}

test_doctor_knows_about_the_vs_code_terminal() {
  install_it
  assert_contains "$(TERM_PROGRAM=vscode ca doctor 2>&1 || true)" "claude-acct vscode-setup"
  ca vscode-setup >/dev/null
  assert_contains "$(TERM_PROGRAM=vscode ca doctor 2>&1 || true)" "terminal vscode: Cmd+click"
}

test_the_installer_sets_up_vs_code_when_it_is_there() {
  local out
  out=$("$ROOT/install.sh")
  assert_contains "$out" "VS Code found: its extension is installed too"
  assert_contains "$(cat "$FAKE_LOG")" "code argv=--install-extension"
  assert_eq "$(state_json | jq -r .vscode.version)" "$(cat "$ROOT/VERSION")"
}

test_the_installer_leaves_vs_code_alone_when_asked_or_absent() {
  local out
  out=$("$ROOT/install.sh" --no-vscode)
  assert_not_contains "$out" "VS Code"
  out=$(CLAUDE_ACCT_CODE_CLI=/nonexistent/code "$ROOT/install.sh")
  assert_contains "$out" "installed."
  assert_not_contains "$out" "VS Code found"
  assert_not_contains "$(cat "$FAKE_LOG")" "install-extension"
  assert_eq "$(state_json | jq -r '.vscode // "none"')" "none"
  # inside the VS Code terminal without the code command, it says what to do
  out=$(CLAUDE_ACCT_CODE_CLI=/nonexistent/code TERM_PROGRAM=vscode "$ROOT/install.sh")
  assert_contains "$out" "claude-acct vscode-setup"
}
