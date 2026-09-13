# shellcheck shell=bash

test_vault_roundtrip_and_delete() {
  printf '{"claudeAiOauth":{"refreshToken":"rt"}}' | ca_lib ca_vault_put 33084eab
  assert_eq "$(ca_lib ca_vault_get 33084eab | jq -r .claudeAiOauth.refreshToken)" "rt"
  ca_lib ca_vault_del 33084eab
  assert_fails ca_lib ca_vault_get 33084eab
}

test_vault_rejects_bad_ids() {
  assert_fails ca_lib ca_vault_put "../x" <<<'{"a":1}'
  assert_fails ca_lib ca_vault_get "ABCDEFGH"
}

test_vault_uses_keychain_on_darwin__darwin() {
  printf '{"a":1}' | ca_lib ca_vault_put 33084eab
  assert_eq "$(security find-generic-password -a 33084eab -s claude-acct -w)" '{"a":1}'
}

test_vault_files_are_private__linux() {
  printf '{"a":1}' | ca_lib ca_vault_put 33084eab
  assert_eq "$(ca_lib ca_file_mode "$XDG_DATA_HOME/claude-acct/vault/33084eab.json" 0)" "600"
  assert_eq "$(ca_lib ca_file_mode "$XDG_DATA_HOME/claude-acct/vault" 0)" "700"
}

test_vault_record_keeps_only_account_bound_keys() {
  local rec
  rec=$(printf '%s\n%s\n' '{"claudeAiOauth":{"x":1},"trustedDeviceToken":"t","mcpOAuth":{"s":1}}' "$(fx_account alice)" |
    ca_lib ca_vault_record)
  assert_eq "$(printf '%s' "$rec" | jq -c 'keys')" '["claudeAiOauth","oauthAccount","trustedDeviceToken"]'
  assert_eq "$(printf '%s' "$rec" | jq -r .oauthAccount.emailAddress)" "alice@example.com"
}

test_index_entry_has_no_secrets() {
  local entry
  entry=$(printf '{"claudeAiOauth":%s}\n%s\n' "$(fx_oauth alice pro)" "$(fx_account alice)" |
    ca_lib ca_index_entry 33084eab acc-alice:org-alice "")
  assert_eq "$(printf '%s' "$entry" | jq -r '[.id, .key, .email, .orgName, .plan, .loginExpiresAt] | join(" ")')" \
    "33084eab acc-alice:org-alice alice@example.com Org alice pro 4102444800000"
  assert_not_contains "$entry" "rt-alice"
  assert_not_contains "$entry" "at-alice"
}

test_index_upsert_default_label_and_keeping_label() {
  ca_lib ca_index_upsert '{"id":"33084eab","key":"k1","label":"","email":"a@x.com","orgName":"A"}'
  assert_eq "$(ca_lib ca_index_label 33084eab)" "a@x.com"
  ca_lib ca_index_upsert '{"id":"33084eab","key":"k1","label":"work","email":"a@x.com","orgName":"A"}'
  assert_eq "$(ca_lib ca_index_label 33084eab)" "work"
  ca_lib ca_index_upsert '{"id":"33084eab","key":"k1","label":"","email":"a@x.com","orgName":"A","plan":"pro"}'
  assert_eq "$(ca_lib ca_index_label 33084eab)" "work"
  assert_eq "$(ca_lib ca_index_read | jq '.accounts | length')" "1"
  assert_eq "$(ca_lib ca_index_get 33084eab | jq -r .plan)" "pro"
}

test_index_duplicate_email_gets_organization_in_label() {
  ca_lib ca_index_upsert '{"id":"11111111","key":"k1","label":"","email":"a@x.com","orgName":"Personal"}'
  ca_lib ca_index_upsert '{"id":"22222222","key":"k2","label":"","email":"a@x.com","orgName":"Team"}'
  assert_eq "$(ca_lib ca_index_label 22222222)" "a@x.com (Team)"
}

test_index_label_strips_control_characters() {
  ca_lib ca_index_upsert "$(jq -cn '{id: "11111111", key: "k", email: "e", orgName: "o",
    label: ("a" + ([27] | implode) + "]8;;x" + ([7] | implode) + "b")}')"
  assert_eq "$(ca_lib ca_index_label 11111111)" "a]8;;xb"
}

test_index_find_by_id_label_email() {
  ca_lib ca_index_upsert '{"id":"11111111","key":"k1","label":"work","email":"a@x.com","orgName":"A"}'
  ca_lib ca_index_upsert '{"id":"22222222","key":"k2","label":"home","email":"b@x.com","orgName":"B"}'
  assert_eq "$(ca_lib ca_index_find 22222222)" "22222222"
  assert_eq "$(ca_lib ca_index_find work)" "11111111"
  assert_eq "$(ca_lib ca_index_find b@x.com)" "22222222"
  assert_fails ca_lib ca_index_find nobody
}

test_index_find_ambiguous() {
  ca_lib ca_index_upsert '{"id":"11111111","key":"k1","label":"same","email":"a@x.com","orgName":"A"}'
  ca_lib ca_index_upsert '{"id":"22222222","key":"k2","label":"same","email":"b@x.com","orgName":"B"}'
  assert_fails ca_lib ca_index_find same
}

test_index_remove() {
  ca_lib ca_index_upsert '{"id":"11111111","key":"k1","label":"","email":"a@x.com","orgName":"A"}'
  ca_lib ca_index_remove 11111111
  assert_eq "$(ca_lib ca_index_read | jq -c .accounts)" "[]"
}
