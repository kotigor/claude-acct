# shellcheck shell=bash

two_accounts() {
  cc_login alice
  ca save >/dev/null
  cc_login bob
  ca save >/dev/null
}

test_click_switches_account_without_a_notification() {
  two_accounts
  ca open-url "http://claude-acct.localhost/use/33084eab"
  assert_eq "$(live_rt)" "rt-alice"
  # the row is the confirmation; notifications are for failures only
  assert_not_contains "$(cat "$FAKE_LOG")" "osascript"
  assert_not_contains "$(cat "$FAKE_LOG")" "notify-send"
}

test_click_on_unknown_account_notifies_and_exits_zero() {
  two_accounts
  ca open-url "http://claude-acct.localhost/use/deadbeef"
  assert_contains "$(cat "$FAKE_LOG")" "switch failed"
  assert_eq "$(live_rt)" "rt-bob"
}

test_click_rejects_malformed_ids() {
  ca open-url 'http://claude-acct.localhost/use/..%2F..'
  ca open-url 'http://claude-acct.localhost/use/__backup__'
  assert_eq "$(grep -c "Invalid account link" "$FAKE_LOG")" "2"
}

test_click_save() {
  cc_login alice
  ca open-url "http://claude-acct.localhost/save"
  assert_contains "$(ca list)" "alice@example.com"
  assert_not_contains "$(cat "$FAKE_LOG")" "osascript"
}

test_other_links_open_as_usual() {
  ca open-url "https://claude.ai/oauth/authorize?x=1"
  if [ "$CLAUDE_ACCT_PLATFORM" = Darwin ]; then
    assert_contains "$(cat "$FAKE_LOG")" "open https://claude.ai/oauth/authorize?x=1"
  else
    assert_contains "$(cat "$FAKE_LOG")" "xdg-open https://claude.ai/oauth/authorize?x=1"
  fi
}

test_opener_failure_is_passed_on() {
  local rc=0
  FAKE_OPEN_EXIT=3 ca open-url "https://example.com" || rc=$?
  assert_eq "$rc" 3
}

test_original_browser_is_used() {
  mkdir -p "$XDG_DATA_HOME/claude-acct"
  # shellcheck disable=SC2016  # the script expands these when it runs
  printf '#!/bin/sh\necho "mybrowser BROWSER=$BROWSER $*" >>"$FAKE_LOG"\n' >"$HOME/mybrowser"
  chmod +x "$HOME/mybrowser"
  jq -n --arg b "$HOME/mybrowser" '{originals: {env: {BROWSER: $b}}}' >"$XDG_DATA_HOME/claude-acct/install.json"
  BROWSER=/x/claude-acct-browser ca open-url "https://example.com"
  assert_contains "$(cat "$FAKE_LOG")" "mybrowser BROWSER=$HOME/mybrowser https://example.com"
}

test_xdg_open_does_not_see_our_browser__linux() {
  mkdir -p "$T/bin"
  # shellcheck disable=SC2016  # the script expands these when it runs
  printf '#!/bin/sh\necho "xdg-open BROWSER=${BROWSER:-unset}" >>"$FAKE_LOG"\n' >"$T/bin/xdg-open"
  chmod +x "$T/bin/xdg-open"
  PATH="$T/bin:$PATH" BROWSER=/x/claude-acct-browser ca open-url "https://example.com"
  assert_contains "$(cat "$FAKE_LOG")" "xdg-open BROWSER=unset"
}

test_browser_shim_forwards_to_open_url() {
  cc_login alice
  "$ROOT/bin/claude-acct-browser" "http://claude-acct.localhost/save"
  assert_contains "$(ca list)" "alice@example.com"
}

test_a_foreign_link_opens_even_without_jq() {
  mkdir -p "$T/nojq"
  # everything but jq
  for tool in bash sh dirname readlink uname id sed grep cat mkdir rmdir find sleep date printf mktemp mv rm chmod perl xxd \
    security open xdg-open osascript notify-send tr head tail cut wc paste shasum sha256sum; do
    p=$(command -v "$tool" 2>/dev/null) && ln -sf "$p" "$T/nojq/$tool"
  done
  local rc=0
  PATH="$T/nojq" "$ROOT/bin/claude-acct-browser" "https://claude.ai/oauth/authorize" || rc=$?
  assert_eq "$rc" "0"
  assert_contains "$(cat "$FAKE_LOG")" "https://claude.ai/oauth/authorize"
}

test_the_link_handler_works_from_an_ide_with_a_bare_path() {
  "$ROOT/install.sh" --no-vscode >/dev/null
  # an IDE launched from the Dock runs it without Homebrew or ~/.local/bin on PATH
  PATH=/usr/bin:/bin "$XDG_DATA_HOME/claude-acct/app/bin/claude-acct-browser" http://claude-acct.localhost/collapse
  assert_eq "$(jq -r .collapsed "$XDG_DATA_HOME/claude-acct/ui.json")" "true"
}
