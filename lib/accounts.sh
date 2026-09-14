# shellcheck shell=bash
# Account commands.

ca_require_valid_blob() {  # ca_require_valid_blob <blob>
  printf '%s' "$1" | ca_oauth_valid ||
    ca_die "Claude Code credentials have an unexpected format; nothing was changed (is claude-acct up to date?)"
}

ca_cmd_save() {  # save [--label LABEL]
  local label="" blob acct key id
  while [ $# -gt 0 ]; do
    case "$1" in
      --label) [ $# -ge 2 ] || ca_die "--label needs a value"; label=$2; shift 2 ;;
      *) ca_die "usage: claude-acct save [--label LABEL]" ;;
    esac
  done
  ca_lock
  ca_store_present || ca_die "Claude Code is not logged in; run /login first"
  blob=$(ca_store_read) || ca_die "could not read Claude Code credentials"
  ca_require_valid_blob "$blob"
  acct=$(ca_gconfig_account) || ca_die "no logged-in account in $(ca_global_config_path); run /login first"
  key=$(printf '%s' "$acct" | ca_account_key)
  id=$(ca_account_id "$key")
  printf '%s\n%s\n' "$blob" "$acct" | ca_vault_record | ca_vault_put "$id" ||
    ca_die "could not store the account"
  ca_index_upsert "$(printf '%s\n%s\n' "$blob" "$acct" | ca_index_entry "$id" "$key" "$label")" ||
    ca_die "could not update $(ca_index_path)"
  ca_log "save $id"
  printf 'Saved %s (%s)\n' "$(ca_index_label "$id")" "$id"
  ca_settings_poke
}

ca_cmd_list() {
  local active
  active=$(ca_active_id 2>/dev/null || true)
  ca_index_read | jq -r --arg active "$active" '
    if (.accounts | length) == 0 then
      "No saved accounts yet. Log in with /login, then run: claude-acct save"
    else
      .accounts[]
      | "\(if .id == $active then "*" else " " end) \(.id)  \(.label)  [\(if (.plan // "") == "" then "?" else .plan end)"
        + (if .loginExpiresAt then ", login until \(.loginExpiresAt / 1000 | floor | strftime("%Y-%m-%d"))" else "" end)
        + "]"
    end'
}

