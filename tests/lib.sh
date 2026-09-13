# shellcheck shell=bash
# Helpers for tests/*.test.sh. tests/run.sh sources this file and one test file
# into a fresh bash, calls t_setup, then the test function.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

t_setup() {
  T=$(mktemp -d "${TMPDIR:-/tmp}/claude-acct-test.XXXXXX")
  export HOME="$T/home" XDG_DATA_HOME="$T/data" USER=tester
  export FAKE_KEYCHAIN_DIR="$T/keychain" FAKE_LOG="$T/fake.log"
  mkdir -p "$HOME" "$FAKE_KEYCHAIN_DIR" "$T/work"
  : >"$FAKE_LOG"
  export PATH="$ROOT/tests/fakes:$PATH"
  export CLAUDE_ACCT_PLATFORM=${CLAUDE_ACCT_PLATFORM:-Darwin}
  unset CLAUDE_CONFIG_DIR CLAUDE_SECURESTORAGE_CONFIG_DIR CLAUDE_CODE_CUSTOM_OAUTH_URL \
    ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_PROFILE \
    CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY \
    ANTHROPIC_FEDERATION_RULE_ID ANTHROPIC_ORGANIZATION_ID BROWSER FORCE_HYPERLINK \
    CLAUDE_CODE_NO_FLICKER TERM_PROGRAM DISPLAY WAYLAND_DISPLAY
  # Deterministic rendering unless a test asks otherwise.
  export COLUMNS=200 NO_COLOR=1 CLAUDE_ACCT_AUTO_REFRESH=0 CA_USAGE_SYNC=1
  export TERM=xterm-256color  # CI runners and containers say "dumb", which rightly disables colour
  cd "$T/work"
  trap 'rm -rf "$T"' EXIT
}

# Running the code under test --------------------------------------------------
ca() { "$ROOT/bin/claude-acct" "$@"; }

ca_lib() {  # ca_lib <function> [args...]: call a library function in a fresh shell
  bash -c 'set -euo pipefail; for f in "$0"/lib/*.sh; do . "$f"; done; "$@"' "$ROOT" "$@"
}

# Rendering ----------------------------------------------------------------------
esc_ch() { printf '\033'; }
bel_ch() { printf '\007'; }

strip_style() {  # remove OSC 8 hyperlinks and SGR colour from stdin, keep the text
  sed -e "s/$(esc_ch)]8;;[^$(bel_ch)]*$(bel_ch)//g" -e "s/$(esc_ch)\[[0-9;]*m//g"
}

row_accounts() { strip_style | tail -n 2 | head -n 1; }  # the account row
row_controls() { strip_style | tail -n 1; }              # the controls row

# Assertions ---------------------------------------------------------------------
fail() { printf '%s\n' "$*" >&2; return 1; }

assert_eq() {
  [ "$1" = "$2" ] && return 0
  printf 'assert_eq failed\n  expected: %s\n  actual:   %s\n' "$2" "$1" >&2
  return 1
}

assert_contains() {
  case "$1" in *"$2"*) return 0 ;; esac
  printf 'assert_contains failed\n  wanted: %s\n  in:     %s\n' "$2" "$1" >&2
  return 1
}

assert_not_contains() {
  case "$1" in *"$2"*)
    printf 'assert_not_contains failed\n  unwanted: %s\n  in:       %s\n' "$2" "$1" >&2
    return 1 ;;
  esac
  return 0
}

assert_fails() {
  if "$@" >/dev/null 2>&1; then
    printf 'expected failure: %s\n' "$*" >&2
    return 1
  fi
}

# Fixtures -------------------------------------------------------------------------
fx_oauth() {  # fx_oauth <name> [plan]: a claudeAiOauth object
  jq -cn --arg n "$1" --arg p "${2:-max}" '{
    accessToken: ("at-" + $n), refreshToken: ("rt-" + $n),
    expiresAt: 4102444800000, refreshTokenExpiresAt: 4102444800000,
    scopes: ["user:inference", "user:profile"], subscriptionType: $p,
    rateLimitTier: "default_claude_max_20x"}'
}

fx_account() {  # fx_account <name> [organizationUuid]: an oauthAccount object
  jq -cn --arg n "$1" --arg o "${2:-org-$1}" '{
    accountUuid: ("acc-" + $n), organizationUuid: $o, emailAddress: ($n + "@example.com"),
    organizationName: ("Org " + $n), displayName: $n, billingType: "stripe_subscription"}'
}

# Claude Code simulators -------------------------------------------------------------
cc_service() { printf 'Claude Code-credentials'; }

cc_store_get() {  # the credential blob as Claude Code would read it
  if [ "$CLAUDE_ACCT_PLATFORM" = Darwin ]; then
    local v
    v=$(security find-generic-password -a "$USER" -s "$(cc_service)" -w 2>/dev/null) || return 1
    case "$v" in '{'*) printf '%s' "$v" ;; *) printf '%s' "$v" | xxd -r -p ;; esac
  else
    cat "$HOME/.claude/.credentials.json" 2>/dev/null
  fi
}

cc_store_put() {  # blob on stdin
  local blob
  blob=$(cat)
  if [ "$CLAUDE_ACCT_PLATFORM" = Darwin ]; then
    security add-generic-password -U -a "$USER" -s "$(cc_service)" -X "$(printf '%s' "$blob" | xxd -p | tr -d '\n')"
  else
    mkdir -p "$HOME/.claude"
    printf '%s' "$blob" >"$HOME/.claude/.credentials.json"
    chmod 600 "$HOME/.claude/.credentials.json"
  fi
}

gc_path() { printf '%s/.claude.json' "$HOME"; }

cc_login() {  # cc_login <name> [organizationUuid] [plan]: what /login leaves behind
  local cur oauth acct
  cur=$(cc_store_get || printf '%s' '{"mcpOAuth":{"srv":{"accessToken":"mcp-secret"}},"pluginSecrets":{"p":"s"}}')
  oauth=$(fx_oauth "$1" "${3:-max}")
  acct=$(fx_account "$1" "${2:-org-$1}")
  printf '%s\n%s\n' "$cur" "$oauth" | jq -cs --arg n "$1" '
    .[1] as $o | .[0] | del(.designOauth, .trustedDeviceToken, .organizationUuid)
    + {claudeAiOauth: $o, trustedDeviceToken: ("tdt-" + $n)}' | cc_store_put
  [ -f "$(gc_path)" ] || printf '{"numStartups":1}\n' >"$(gc_path)"
  jq --argjson a "$acct" '.oauthAccount = $a' "$(gc_path)" >"$(gc_path).tmp"
  mv "$(gc_path).tmp" "$(gc_path)"
}

cc_refresh() {  # cc_refresh <suffix>: Claude Code rotating the active tokens
  cc_store_get | jq -c --arg s "$1" '
    .claudeAiOauth.accessToken = ("at-" + $s) | .claudeAiOauth.refreshToken = ("rt-" + $s)' | cc_store_put
}

live_rt() { cc_store_get | jq -r '.claudeAiOauth.refreshToken'; }
live_email() { jq -r '.oauthAccount.emailAddress' "$(gc_path)"; }
