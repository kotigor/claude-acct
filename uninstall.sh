#!/usr/bin/env bash
# Remove claude-acct. --purge also deletes the saved accounts.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
for f in "$here"/lib/*.sh; do
  # shellcheck source=/dev/null
  . "$f"
done
ca_uninstall "$@"