ca_cmd_rename() {  # rename <account> <label>
  local id new
  { [ $# -eq 2 ] && [ -n "$2" ]; } || ca_die "usage: claude-acct rename <account> <label>"
  ca_lock
  id=$(ca_index_find "$1") || exit 1
  new=$(ca_index_read | jq -c --arg id "$id" --arg label "$2" '
    .accounts |= map(if .id == $id then .label = ($label | gsub("[[:cntrl:]]"; "")) else . end)') ||
    ca_die "could not update $(ca_index_path)"
  printf '%s\n' "$new" | ca_index_write || ca_die "could not update $(ca_index_path)"
  printf 'Renamed %s to %s\n' "$id" "$(ca_index_label "$id")"
  ca_settings_poke
}

ca_cmd_rm() {  # rm <account>
  local id
  [ $# -eq 1 ] || ca_die "usage: claude-acct rm <account>"
  ca_lock
  id=$(ca_index_find "$1") || exit 1
  ca_vault_del "$id"
  ca_index_remove "$id" || ca_die "could not update $(ca_index_path)"
  ca_rl_remove "$id" 2>/dev/null || true
  ca_log "rm $id"
  printf 'Removed %s\n' "$id"
  ca_settings_poke
}

# ca_apply <live-blob> <record>: make Claude Code use the account in <record>.
# Only account-bound keys change; verified by reading back, rolled back on failure.
ca_apply() {
  local new want got acct
  { [ -n "$1" ] && [ -n "$2" ]; } || return 1
  new=$(printf '%s\n%s\n' "$1" "$2" | jq -cs --argjson bound "$CA_BOUND_KEYS" '
    (.[0] | with_entries(select(.key as $k | any($bound[]; . == $k) | not)))
    + (.[1] | del(.oauthAccount))') || return 1
  want=$(printf '%s' "$2" | jq -r '.claudeAiOauth.refreshToken // empty')
  if printf '%s' "$new" | ca_store_write &&
    got=$(ca_store_read | jq -r '.claudeAiOauth.refreshToken // empty') &&
    [ "$got" = "$want" ]; then
    acct=$(printf '%s' "$2" | jq -c '.oauthAccount // null')
    # The config and the store must agree: the background re-save picks the vault
    # slot from the config, so a store holding B under a config naming A would file
    # B's tokens under A. A record without an account is a logged-out state and
    # clears the config for the same reason.
    if { [ "$acct" != null ] && printf '%s' "$acct" | ca_gconfig_set_account; } ||
       { [ "$acct" = null ] && ca_gconfig_clear_account; }; then
      return 0
    fi
    ca_warn "could not update $(ca_global_config_path); undoing the switch"
  fi
  printf '%s' "$1" | ca_store_write || ca_warn "rollback failed; run: claude-acct restore"
  return 1
}

# ca_current_state: what Claude Code holds now — CA_LIVE (blob, {} when logged
# out), CA_ACCT (oauthAccount or null) and CA_CUR_ID (its id, or empty).
ca_current_state() {
  CA_LIVE=$(ca_live_blob) || return 1
  if CA_ACCT=$(ca_gconfig_account); then
    CA_CUR_ID=$(ca_account_id "$(printf '%s' "$CA_ACCT" | ca_account_key)")
  else
    CA_ACCT=null
    CA_CUR_ID=""
  fi
}

# ca_switch_to <record> <label> [poked-at-ms]: the switch itself, shared by use
# and restore. Expects ca_current_state to have run under ca_lock.
ca_switch_to() {
  local record=$1 label=$2 started=${3:-} overrides
  overrides=$(ca_overrides | paste -sd, - || true)
  [ -z "$overrides" ] ||
    ca_warn "note: $overrides takes precedence over the login, so Claude Code keeps using it"

  # Poke now, not after: Claude Code redraws about a second after settings change,
  # and the switch below finishes well within that, so the redraw shows the result.
  # A click has already poked before even resolving the account (see url.sh).
  if [ -z "$started" ]; then
    started=$(ca_now_ms)
    ca_settings_poke
  fi

  # Refresh tokens rotate while an account is in use: update its saved copy before leaving.
  if [ -n "$CA_CUR_ID" ] && ca_index_get "$CA_CUR_ID" >/dev/null 2>&1 &&
    printf '%s' "$CA_LIVE" | jq -e 'has("claudeAiOauth")' >/dev/null 2>&1; then
    printf '%s\n%s\n' "$CA_LIVE" "$CA_ACCT" | ca_vault_record | ca_vault_put "$CA_CUR_ID" ||
      ca_die "could not update the saved copy of the current account; nothing was switched"
  elif [ -n "$CA_CUR_ID" ]; then
    ca_warn "the account you are leaving is not saved; to keep it, /login to it and click ＋ save"
  fi

  # The backup goes first, so a failed rollback can still point at it.
  printf '%s\n%s\n' "$CA_LIVE" "$CA_ACCT" | ca_vault_record | ca_vault_put __backup__ ||
    ca_die "could not write the backup; nothing was switched"
  ca_apply "$CA_LIVE" "$record" || ca_die "switch failed; the previous login is still active"
  # shellcheck disable=SC2016  # a jq filter: its $names are jq variables
  ca_rl_update '.switch = {from: (if $from == "" then null else $from end), at: $now}' \
    --arg from "${CA_CUR_ID:-}" --argjson now "$(date +%s)" >/dev/null 2>&1 || true
  ca_log "switch to $label (was ${CA_CUR_ID:-none})"
  printf 'Switched to %s\n' "$label"

  # Bookkeeping nothing above depends on: the index entry of the account just left.
  if [ -n "$CA_CUR_ID" ] && [ "$CA_ACCT" != null ] && ca_index_get "$CA_CUR_ID" >/dev/null 2>&1; then
    ca_index_upsert "$(printf '%s\n%s\n' "$CA_LIVE" "$CA_ACCT" |
      ca_index_entry "$CA_CUR_ID" "$(printf '%s' "$CA_ACCT" | ca_account_key)" "")" || true
  fi
  # If a status line already drew while the switch was in progress, it showed the
  # old account: poke once more so the next redraw shows the new one.
  ! ca_statusline_ran_since "$started" || ca_settings_poke

  # Its limits are refreshed in the background (answers from the last minute are
  # reused) and appear at the next timer tick — the row already shows what that
  # account last reported.
  if [ "${CA_USAGE_SYNC:-0}" = 1 ]; then
    ca_usage_refresh --if-older-than "$CA_USAGE_FRESH_SECONDS" >/dev/null 2>&1 || true
  else
    "$(ca_self)" round switch >/dev/null 2>&1 </dev/null &
  fi
  return 0
}

ca_live_blob() {  # the current blob, {} when logged out; dies when it exists but cannot be read
  local blob
  if ! ca_store_present; then
    printf '{}'
    return 0
  fi
  blob=$(ca_store_read) || ca_die "could not read Claude Code credentials; nothing was changed"
  if printf '%s' "$blob" | jq -e 'has("claudeAiOauth")' >/dev/null 2>&1; then
    ca_require_valid_blob "$blob"
  fi
  printf '%s' "$blob"
}

ca_cmd_use() {  # use <account>
  local id saved
  [ $# -eq 1 ] || ca_die "usage: claude-acct use <account>"
  ca_lock
  id=$(ca_index_find "$1") || exit 1
  saved=$(ca_vault_get "$id") ||
    ca_die "no saved credentials for $id; log in to that account and run: claude-acct save"
  ca_current_state || exit 1
  if [ "$CA_CUR_ID" = "$id" ] && printf '%s' "$CA_LIVE" | jq -e 'has("claudeAiOauth")' >/dev/null 2>&1; then
    printf 'Already using %s (%s)\n' "$(ca_index_label "$id")" "$id"
    return 0
  fi
  ca_switch_to "$saved" "$(ca_index_label "$id") ($id)" "${CA_POKED_AT:-}"
}

# ca_sync_active: bring the vault copy of the active account up to date with the
# tokens Claude Code is using now. Refresh tokens rotate while an account is in
# use, and /login to another account drops the old ones without telling us, so
# the background round calls this every few minutes. Nothing to do when the
# active account is not saved, or when the tokens have not changed.
ca_sync_active() {
  local acct id live saved
  acct=$(ca_gconfig_account) || return 0
  id=$(ca_account_id "$(printf '%s' "$acct" | ca_account_key)")
  ca_index_get "$id" >/dev/null 2>&1 || return 0
  ca_store_present || return 0
  live=$(ca_store_read) || return 0
  printf '%s' "$live" | ca_oauth_valid || return 0
  saved=$(ca_vault_get "$id") || return 0
  [ "$(printf '%s' "$live" | jq -r '.claudeAiOauth.refreshToken + "/" + .claudeAiOauth.accessToken')" != \
    "$(printf '%s' "$saved" | jq -r '.claudeAiOauth.refreshToken + "/" + .claudeAiOauth.accessToken')" ] || return 0
  printf '%s\n%s\n' "$live" "$acct" | ca_vault_record | ca_vault_put "$id" || return 0
  ca_index_upsert "$(printf '%s\n%s\n' "$live" "$acct" | ca_index_entry "$id" "$(printf '%s' "$acct" | ca_account_key)" "")" || true
  ca_log "sync $id"
}

ca_cmd_restore() {
  local backup
  ca_lock
  backup=$(ca_vault_get __backup__) || ca_die "there is no backup yet"
  ca_current_state || exit 1
  # A restore is a switch like any other: it re-saves the account it leaves and
  # writes a new backup, so a second restore goes back again.
  ca_switch_to "$backup" "$(printf '%s' "$backup" | jq -r '.oauthAccount.emailAddress // "the logged-out state"') (restored)"
}
