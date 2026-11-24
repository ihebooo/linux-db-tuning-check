# linux-db-tuning-check

[![CI](https://github.com/ihebooo/linux-db-tuning-check/actions/workflows/ci.yml/badge.svg)](https://github.com/ihebooo/linux-db-tuning-check/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Release](https://img.shields.io/github/v/release/ihebooo/linux-db-tuning-check)](https://github.com/ihebooo/linux-db-tuning-check/releases)

**One read-only Bash script: is this Linux host tuned for a database server — and what should I change?**

It reads kernel and OS settings from `/proc`, `/sys` and `/etc`, gives each one **OK / WARN / CRIT**
with a concrete fix, suggests starting values for `postgresql.conf` from the host's RAM, CPUs and
disks, and exits with the worst status — so it works by hand, in a build pipeline, or as a
monitoring check. It never changes a setting.

📄 **Example report:** [Markdown](docs/example-report.md) · [JSON](docs/example-report.json)

## Quick start

```bash
curl -fsSLO https://raw.githubusercontent.com/ihebooo/linux-db-tuning-check/v0.1.0/db_tuning_check.sh
chmod +x db_tuning_check.sh
./db_tuning_check.sh                       # Markdown report on stdout
./db_tuning_check.sh -s 16GB -c 300        # with your planned shared_buffers and max_connections
./db_tuning_check.sh --json | jq .status   # for scripts and dashboards
```

Requirements: Bash 4+, awk, coreutils. Tested in CI on **Rocky Linux 9, Ubuntu 24.04 and Debian 12**.
Root is not required.

## Options

```text
-u, --db-user USER          database OS user for the ulimit checks (default: postgres)
-s, --shared-buffers SIZE   planned shared_buffers, e.g. 8GB (default: 25 % of RAM)
-c, --max-connections N     planned max_connections, for work_mem (default: 100)
    --storage ssd|hdd       disk type for the planner settings (default: detected)
    --sysroot DIR           read /proc, /sys and /etc under DIR instead of /
-j, --json                  one JSON object instead of Markdown
-h, --help  -V, --version
```

## Exit codes

| Code | Meaning |
|---|---|
| 0 | every check OK |
| 1 | at least one WARN |
| 2 | at least one CRIT |
| 3 | usage error or not a Linux host |

A value that cannot be read (a missing file, a kernel without the feature) is reported as **SKIP**
and does not change the exit code.

## The checks — why they matter and how to fix them

Persist `vm.*` and `fs.*` values in a file such as `/etc/sysctl.d/90-database.conf` and load it with
`sysctl --system`. On RHEL-family hosts a [tuned](https://tuned-project.org/) profile can set most of
them in one place.

### Memory

| Check | WARN / CRIT when | Why it matters | Fix |
|---|---|---|---|
| `vm.swappiness` | WARN > 10 | At the default 60 the kernel swaps out database memory (shared buffers, backends) to keep page cache, and queries stall on swap-in. | `vm.swappiness = 1` |
| `vm.dirty_*` | WARN when the background threshold > 1 GiB or the limit > 4 GiB, or background ≥ limit | The ratios are a percentage of RAM: on a 64 GiB host the kernel collects 6 GiB of dirty pages before writing. A checkpoint then flushes it all at once and every query waits for the disk. | `vm.dirty_background_bytes = 268435456` and `vm.dirty_bytes = 1073741824` |
| `vm.overcommit_memory` | WARN = 1 | With "always overcommit" allocations never fail; under memory pressure the OOM killer picks a process — possibly the postmaster, which takes every connection down. | `0` (default) or, as the PostgreSQL docs recommend, `2` with `vm.overcommit_ratio` sized so the commit limit covers RAM |

### Huge pages and NUMA

| Check | WARN / CRIT when | Why it matters | Fix |
|---|---|---|---|
| Transparent Huge Pages | WARN when `enabled = always` | khugepaged and memory compaction run in the background and cause latency spikes for database workloads. | boot with `transparent_hugepage=never` (or `madvise`), or a tuned profile that sets it |
| Huge pages | WARN when reserved huge pages < `shared_buffers` + 5 %, or none reserved with `shared_buffers` ≥ 8 GiB | Every backend maps shared memory; with 4 kB pages the page tables for large `shared_buffers` cost gigabytes of RAM and TLB misses. Too few reserved pages mean PostgreSQL silently falls back (`huge_pages=try`) or refuses to start (`on`). | `vm.nr_hugepages = N` (the report computes N) and `huge_pages = on` |
| NUMA | WARN when there are several nodes and `vm.zone_reclaim_mode` ≠ 0 | The kernel then evicts page cache on the local node instead of using free memory on the other one: the database's cache shrinks for no reason. | `vm.zone_reclaim_mode = 0` |

### Storage

| Check | WARN / CRIT when | Why it matters | Fix |
|---|---|---|---|
| I/O scheduler per disk | WARN for `bfq` / `cfq` on any disk, `none` on a spinning disk | `bfq` is built for desktop fairness and costs CPU and latency per request; a spinning disk needs request reordering. | `none` or `mq-deadline` for SSD/NVMe, `mq-deadline` for HDD — a udev rule or a tuned profile |
| Mount options | **CRIT** with `nobarrier` / `barrier=0`; WARN without `noatime`/`relatime`, on ext2/ext3, or on btrfs | Without write barriers a power loss can reorder writes past the WAL and corrupt the database. Strict atime turns every read into a write. btrfs copy-on-write fragments table files. | remove `nobarrier`; mount with `noatime`; use xfs or ext4 (or `chattr +C` on the data directory on btrfs) |

Bind mounts (containers, `/etc/hosts`, …) repeat a device and are reported once.

### Limits and CPU

| Check | WARN / CRIT when | Why it matters | Fix |
|---|---|---|---|
| Open files (DB user) | **CRIT** < 1024, WARN < 4096 | Each table, index and connection needs file descriptors; at the limit the database fails with "too many open files". | `LimitNOFILE=65536` in the systemd unit (services ignore `limits.conf`), or `nofile` in `/etc/security/limits.d/` |
| Processes (DB user) | WARN < 4096 | PostgreSQL runs one process per connection plus background workers. | `LimitNPROC=` or `nproc` in `limits.d` |
| `fs.file-max` | WARN < 65536 | The system-wide cap on open files. | `fs.file-max = 6553600` |
| CPU governor | WARN for `powersave`, `ondemand`, `conservative` | CPUs clock down between queries and take time to ramp up: short queries get slower. | `performance` governor (`cpupower frequency-set -g performance`, or tuned `throughput-performance`) |
| tuned profile | WARN for `balanced`, `powersave`, desktop/laptop profiles | Power-saving profiles undo several of the settings above. | `tuned-adm profile throughput-performance` |

The limits are read from a running process of the DB user when there is one (what the database
really gets), otherwise from `limits.conf` and `limits.d`.

## Suggested PostgreSQL settings

Every report ends with a table and a ready-to-paste `postgresql.conf` snippet, each value with its
reasoning:

| Setting | Rule |
|---|---|
| `shared_buffers` | 25 % of RAM (or `--shared-buffers`) |
| `effective_cache_size` | 75 % of RAM |
| `maintenance_work_mem` | RAM / 16, at most 2GB |
| `work_mem` | (RAM − shared_buffers) / (max_connections × 3), at least 4MB |
| `max_wal_size` / `min_wal_size` | 1 / 4 / 8 GB by RAM size; min = a quarter |
| `checkpoint_completion_target` | 0.9 |
| `random_page_cost` / `effective_io_concurrency` | 1.1 / 200 on SSD/NVMe, 4 / 2 on HDD |
| parallel workers | one per CPU; per gather and maintenance: half the CPUs, at most 4 |
| `huge_pages` | `on` when enough are reserved, else `try` with the `vm.nr_hugepages` to set |

These are starting points for a server dedicated to PostgreSQL, not a substitute for measuring your
own workload.

## Check another host, or a snapshot

`--sysroot DIR` reads everything under `DIR` instead of `/`. Copy the relevant files from a server you
cannot run scripts on and check them on your laptop:

```bash
# on the server: copy with cat, because tar sees /proc and /sys files as empty
for f in /proc/meminfo /proc/cpuinfo /proc/mounts /proc/sys/vm/* /proc/sys/fs/file-max \
         /proc/sys/kernel/hostname /proc/sys/kernel/osrelease \
         /sys/block/*/queue/scheduler /sys/block/*/queue/rotational \
         /sys/kernel/mm/transparent_hugepage/enabled /sys/kernel/mm/transparent_hugepage/defrag \
         /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor \
         /etc/os-release /etc/passwd /etc/tuned/active_profile \
         /etc/security/limits.conf /etc/security/limits.d/*.conf; do
  [ -f "$f" ] && [ -r "$f" ] || continue
  mkdir -p "snap${f%/*}" && cat "$f" > "snap$f" 2>/dev/null
done
for n in /sys/devices/system/node/node[0-9]*; do [ -d "$n" ] && mkdir -p "snap$n"; done
tar czf snapshot.tgz snap

# on your machine
tar xzf snapshot.tgz && ./db_tuning_check.sh --sysroot snap
```

Limits then come from `limits.conf` (a snapshot has no running processes).

The tests use the same mechanism: `tests/fixtures/` holds three fake hosts — stock defaults, a tuned
server and a risky one — and `tests/run-fixtures.sh` asserts every status, exit code and suggested
setting.

## In monitoring

```ini
# Zabbix agent: the status, and the full report for whoever picks up the alert
UserParameter=db.tuning.status,/opt/db_tuning_check.sh --json | jq -r .status
```

```cron
# weekly mail when something drifted
0 7 * * 1  root  /opt/db_tuning_check.sh > /tmp/tuning.md || mail -s "DB host tuning: action needed" dba@example.com < /tmp/tuning.md
```

## License

[MIT](LICENSE) · Changes per version: [CHANGELOG.md](CHANGELOG.md) ·
Ideas and bug reports: [open an issue](https://github.com/ihebooo/linux-db-tuning-check/issues).
See also [pg-health-report](https://github.com/ihebooo/pg-health-report), the same idea inside PostgreSQL.
