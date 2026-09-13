#!/usr/bin/env bash
# Install or upgrade claude-acct for the current user.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
for f in "$here"/lib/*.sh; do
  # shellcheck source=/dev/null
  . "$f"
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
cp -R "$here/bin" "$here/lib" "$here/VERSION" "$app.new/"
chmod 755 "$app.new/bin/claude-acct" "$app.new/bin/claude-acct-browser"
rm -rf "$app"
mv "$app.new" "$app"

mkdir -p "$HOME/.local/bin"
ln -sfn "$app/bin/claude-acct" "$HOME/.local/bin/claude-acct"

ca_settings_apply "$app"

printf 'claude-acct %s installed.\n' "$(cat "$app/VERSION")"
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
