#!/usr/bin/env bash
# Minimal test runner. Runs every test_* function of tests/*.test.sh in a fresh
# bash, once per platform (Darwin, Linux) unless the name ends in __darwin or
# __linux. Usage: tests/run.sh [name-filter]
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
filter=${1:-}
passed=0
failed=0

for file in "$ROOT"/tests/*.test.sh; do
  fns=$(bash -c '. "$1"; . "$2"; declare -F' _ "$ROOT/tests/lib.sh" "$file" | awk '{print $3}' | grep '^test_' || true)
  for fn in $fns; do
    case "$(basename "$file" .test.sh)::$fn" in *"$filter"*) ;; *) continue ;; esac
    case "$fn" in
      *__darwin) platforms=Darwin ;;
      *__linux) platforms=Linux ;;
      *) platforms="Darwin Linux" ;;
    esac
    for platform in $platforms; do
      name="$(basename "$file" .test.sh)::$fn [$platform]"
      if out=$(CLAUDE_ACCT_PLATFORM=$platform bash -c '. "$1"; . "$2"; t_setup; "$3"' _ "$ROOT/tests/lib.sh" "$file" "$fn" 2>&1); then
        passed=$((passed + 1))
        printf 'ok    %s\n' "$name"
      else
        failed=$((failed + 1))
        printf 'FAIL  %s\n' "$name"
        printf '%s\n' "$out" | sed 's/^/      /'
      fi
    done
  done
done

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
