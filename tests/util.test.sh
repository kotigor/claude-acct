# shellcheck shell=bash

test_sha256_hex() {
  assert_eq "$(ca_lib ca_sha256_hex /a | cut -c1-8)" "6a50dc85"
}

test_write_atomic_replaces_content_and_sets_mode() {
  printf 'old' >"$HOME/f"
  printf 'new' | ca_lib ca_write_atomic "$HOME/f" 600
  assert_eq "$(cat "$HOME/f")" "new"
  assert_eq "$(ca_lib ca_file_mode "$HOME/f" 644)" "600"
}

test_write_atomic_refuses_empty_input() {
  printf 'keep' >"$HOME/f"
  assert_fails ca_lib ca_write_atomic "$HOME/f" 600 </dev/null
  assert_eq "$(cat "$HOME/f")" "keep"
  assert_eq "$(find "$HOME" -maxdepth 1 -name '.claude-acct.*' | wc -l | tr -d ' ')" "0"
}

test_file_mode_default_for_missing_file() {
  assert_eq "$(ca_lib ca_file_mode "$HOME/missing" 644)" "644"
}

test_lock_is_released_on_exit() {
  ca_lib ca_lock
  ca_lib ca_lock
  assert_fails test -d "$XDG_DATA_HOME/claude-acct/lock"
}

test_data_dir_is_private() {
  ca_lib ca_ensure_data_dir
  assert_eq "$(ca_lib ca_file_mode "$XDG_DATA_HOME/claude-acct" 0)" "700"
}

test_log_never_fails_even_when_it_cannot_write() {
  ca_lib ca_ensure_data_dir
  chmod 500 "$XDG_DATA_HOME/claude-acct"
  ca_lib ca_log "hello" || fail "ca_log failed instead of giving up quietly"
  chmod 700 "$XDG_DATA_HOME/claude-acct"
}

test_lock_is_broken_only_when_its_owner_is_gone() {
  local dir="$XDG_DATA_HOME/claude-acct/lock"
  ca_lib ca_ensure_data_dir
  # a lock held by a live process is honoured
  sleep 30 &
  local holder=$!
  mkdir "$dir" && printf '%s' "$holder" >"$dir/pid"
  local rc=0
  CA_LOCK_TRIES=3 ca_lib ca_lock 2>/dev/null || rc=$?
  [ "$rc" -ne 0 ] || fail "a lock held by a live process was taken over"
  assert_eq "$(cat "$dir/pid")" "$holder"
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null || true
  # now its owner is gone: the lock is stale at once, whatever its age
  CA_LOCK_TRIES=3 ca_lib ca_lock || fail "a lock whose owner died was not broken"
  assert_fails test -d "$dir"
}

test_only_the_owner_releases_the_lock() {
  local dir="$XDG_DATA_HOME/claude-acct/lock"
  ca_lib ca_ensure_data_dir
  mkdir "$dir" && printf '%s' "$$" >"$dir/pid"   # held by this test shell
  ca_lib ca_unlock                                  # another process: must not touch it
  [ -d "$dir" ] || fail "a process released a lock it did not own"
  rm -rf "$dir"
}
