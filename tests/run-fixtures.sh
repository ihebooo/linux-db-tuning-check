#!/usr/bin/env bash
# tests/run-fixtures.sh - run db_tuning_check.sh against the snapshot hosts in
# tests/fixtures/ (via --sysroot) and check every status and exit code.
#
# Each fixture has an "expect" file:
#   exit N              expected exit code
#   CHECK<TAB>STATUS    expected status of the row named CHECK
set -euo pipefail
cd "$(dirname "$0")/.."

fails=0
for dir in tests/fixtures/*/; do
  fx=$(basename "$dir")
  set +e
  out=$(./db_tuning_check.sh --sysroot "$dir" 2>&1); rc=$?
  set -e
  echo "# $fx"
  while IFS=$'\t' read -r name want; do
    [ -n "$name" ] || continue
    case $name in \#*) continue ;; esac
    if [ "$name" = exit ]; then
      got=$rc
    else
      got=$(awk -F' \\| ' -v n="| $name" '$1 == n { print $3; exit }' <<<"$out")
    fi
    if [ "$got" = "$want" ]; then
      echo "ok   - $name = $want"
    else
      echo "FAIL - $name = ${got:-<missing>}, expected $want"
      fails=$((fails + 1))
    fi
  done <"$dir/expect"
done

echo
if (( fails )); then
  echo "$fails check(s) failed"
  exit 1
fi
echo "all fixtures passed"
