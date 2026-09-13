# shellcheck shell=bash

test_keychain_service_default() {
  assert_eq "$(ca_lib ca_keychain_service)" "Claude Code-credentials"
}

test_keychain_service_hashes_config_dir() {
  export CLAUDE_CONFIG_DIR=/Users/x/.claude-work
  assert_eq "$(ca_lib ca_keychain_service)" "Claude Code-credentials-74ed04d5"
}

test_keychain_service_securestorage_dir_wins() {
  export CLAUDE_CONFIG_DIR=/Users/x/.claude-work CLAUDE_SECURESTORAGE_CONFIG_DIR=/a
  assert_eq "$(ca_lib ca_keychain_service)" "Claude Code-credentials-6a50dc85"
}

test_keychain_service_empty_securestorage_dir_disables_hash() {
  export CLAUDE_CONFIG_DIR=/Users/x/.claude-work CLAUDE_SECURESTORAGE_CONFIG_DIR=
  assert_eq "$(ca_lib ca_keychain_service)" "Claude Code-credentials"
}

test_keychain_service_custom_oauth() {
  export CLAUDE_CODE_CUSTOM_OAUTH_URL=https://example.com
  assert_eq "$(ca_lib ca_keychain_service)" "Claude Code-custom-oauth-credentials"
}

test_keychain_account() {
  assert_eq "$(ca_lib ca_keychain_account)" "tester"
  assert_eq "$(USER='bad user' ca_lib ca_keychain_account)" "claude-code-user"
}

test_paths_default() {
  assert_eq "$(ca_lib ca_global_config_path)" "$HOME/.claude.json"
  assert_eq "$(ca_lib ca_settings_path)" "$HOME/.claude/settings.json"
  assert_eq "$(ca_lib ca_credentials_file)" "$HOME/.claude/.credentials.json"
}

test_paths_with_config_dir() {
  export CLAUDE_CONFIG_DIR="$HOME/cc"
  assert_eq "$(ca_lib ca_global_config_path)" "$HOME/cc/.claude.json"
  assert_eq "$(ca_lib ca_settings_path)" "$HOME/cc/settings.json"
  assert_eq "$(ca_lib ca_credentials_file)" "$HOME/cc/.credentials.json"
}

test_credentials_file_with_empty_securestorage_dir() {
  export CLAUDE_CONFIG_DIR="$HOME/cc" CLAUDE_SECURESTORAGE_CONFIG_DIR=
  assert_eq "$(ca_lib ca_credentials_file)" "$HOME/.claude/.credentials.json"
}

test_overrides_none() {
  assert_eq "$(ca_lib ca_overrides)" ""
}

test_overrides_from_env_and_settings() {
  export ANTHROPIC_API_KEY=sk-test
  mkdir -p "$HOME/.claude"
  printf '{"apiKeyHelper":"/bin/echo","env":{"CLAUDE_CODE_OAUTH_TOKEN":"x"}}' >"$HOME/.claude/settings.json"
  local out
  out=$(ca_lib ca_overrides)
  assert_contains "$out" "ANTHROPIC_API_KEY"
  assert_contains "$out" "apiKeyHelper"
  assert_contains "$out" "settings.env.CLAUDE_CODE_OAUTH_TOKEN"
}

test_overrides_federation_needs_both_variables() {
  export ANTHROPIC_FEDERATION_RULE_ID=r
  assert_eq "$(ca_lib ca_overrides)" ""
  export ANTHROPIC_ORGANIZATION_ID=o
  assert_eq "$(ca_lib ca_overrides)" "ANTHROPIC_FEDERATION_RULE_ID"
}
