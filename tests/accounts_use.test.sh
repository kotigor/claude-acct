# shellcheck shell=bash

two_accounts() {  # alice and bob saved, bob active
  cc_login alice
  ca save >/dev/null
  cc_login bob
  ca save >/dev/null
}

test_use_switches_credentials_and_account() {
  two_accounts
  assert_contains "$(ca use alice@example.com)" "Switched to alice@example.com (33084eab)"
  assert_eq "$(live_rt)" "rt-alice"
  assert_eq "$(live_email)" "alice@example.com"
  assert_eq "$(cc_store_get | jq -r .trustedDeviceToken)" "tdt-alice"
}

test_use_keeps_keys_that_do_not_belong_to_the_account() {
  two_accounts
  ca use 33084eab >/dev/null
  assert_eq "$(cc_store_get | jq -r .mcpOAuth.srv.accessToken)" "mcp-secret"
  assert_eq "$(cc_store_get | jq -r .pluginSecrets.p)" "s"
}

test_use_drops_bound_keys_the_target_does_not_have() {
  two_accounts
  cc_store_get | jq -c '.designOauth = {"refreshToken": "design-bob"}' | cc_store_put
  ca use alice@example.com >/dev/null
  assert_eq "$(cc_store_get | jq -r '.designOauth // "absent"')" "absent"
  ca use bob@example.com >/dev/null
  assert_eq "$(cc_store_get | jq -r .designOauth.refreshToken)" "design-bob"
}

test_use_saves_rotated_tokens_before_leaving() {
  two_accounts
  cc_refresh bob2
  ca use alice@example.com >/dev/null
  ca use bob@example.com >/dev/null
  assert_eq "$(live_rt)" "rt-bob2"
}

test_use_same_account_is_a_no_op() {
  two_accounts
  assert_contains "$(ca use bob@example.com)" "Already using bob@example.com"
}

test_use_unknown_account_changes_nothing() {
  two_accounts
  assert_fails ca use nobody
  assert_eq "$(live_rt)" "rt-bob"
}

test_use_warns_about_overrides_but_switches() {
  two_accounts
  local out
  out=$(ANTHROPIC_API_KEY=x ca use alice@example.com 2>&1)
  assert_contains "$out" "ANTHROPIC_API_KEY"
  assert_eq "$(live_rt)" "rt-alice"
}

test_use_warns_when_leaving_an_unsaved_account() {
  two_accounts
  cc_login carol
  assert_contains "$(ca use alice@example.com 2>&1)" "not saved"
  assert_eq "$(live_rt)" "rt-alice"
}

test_use_rolls_back_when_the_write_does_not_stick__darwin() {
  two_accounts
  export FAKE_SECURITY_IGNORE_WRITES_FOR="Claude Code-credentials"
  assert_contains "$(ca use alice@example.com 2>&1 || true)" "switch failed"
  unset FAKE_SECURITY_IGNORE_WRITES_FOR
  assert_eq "$(live_rt)" "rt-bob"
  assert_eq "$(live_email)" "bob@example.com"
}

test_use_works_after_logout() {
  two_accounts
  cc_store_get | jq -c 'del(.claudeAiOauth, .trustedDeviceToken)' | cc_store_put
  jq 'del(.oauthAccount)' "$(gc_path)" >"$(gc_path).tmp" && mv "$(gc_path).tmp" "$(gc_path)"
  ca use alice@example.com >/dev/null
  assert_eq "$(live_rt)" "rt-alice"
  assert_eq "$(cc_store_get | jq -r .mcpOAuth.srv.accessToken)" "mcp-secret"
}

test_restore_undoes_the_last_switch() {
  two_accounts
  ca use alice@example.com >/dev/null
  ca restore >/dev/null
  assert_eq "$(live_rt)" "rt-bob"
  assert_eq "$(live_email)" "bob@example.com"
}

test_concurrent_switches_leave_a_consistent_login() {
  two_accounts
  ca use alice@example.com >/dev/null 2>&1 &
  ca use bob@example.com >/dev/null 2>&1 &
  wait
  case "$(live_rt)" in
    rt-alice) assert_eq "$(live_email)" "alice@example.com" ;;
    rt-bob) assert_eq "$(live_email)" "bob@example.com" ;;
    *) fail "unexpected refresh token $(live_rt)" ;;
  esac
}

test_click_path_with_unexpected_credentials_changes_nothing() {
  two_accounts
  cc_store_get | jq -c '.claudeAiOauth = {"accessToken": 1}' | cc_store_put
  local before
  before=$(cc_store_get)
  ca open-url "http://claude-acct.localhost/use/33084eab" 2>/dev/null || true
  assert_eq "$(cc_store_get)" "$before"
  assert_eq "$(live_email)" "bob@example.com"
}
