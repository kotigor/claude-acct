# claude-acct

Switch [Claude Code](https://code.claude.com) between **your own** Claude accounts with one click in the status line — no browser, no re-login.

```
● me@example.com 5h 24%↻2h · 7d 5%↻5d  │  work@example.com 5h 80%↻1h · 7d 31%↻3d
⤡ collapse   ↻ limits
```

The active account is bold and orange. Each account, limits included, is one link (the active marker sits just before it), and so is each control. When the row is wider than the terminal the names shorten to `me…`, and `collapse` / `expand` force it either way.

Everything except the login stays the same: `CLAUDE.md`, settings, plugins, MCP servers, projects, history. Switching does to your credentials exactly what `/login` does, without the browser round trip.

## Is this allowed?

claude-acct is for people who pay for more than one Claude subscription themselves. Anthropic's terms forbid sharing accounts, reselling access, and automated or non-human access beyond what they permit. claude-acct only switches between logins you created, when you click. It never sends a prompt on its own, never "warms up" accounts, and never proxies traffic; the only requests it makes by itself are read-only usage lookups, the same ones Claude Code makes, at most every five minutes, and the standard OAuth renewal of a saved login whose access token has expired. Read the [Consumer Terms](https://www.anthropic.com/legal/consumer-terms) and the [Usage Policy](https://www.anthropic.com/legal/aup) and decide for yourself.

## Requirements

- Claude Code with **fullscreen rendering** (`/tui fullscreen`): clicks in the status line only work there.
- macOS, or Linux/WSL, with bash and `jq` (macOS 15+ ships `jq`).
- A terminal in which Claude Code handles link clicks: Ghostty and Warp (plain click), iTerm2, kitty, WezTerm (Cmd+click). The VS Code and JetBrains terminals open links by themselves; the installer sets both up (see below).
  Warp shows a URL tooltip over every link; to hide it, add `link_tooltip = false` under `[general]` in `~/.warp/settings.toml` (hot-reloaded, no restart).

## Install

```sh
git clone https://github.com/kotigor/claude-acct.git
cd claude-acct
./install.sh
```

The installer copies itself to `~/.local/share/claude-acct`, links `~/.local/bin/claude-acct`, and adds `statusLine`, `env.BROWSER` and `env.FORCE_HYPERLINK` to `~/.claude/settings.json` (or `$CLAUDE_CONFIG_DIR/settings.json`). An existing status line keeps working and is shown above the account row. Open sessions pick the change up by themselves. The clone is not needed after installing.

## Add your accounts

For each account:

1. `/login` in Claude Code and sign in.
2. Click **＋ save** in the status line.

To add another account later, just `/login` again and click **＋ save**. The saved copy of the account you leave is kept current in the background (see below), so nothing is lost.

> **Never use `/logout` to switch.** It revokes the login on Anthropic's side, and the saved copy stops working. `/login` does not revoke anything.

## Switch

Click an account in the status line. The row updates within a couple of seconds and open sessions follow; a notification appears only if something went wrong. From a terminal:

```sh
claude-acct list
claude-acct refresh                # update the limits of every account
claude-acct use work@example.com   # id, label or email
claude-acct restore                # undo the last switch
claude-acct rename work@example.com work
claude-acct rm work
claude-acct doctor
```

## VS Code

VS Code's terminal opens clicked links itself (Cmd+click, Ctrl+click on Linux) and sends `localhost` links to its built-in browser, so Claude Code never hands them to `$BROWSER` there. The installer handles it: when VS Code is on the machine, `install.sh` also builds a tiny extension (`kotigor.claude-acct`, one file: it receives `vscode://kotigor.claude-acct/...` links and passes them to `claude-acct open-url`) and installs it with VS Code's `code` command; the status line then links through that scheme whenever it runs inside VS Code. Reload open windows afterwards; the first click asks whether the extension may open the link.

`./install.sh --no-vscode` skips this; `claude-acct vscode-setup` does it later; `claude-acct uninstall` removes the extension too. If `code` is not on your PATH, install it from the Command Palette ("Shell Command: Install 'code' command in PATH") or point `CLAUDE_ACCT_CODE_CLI` at it.

## JetBrains IDEs

The terminal in PhpStorm, IntelliJ IDEA and the other JetBrains IDEs also opens clicked links by itself, in the browser the IDE is set to use. The installer points that setting at claude-acct's link handler for every JetBrains IDE it finds on the machine (Settings > Tools > Web Browsers and Preview > Default Browser > Custom path, in the IDE's `ide.general.local.xml`), so clicks reach claude-acct the same way they do from Claude Code. The handler takes claude-acct's own links and opens every other link in your system browser, so nothing else changes. An IDE that is running picks the setting up when its window is next focused, or on restart.

`./install.sh --no-jetbrains` skips this; `claude-acct jetbrains-setup` does it later (for an IDE installed afterwards, say); `claude-acct uninstall` puts the previous setting back. Run `claude-acct doctor` from the IDE's terminal to check.

