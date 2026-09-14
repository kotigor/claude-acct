# shellcheck shell=bash
# Helpers shared by every module.

ca_die() { printf 'claude-acct: %s\n' "$*" >&2; exit 1; }
ca_warn() { printf 'claude-acct: %s\n' "$*" >&2; }

ca_platform() { printf '%s' "${CLAUDE_ACCT_PLATFORM:-$(uname -s)}"; }

ca_data_dir() { printf '%s/claude-acct' "${XDG_DATA_HOME:-$HOME/.local/share}"; }

ca_ensure_data_dir() {
  mkdir -p "$(ca_data_dir)" && chmod 700 "$(ca_data_dir)"
}

ca_sha256_hex() {  # ca_sha256_hex <string>
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1
  else
    printf '%s' "$1" | sha256sum | cut -d' ' -f1
  fi
}

ca_file_mode() {  # ca_file_mode <path> <default>: permission bits such as 600
  if [ -e "$1" ]; then
    stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
  else
    printf '%s' "$2"
  fi
}

ca_write_atomic() {  # ca_write_atomic <path> <mode>: replace a file with stdin, never leaving it partial
  local tmp
  tmp=$(mktemp "$(dirname "$1")/.claude-acct.XXXXXX") || return 1
  if chmod "$2" "$tmp" && cat >"$tmp" && [ -s "$tmp" ] && mv -f "$tmp" "$1"; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# ca_lock: serialise state-changing commands. The lock is a directory holding
# the owner's pid. A lock is stale only when its owner is gone — a switch that
# sits on a Keychain prompt for minutes still owns it — and only the owner
# releases it, so a later command can never drop a lock it did not take.
ca_lock() {
  local dir tries=0 owner
  ca_ensure_data_dir
  dir="$(ca_data_dir)/lock"
  until mkdir "$dir" 2>/dev/null; do
    owner=$(cat "$dir/pid" 2>/dev/null || true)
    if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then
      rm -f "$dir/pid"
      rmdir "$dir" 2>/dev/null || true
      continue
    fi
    if [ -z "$owner" ] && [ -n "$(find "$dir" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
      rmdir "$dir" 2>/dev/null || true  # died between mkdir and writing the pid
      continue
    fi
    tries=$((tries + 1))
    [ "$tries" -lt "${CA_LOCK_TRIES:-100}" ] ||
      ca_die "another claude-acct command is running (pid ${owner:-unknown}; if it is not, remove $dir)"
    sleep 0.1
  done
  printf '%s' "$$" >"$dir/pid"
  CA_LOCK_DIR=$dir
  trap ca_unlock EXIT
}

ca_unlock() {
  [ -n "${CA_LOCK_DIR:-}" ] || return 0
  if [ "$(cat "$CA_LOCK_DIR/pid" 2>/dev/null)" = "$$" ]; then
    rm -f "$CA_LOCK_DIR/pid"
    rmdir "$CA_LOCK_DIR" 2>/dev/null || true
  fi
  return 0
}

ca_log() {  # ca_log <message>: append to the log in the data dir; never pass secrets
  local f
  {
    ca_ensure_data_dir
    f="$(ca_data_dir)/claude-acct.log"
    if [ -f "$f" ] && [ "$(($(wc -c <"$f")))" -gt 200000 ]; then mv -f "$f" "$f.1"; fi
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$f"
  } 2>/dev/null || true  # a log that cannot be written must never stop the real work
}

ca_notify() {  # ca_notify <title> <message>: desktop notification, best effort
  case "$(ca_platform)" in
    Darwin)
      command -v osascript >/dev/null 2>&1 &&
        osascript -e 'on run argv' -e 'display notification (item 2 of argv) with title (item 1 of argv)' -e 'end run' "$1" "$2" ;;
    *)
      command -v notify-send >/dev/null 2>&1 && notify-send "$1" "$2" ;;
  esac >/dev/null 2>&1 || true
}
