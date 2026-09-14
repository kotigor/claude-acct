# shellcheck shell=bash
# Saved accounts. Secrets go to the vault (Keychain service "claude-acct" on
# macOS, 0600 files elsewhere); accounts.json indexes them without secrets.

CA_VAULT_SERVICE=claude-acct

ca_valid_id() {
  case "$1" in *$'\n'* | *$'\r'*) return 1 ;; esac
  printf '%s' "$1" | grep -Eq '^([0-9a-f]{8}|__backup__)$'
}

ca_vault_put() {  # ca_vault_put <id>: store stdin
  local dir
  ca_valid_id "$1" || return 1
  if [ "$(ca_platform)" = Darwin ]; then
    ca_kc_write "$CA_VAULT_SERVICE" "$1"
  else
    ca_ensure_data_dir
    dir="$(ca_data_dir)/vault"
    mkdir -p "$dir" && chmod 700 "$dir" && ca_write_atomic "$dir/$1.json" 600
  fi
}

ca_vault_get() {  # ca_vault_get <id>
  ca_valid_id "$1" || return 1
  if [ "$(ca_platform)" = Darwin ]; then
    ca_kc_read "$CA_VAULT_SERVICE" "$1"
  else
    cat "$(ca_data_dir)/vault/$1.json" 2>/dev/null
  fi
}

ca_vault_del() {  # ca_vault_del <id>
  ca_valid_id "$1" || return 1
  if [ "$(ca_platform)" = Darwin ]; then
    ca_kc_delete "$CA_VAULT_SERVICE" "$1" || true
  else
    rm -f "$(ca_data_dir)/vault/$1.json"
  fi
}

ca_vault_record() {  # stdin: blob, then oauthAccount -> what the vault keeps for an account
  jq -cs --argjson bound "$CA_BOUND_KEYS" '
    (.[0] | with_entries(select(.key as $k | any($bound[]; . == $k)))) + {oauthAccount: .[1]}'
}

ca_index_path() { printf '%s/accounts.json' "$(ca_data_dir)"; }

ca_index_read() {
  if [ -f "$(ca_index_path)" ]; then cat "$(ca_index_path)"; else printf '{"accounts":[]}'; fi
}

ca_index_write() {  # index JSON on stdin
  ca_ensure_data_dir && ca_write_atomic "$(ca_index_path)" 600
}

ca_index_entry() {  # ca_index_entry <id> <key> <label>; stdin: blob, then oauthAccount
  jq -cs --arg id "$1" --arg key "$2" --arg label "$3" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    .[0].claudeAiOauth as $o | .[1] as $a
    | {id: $id, key: $key, label: $label, email: ($a.emailAddress // ""),
       orgName: ($a.organizationName // ""), plan: ($o.subscriptionType // ""),
       loginExpiresAt: ($o.refreshTokenExpiresAt // null), savedAt: $now}'
}

# ca_index_upsert <entry>: add or update by id. An empty label keeps the current one;
# a new account is labelled with its email, or "email (organization)" if taken.
ca_index_upsert() {
  local new
  new=$(ca_index_read | jq -c --argjson e "$1" '
    (.accounts | map(select(.id == $e.id)) | .[0]) as $old
    | any(.accounts[]; .id != $e.id and .email == $e.email) as $dup
    | ($e + {label: ((if ($e.label // "") != "" then $e.label
                      elif $old != null then $old.label
                      elif $dup then "\($e.email) (\($e.orgName))"
                      else $e.email end) | gsub("[[:cntrl:]]"; ""))}) as $entry
    | .accounts |= (if $old != null then map(if .id == $e.id then $entry else . end) else . + [$entry] end)') ||
    return 1
  printf '%s\n' "$new" | ca_index_write
}

ca_index_remove() {  # ca_index_remove <id>
  local new
  new=$(ca_index_read | jq -c --arg id "$1" '.accounts |= map(select(.id != $id))') || return 1
  printf '%s\n' "$new" | ca_index_write
}

ca_index_get() { ca_index_read | jq -ce --arg id "$1" '.accounts[] | select(.id == $id)'; }

ca_index_label() { ca_index_read | jq -r --arg id "$1" '.accounts[] | select(.id == $id) | .label'; }

ca_index_find() {  # ca_index_find <id|label|email>: prints the id; fails on no or several matches
  local ids count
  ids=$(ca_index_read | jq -r --arg q "$1" '
    [.accounts[] | select(.id == $q)] as $by_id
    | [.accounts[] | select(.label == $q)] as $by_label
    | [.accounts[] | select(.email == $q)] as $by_email
    | (if ($by_id | length) > 0 then $by_id elif ($by_label | length) > 0 then $by_label else $by_email end)
    | .[].id')
  count=$(printf '%s\n' "$ids" | grep -c . || true)
  case "$count" in
    1) printf '%s' "$ids" ;;
    0) ca_warn "no saved account matches '$1' (see: claude-acct list)"; return 1 ;;
    *) ca_warn "'$1' matches several accounts; use its id (see: claude-acct list)"; return 1 ;;
  esac
}
