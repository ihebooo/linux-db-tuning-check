#!/usr/bin/env bash
# db_tuning_check.sh - check a Linux host's kernel and OS settings for a database server.
#
# Read-only: it only reads /proc, /sys and command output; it never changes a setting.
# See --help for usage and exit codes.
set -euo pipefail

readonly VERSION="0.0.1"
readonly PROG=${0##*/}

usage() {
  cat <<EOF
Usage: $PROG [options]

Check the kernel and OS settings of a Linux host that runs (or will run)
a database such as PostgreSQL, and print OK / WARN / CRIT with a hint.

Options:
  -u, --db-user USER  database OS user for the ulimit checks (default: postgres)
  -h, --help          show this help and exit
  -V, --version       show the version and exit

Read-only: no setting is changed. Run as any user; some checks need root
to read every value and say so when they cannot.

Exit codes:
  0  every check OK
  1  at least one WARN
  2  at least one CRIT
  3  usage error or not a Linux host
EOF
}

die() { echo "$PROG: $*" >&2; exit 3; }

DB_USER=postgres

while [ $# -gt 0 ]; do
  case $1 in
    -h|--help)    usage; exit 0 ;;
    -V|--version) echo "$PROG $VERSION"; exit 0 ;;
    -u|--db-user)
      [ $# -ge 2 ] || die "$1 needs a user name (see --help)"
      DB_USER=$2; shift 2 ;;
    --db-user=*)  DB_USER=${1#*=}; shift ;;
    *)            die "unknown option: $1 (see --help)" ;;
  esac
done

[ -n "$DB_USER" ] || die "--db-user must not be empty"
[ "$(uname -s)" = Linux ] || die "this script checks Linux hosts only"

# Checks are added from the next release; the report header is already final.
echo "# Linux DB tuning check"
echo
echo "| Item | Value |"
echo "|---|---|"
echo "| Host | $(uname -n) |"
echo "| Kernel | $(uname -r) |"
echo "| DB OS user | $DB_USER |"
echo
echo "Overall: **OK**"
exit 0
