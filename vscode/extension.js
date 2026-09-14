// The VS Code side of claude-acct. VS Code's terminal opens clicked links by
// itself, so Claude Code never hands them to $BROWSER there; instead the status
// line links to vscode://kotigor.claude-acct/<action>, VS Code routes such links
// to this extension, and this passes them on to the claude-acct command exactly
// as $BROWSER would. Nothing else lives here.
'use strict';
const vscode = require('vscode');
const { execFile } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const URL_BASE = 'http://claude-acct.localhost';

function claudeAcct() {
  const home = os.homedir();
  const data = process.env.XDG_DATA_HOME || path.join(home, '.local', 'share');
  const candidates = [
    path.join(data, 'claude-acct', 'app', 'bin', 'claude-acct'),
    path.join(home, '.local', 'bin', 'claude-acct'),
  ];
  for (const p of candidates) {
    try { fs.accessSync(p, fs.constants.X_OK); return p; } catch (_) { /* try the next */ }
  }
  return 'claude-acct';
}

function env() {
  // The extension host can run with a bare PATH; jq usually lives in one of these.
  const extra = ['/opt/homebrew/bin', '/usr/local/bin', path.join(os.homedir(), '.local', 'bin'), '/usr/bin', '/bin'];
  const current = (process.env.PATH || '').split(path.delimiter).filter(Boolean);
  const merged = current.concat(extra.filter((p) => !current.includes(p)));
  return Object.assign({}, process.env, { PATH: merged.join(path.delimiter) });
}

function activate(context) {
  context.subscriptions.push(vscode.window.registerUriHandler({
    handleUri(uri) {
      const url = URL_BASE + uri.path + (uri.query ? '?' + uri.query : '');
      execFile(claudeAcct(), ['open-url', url], { env: env() }, (error, _stdout, stderr) => {
        if (error) {
          vscode.window.showErrorMessage('claude-acct: ' + String(stderr || error.message).trim());
        }
      });
    },
  }));
}

function deactivate() {}

module.exports = { activate, deactivate };
