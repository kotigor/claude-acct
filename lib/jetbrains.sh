# shellcheck shell=bash
# JetBrains IDEs (PhpStorm, IntelliJ IDEA, Rider, ...) open links from their
# terminal in the browser the IDE is set to use. Pointing that setting at
# claude-acct-browser makes clicks reach claude-acct the way they do from Claude
# Code; every other link still opens in the system browser. The setting lives in
# each IDE's options/ide.general.local.xml (component GeneralLocalSettings:
# browserPath plus useDefaultBrowser=false is what "Custom path" means).
# `claude-acct jetbrains-setup` writes it for every JetBrains IDE on the machine,
# the installer does so by itself, and uninstall puts the previous values back.

ca_jetbrains_roots() {
  case "$(ca_platform)" in
    Darwin) printf '%s\n' "$HOME/Library/Application Support/JetBrains" ;;
    *) printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/JetBrains" ;;
  esac
}

# ca_jetbrains_files: every IDE's ide.general.local.xml, one per line (the file
# itself may not exist yet; its options directory does).
ca_jetbrains_files() {
  local root d
  while IFS= read -r root; do
    [ -d "$root" ] || continue
    for d in "$root"/*/options; do
      [ -d "$d" ] || continue
      printf '%s\n' "$d/ide.general.local.xml"
    done
  done <<EOR
$(ca_jetbrains_roots)
EOR
}

ca_jetbrains_ide() { basename "$(dirname "$(dirname "$1")")"; }  # PhpStorm2025.3 from its file

# ca_same_file <a> <b>: the same file under two spellings (symlinks, doubled slashes)?
ca_same_file() {
  local a b
  a=$(cd -P "$(dirname "$1")" 2>/dev/null && pwd)/$(basename "$1")
  b=$(cd -P "$(dirname "$2")" 2>/dev/null && pwd)/$(basename "$2")
  [ "$a" = "$b" ]
}

ca_xml_escape() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'; }
ca_xml_unescape() { printf '%s' "$1" | sed -e 's/&quot;/"/g' -e 's/&lt;/</g' -e 's/&gt;/>/g' -e 's/&apos;/'"'"'/g' -e 's/&amp;/\&/g'; }

# ca_jetbrains_option <file> <name>: that GeneralLocalSettings option's value, if set.
ca_jetbrains_option() {
  [ -f "$1" ] || return 0
  ca_xml_unescape "$(sed -n "s/.*<option name=\"$2\" value=\"\([^\"]*\)\".*/\1/p" "$1" | head -n 1)"
}

# ca_jetbrains_apply <file> <browserPath> <useDefaultBrowser>: set the two options
# (an empty value drops the option), keeping everything else in the file.
ca_jetbrains_apply() {
  local file=$1 opts="" cur new
  [ -z "$2" ] || opts="$opts    <option name=\"browserPath\" value=\"$(ca_xml_escape "$2")\" />"$'\n'
  [ -z "$3" ] || opts="$opts    <option name=\"useDefaultBrowser\" value=\"$3\" />"$'\n'
  if [ -f "$file" ]; then cur=$(cat "$file"); else cur=$'<application>\n</application>'; fi
  new=$(printf '%s\n' "$cur" | CA_OPTS="$opts" awk '
    /<option name="browserPath"/ || /<option name="useDefaultBrowser"/ { next }
    /<component name="GeneralLocalSettings" *\/>/ {
      print "  <component name=\"GeneralLocalSettings\">"; printf "%s", ENVIRON["CA_OPTS"]; print "  </component>"; done = 1; next }
    /<component name="GeneralLocalSettings">/ { print; printf "%s", ENVIRON["CA_OPTS"]; done = 1; next }
    /<\/application>/ && !done {
      print "  <component name=\"GeneralLocalSettings\">"; printf "%s", ENVIRON["CA_OPTS"]; print "  </component>"; done = 1 }
    { print }') || return 1
  printf '%s\n' "$new" | ca_write_atomic "$file" "$(ca_file_mode "$file" 644)"
}

# ca_jetbrains_configured: does a JetBrains IDE here open links with our handler?
ca_jetbrains_configured() {
  local f
  while IFS= read -r f; do
    if [ -z "$f" ] || [ ! -f "$f" ]; then continue; fi
    ! grep -q 'claude-acct-browser' "$f" 2>/dev/null || return 0
  done <<EOR
$(ca_jetbrains_files)
EOR
  return 1
}

ca_cmd_jetbrains_setup() {  # jetbrains-setup
  local shim files f prev_path prev_use state ides=""
  [ $# -eq 0 ] || ca_die "usage: claude-acct jetbrains-setup"
  shim="${CA_APP:?}/bin/claude-acct-browser"
  files=$(ca_jetbrains_files)
  [ -n "$files" ] || ca_die "no JetBrains IDE settings found under $(ca_jetbrains_roots)"
  ca_ensure_data_dir
  state=$(cat "$(ca_install_state_path)" 2>/dev/null || printf '{}')
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    prev_path=$(ca_jetbrains_option "$f" browserPath)
    prev_use=$(ca_jetbrains_option "$f" useDefaultBrowser)
    ides="$ides${ides:+, }$(ca_jetbrains_ide "$f")"
    # Already ours: leave the file alone. An older install's handler is replaced
    # without being remembered; anything else is what uninstall puts back.
    if [ -n "$prev_path" ] && ca_same_file "$prev_path" "$shim" && [ "$prev_use" = false ]; then continue; fi
    case "$prev_path" in
      */claude-acct-browser) ;;
      *) state=$(printf '%s' "$state" | jq --arg f "$f" --arg p "$prev_path" --arg u "$prev_use" \
           '.jetbrains[$f] = {browserPath: (if $p == "" then null else $p end), useDefaultBrowser: (if $u == "" then null else $u end)}') ||
           ca_die "could not update $(ca_install_state_path)" ;;
    esac
    ca_jetbrains_apply "$f" "$shim" false || ca_die "could not write $f"
  done <<EOR
$files
EOR
  printf '%s\n' "$state" | ca_write_atomic "$(ca_install_state_path)" 600 || ca_die "could not update $(ca_install_state_path)"
  ca_log "jetbrains-setup"
  printf 'JetBrains IDEs found (%s): their terminals now open links through claude-acct.\n' "$ides"
  echo "An IDE that is running picks the setting up when its window is next focused, or on restart."
}

# ca_jetbrains_revert: put the previous browser setting back in every IDE we changed,
# unless the user changed it again since. Best effort; used by uninstall.
ca_jetbrains_revert() {
  local f p u
  [ -f "$(ca_install_state_path)" ] || return 0
  while IFS=$'\t' read -r f p u; do
    if [ -z "$f" ] || [ ! -f "$f" ]; then continue; fi
    grep -q 'claude-acct-browser' "$f" 2>/dev/null || continue
    ca_jetbrains_apply "$f" "$p" "$u" || true
  done <<EOR
$(jq -r '.jetbrains // {} | to_entries[] | "\(.key)\t\(.value.browserPath // "")\t\(.value.useDefaultBrowser // "")"' \
  "$(ca_install_state_path)" 2>/dev/null)
EOR
  return 0
}