JetBrains ships two terminal engines (Settings > Tools > Terminal > Terminal engine). The classic one understands OSC 8 links: a click goes through the browser setting above, and links underline under the mouse. The reworked one does not, so there the click reaches Claude Code itself, which opens links on Ctrl+click; on macOS Ctrl+click is also the system right-click, so the terminal's context menu opens along with it. On the reworked engine the status line says so in a third row, with a `✕ hide` link for those who prefer to stay. Which engine runs is read from the IDE's settings (the shell drops the engine's own marker before Claude Code starts), so the Claude Code plugin's own tab, which is always classic, shows the row too while the setting is the reworked engine; hide it there.

## How it works

- **Credentials.** Claude Code keeps its login in the macOS Keychain (`Claude Code-credentials`) or in `~/.claude/.credentials.json`. The same record holds MCP logins and plugin secrets. claude-acct changes only the keys that belong to the account (`claudeAiOauth`, `designOauth`, `trustedDeviceToken`, `organizationUuid`) and `oauthAccount` in `~/.claude.json`, verifies the write, and rolls back on failure.
- **Saved accounts** live in the Keychain (service `claude-acct`) on macOS and in `0600` files under `~/.local/share/claude-acct/vault` on Linux. Claude Code rotates refresh tokens while an account is in use, and `/login` to another account drops the old ones, so claude-acct re-saves the active account's tokens before every switch and, every few minutes, whenever they changed.
- **Clicks.** The status line prints links to `http://claude-acct.localhost/…`. Claude Code opens clicked links with `$BROWSER`, which points to `claude-acct-browser`; it handles these links and passes every other link to your browser as before.
- **Redraws.** Claude Code re-runs a status line the moment its `command` changes in `settings.json`, so after every click or finished refresh claude-acct puts a fresh `--tick <ms>` argument on its own command and every open session redraws the row about 1.2 seconds after the last such change; the value only grows, so changes that land close together merge into one redraw rather than cancelling out. The timer (`refreshInterval: 10`) only moves the countdown.
- **Limits.** Claude Code reports rate limits only for the active account. For the rest, claude-acct asks the same endpoint Claude Code itself uses (`GET /api/oauth/usage`) with each account's own token, so the row shows real numbers for everyone. The numbers refresh at most once every 5 minutes, which is the same interval Claude Code caches them for, and also on a switch or a click of `↻ limits`. Idle sessions keep refreshing on purpose: waiting for a limit to reset is exactly when the countdown matters. No prompt is sent and no quota is consumed; a request that stalls is tried once more, and a login Anthropic is throttling is left alone for 15 minutes. Set `CLAUDE_ACCT_AUTO_REFRESH=0` to look limits up only when you ask; the background round still runs to keep the saved tokens current. A saved account's access token lasts a few hours; when it has expired, claude-acct renews that login the standard OAuth way (the same token endpoint and client id Claude Code uses, with the account's own refresh token) before asking, and files the new tokens in the vault first. Only saved, non-active accounts are renewed this way — the active one is Claude Code's. Requests identify themselves as `claude-acct/<version>`. Set `CLAUDE_ACCT_TOKEN_REFRESH=0` to turn that off. Numbers older than an hour show as `?`, and `refresh` says why. Right after a switch the session still reports the account you left until its next response; claude-acct recognises those numbers and never files them under the new account.

Running Claude Code sessions are not restarted: they re-read credentials before refreshing tokens and cannot overwrite the switched login.

## Limitations

- The usage endpoint is undocumented and could change or start refusing requests that do not come from Claude Code itself; claude-acct sends no forged client identity, so if that happens the row falls back to the last numbers each account reported.
- claude-acct relies on undocumented details of Claude Code: the credential record layout, the Keychain item name, and how links are opened. `claude-acct doctor` tells you when something no longer matches, and nothing is written if the credential format is unexpected.
- `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN`, `apiKeyHelper`, cloud providers and gateways take precedence over `/login`; switching has no effect while they are set.
- On macOS, credentials larger than about 2 KB are handed to `security` as arguments, which other local users can see with `ps` for a moment. Claude Code does the same.
- If a session refreshes its token at the very moment you switch, the saved copy of that account can go stale. `/login` to it and click **＋ save** again.
- A project `.claude/settings.json` with its own `statusLine` hides the switcher in that project.
- Hover highlighting is up to your terminal, not claude-acct: Claude Code passes the OSC 8 links through, and a terminal that highlights such links under the cursor (Warp from 0.2026.09, for example) highlights these too. Older Warp builds only highlighted bare URLs.

## Uninstall

```sh
claude-acct uninstall           # keeps saved accounts
claude-acct uninstall --purge   # also deletes them
```

The settings you had before installing are restored.

## Development

```sh
tests/run.sh            # all tests, for both the macOS and Linux backends
tests/run.sh use        # filter by name
```

Tests use a fake `security` and a temporary `HOME`; they never touch your real credentials.

## License

MIT
