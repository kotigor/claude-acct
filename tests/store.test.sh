# shellcheck shell=bash

test_backend_keychain_on_darwin__darwin() {
  cc_login alice
  assert_eq "$(ca_lib ca_store_backend)" keychain
}

test_backend_file_on_linux__linux() {
  cc_login alice
  assert_eq "$(ca_lib ca_store_backend)" file
}

test_backend_file_fallback_on_darwin__darwin() {
  mkdir -p "$HOME/.claude"
  printf '{"claudeAiOauth":{}}' >"$HOME/.claude/.credentials.json"
  assert_eq "$(ca_lib ca_store_backend)" file
}

test_store_read_returns_blob() {
  cc_login alice
  assert_eq "$(ca_lib ca_store_read | jq -r .claudeAiOauth.refreshToken)" "rt-alice"
  ca_lib ca_store_present
}

test_store_read_fails_when_logged_out() {
  assert_fails ca_lib ca_store_present
  assert_fails ca_lib ca_store_read
}

test_store_write_roundtrip_non_ascii() {
  cc_login alice
  printf '%s' '{"claudeAiOauth":{"accessToken":"a","refreshToken":"r","expiresAt":1,"scopes":[]},"note":"naïve ✓"}' |
    ca_lib ca_store_write
  assert_eq "$(cc_store_get | jq -r .note)" "naïve ✓"
  assert_eq "$(ca_lib ca_store_read | jq -r .note)" "naïve ✓"
}

test_small_keychain_write_goes_through_stdin__darwin() {
  printf '{"k":"small"}' | ca_lib ca_kc_write svc acct
  assert_contains "$(cat "$FAKE_LOG")" "security -i"
  assert_not_contains "$(cat "$FAKE_LOG")" "security add-generic-password"
  assert_eq "$(ca_lib ca_kc_read svc acct)" '{"k":"small"}'
}

test_large_keychain_write_uses_arguments__darwin() {
  local big
  big=$(jq -cn '{k: ("x" * 5000)}')
  printf '%s' "$big" | ca_lib ca_kc_write svc acct
  assert_contains "$(cat "$FAKE_LOG")" "security add-generic-password -U -a acct -s svc -X"
  assert_eq "$(ca_lib ca_kc_read svc acct)" "$big"
}

test_keychain_write_reports_failure__darwin() {
  export FAKE_SECURITY_IGNORE_WRITES_FOR=svc
  assert_fails ca_lib ca_kc_write svc acct <<<'{"k":1}'
}

test_oauth_valid() {
  printf '{"claudeAiOauth":%s}' "$(fx_oauth alice)" | ca_lib ca_oauth_valid
  assert_fails ca_lib ca_oauth_valid <<<'{"claudeAiOauth":{"accessToken":"a"}}'
  assert_fails ca_lib ca_oauth_valid <<<'{"mcpOAuth":{}}'
}
