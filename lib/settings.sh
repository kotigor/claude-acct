# shellcheck shell=bash
# Wiring claude-acct into Claude Code's settings.json, and taking it out again.

ca_install_state_path() { printf '%s/install.json' "$(ca_data_dir)"; }

ca_settings_apply() {  # ca_settings_apply <app-dir>
  local app=$1 settings cur state new
  settings=$(ca_settings_path)
  mkdir -p "$(dirname "$settings")"
  if [ -f "$settings" ]; then cur=$(cat "$settings"); else cur='{}'; fi
  printf '%s' "$cur" | jq -e 'type == "object"' >/dev/null 2>&1 ||
    ca_die "$settings is not valid JSON; fix it and run the installer again"
  ca_ensure_data_dir
  mkdir -p "$(ca_data_dir)/backup"
  if [ -f "$settings" ]; then cp -p "$settings" "$(ca_data_dir)/backup/settings.json.$(date +%Y%m%d%H%M%S)"; fi
  if [ -f "$(ca_install_state_path)" ]; then state=$(cat "$(ca_install_state_path)"); else state='{}'; fi

  state=$(printf '%s\n%s\n' "$state" "$cur" | jq -cs --arg app "$app" --arg settings "$settings" '
    def ours_statusline: if type == "object" then ((.command // "") | test("claude-acct.*statusline")) else false end;
    def ours_browser: if type == "string" then test("claude-acct-browser") else false end;
    .[0] as $old | .[1] as $cur
    | {version: 1, appDir: $app, settingsPath: $settings,
       originals: {
         statusLine: (if ($cur.statusLine | ours_statusline) then $old.originals.statusLine else $cur.statusLine end),
         env: {
           BROWSER: (if ($cur.env.BROWSER | ours_browser) then $old.originals.env.BROWSER else $cur.env.BROWSER end),
           FORCE_HYPERLINK: (if ($cur.env.BROWSER | ours_browser) then $old.originals.env.FORCE_HYPERLINK
                             else $cur.env.FORCE_HYPERLINK end)}}}') || return 1

  new=$(printf '%s\n%s\n' "$cur" "$state" | jq -s --arg app "$app" '
    .[1].originals as $o
    | .[0]
    | .statusLine = ({type: "command",
                      command: (($app + "/bin/claude-acct" | @sh) + " statusline"),
                      refreshInterval: ([10, ($o.statusLine.refreshInterval // 10)] | min)}
                     + (if $o.statusLine.padding != null then {padding: $o.statusLine.padding} else {} end))
    | .env = ((.env // {}) + {BROWSER: ($app + "/bin/claude-acct-browser"), FORCE_HYPERLINK: "1"})') || return 1

  printf '%s\n' "$state" | ca_write_atomic "$(ca_install_state_path)" 600 || return 1
  printf '%s\n' "$new" | ca_write_atomic "$settings" "$(ca_file_mode "$settings" 644)"
}

ca_now_ms() {
  perl -MTime::HiRes=time -e 'printf "%.0f", time * 1000' 2>/dev/null || printf '%s000' "$(date +%s)"
}

# ca_settings_poke: make every open Claude Code session re-run the status line now.
# Claude Code re-runs it when statusLine.command changes, so the command gets a
# fresh "--tick <ms>" argument (ignored by the script). Claude Code applies the
# change once the file has been stable for about a second, comparing content:
# the value only ever grows, so pokes that land close together merge into one
# redraw after the last of them instead of cancelling each other out.
ca_settings_poke() {
  local settings new lock tries=0
  settings=$(ca_settings_path)
  [ -f "$settings" ] || return 0
  ca_ensure_data_dir
  lock="$(ca_data_dir)/poke.lock"
  if [ -d "$lock" ] && [ -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
    rmdir "$lock" 2>/dev/null || true
  fi
  until mkdir "$lock" 2>/dev/null; do
    tries=$((tries + 1))
    [ "$tries" -lt 40 ] || return 0
    sleep 0.05
  done
  # Only our own status line is touched; nothing else in the file changes.
  new=$(jq -e --arg tick "$(ca_now_ms)" '
    if ((.statusLine.command // "") | test("claude-acct.*statusline")) then
      .statusLine.command |= (sub(" --tick [0-9]+$"; "") + " --tick " + $tick)
    else empty end' "$settings" 2>/dev/null) &&
    printf '%s\n' "$new" | ca_write_atomic "$settings" "$(ca_file_mode "$settings" 644)" && ca_log "poke"
  rmdir "$lock" 2>/dev/null || true
  return 0
}

ca_statusline_ran_since() {  # ca_statusline_ran_since <ms>: did a status line read its state after that moment?
  local ran
  ran=$(cat "$(ca_data_dir)/statusline.at" 2>/dev/null || echo 0)
  case "$ran" in '' | *[!0-9]*) ran=0 ;; esac
  [ "$ran" -gt "$1" ]
}

ca_settings_revert() {
  local state settings cur new
  [ -f "$(ca_install_state_path)" ] || return 0
  state=$(cat "$(ca_install_state_path)")
  settings=$(printf '%s' "$state" | jq -r '.settingsPath // empty')
  { [ -n "$settings" ] && [ -f "$settings" ]; } || return 0
  cur=$(cat "$settings")
  printf '%s' "$cur" | jq -e '(.statusLine.command // "") | test("claude-acct.*statusline")' >/dev/null 2>&1 ||
    ca_warn "statusLine in $settings was changed after installing; leaving it as it is"
  new=$(printf '%s\n%s\n' "$cur" "$state" | jq -s '
    def ours_statusline: if type == "object" then ((.command // "") | test("claude-acct.*statusline")) else false end;
    def ours_browser: if type == "string" then test("claude-acct-browser") else false end;
    def put($key; $value): if $value == null then del(.[$key]) else .[$key] = $value end;
    .[1].originals as $o
    | .[0]
    | (if (.statusLine | ours_statusline) then put("statusLine"; $o.statusLine) else . end)
    | (if (.env.BROWSER | ours_browser)
       then .env |= (put("BROWSER"; $o.env.BROWSER) | put("FORCE_HYPERLINK"; $o.env.FORCE_HYPERLINK))
       else . end)
    | if .env == {} then del(.env) else . end') || return 1
  printf '%s\n' "$new" | ca_write_atomic "$settings" "$(ca_file_mode "$settings" 644)"
}

ca_uninstall() {  # ca_uninstall [--purge]
  local purge=0 id
  case "${1:-}" in
    "") ;;
    --purge) purge=1 ;;
    *) ca_die "usage: claude-acct uninstall [--purge]" ;;
  esac
  ca_settings_revert || ca_warn "could not restore settings.json; remove statusLine and env.BROWSER by hand"
  if [ "$purge" = 1 ]; then
    for id in $(ca_index_read | jq -r '.accounts[].id') __backup__; do ca_vault_del "$id" || true; done
    rm -rf "$(ca_data_dir)"
  else
    rm -rf "$(ca_data_dir)/app"
    rm -f "$(ca_install_state_path)"
  fi
  if [ -L "$HOME/.local/bin/claude-acct" ]; then rm -f "$HOME/.local/bin/claude-acct"; fi
  echo "claude-acct removed."
  if [ "$purge" = 1 ]; then
    echo "Saved accounts and backups were deleted."
  else
    echo "Saved accounts were kept; run with --purge to delete them."
  fi
  echo "Claude Code sessions that are already open keep the old BROWSER value until restarted."
}
