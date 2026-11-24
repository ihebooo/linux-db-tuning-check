# Linux DB tuning check

| Item | Value |
|---|---|
| Host | db-defaults |
| OS | Rocky Linux 9.4 (Blue Onyx) |
| Kernel | 5.14.0-427.el9.x86_64 |
| CPUs | 8 |
| RAM | 15.5 GiB |
| DB OS user | postgres |

Overall: **WARN** — 0 CRIT, 10 WARN, 4 OK

## Memory

| Check | Value | Status | What to do |
|---|---|---|---|
| vm.swappiness | 60 | WARN | set vm.swappiness=1 in /etc/sysctl.d/: at 60 the kernel swaps out database memory when the page cache grows |
| vm.dirty_* | background 10 % = 1.6 GiB, limit 20 % = 3.1 GiB | WARN | too much dirty data before write-back: checkpoints flush it in bursts that stall queries; set vm.dirty_background_bytes=268435456 and vm.dirty_bytes=1073741824 |
| vm.overcommit_memory | 1 | WARN | always overcommit: under memory pressure the OOM killer kills a backend or the postmaster; use 2 (with vm.overcommit_ratio) or 0 |

## Huge pages and NUMA

| Check | Value | Status | What to do |
|---|---|---|---|
| Transparent Huge Pages | enabled=always, defrag=madvise | WARN | disable THP for database hosts: compaction and khugepaged cause latency spikes; boot with transparent_hugepage=never or use a tuned profile that sets it |
| Huge pages | none reserved; shared_buffers 25 % of RAM = 3.9 GiB | OK | not needed below 8 GiB of shared_buffers; above that reserve vm.nr_hugepages |
| NUMA | 2 nodes, vm.zone_reclaim_mode=1 | WARN | set vm.zone_reclaim_mode=0: otherwise the kernel drops local page cache instead of using memory on the other node |

## Storage

| Check | Value | Status | What to do |
|---|---|---|---|
| I/O scheduler sda | bfq (SSD/NVMe) | WARN | bfq is tuned for desktops and adds latency under a database load: use none or mq-deadline (udev rule or a tuned profile) |
| Mount / | xfs, relatime | OK | fine; noatime saves a few more writes |
| Mount /data pg | ext3, strictatime | WARN | ext3 is outdated for a database: use xfs or ext4; every read updates the access time: mount with noatime |

## Limits and CPU

| Check | Value | Status | What to do |
|---|---|---|---|
| Open files (postgres) | 1024 (running process 4242) | WARN | raise to 65536: LimitNOFILE=65536 in the systemd unit (services ignore limits.conf) or nofile in /etc/security/limits.d/ |
| Processes (postgres) | 63000 (running process 4242) | OK | enough for one backend process per connection |
| fs.file-max | 9223372036854775807 | OK | the system-wide file limit is not a bottleneck |
| CPU governor | powersave x2 | WARN | CPUs clock down between queries and add latency: use the performance governor (tuned profile throughput-performance, or cpupower frequency-set -g performance) |
| tuned profile | balanced | WARN | a power-saving profile: switch with tuned-adm profile throughput-performance |

## Suggested PostgreSQL settings

Starting values for a server dedicated to PostgreSQL, computed from 15.5 GiB RAM and 8 CPUs.
Measure and adjust; they are not a substitute for load testing.

| Setting | Suggested | Why |
|---|---|---|
| shared_buffers | 3840MB | 25 % of RAM: the rest stays for the OS page cache, which PostgreSQL also reads through |
| effective_cache_size | 11GB | 75 % of RAM: shared_buffers plus the page cache the planner can count on (no memory is allocated) |
| maintenance_work_mem | 995MB | RAM / 16, at most 2GB: faster VACUUM and CREATE INDEX |
| work_mem | 39MB | (RAM - shared_buffers) / (max_connections 100 x 3): per sort or hash, so a query can use several; raise per session for reports |
| max_wal_size | 4GB | fewer, calmer checkpoints than the 1GB default; watch checkpoints_req in pg_stat_bgwriter / pg_stat_checkpointer |
| min_wal_size | 1GB | a quarter of max_wal_size: WAL files are recycled instead of created |
| checkpoint_completion_target | 0.9 | spread checkpoint writes over 90 % of the interval (default since PostgreSQL 14) |
| random_page_cost | 1.1 | SSD/NVMe (non-rotational disks detected): a random read costs about the same as a sequential one, so index scans get chosen |
| effective_io_concurrency | 200 | SSD/NVMe (non-rotational disks detected): many I/O requests in flight for bitmap heap scans |
| max_worker_processes | 8 | one per CPU (8), at least the default 8 |
| max_parallel_workers | 8 | one per CPU |
| max_parallel_workers_per_gather | 4 | half the CPUs, at most 4: one query must not take every core |
| max_parallel_maintenance_workers | 4 | half the CPUs, at most 4, for CREATE INDEX |
| huge_pages | try | use huge pages once vm.nr_hugepages=2090 is reserved; falls back to normal pages until then |
| max_connections | 100 | more than 4 x CPUs (32) busy at once only queue for CPU: if most connections are active, put a pooler such as PgBouncer in front |

```ini
# postgresql.conf — suggested by db_tuning_check.sh 0.1.0 for db-defaults
shared_buffers                   = 3840MB
effective_cache_size             = 11GB
maintenance_work_mem             = 995MB
work_mem                         = 39MB
max_wal_size                     = 4GB
min_wal_size                     = 1GB
checkpoint_completion_target     = 0.9
random_page_cost                 = 1.1
effective_io_concurrency         = 200
max_worker_processes             = 8
max_parallel_workers             = 8
max_parallel_workers_per_gather  = 4
max_parallel_maintenance_workers = 4
huge_pages                       = try
max_connections                  = 100
```
