# shellcheck shell=bash

test_account_absent_without_login() {
  assert_fails ca_lib ca_gconfig_account
  assert_fails ca_lib ca_active_id
}

test_active_id_is_hash_of_account_and_org() {
  cc_login alice
  assert_eq "$(ca_lib ca_active_id)" "33084eab"
}

test_set_account_keeps_other_keys_and_mode() {
  cc_login alice
  chmod 600 "$(gc_path)"
  fx_account bob | ca_lib ca_gconfig_set_account
  assert_eq "$(live_email)" "bob@example.com"
  assert_eq "$(jq -r .numStartups "$(gc_path)")" "1"
  assert_eq "$(ca_lib ca_file_mode "$(gc_path)" 644)" "600"
}

test_config_dir_moves_global_config() {
  export CLAUDE_CONFIG_DIR="$HOME/cc"
  mkdir -p "$HOME/cc"
  fx_account bob | ca_lib ca_gconfig_set_account
  assert_eq "$(jq -r .oauthAccount.emailAddress "$HOME/cc/.claude.json")" "bob@example.com"
}
