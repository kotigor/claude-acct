# shellcheck shell=bash

jb_root() {
  if [ "$CLAUDE_ACCT_PLATFORM" = Darwin ]; then printf '%s' "$HOME/Library/Application Support/JetBrains"
  else printf '%s' "$HOME/.config/JetBrains"; fi
}
jb_file() { printf '%s/%s/options/ide.general.local.xml' "$(jb_root)" "$1"; }
jb_ide() { mkdir -p "$(jb_root)/$1/options"; }
state_json() { cat "$XDG_DATA_HOME/claude-acct/install.json"; }
firefox_xml() {
  printf '<application>\n  <component name="GeneralLocalSettings">\n    <option name="browserPath" value="/Applications/Firefox.app" />\n    <option name="useDefaultBrowser" value="false" />\n  </component>\n</application>\n'
}

test_jetbrains_setup_writes_the_browser_setting_of_every_ide() {
  jb_ide PhpStorm2025.3; jb_ide Rider2024.3; mkdir -p "$(jb_root)/PrivacyPolicy"
  printf '<application>\n  <component name="GeneralLocalSettings">\n    <option name="defaultProjectDirectory" />\n  </component>\n</application>\n' >"$(jb_file PhpStorm2025.3)"
  "$ROOT/install.sh" --no-vscode --no-jetbrains >/dev/null
  local out f
  out=$(ca jetbrains-setup)
  assert_contains "$out" "JetBrains IDEs found (PhpStorm2025.3, Rider2024.3)"
  f=$(jb_file PhpStorm2025.3)
  assert_contains "$(cat "$f")" "<option name=\"browserPath\" value=\"$ROOT/bin/claude-acct-browser\" />"
  assert_contains "$(cat "$f")" '<option name="useDefaultBrowser" value="false" />'
  assert_contains "$(cat "$f")" '<option name="defaultProjectDirectory" />'
  assert_eq "$(grep -c 'browserPath' "$f")" "1"
  # a file the IDE has not written yet is created the way it would write it
  f=$(jb_file Rider2024.3)
  assert_contains "$(cat "$f")" '<component name="GeneralLocalSettings">'
  assert_contains "$(cat "$f")" '<option name="useDefaultBrowser" value="false" />'
  assert_contains "$(cat "$f")" '</application>'
  # running it again changes nothing
  local before
  before=$(cat "$f")
  ca jetbrains-setup >/dev/null
  assert_eq "$(cat "$f")" "$before"
  assert_eq "$(state_json | jq -r --arg f "$f" '.jetbrains[$f].browserPath')" "null"
}

test_uninstall_puts_the_previous_browser_setting_back() {
  jb_ide PhpStorm2025.3
  firefox_xml >"$(jb_file PhpStorm2025.3)"
  "$ROOT/install.sh" --no-vscode >/dev/null   # sets the IDE up by itself
  assert_contains "$(cat "$(jb_file PhpStorm2025.3)")" "claude-acct-browser"
  assert_not_contains "$(cat "$(jb_file PhpStorm2025.3)")" "Firefox"
  assert_eq "$(state_json | jq -r '.jetbrains | to_entries[0].value.browserPath')" "/Applications/Firefox.app"
  ca uninstall >/dev/null
  assert_contains "$(cat "$(jb_file PhpStorm2025.3)")" '<option name="browserPath" value="/Applications/Firefox.app" />'
  assert_contains "$(cat "$(jb_file PhpStorm2025.3)")" '<option name="useDefaultBrowser" value="false" />'
  assert_not_contains "$(cat "$(jb_file PhpStorm2025.3)")" "claude-acct-browser"
}

test_uninstall_returns_an_untouched_ide_to_its_default_browser() {
  jb_ide PhpStorm2025.3
  "$ROOT/install.sh" --no-vscode >/dev/null
  ca uninstall >/dev/null
  assert_not_contains "$(cat "$(jb_file PhpStorm2025.3)")" "browserPath"
  assert_not_contains "$(cat "$(jb_file PhpStorm2025.3)")" "useDefaultBrowser"
  assert_contains "$(cat "$(jb_file PhpStorm2025.3)")" '</application>'
}

