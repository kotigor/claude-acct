# shellcheck shell=bash
# oauthAccount in Claude Code's global config: who is logged in.

ca_gconfig_account() {  # prints oauthAccount; fails when there is none
  local f
  f=$(ca_global_config_path)
  [ -f "$f" ] || return 1
  jq -ce '.oauthAccount
    | select(type == "object" and (.accountUuid | type) == "string" and (.organizationUuid | type) == "string")' \
    "$f" 2>/dev/null
}

ca_account_key() { jq -r '"\(.accountUuid):\(.organizationUuid)"'; }  # oauthAccount on stdin

ca_account_id() { ca_sha256_hex "$1" | cut -c1-8; }  # ca_account_id <key>

ca_active_id() {  # id of the account Claude Code is logged in as
  local acct
  acct=$(ca_gconfig_account) || return 1
  ca_account_id "$(printf '%s' "$acct" | ca_account_key)"
}

ca_gconfig_set_account() {  # oauthAccount on stdin
  local f acct new
  f=$(ca_global_config_path)
  acct=$(cat)
  if [ -f "$f" ]; then
    new=$(jq --argjson a "$acct" '.oauthAccount = $a' "$f") || return 1
  else
    new=$(jq -n --argjson a "$acct" '{oauthAccount: $a}') || return 1
  fi
  printf '%s\n' "$new" | ca_write_atomic "$f" "$(ca_file_mode "$f" 600)"
}
