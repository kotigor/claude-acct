# shellcheck shell=bash

test_concurrent_updates_are_all_kept() {
  ca_lib ca_ensure_data_dir
  local i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    # shellcheck disable=SC2016  # a jq filter: its $names are jq variables
    ca_lib ca_rl_update '.accounts[$id] = {n: $n}' --arg id "$i" --argjson n "$i" &
  done
  wait
  assert_eq "$(ca_lib ca_rl_read | jq '.accounts | length')" "20"
}

test_update_applies_only_its_own_change() {
  ca_lib ca_ensure_data_dir
  # shellcheck disable=SC2016  # a jq filter: its $names are jq variables
  ca_lib ca_rl_update '.accounts.a = {x: 1} | .auto = {at: 5}'
  # shellcheck disable=SC2016  # a jq filter: its $names are jq variables
  ca_lib ca_rl_update '.accounts.b = {y: 2}'
  assert_eq "$(ca_lib ca_rl_read | jq -c '[.accounts.a.x, .accounts.b.y, .auto.at]')" "[1,2,5]"
}

test_remove_is_an_update() {
  ca_lib ca_ensure_data_dir
  # shellcheck disable=SC2016  # a jq filter: its $names are jq variables
  ca_lib ca_rl_update '.accounts.a = {x: 1} | .accounts.b = {y: 2}'
  ca_lib ca_rl_remove a
  assert_eq "$(ca_lib ca_rl_read | jq -c '.accounts | keys')" '["b"]'
}
