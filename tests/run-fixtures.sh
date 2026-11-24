#!/usr/bin/env bash
# tests/run-fixtures.sh - run db_tuning_check.sh against the snapshot hosts in
# tests/fixtures/ (via --sysroot) and check every status and exit code.
#
# Each fixture has an "expect" file, one tab-separated rule per line:
#   args<TAB>OPTIONS             extra options for this fixture
#   exit<TAB>N                   expected exit code
#   CHECK<TAB>STATUS             expected status of the check row named CHECK
#   setting<TAB>NAME<TAB>VALUE   expected suggested PostgreSQL setting
set -euo pipefail
cd "$(dirname "$0")/.."

# cell_of NAME COLUMN: column COLUMN of the Markdown row whose first cell is NAME.
cell_of() {
  awk -F' [|] ' -v n="| $1" -v c="$2" '$1 == n { print $c; exit }' <<<"$out"
}

fails=0
for dir in tests/fixtures/*/; do
  fx=$(basename "$dir")
  args=()
  line=$(grep -m1 $'^args\t' "$dir/expect" || true)
  [ -z "$line" ] || read -ra args <<<"${line#args$'\t'}"

  set +e
  out=$(./db_tuning_check.sh --sysroot "$dir" "${args[@]}" 2>&1); rc=$?
  set -e
  echo "# $fx ${args[*]}"

  while IFS=$'\t' read -r name want extra; do
    case $name in ""|"#"*|args) continue ;; esac
    if [ "$name" = exit ]; then
      label="exit"; got=$rc
    elif [ "$name" = setting ]; then
      label="$want"; got=$(cell_of "$want" 2); want=$extra
    else
      label="$name"; got=$(cell_of "$name" 3)
    fi
    if [ "$got" = "$want" ]; then
      echo "ok   - $label = $want"
    else
      echo "FAIL - $label = ${got:-<missing>}, expected $want"
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