test_uninstall_leaves_a_setting_the_user_changed_since() {
  jb_ide PhpStorm2025.3
  "$ROOT/install.sh" --no-vscode >/dev/null
  firefox_xml >"$(jb_file PhpStorm2025.3)"
  ca uninstall >/dev/null
  assert_contains "$(cat "$(jb_file PhpStorm2025.3)")" "/Applications/Firefox.app"
}

test_the_installer_can_leave_jetbrains_alone() {
  jb_ide PhpStorm2025.3
  local out
  out=$("$ROOT/install.sh" --no-vscode --no-jetbrains)
  assert_not_contains "$out" "JetBrains"
  [ ! -f "$(jb_file PhpStorm2025.3)" ] || fail "--no-jetbrains still wrote the setting"
  out=$("$ROOT/install.sh" --no-vscode)
  assert_contains "$out" "JetBrains IDEs found (PhpStorm2025.3)"
  assert_contains "$(cat "$(jb_file PhpStorm2025.3)")" "$XDG_DATA_HOME/claude-acct/app/bin/claude-acct-browser"
}

test_jetbrains_setup_without_any_ide_says_so() {
  "$ROOT/install.sh" --no-vscode >/dev/null
  local out rc=0
  out=$(ca jetbrains-setup 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "jetbrains-setup succeeded with no IDE around"
  assert_contains "$out" "no JetBrains IDE settings found"
}

test_a_handler_path_with_special_characters_is_escaped_in_the_xml() {
  export XDG_DATA_HOME="$T/data & <dir>"
  jb_ide PhpStorm2025.3
  "$ROOT/install.sh" --no-vscode >/dev/null
  assert_contains "$(cat "$(jb_file PhpStorm2025.3)")" 'data &amp; &lt;dir&gt;/claude-acct/app/bin/claude-acct-browser'
  # read back unescaped, so a rerun knows it is already ours
  local before
  before=$(cat "$(jb_file PhpStorm2025.3)")
  "$XDG_DATA_HOME/claude-acct/app/bin/claude-acct" jetbrains-setup >/dev/null
  assert_eq "$(cat "$(jb_file PhpStorm2025.3)")" "$before"
  assert_eq "$(state_json | jq -r '.jetbrains | to_entries[0].value.browserPath')" "null"
}

classic_xml() {
  printf '<application>\n  <component name="TerminalOptionsProvider">\n    <option name="terminalEngine" value="CLASSIC" />\n  </component>\n</application>\n'
}

test_the_status_line_warns_on_the_reworked_jetbrains_engine() {
  cc_login alice
  ca save >/dev/null
  local out
  out=$(printf '{}' | TERMINAL_EMULATOR=JetBrains-JediTerm ca statusline)
  assert_contains "$out" "Ctrl+click"
  assert_contains "$out" "$(esc_ch)]8;;http://claude-acct.localhost/hint/jetbrains/off$(bel_ch)✕ hide"
  assert_contains "$(printf '{}' | COLUMNS=80 TERMINAL_EMULATOR=JetBrains-JediTerm ca statusline)" "⚠ links here need Ctrl+click"
  # not in other terminals
  assert_not_contains "$(printf '{}' | ca statusline)" "Ctrl+click"
  # nor once an IDE here is set to the classic engine ...
  jb_ide PhpStorm2025.3
  classic_xml >"$(jb_root)/PhpStorm2025.3/options/terminal.xml"
  assert_not_contains "$(printf '{}' | TERMINAL_EMULATOR=JetBrains-JediTerm ca statusline)" "Ctrl+click"
  # ... unless the shell still carries the engine s own marker (bash and fish keep it)
  assert_contains "$(printf '{}' | TERMINAL_EMULATOR=JetBrains-JediTerm INTELLIJ_TERMINAL_COMMAND_BLOCKS_REWORKED=1 ca statusline)" "Ctrl+click"
}

test_the_engine_hint_can_be_hidden_for_good() {
  cc_login alice
  ca save >/dev/null
  ca open-url http://claude-acct.localhost/hint/jetbrains/off
  assert_eq "$(jq -r .hints.jetbrains "$XDG_DATA_HOME/claude-acct/ui.json")" "false"
  assert_not_contains "$(printf '{}' | TERMINAL_EMULATOR=JetBrains-JediTerm ca statusline)" "Ctrl+click"
  assert_contains "$(printf '{}' | TERMINAL_EMULATOR=JetBrains-JediTerm ca statusline)" "alice@example.com"
}
