# shellcheck shell=bash
# Last known rate limits per account, as written by the status line (session
# numbers) and the usage refresh (endpoint numbers).

# shellcheck disable=SC2034  # used by statusline.sh
CA_RL_STALE_SECONDS=3600  # Claude Code itself treats cached usage older than this as unusable

ca_rl_path() { printf '%s/ratelimits.json' "$(ca_data_dir)"; }

ca_rl_read() {
  if [ -f "$(ca_rl_path)" ]; then cat "$(ca_rl_path)"; else printf '{"accounts":{}}'; fi
}

# ca_rl_update <jq filter> [jq options...]: change ratelimits.json under a lock.
# Several sessions' status lines, the usage refresh and a switch all write this
# file; each applies its own small change instead of overwriting a snapshot.
ca_rl_update() {
  local filter=$1 lock tries=0 new rc=0
  shift
  ca_ensure_data_dir
  lock="$(ca_data_dir)/rl.lock"
  until mkdir "$lock" 2>/dev/null; do
    if [ -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
      rmdir "$lock" 2>/dev/null || true
      continue
    fi
    tries=$((tries + 1))
    [ "$tries" -lt 100 ] || return 1
    sleep 0.02
  done
  new=$(ca_rl_read | jq -c "$@" "$filter") && printf '%s\n' "$new" | ca_write_atomic "$(ca_rl_path)" 600 || rc=1
  rmdir "$lock" 2>/dev/null || true
  return "$rc"
}

ca_rl_remove() {  # ca_rl_remove <id>
  [ -f "$(ca_rl_path)" ] || return 0
  # shellcheck disable=SC2016  # a jq filter: its $names are jq variables
  ca_rl_update 'del(.accounts[$id])' --arg id "$1"
}
