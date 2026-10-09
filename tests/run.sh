#!/usr/bin/env bash
# Run all tests:  tests/run.sh [test_file...]
# Tests use temporary repositories and mock system commands only; they never
# touch the real agent worktrees or the real systemd service.
set -uo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")" || exit 1
files=("$@")
((${#files[@]})) || files=(test_*.sh)
rc=0
for f in "${files[@]}"; do
  printf '%s\n' "${f##*/}"
  bash "$f" || rc=1
done
if ((rc)); then echo "FAILED"; else echo "ALL PASSED"; fi
exit "$rc"
