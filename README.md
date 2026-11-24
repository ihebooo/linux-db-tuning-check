# linux-db-tuning-check

[![CI](https://github.com/ihebooo/linux-db-tuning-check/actions/workflows/ci.yml/badge.svg)](https://github.com/ihebooo/linux-db-tuning-check/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

**One read-only Bash script: is this Linux host tuned for a database server?**

It reads kernel and OS settings (`/proc`, `/sys`, `ulimit`, …), gives each one
**OK / WARN / CRIT** with a "what to do" hint, and exits with the worst status — so it works
by hand, from cron, or as a monitoring check. It never changes a setting.

> Status: early skeleton (`--help`, CI). Checks land one per day — see the roadmap below.

## Quick start

```bash
git clone https://github.com/ihebooo/linux-db-tuning-check.git && cd linux-db-tuning-check
./db_tuning_check.sh --help
./db_tuning_check.sh --db-user postgres
```

Requirements: Bash 4+, a Linux host. Root is optional (a few values are only readable as root).

## Exit codes

| Code | Meaning |
|---|---|
| 0 | every check OK |
| 1 | at least one WARN |
| 2 | at least one CRIT |
| 3 | usage error or not a Linux host |

## Planned checks

- [ ] `vm.swappiness`, `vm.dirty_ratio` / `dirty_background_ratio`, memory overcommit
- [ ] Transparent Huge Pages, huge pages vs `shared_buffers`, NUMA
- [ ] I/O scheduler per disk, mount options (`noatime`), filesystem type
- [ ] ulimits for the DB user, open files, CPU governor / `tuned` profile
- [ ] PostgreSQL config advice from RAM/CPU (`shared_buffers`, `effective_cache_size`, `work_mem`, `max_wal_size`)
- [ ] `--json` output; CI on Rocky Linux and Ubuntu

## License

[MIT](LICENSE)
