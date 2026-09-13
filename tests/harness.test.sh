# shellcheck shell=bash

test_fake_security_roundtrip__darwin() {
  security add-generic-password -a acct -s "Svc Name" -w '{"x":1}'
  assert_eq "$(security find-generic-password -a acct -s "Svc Name" -w)" '{"x":1}'
}

test_fake_security_prints_hex_for_non_ascii__darwin() {
  local hex
  hex=$(printf '%s' '{"x":"ü"}' | xxd -p | tr -d '\n')
  security add-generic-password -a acct -s svc -X "$hex"
  assert_eq "$(security find-generic-password -a acct -s svc -w)" "$hex"
}

test_fake_security_missing_item_exits_44__darwin() {
  local rc=0
  security find-generic-password -a acct -s nope -w >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" 44
}

test_fake_security_interactive_mode_breaks_on_long_lines__darwin() {
  local hex
  hex=$(head -c 3000 /dev/zero | tr '\0' a | xxd -p | tr -d '\n')
  printf 'add-generic-password -U -a "acct" -s "svc" -X "%s"\n' "$hex" | security -i >/dev/null 2>&1 || true
  assert_fails security find-generic-password -a acct -s svc
}

test_cc_login_simulator() {
  cc_login alice
  assert_eq "$(live_rt)" "rt-alice"
  assert_eq "$(live_email)" "alice@example.com"
  assert_eq "$(cc_store_get | jq -r '.mcpOAuth.srv.accessToken')" "mcp-secret"
  cc_login bob
  assert_eq "$(live_rt)" "rt-bob"
  assert_eq "$(cc_store_get | jq -r '.trustedDeviceToken')" "tdt-bob"
  assert_eq "$(cc_store_get | jq -r '.mcpOAuth.srv.accessToken')" "mcp-secret"
}
