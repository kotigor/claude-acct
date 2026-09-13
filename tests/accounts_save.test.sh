# shellcheck shell=bash

test_save_requires_login() {
  assert_contains "$(ca save 2>&1 || true)" "not logged in"
}

test_save_stores_account_bound_keys_only() {
  cc_login alice
  assert_contains "$(ca save)" "Saved alice@example.com (33084eab)"
  local rec
  rec=$(ca_lib ca_vault_get 33084eab)
  assert_eq "$(printf '%s' "$rec" | jq -r .claudeAiOauth.refreshToken)" "rt-alice"
  assert_eq "$(printf '%s' "$rec" | jq -r .trustedDeviceToken)" "tdt-alice"
  assert_eq "$(printf '%s' "$rec" | jq -r .oauthAccount.emailAddress)" "alice@example.com"
  assert_eq "$(printf '%s' "$rec" | jq -r '.mcpOAuth // "absent"')" "absent"
}

test_save_with_label_and_list_marks_active() {
  cc_login alice
  ca save --label work >/dev/null
  cc_login bob
  ca save >/dev/null
  local out
  out=$(ca list)
  assert_contains "$out" "  33084eab  work  [max, login until 2100-01-01]"
  assert_contains "$out" "* a1eeea2a  bob@example.com  [max"
}

test_list_without_accounts() {
  assert_contains "$(ca list)" "No saved accounts yet"
}

test_save_refuses_unexpected_format() {
  cc_login alice
  cc_store_get | jq -c '.claudeAiOauth |= del(.refreshToken)' | cc_store_put
  assert_contains "$(ca save 2>&1 || true)" "unexpected format"
  assert_fails ca_lib ca_vault_get 33084eab
}

test_rename_and_rm() {
  cc_login alice
  ca save >/dev/null
  ca rename alice@example.com personal >/dev/null
  assert_contains "$(ca list)" "personal"
  ca rm personal >/dev/null
  assert_contains "$(ca list)" "No saved accounts yet"
  assert_fails ca_lib ca_vault_get 33084eab
}

test_unknown_command_exits_2() {
  local rc=0
  ca frobnicate >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" 2
}

test_version() {
  assert_eq "$(ca version)" "$(cat "$ROOT/VERSION")"
}
