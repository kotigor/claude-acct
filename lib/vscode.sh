# shellcheck shell=bash
# The VS Code terminal opens clicked links by itself (and sends http links to its
# built-in browser), so Claude Code does not hand them to $BROWSER there. The way
# in is a vscode://<extension>/... link: VS Code routes those to the extension
# with that id, and ours (vscode/ in the app) passes them to `claude-acct open-url`.
# `claude-acct vscode-setup` builds that extension into a .vsix and installs it
# with VS Code's own command; the status line then links through it under VS Code.

CA_VSCODE_EXT_ID=kotigor.claude-acct
# shellcheck disable=SC2034  # used by statusline.sh
CA_VSCODE_URL_BASE="vscode://$CA_VSCODE_EXT_ID"

# ca_vscode_cli: VS Code's `code` command. CLAUDE_ACCT_CODE_CLI overrides the search.
ca_vscode_cli() {
  local c
  if [ -n "${CLAUDE_ACCT_CODE_CLI:-}" ]; then
    [ -x "$CLAUDE_ACCT_CODE_CLI" ] && printf '%s' "$CLAUDE_ACCT_CODE_CLI"
    return
  fi
  if command -v code >/dev/null 2>&1; then command -v code; return; fi
  for c in "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code" \
    "$HOME/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code" \
    /usr/share/code/bin/code /usr/bin/code; do
    if [ -x "$c" ]; then printf '%s' "$c"; return; fi
  done
  return 1
}

ca_vscode_version() { jq -r '.vscode.version // empty' "$(ca_install_state_path)" 2>/dev/null || true; }

# ca_vscode_build_vsix <out-file>: package vscode/ the way vsce would, with zip.
ca_vscode_build_vsix() {
  local out=$1 src="${CA_APP:?}/vscode" tmp version
  version=$(cat "$CA_APP/VERSION")
  if ! { [ -f "$src/package.json" ] && [ -f "$src/extension.js" ]; }; then
    ca_die "the extension sources are missing from $src; reinstall claude-acct"
  fi
  command -v zip >/dev/null 2>&1 || ca_die "zip is required to build the extension (sudo apt install zip)"
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/claude-acct-vsix.XXXXXX") || return 1
  mkdir -p "$tmp/extension"
  jq --arg v "$version" '.version = $v' "$src/package.json" >"$tmp/extension/package.json" || { rm -rf "$tmp"; return 1; }
  cp "$src/extension.js" "$tmp/extension/extension.js"
  cat >"$tmp/[Content_Types].xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension=".json" ContentType="application/json"/>
  <Default Extension=".js" ContentType="application/javascript"/>
  <Default Extension=".vsixmanifest" ContentType="text/xml"/>
</Types>
XML
  cat >"$tmp/extension.vsixmanifest" <<XML
<?xml version="1.0" encoding="utf-8"?>
<PackageManifest Version="2.0.0" xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011" xmlns:d="http://schemas.microsoft.com/developer/vsx-schema-design/2011">
  <Metadata>
    <Identity Language="en-US" Id="claude-acct" Version="$version" Publisher="kotigor"/>
    <DisplayName>claude-acct</DisplayName>
    <Description xml:space="preserve">Makes the claude-acct status line links work in the VS Code terminal.</Description>
    <Tags></Tags>
    <Categories>Other</Categories>
    <GalleryFlags>Public</GalleryFlags>
    <Properties>
      <Property Id="Microsoft.VisualStudio.Code.Engine" Value="^1.80.0"/>
      <Property Id="Microsoft.VisualStudio.Code.ExtensionDependencies" Value=""/>
      <Property Id="Microsoft.VisualStudio.Code.ExtensionPack" Value=""/>
      <Property Id="Microsoft.VisualStudio.Code.ExtensionKind" Value="workspace,ui"/>
      <Property Id="Microsoft.VisualStudio.Code.LocalizedLanguages" Value=""/>
    </Properties>
  </Metadata>
  <Installation>
    <InstallationTarget Id="Microsoft.VisualStudio.Code"/>
  </Installation>
  <Dependencies/>
  <Assets>
    <Asset Type="Microsoft.VisualStudio.Code.Manifest" Path="extension/package.json" Addressable="true"/>
  </Assets>
</PackageManifest>
XML
  rm -f "$out"
  (cd "$tmp" && zip -qr "$out" '[Content_Types].xml' extension.vsixmanifest extension) || { rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
}

ca_cmd_vscode_setup() {  # vscode-setup
  local cli vsix state
  [ $# -eq 0 ] || ca_die "usage: claude-acct vscode-setup"
  cli=$(ca_vscode_cli) || ca_die "VS Code's code command was not found; in VS Code run \"Shell Command: Install 'code' command in PATH\" from the Command Palette, or set CLAUDE_ACCT_CODE_CLI to it"
  ca_ensure_data_dir
  vsix="$(ca_data_dir)/claude-acct.vsix"
  ca_vscode_build_vsix "$vsix" || ca_die "could not build the extension"
  "$cli" --install-extension "$vsix" --force >/dev/null || ca_die "VS Code refused the extension; run by hand: $cli --install-extension $vsix"
  state=$(cat "$(ca_install_state_path)" 2>/dev/null || printf '{}')
  printf '%s' "$state" | jq --arg v "$(cat "$CA_APP/VERSION")" '.vscode = {version: $v}' |
    ca_write_atomic "$(ca_install_state_path)" 600 || ca_die "could not update $(ca_install_state_path)"
  ca_log "vscode-setup"
  cat <<EOM
Installed the $CA_VSCODE_EXT_ID extension in VS Code.
Reload VS Code windows that are open (Developer: Reload Window). In its terminal,
Cmd+click (Ctrl+click on Linux) an account in the status line; the first time,
VS Code asks whether the extension may open the link.
EOM
}

# ca_vscode_uninstall: take the extension out again, if it was ever set up. Best effort.
ca_vscode_uninstall() {
  local cli
  [ -n "$(ca_vscode_version)" ] || return 0
  cli=$(ca_vscode_cli) || return 0
  "$cli" --uninstall-extension "$CA_VSCODE_EXT_ID" >/dev/null 2>&1 || true
}
