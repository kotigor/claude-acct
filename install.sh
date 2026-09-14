#!/usr/bin/env bash
# Install or upgrade claude-acct for the current user.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
for f in "$here"/lib/*.sh; do
  # shellcheck source=/dev/null
  . "$f"
done

want_vscode=1
want_jetbrains=1
for arg in "$@"; do
  case "$arg" in
    --no-vscode) want_vscode=0 ;;
    --no-jetbrains) want_jetbrains=0 ;;
    *) ca_die "usage: install.sh [--no-vscode] [--no-jetbrains]" ;;
  esac
done

command -v jq >/dev/null 2>&1 ||
  ca_die "jq is required (macOS 15+ includes it; otherwise: brew install jq, or sudo apt install jq)"
case "$(ca_platform)" in
  Darwin) command -v xxd >/dev/null 2>&1 || ca_die "xxd is required" ;;
  Linux) ;;
  *) ca_die "unsupported platform $(ca_platform): claude-acct works on macOS and Linux/WSL" ;;
esac

app="$(ca_data_dir)/app"
ca_ensure_data_dir
rm -rf "$app.new"
mkdir -p "$app.new"
cp -R "$here/bin" "$here/lib" "$here/vscode" "$here/VERSION" "$app.new/"
chmod 755 "$app.new/bin/claude-acct" "$app.new/bin/claude-acct-browser"
rm -rf "$app"
mv "$app.new" "$app"

mkdir -p "$HOME/.local/bin"
ln -sfn "$app/bin/claude-acct" "$HOME/.local/bin/claude-acct"

ca_settings_apply "$app"

printf 'claude-acct %s installed.\n' "$(cat "$app/VERSION")"
# VS Code's terminal opens links by itself; its extension makes them reach claude-acct.
# Set up whenever VS Code is on this machine; --no-vscode leaves it alone.
vscode_line=""
if [ "$want_vscode" = 1 ] && ca_vscode_cli >/dev/null 2>&1; then
  if CA_APP=$app ca_cmd_vscode_setup >/dev/null 2>&1; then
    vscode_line="VS Code found: its extension is installed too, so clicks work in its terminal (reload open windows)."
  else
    vscode_line="VS Code found, but its extension could not be installed; run by hand: claude-acct vscode-setup"
  fi
elif [ "${TERM_PROGRAM:-}" = vscode ]; then
  vscode_line="For clicks in the VS Code terminal, run once: claude-acct vscode-setup"
fi
[ -z "$vscode_line" ] || printf '%s\n' "$vscode_line"
# JetBrains terminals open links in the browser the IDE is set to use: make that us.
if [ "$want_jetbrains" = 1 ] && [ -n "$(ca_jetbrains_files)" ]; then
  CA_APP=$app ca_cmd_jetbrains_setup || echo "JetBrains IDEs found, but their setting could not be written; run by hand: claude-acct jetbrains-setup"
fi
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) printf 'Add %s to your PATH to use the claude-acct command.\n' "$HOME/.local/bin" ;;
esac
cat <<'EOF'

In Claude Code:
  1. Clicking needs fullscreen rendering: run /tui fullscreen if it is not on.
  2. For each of your accounts: /login, then click "＋ save" in the status line.
  3. Click an account in the status line to switch to it.
  Do not use /logout to switch: it revokes the login, and the saved copy stops working.

Open sessions pick this up by themselves. Check the setup with: claude-acct doctor
EOF
