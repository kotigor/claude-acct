# shellcheck shell=bash
# Where Claude Code keeps things, following its own lookup rules (spec §2).

ca_config_dir() { printf '%s' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"; }

ca_global_config_path() {
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
    printf '%s/.claude.json' "$CLAUDE_CONFIG_DIR"
  else
    printf '%s/.claude.json' "$HOME"
  fi
}

ca_settings_path() { printf '%s/settings.json' "$(ca_config_dir)"; }

ca_securestorage_dir() {  # the directory Claude Code keys credential storage to
  if [ "${CLAUDE_SECURESTORAGE_CONFIG_DIR+set}" = set ]; then
    printf '%s' "${CLAUDE_SECURESTORAGE_CONFIG_DIR:-$HOME/.claude}"
  else
    ca_config_dir
  fi
}

ca_credentials_file() { printf '%s/.credentials.json' "$(ca_securestorage_dir)"; }

ca_keychain_service() {
  local suffix="" hash="" dir
  [ -z "${CLAUDE_CODE_CUSTOM_OAUTH_URL:-}" ] || suffix="-custom-oauth"
  if [ "${CLAUDE_SECURESTORAGE_CONFIG_DIR+set}" = set ]; then
    dir=$CLAUDE_SECURESTORAGE_CONFIG_DIR
  else
    dir=${CLAUDE_CONFIG_DIR:-}
  fi
  [ -z "$dir" ] || hash="-$(ca_sha256_hex "$dir" | cut -c1-8)"
  printf 'Claude Code%s-credentials%s' "$suffix" "$hash"
}

ca_keychain_account() {
  local user=${USER:-}
  [ -n "$user" ] || user=$(id -un 2>/dev/null || true)
  case "$user" in '' | *[!A-Za-z0-9._-]*) user=claude-code-user ;; esac
  printf '%s' "$user"
}

ca_overrides() {  # credential sources that take precedence over /login, one per line
  local name settings
  for name in CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY \
    ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_PROFILE; do
    [ -z "$(printenv "$name" 2>/dev/null)" ] || printf '%s\n' "$name"
  done
  if [ -n "${ANTHROPIC_FEDERATION_RULE_ID:-}" ] && [ -n "${ANTHROPIC_ORGANIZATION_ID:-}" ]; then
    printf '%s\n' ANTHROPIC_FEDERATION_RULE_ID
  fi
  settings=$(ca_settings_path)
  [ -f "$settings" ] || return 0
  jq -r '
    (if .apiKeyHelper then "apiKeyHelper" else empty end),
    ((.env // {}) | keys[]
      | select(IN("ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN",
                  "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY",
                  "ANTHROPIC_PROFILE"))
      | "settings.env." + .)' "$settings" 2>/dev/null || true
}
