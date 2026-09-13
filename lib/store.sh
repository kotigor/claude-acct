# shellcheck shell=bash
# Claude Code's credential blob: a macOS Keychain item or .credentials.json.

# `security -i` silently mangles command lines longer than ~4096 bytes.
CA_KC_INTERACTIVE_MAX=4000

# Keys of the blob that belong to the logged-in account. Claude Code drops these
# when /login switches accounts; everything else (MCP logins, plugin secrets) stays.
# shellcheck disable=SC2034  # used by vault.sh and accounts.sh
CA_BOUND_KEYS='["claudeAiOauth","designOauth","trustedDeviceToken","organizationUuid"]'

ca_kc_decode() {  # stdin: `security -w` output, which is hex when the data is not plain ASCII
  local value
  value=$(cat)
  case "$value" in
    '{'* | '['*) printf '%s' "$value" ;;
    *)
      if printf '%s' "$value" | LC_ALL=C grep -Eq '^([0-9a-fA-F]{2})+$'; then
        printf '%s' "$value" | xxd -r -p
      else
        printf '%s' "$value"
      fi ;;
  esac
}

ca_kc_read() {  # ca_kc_read <service> <account>
  local out
  out=$(security find-generic-password -a "$2" -s "$1" -w 2>/dev/null) || return 1
  printf '%s' "$out" | ca_kc_decode
}

ca_kc_exists() { security find-generic-password -a "$2" -s "$1" >/dev/null 2>&1; }

ca_kc_delete() { security delete-generic-password -a "$2" -s "$1" >/dev/null 2>&1; }

ca_kc_write() {  # ca_kc_write <service> <account>: store stdin, verified by reading it back
  local value hex line
  value=$(cat)
  hex=$(printf '%s' "$value" | xxd -p | tr -d '\n')
  [ -n "$hex" ] || return 1
  line="add-generic-password -U -a \"$2\" -s \"$1\" -X \"$hex\""
  if [ "${#line}" -le "$CA_KC_INTERACTIVE_MAX" ]; then
    # Through stdin, so the secret never appears in the process list.
    printf '%s\n' "$line" | security -i >/dev/null 2>&1 || true
  else
    # Too long for `security -i`: arguments are visible to local users (ps) for a moment.
    security add-generic-password -U -a "$2" -s "$1" -X "$hex" >/dev/null 2>&1 || return 1
  fi
  [ "$(ca_kc_read "$1" "$2")" = "$value" ]
}

ca_store_backend() {  # keychain | file: where Claude Code keeps credentials right now
  if [ "$(ca_platform)" != Darwin ]; then
    echo file
  elif ca_kc_exists "$(ca_keychain_service)" "$(ca_keychain_account)"; then
    echo keychain
  elif [ -f "$(ca_credentials_file)" ]; then
    echo file
  else
    echo keychain
  fi
}

ca_store_present() {  # is there a credential blob at all?
  case "$(ca_store_backend)" in
    keychain) ca_kc_exists "$(ca_keychain_service)" "$(ca_keychain_account)" ;;
    file) [ -f "$(ca_credentials_file)" ] ;;
  esac
}

ca_store_read() {  # prints the blob; fails when there is none or it cannot be read
  case "$(ca_store_backend)" in
    keychain) ca_kc_read "$(ca_keychain_service)" "$(ca_keychain_account)" ;;
    file) cat "$(ca_credentials_file)" 2>/dev/null ;;
  esac
}

ca_store_write() {  # blob on stdin
  local f
  case "$(ca_store_backend)" in
    keychain) ca_kc_write "$(ca_keychain_service)" "$(ca_keychain_account)" ;;
    file)
      f=$(ca_credentials_file)
      mkdir -p "$(dirname "$f")" && ca_write_atomic "$f" 600 ;;
  esac
}

ca_oauth_valid() {  # blob on stdin: does claudeAiOauth have the shape claude-acct relies on?
  jq -e '(.claudeAiOauth | type) == "object"
    and (.claudeAiOauth.accessToken | type) == "string"
    and (.claudeAiOauth.refreshToken | type) == "string"
    and (.claudeAiOauth.expiresAt | type) == "number"
    and (.claudeAiOauth.scopes | type) == "array"' >/dev/null 2>&1
}
