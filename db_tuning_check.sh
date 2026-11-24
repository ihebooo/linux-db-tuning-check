#!/usr/bin/env bash
# db_tuning_check.sh - check a Linux host's kernel and OS settings for a database server.
#
# Read-only: it only reads /proc, /sys and /etc; it never changes a setting.
# See --help for usage and exit codes.
set -euo pipefail

readonly VERSION="0.0.3"
readonly PROG=${0##*/}

usage() {
  cat <<EOF
Usage: $PROG [options]

Check the kernel and OS settings of a Linux host that runs (or will run)
a database such as PostgreSQL, and print OK / WARN / CRIT with a hint.

Options:
  -u, --db-user USER  database OS user for the ulimit checks (default: postgres)
  -s, --shared-buffers SIZE
                      planned PostgreSQL shared_buffers, e.g. 8GB, for the
                      huge pages check (default: 25 % of RAM)
      --sysroot DIR   read /proc, /sys and /etc under DIR instead of /
                      (a saved snapshot of another host, or test fixtures)
  -h, --help          show this help and exit
  -V, --version       show the version and exit

Read-only: no setting is changed. Run as any user; a value that cannot be
read is reported as SKIP.

Exit codes:
  0  every check OK
  1  at least one WARN
  2  at least one CRIT
  3  usage error or not a Linux host
EOF
}

die() { echo "$PROG: $*" >&2; exit 3; }

DB_USER=postgres
ROOT=""
SB=""

while [ $# -gt 0 ]; do
  case $1 in
    -h|--help)    usage; exit 0 ;;
    -V|--version) echo "$PROG $VERSION"; exit 0 ;;
    -u|--db-user|--sysroot|-s|--shared-buffers)
      [ $# -ge 2 ] || die "$1 needs a value (see --help)"
      case $1 in --sysroot) ROOT=$2 ;; -s|--shared-buffers) SB=$2 ;; *) DB_USER=$2 ;; esac
      shift 2 ;;
    --db-user=*)  DB_USER=${1#*=}; shift ;;
    --shared-buffers=*) SB=${1#*=}; shift ;;
    --sysroot=*)  ROOT=${1#*=}; shift ;;
    *)            die "unknown option: $1 (see --help)" ;;
  esac
done

[ -n "$DB_USER" ] || die "--db-user must not be empty"

# to_bytes SIZE: PostgreSQL-style size (8GB, 512MB, 1TB, 64kB) to bytes.
to_bytes() {
  local n u
  [[ $1 =~ ^([0-9]+)[[:space:]]*([kKmMgGtT])[bB]?$ ]] || return 1
  n=${BASH_REMATCH[1]} u=${BASH_REMATCH[2]}
  case $u in
    k|K) echo $(( n * 1024 )) ;;
    m|M) echo $(( n * 1024 ** 2 )) ;;
    g|G) echo $(( n * 1024 ** 3 )) ;;
    t|T) echo $(( n * 1024 ** 4 )) ;;
  esac
}
if [ -n "$SB" ]; then
  SB=$(to_bytes "$SB") || die "--shared-buffers needs a size with a unit, e.g. 8GB or 512MB"
fi
if [ -n "$ROOT" ]; then
  ROOT=${ROOT%/}
  [ -d "$ROOT/proc" ] || die "--sysroot $ROOT has no proc/ directory"
else
  [ "$(uname -s)" = Linux ] || die "this script checks Linux hosts only"
fi

# ---------------------------------------------------------------- helpers

# rd PATH: print the first line of $ROOT/PATH; fail if it is missing or unreadable.
rd() {
  local f=$ROOT$1 line=""
  [ -r "$f" ] || return 1
  IFS= read -r line <"$f" || [ -n "$line" ] || return 1
  printf '%s\n' "$line"
}

# meminfo KEY: value of KEY in /proc/meminfo, in kB (0 if absent).
meminfo() {
  awk -v k="$1:" '$1 == k { print $2; found = 1; exit } END { if (!found) print 0 }' \
    "$ROOT/proc/meminfo" 2>/dev/null || echo 0
}

# hb BYTES: human-readable size, binary units.
hb() {
  awk -v b="$1" 'BEGIN {
    split("B KiB MiB GiB TiB", u, " "); i = 1
    while (b >= 1024 && i < 5) { b /= 1024; i++ }
    printf (i == 1 ? "%d %s" : "%.1f %s"), b, u[i]
  }'
}

# Results: one row per check, grouped by section in the order they are added.
r_sec=() r_name=() r_value=() r_status=() r_hint=()
worst=0

# add SECTION CHECK VALUE STATUS HINT
add() {
  local n=0
  case $4 in WARN) n=1 ;; CRIT) n=2 ;; esac
  (( n > worst )) && worst=$n
  r_sec+=("$1") r_name+=("$2") r_value+=("$3") r_status+=("$4") r_hint+=("$5")
}

