# shellcheck shell=bash
# claude-acct doctor: what works, what does not, and what to do about it.

ca_cmd_doctor() {
  local failures=0 backend blob="" active overrides settings f
  ca_ok() { printf '  ok    %s\n' "$*"; }
  ca_note() { printf '  warn  %s\n' "$*"; }
  ca_bad() { printf '  FAIL  %s\n' "$*"; failures=$((failures + 1)); }

  printf 'claude-acct %s on %s\n' "$(cat "$CA_APP/VERSION" 2>/dev/null || echo '?')" "$(ca_platform)"
  ca_ok "$(jq --version)"

  backend=$(ca_store_backend)
  if ! ca_store_present; then
    ca_note "credentials: not logged in ($backend); run /login in Claude Code"
  elif ! blob=$(ca_store_read); then
    ca_bad "credentials: could not read them ($backend)"
  elif printf '%s' "$blob" | ca_oauth_valid; then
    ca_ok "credentials: $backend, format recognised"
  elif ! printf '%s' "$blob" | jq -e 'has("claudeAiOauth")' >/dev/null 2>&1; then
    ca_note "credentials: $backend, logged out (MCP logins and plugin secrets kept); /login or switch to a saved account"
  else
    ca_bad "credentials: $backend, unexpected format; switching is disabled until claude-acct is updated"
  fi
  if [ "$(ca_platform)" = Darwin ] && [ "$backend" = keychain ] && [ -f "$(ca_credentials_file)" ]; then
    ca_note "both a Keychain item and $(ca_credentials_file) exist; Claude Code uses the Keychain"
  fi
  if [ -n "$blob" ] && printf '%s' "$blob" | jq -e 'has("enterpriseGateway")' >/dev/null 2>&1; then
    ca_note "a Claude apps gateway login is present; it outranks claude.ai logins, so switching has no effect"
  fi

  if active=$(ca_active_id 2>/dev/null); then
    if ca_index_get "$active" >/dev/null 2>&1; then
      ca_ok "active account is saved: $(ca_index_label "$active")"
    else
      ca_note "active account is not saved yet; click ＋ save in the status line or run: claude-acct save"
    fi
  else
    ca_note "no logged-in account in $(ca_global_config_path)"
  fi

  overrides=$(ca_overrides | paste -sd, - || true)
  if [ -n "$overrides" ]; then
    ca_note "these take precedence over /login, so switching has no effect: $overrides"
  else
    ca_ok "no credential overrides (API keys, tokens, cloud providers)"
  fi

  settings=$(ca_settings_path)
  if jq -e '(.statusLine.command // "") | test("claude-acct.*statusline")' "$settings" >/dev/null 2>&1; then
    ca_ok "status line installed in $settings"
  else
    ca_bad "status line not installed in $settings; run install.sh"
  fi
  if jq -e '(.env.BROWSER // "") | test("claude-acct-browser")' "$settings" >/dev/null 2>&1; then
    ca_ok "link handler installed (env.BROWSER)"
  else
    ca_bad "env.BROWSER does not point to claude-acct-browser; run install.sh"
  fi
  if jq -e '.tui == "fullscreen"' "$settings" >/dev/null 2>&1 || [ "${CLAUDE_CODE_NO_FLICKER:-}" = 1 ]; then
    ca_ok "fullscreen rendering is on"
  else
    ca_note "clicking needs fullscreen rendering; run /tui in Claude Code to check, /tui fullscreen to enable"
  fi

  case "${TERM_PROGRAM:-}" in
    ghostty | WarpTerminal) ca_ok "terminal $TERM_PROGRAM: plain click" ;;
    iTerm.app | WezTerm | kitty) ca_ok "terminal $TERM_PROGRAM: Cmd+click (Ctrl+click on Linux)" ;;
    vscode)
      if [ -n "$(ca_vscode_version)" ]; then
        ca_ok "terminal vscode: Cmd+click (Ctrl+click on Linux), through the $CA_VSCODE_EXT_ID extension"
      else
        ca_note "the VS Code terminal opens links itself; run once: claude-acct vscode-setup"
      fi ;;
    "") ca_note "terminal unknown; run inside Claude Code as: ! claude-acct doctor" ;;
    *) ca_note "terminal $TERM_PROGRAM: untested; try Cmd+click or Ctrl+click" ;;
  esac

  if [ -d .claude ] && [ "$(cd .claude && pwd -P)" != "$(cd "$(ca_config_dir)" 2>/dev/null && pwd -P)" ]; then
    for f in .claude/settings.json .claude/settings.local.json; do
      if jq -e 'has("statusLine")' "$f" >/dev/null 2>&1; then
        ca_note "$PWD/$f sets its own statusLine, which hides the switcher in this project"
      fi
    done
  fi
  if [ "$(ca_platform)" = Linux ] && [ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
    ca_note "no graphical display: links Claude Code opens (such as /login) may fail; copy the URL it prints"
  fi

  [ "$failures" -eq 0 ]
}
