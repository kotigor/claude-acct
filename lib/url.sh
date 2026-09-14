# shellcheck shell=bash
# $BROWSER handler. Claude Code opens clicked links with "$BROWSER <url>":
# claude-acct.localhost links are ours, anything else goes where it would have gone.

ca_cmd_open_url() {  # open-url <url>
  local url=${1:-} path id out
  case "$url" in
    "$CA_URL_BASE"/*) ;;
    *) ca_open_elsewhere "$@"; return ;;
  esac
  path=${url#"$CA_URL_BASE"/}
  path=${path%%[?#]*}
  path=${path%/}
  case "$path" in
    use/*)
      id=${path#use/}
      if ! ca_valid_id "$id" || [ "$id" = __backup__ ]; then
        ca_notify "claude-acct" "Invalid account link"
        return 0
      fi
      # Poke before doing anything: Claude Code redraws about a second after the
      # settings change, and the whole switch fits inside that second.
      # shellcheck disable=SC2034  # read by ca_switch_to (accounts.sh)
      CA_POKED_AT=$(ca_now_ms)
      ca_settings_poke
      out=$( (ca_cmd_use "$id") 2>&1) ||
        ca_notify "claude-acct: switch failed" "$(printf '%s\n' "$out" | tail -n 1 | sed 's/^claude-acct: //')" ;;
    save)
      if out=$( (ca_cmd_save) 2>&1); then
        :
      else
        ca_notify "claude-acct: save failed" "$(printf '%s\n' "$out" | tail -n 1 | sed 's/^claude-acct: //')"
      fi ;;
    refresh)
      out=$(ca_usage_refresh)
      ca_settings_poke
      [ -z "$out" ] || ca_notify "claude-acct: some limits are missing" "$(printf '%s' "$out" | head -n 2)" ;;
    collapse) ca_ui_set_collapsed true ;;
    expand) ca_ui_set_collapsed false ;;
    *) ca_notify "claude-acct" "Unknown link: $path" ;;
  esac
  return 0
}

ca_open_elsewhere() {  # open a URL the way it would be opened without claude-acct
  local orig
  # settings.json's BROWSER, or the one the shell had when claude-acct was installed
  orig=$(jq -r '.originals.env.BROWSER // .shellBrowser // empty' "$(ca_data_dir)/install.json" 2>/dev/null || true)
  case "$orig" in *claude-acct-browser*) orig="" ;; esac
  if [ -n "$orig" ]; then
    BROWSER=$orig "$orig" "$@"
    return
  fi
  unset BROWSER  # xdg-open falls back to $BROWSER, which points back here
  case "$(ca_platform)" in
    Darwin) open "$@" ;;
    *) command -v xdg-open >/dev/null 2>&1 && xdg-open "$@" ;;
  esac
}