# selected "a [b] c": the bracketed choice of a sysfs selector ("b").
selected() {
  local s=$1
  [[ $s == *\[*\]* ]] || { printf '%s\n' "$s"; return; }
  s=${s#*[}
  printf '%s\n' "${s%%]*}"
}

# Cells must not break the Markdown table.
cell() { local s=${1//|/¦}; printf '%s' "${s//$'\n'/ }"; }

# ---------------------------------------------------------------- host facts

host=$(rd /proc/sys/kernel/hostname || uname -n)
kernel=$(rd /proc/sys/kernel/osrelease || uname -r)
distro=$(awk -F= '$1 == "PRETTY_NAME" { gsub(/"/, "", $2); print $2 }' "$ROOT/etc/os-release" 2>/dev/null || true)
cpus=$(grep -c '^processor' "$ROOT/proc/cpuinfo" 2>/dev/null || true)
mem_kb=$(meminfo MemTotal)
mem_b=$(( mem_kb * 1024 ))

# ---------------------------------------------------------------- memory

check_memory() {
  local sec=Memory v dr dbr db dbb fg bg val

  if v=$(rd /proc/sys/vm/swappiness); then
    if (( v <= 10 )); then
      add "$sec" vm.swappiness "$v" OK "low: the kernel keeps database memory in RAM and drops page cache first"
    else
      add "$sec" vm.swappiness "$v" WARN "set vm.swappiness=1 in /etc/sysctl.d/: at $v the kernel swaps out database memory when the page cache grows"
    fi
  else
    add "$sec" vm.swappiness "?" SKIP "cannot read /proc/sys/vm/swappiness"
  fi

  if dr=$(rd /proc/sys/vm/dirty_ratio) && dbr=$(rd /proc/sys/vm/dirty_background_ratio); then
    db=$(rd /proc/sys/vm/dirty_bytes || echo 0)
    dbb=$(rd /proc/sys/vm/dirty_background_bytes || echo 0)
    if (( db > 0 )); then fg=$db; else fg=$(( dr * mem_b / 100 )); fi
    if (( dbb > 0 )); then bg=$dbb; else bg=$(( dbr * mem_b / 100 )); fi
    val="background $(hb "$bg"), limit $(hb "$fg")"
    (( dbb > 0 )) || val="background ${dbr} % = $(hb "$bg"), limit ${dr} % = $(hb "$fg")"
    if (( bg > 1024 * 1024 * 1024 || fg > 4 * 1024 * 1024 * 1024 )); then
      add "$sec" "vm.dirty_*" "$val" WARN "too much dirty data before write-back: checkpoints flush it in bursts that stall queries; set vm.dirty_background_bytes=268435456 and vm.dirty_bytes=1073741824"
    elif (( bg >= fg )); then
      add "$sec" "vm.dirty_*" "$val" WARN "the background threshold must be below the limit, or writers block without background flushing"
    else
      add "$sec" "vm.dirty_*" "$val" OK "write-back starts early enough to avoid large I/O bursts"
    fi
  else
    add "$sec" "vm.dirty_*" "?" SKIP "cannot read /proc/sys/vm/dirty_ratio"
  fi

  if v=$(rd /proc/sys/vm/overcommit_memory); then
    case $v in
      0) add "$sec" vm.overcommit_memory 0 OK "heuristic overcommit (kernel default); the PostgreSQL docs prefer 2 with a matching vm.overcommit_ratio so the OOM killer never hits the postmaster" ;;
      1) add "$sec" vm.overcommit_memory 1 WARN "always overcommit: under memory pressure the OOM killer kills a backend or the postmaster; use 2 (with vm.overcommit_ratio) or 0" ;;
      2)
        local cl; cl=$(meminfo CommitLimit)
        if (( cl * 2 < mem_kb )); then
          add "$sec" vm.overcommit_memory "2, commit limit $(hb $(( cl * 1024 )))" WARN "strict overcommit with a commit limit under half of RAM: allocations fail early; raise vm.overcommit_ratio"
        else
          add "$sec" vm.overcommit_memory "2, commit limit $(hb $(( cl * 1024 )))" OK "strict overcommit: allocations fail cleanly instead of waking the OOM killer"
        fi ;;
      *) add "$sec" vm.overcommit_memory "$v" WARN "unknown value" ;;
    esac
  else
    add "$sec" vm.overcommit_memory "?" SKIP "cannot read /proc/sys/vm/overcommit_memory"
  fi
}

# ---------------------------------------------------------------- huge pages and NUMA

