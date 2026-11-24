#!/usr/bin/env bash
# db_tuning_check.sh - check a Linux host's kernel and OS settings for a database server.
#
# Read-only: it only reads /proc, /sys and /etc; it never changes a setting.
# See --help for usage and exit codes.
set -euo pipefail

readonly VERSION="0.0.5"
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

  nodes=0
  for zr in "$ROOT"/sys/devices/system/node/node[0-9]*; do
    [ -d "$zr" ] && nodes=$((nodes + 1))
  done
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

# ---------------------------------------------------------------- storage

check_storage() {
  local sec=Storage dev name sch rot kind found=0
  local mnt fs opts atime issues level hint

  for dev in "$ROOT"/sys/block/*; do
    [ -e "$dev/queue/scheduler" ] || continue
    name=${dev##*/}
    case $name in loop*|ram*|zram*|sr*|fd*|dm-*|md*|nbd*) continue ;; esac
    found=1
    sch=$(rd "/sys/block/$name/queue/scheduler") && sch=$(selected "$sch") || sch="?"
    rot=$(rd "/sys/block/$name/queue/rotational" || echo 0)
    if (( rot == 1 )); then kind=HDD; else kind="SSD/NVMe"; fi
    case $kind:$sch in
      HDD:mq-deadline|HDD:deadline|"SSD/NVMe":none|"SSD/NVMe":noop|"SSD/NVMe":mq-deadline|"SSD/NVMe":deadline|"SSD/NVMe":kyber)
        add "$sec" "I/O scheduler $name" "$sch ($kind)" OK "a good fit for a database on $kind" ;;
      HDD:none|HDD:noop)
        add "$sec" "I/O scheduler $name" "$sch ($kind)" WARN "a spinning disk needs request reordering: use mq-deadline (udev rule or a tuned profile)" ;;
      *:\?)
        add "$sec" "I/O scheduler $name" "? ($kind)" SKIP "cannot read the scheduler" ;;
      *)
        if [ "$kind" = HDD ]; then hint="use mq-deadline"; else hint="use none or mq-deadline"; fi
        add "$sec" "I/O scheduler $name" "$sch ($kind)" WARN "$sch is tuned for desktops and adds latency under a database load: $hint (udev rule or a tuned profile)" ;;
    esac
  done
  (( found )) || add "$sec" "I/O scheduler" "no disk found" SKIP "no block device with a scheduler in /sys/block"

  found=0
  while read -r _ mnt fs opts _; do
    case $fs in ext2|ext3|ext4|xfs|btrfs|zfs) ;; *) continue ;; esac
    found=1
    mnt=$(printf '%b' "$mnt")   # /proc/mounts escapes a space as \040
    case ,$opts, in
      *,noatime,*)     atime=noatime ;;
      *,relatime,*)    atime=relatime ;;
      *,lazytime,*)    atime=lazytime ;;
      *)               atime=strictatime ;;
    esac
    issues=() level=OK
    case ,$opts, in
      *,nobarrier,*|*,barrier=0,*)
        level=CRIT; issues+=("write barriers are off: a power loss can corrupt the database; remove nobarrier/barrier=0") ;;
    esac
    case $fs in
      ext2|ext3)
        [ "$level" = CRIT ] || level=WARN
        issues+=("$fs is outdated for a database: use xfs or ext4") ;;
      btrfs)
        [ "$level" = CRIT ] || level=WARN
        issues+=("btrfs copy-on-write fragments database files: use xfs/ext4, or chattr +C on the data directory") ;;
    esac
    if [ "$atime" = strictatime ]; then
      [ "$level" = CRIT ] || level=WARN
      issues+=("every read updates the access time: mount with noatime")
    fi
    if (( ${#issues[@]} )); then
      hint=$(printf '%s. ' "${issues[@]}"); hint=${hint%. }
    elif [ "$atime" = noatime ]; then
      hint="no access-time writes, barriers on"
    else
      hint="fine; noatime saves a few more writes"
    fi
    add "$sec" "Mount $mnt" "$fs, $atime" "$level" "$hint"
  done < <(cat "$ROOT/proc/mounts" 2>/dev/null || true)
  (( found )) || add "$sec" "Mounts" "no ext4/xfs/btrfs/zfs mount" SKIP "nothing to check in /proc/mounts"
}

# ---------------------------------------------------------------- limits and CPU

# conf_limit USER ITEM: soft value of ITEM for USER from limits.conf and limits.d
# (a line for the user wins over "*"); empty if not set.
conf_limit() {
  local f files=() u_val="" any_val="" dom typ item val
  [ -r "$ROOT/etc/security/limits.conf" ] && files+=("$ROOT/etc/security/limits.conf")
  for f in "$ROOT"/etc/security/limits.d/*.conf; do [ -r "$f" ] && files+=("$f"); done
  (( ${#files[@]} )) || return 0
  while read -r dom typ item val _; do
    [ "$item" = "$2" ] || continue
    case $typ in soft|-) ;; *) continue ;; esac
    case $dom in "$1") u_val=$val ;; \*) any_val=$val ;; esac
  done < <(grep -hv '^[[:space:]]*#' "${files[@]}" 2>/dev/null || true)
  printf '%s\n' "${u_val:-$any_val}"
}

check_limits_cpu() {
  local sec="Limits and CPU" uid="" p pid="" nofile="" nproc="" src v govs g n prof

  uid=$(awk -F: -v u="$DB_USER" '$1 == u { print $3; exit }' "$ROOT/etc/passwd" 2>/dev/null || true)
  if [ -z "$uid" ]; then
    add "$sec" "Open files ($DB_USER)" "user not found" SKIP "no user $DB_USER in /etc/passwd: pass the database OS user with --db-user"
  else
    for p in "$ROOT"/proc/[0-9]*; do
      [ -r "$p/status" ] && [ -r "$p/limits" ] || continue
      if awk -v u="$uid" '$1 == "Uid:" && $2 == u { f = 1 } END { exit !f }' "$p/status"; then
        pid=${p##*/}; break
      fi
    done
    if [ -n "$pid" ]; then
      nofile=$(awk '/^Max open files/ { print $4 }' "$ROOT/proc/$pid/limits")
      nproc=$(awk '/^Max processes/ { print $3 }' "$ROOT/proc/$pid/limits")
      src="running process $pid"
    else
      nofile=$(conf_limit "$DB_USER" nofile)
      nproc=$(conf_limit "$DB_USER" nproc)
      src="limits.conf, no process running"
      [ -n "$nofile" ] || { nofile=1024; src="kernel default, no process running"; }
    fi

    if [ "$nofile" = unlimited ] || (( nofile >= 4096 )); then
      add "$sec" "Open files ($DB_USER)" "$nofile ($src)" OK "enough file descriptors for the database's tables, indexes and connections"
    elif (( nofile < 1024 )); then
      add "$sec" "Open files ($DB_USER)" "$nofile ($src)" CRIT "far too few file descriptors: the database fails with 'too many open files'; set nofile 65536 (LimitNOFILE= in the systemd unit, or limits.d)"
    else
      add "$sec" "Open files ($DB_USER)" "$nofile ($src)" WARN "raise to 65536: LimitNOFILE=65536 in the systemd unit (services ignore limits.conf) or nofile in /etc/security/limits.d/"
    fi

    if [ -z "$nproc" ] || [ "$nproc" = unlimited ]; then
      add "$sec" "Processes ($DB_USER)" "${nproc:-not limited} ($src)" OK "no per-user process limit"
    elif (( nproc >= 4096 )); then
      add "$sec" "Processes ($DB_USER)" "$nproc ($src)" OK "enough for one backend process per connection"
    else
      add "$sec" "Processes ($DB_USER)" "$nproc ($src)" WARN "each connection is a process: raise nproc to at least 4096 (LimitNPROC= or limits.d)"
    fi
  fi

  if v=$(rd /proc/sys/fs/file-max); then
    if (( ${#v} > 12 || v >= 65536 )); then
      add "$sec" fs.file-max "$v" OK "the system-wide file limit is not a bottleneck"
    else
      add "$sec" fs.file-max "$v" WARN "system-wide limit below 65536: set fs.file-max=6553600 in /etc/sysctl.d/"
    fi
  else
    add "$sec" fs.file-max "?" SKIP "cannot read /proc/sys/fs/file-max"
  fi

  govs=$(cat "$ROOT"/sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor 2>/dev/null | sort | uniq -c | awk '{ printf "%s%s x%s", (NR > 1 ? ", " : ""), $2, $1 }' || true)
  if [ -z "$govs" ]; then
    add "$sec" "CPU governor" "not exposed" OK "no cpufreq control (virtual machine or fixed frequency)"
  else
    n=OK
    for g in powersave conservative ondemand; do
      [[ $govs == *"$g x"* ]] && n=WARN
    done
    if [ "$n" = WARN ]; then
      add "$sec" "CPU governor" "$govs" WARN "CPUs clock down between queries and add latency: use the performance governor (tuned profile throughput-performance, or cpupower frequency-set -g performance)"
    else
      add "$sec" "CPU governor" "$govs" OK "CPUs run at full speed when the database needs them"
    fi
  fi

  if prof=$(rd /etc/tuned/active_profile); then
    case $prof in
      balanced*|powersave*|desktop*|laptop*|"")
        add "$sec" "tuned profile" "${prof:-none}" WARN "a power-saving profile: switch with tuned-adm profile throughput-performance" ;;
      *)
        add "$sec" "tuned profile" "$prof" OK "a server profile" ;;
    esac
  else
    add "$sec" "tuned profile" "not installed" OK "no tuned: make sure the sysctl and udev settings above persist on their own"
  fi
}

# ---------------------------------------------------------------- report

check_memory
check_hugepages_numa
check_storage
check_limits_cpu

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
