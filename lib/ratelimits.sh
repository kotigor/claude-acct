# shellcheck shell=bash
# Last known rate limits per account, as written by the status line (session
# numbers) and the usage refresh (endpoint numbers).

ca_rl_path() { printf '%s/ratelimits.json' "$(ca_data_dir)"; }

ca_rl_read() {
  if [ -f "$(ca_rl_path)" ]; then cat "$(ca_rl_path)"; else printf '{"accounts":{}}'; fi
}

ca_rl_remove() {  # ca_rl_remove <id>
  local new
  [ -f "$(ca_rl_path)" ] || return 0
  new=$(ca_rl_read | jq -c --arg id "$1" 'del(.accounts[$id])') || return 1
  printf '%s\n' "$new" | ca_write_atomic "$(ca_rl_path)" 600
}