check_hugepages_numa() {
  local sec="Huge pages and NUMA" en df total size_kb hp sb need nr nodes zr sbtxt

  if en=$(rd /sys/kernel/mm/transparent_hugepage/enabled); then
    en=$(selected "$en")
    df=$(rd /sys/kernel/mm/transparent_hugepage/defrag) && df=$(selected "$df") || df="?"
    if [ "$en" = always ]; then
      add "$sec" "Transparent Huge Pages" "enabled=$en, defrag=$df" WARN "disable THP for database hosts: compaction and khugepaged cause latency spikes; boot with transparent_hugepage=never or use a tuned profile that sets it"
    else
      add "$sec" "Transparent Huge Pages" "enabled=$en, defrag=$df" OK "THP is not forced on every allocation"
    fi
  else
    add "$sec" "Transparent Huge Pages" "?" SKIP "THP not available in this kernel"
  fi

  total=$(meminfo HugePages_Total) size_kb=$(meminfo Hugepagesize)
  if (( size_kb > 0 )); then
    hp=$(( total * size_kb * 1024 ))
    if [ -n "$SB" ]; then sb=$SB sbtxt="shared_buffers $(hb "$SB")"
    else sb=$(( mem_b / 4 )) sbtxt="shared_buffers 25 % of RAM = $(hb "$sb")"
    fi
    need=$(( sb + sb / 20 ))
    nr=$(( (need + size_kb * 1024 - 1) / (size_kb * 1024) ))
    if (( total == 0 )); then
      if (( sb >= 8 * 1024 ** 3 )); then
        add "$sec" "Huge pages" "none reserved; $sbtxt" WARN "with large shared_buffers every backend's page tables cost a lot of RAM: set vm.nr_hugepages=$nr and huge_pages=try in postgresql.conf"
      else
        add "$sec" "Huge pages" "none reserved; $sbtxt" OK "not needed below 8 GiB of shared_buffers; above that reserve vm.nr_hugepages"
      fi
    elif (( hp < need )); then
      add "$sec" "Huge pages" "$total x $(hb $(( size_kb * 1024 ))) = $(hb "$hp"); $sbtxt" WARN "fewer huge pages than shared_buffers + 5 %: PostgreSQL falls back to normal pages (huge_pages=try) or does not start (huge_pages=on); set vm.nr_hugepages=$nr"
    else
      add "$sec" "Huge pages" "$total x $(hb $(( size_kb * 1024 ))) = $(hb "$hp"); $sbtxt" OK "enough huge pages for shared_buffers; set huge_pages=on in postgresql.conf to be sure they are used"
    fi
  else
    add "$sec" "Huge pages" "?" SKIP "no Hugepagesize in /proc/meminfo"
  fi

  nodes=$(find "$ROOT/sys/devices/system/node" -maxdepth 1 -name 'node[0-9]*' 2>/dev/null | wc -l)
  if (( nodes <= 1 )); then
    add "$sec" "NUMA" "1 node" OK "single NUMA node: nothing to tune"
  elif zr=$(rd /proc/sys/vm/zone_reclaim_mode); then
    if (( zr != 0 )); then
      add "$sec" "NUMA" "$nodes nodes, vm.zone_reclaim_mode=$zr" WARN "set vm.zone_reclaim_mode=0: otherwise the kernel drops local page cache instead of using memory on the other node"
    else
      add "$sec" "NUMA" "$nodes nodes, vm.zone_reclaim_mode=0" OK "the whole RAM is used as cache across nodes"
    fi
  else
    add "$sec" "NUMA" "$nodes nodes" SKIP "cannot read /proc/sys/vm/zone_reclaim_mode"
  fi
}

# ---------------------------------------------------------------- report

check_memory
check_hugepages_numa

ok=0 warn=0 crit=0
for s in "${r_status[@]}"; do
  case $s in OK) ok=$((ok + 1)) ;; WARN) warn=$((warn + 1)) ;; CRIT) crit=$((crit + 1)) ;; esac
done
overall=OK
(( worst == 1 )) && overall=WARN
(( worst == 2 )) && overall=CRIT

echo "# Linux DB tuning check"
echo
echo "| Item | Value |"
echo "|---|---|"
echo "| Host | $(cell "$host") |"
[ -z "$distro" ] || echo "| OS | $(cell "$distro") |"
echo "| Kernel | $(cell "$kernel") |"
echo "| CPUs | ${cpus:-?} |"
echo "| RAM | $(hb "$mem_b") |"
echo "| DB OS user | $(cell "$DB_USER") |"
echo
echo "Overall: **$overall** — $crit CRIT, $warn WARN, $ok OK"

prev=""
for i in "${!r_sec[@]}"; do
  if [ "${r_sec[i]}" != "$prev" ]; then
    prev=${r_sec[i]}
    echo
    echo "## $prev"
    echo
    echo "| Check | Value | Status | What to do |"
    echo "|---|---|---|---|"
  fi
  echo "| $(cell "${r_name[i]}") | $(cell "${r_value[i]}") | ${r_status[i]} | $(cell "${r_hint[i]}") |"
done

exit "$worst"
