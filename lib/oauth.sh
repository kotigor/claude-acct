# shellcheck shell=bash
# Renewing a saved account's login.
#
# Access tokens last a few hours. Claude Code renews the active account's by
# itself; a saved account nobody has switched to for a while ends up with an
# expired one, and the usage endpoint refuses it. This renews such a login the
# standard way — the same token endpoint and client id Claude Code uses, with the
# account's own refresh token — and files the new tokens in the vault before
# they are used. Only saved, non-active accounts are ever renewed here; the
# active one belongs to Claude Code. Set CLAUDE_ACCT_TOKEN_REFRESH=0 to turn
# this off (their limits then go stale once their tokens expire).

CA_OAUTH_TOKEN_URL='https://platform.claude.com/v1/oauth/token'
CA_OAUTH_CLIENT_ID='9d1c250a-e61b-44d9-88ed-5944d1962f5e'
CA_OAUTH_CONNECT_TIMEOUT=4
CA_OAUTH_TIMEOUT=8   # short on purpose: the command lock is held meanwhile
CA_OAUTH_BACKOFF=900   # a throttled login is left alone this long; asking again only prolongs it

ca_oauth_expired() {  # ca_oauth_expired <record>: is its access token (about to be) expired?
  printf '%s' "$1" | jq -e --argjson now "$(date +%s)" \
    '(.claudeAiOauth.expiresAt // 0) / 1000 < $now + 60' >/dev/null 2>&1
}

# ca_oauth_renew <record>: prints the record with fresh tokens, or one of
# invalid_grant / throttled / unreachable / unexpected on stderr and fails
# (status 3 when throttled). Network only.
ca_oauth_renew() {
  local record=$1 body reply code data
  body=$(printf '%s' "$record" | jq -c --arg cid "$CA_OAUTH_CLIENT_ID" '.claudeAiOauth
    | {grant_type: "refresh_token", refresh_token: .refreshToken,
       client_id: (.clientId // $cid), scope: ((.scopes // []) | join(" "))}
    | if .scope == "" then del(.scope) else . end') || { echo unexpected >&2; return 1; }
  # The body goes in through curl's config on stdin, quoted the way curl expects,
  # so the refresh token never appears in a process list.
  data=$(printf '%s' "$body" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
  reply=$(printf 'url = "%s"\nheader = "Content-Type: application/json"\nheader = "User-Agent: %s"\ndata = "%s"\n' \
    "$CA_OAUTH_TOKEN_URL" "$(ca_user_agent)" "$data" |
    curl -sS -K - --connect-timeout "$CA_OAUTH_CONNECT_TIMEOUT" --max-time "$CA_OAUTH_TIMEOUT" \
      -w '\n%{http_code}' 2>/dev/null) || { echo unreachable >&2; return 1; }
  code=$(printf '%s' "$reply" | tail -n 1)
  reply=$(printf '%s' "$reply" | sed '$d')
  case "$code" in
    200) ;;
    429) echo throttled >&2; return 3 ;;
    400 | 401)
      if printf '%s' "$reply" | jq -e '.error == "invalid_grant" or .error.type == "invalid_grant"' >/dev/null 2>&1; then
        echo invalid_grant >&2
      else
        echo unexpected >&2
      fi
      return 1 ;;
    *) echo unreachable >&2; return 1 ;;
  esac
  printf '%s\n%s\n' "$record" "$reply" | jq -cs --argjson now "$(date +%s)" '
    .[0] as $rec | .[1] as $r
    | if ($r.access_token | type) != "string" or ($r.expires_in | type) != "number" then empty else
      $rec | .claudeAiOauth += {
        accessToken: $r.access_token,
        refreshToken: ($r.refresh_token // $rec.claudeAiOauth.refreshToken),
        expiresAt: (($now + $r.expires_in) * 1000),
        scopes: (if ($r.scope | type) == "string" and $r.scope != "" then ($r.scope | split(" ")) else $rec.claudeAiOauth.scopes end)}
      + (if ($r.refresh_token_expires_in | type) == "number"
         then {refreshTokenExpiresAt: (($now + $r.refresh_token_expires_in) * 1000)} else {} end)
      end' 2>/dev/null | grep . || { echo unexpected >&2; return 1; }
}

# ca_oauth_renew_vault <id>: renew a saved account's login and file it, under the
# command lock so two rounds cannot both spend the same refresh token. Prints
# nothing on success; the failure word on stderr otherwise.
ca_oauth_renew_vault() {
  local id=$1 record fresh rc
  [ "${CLAUDE_ACCT_TOKEN_REFRESH:-1}" != 0 ] || { echo disabled >&2; return 1; }
  [ "$id" != "$(ca_active_id 2>/dev/null || true)" ] || { echo active >&2; return 1; }
  if [ "$(ca_rl_read | jq -r --arg id "$id" --argjson now "$(date +%s)" \
      '(.accounts[$id].renewAfter // 0) > $now' 2>/dev/null)" = true ]; then
    echo throttled >&2
    return 1
  fi
  (
    ca_lock
    record=$(ca_vault_get "$id") || { echo unexpected >&2; exit 1; }
    ca_oauth_expired "$record" || exit 0   # someone else renewed it meanwhile
    fresh=$(ca_oauth_renew "$record") || {
      rc=$?
      # shellcheck disable=SC2016  # a jq filter: its $names are jq variables
      [ "$rc" -ne 3 ] || ca_rl_update '.accounts[$id] = ((.accounts[$id] // {}) + {renewAfter: $t})' \
        --arg id "$id" --argjson t "$(( $(date +%s) + CA_OAUTH_BACKOFF ))" >/dev/null 2>&1 || true
      exit 1
    }
    # Filed before anything uses it: the old refresh token may already be spent.
    printf '%s' "$fresh" | ca_vault_put "$id" || { echo unexpected >&2; exit 1; }
    ca_index_upsert "$(printf '%s\n%s\n' "$fresh" "$(printf '%s' "$fresh" | jq -c .oauthAccount)" |
      ca_index_entry "$id" "$(ca_index_get "$id" | jq -r .key)" "")" || true
    ca_log "token renewed $id"
  )
}
