# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [0.1.0] — 2026-11-24

First release.

### Added
- Memory checks: `vm.swappiness`, `vm.dirty_*` (ratios and bytes, judged against RAM), `vm.overcommit_memory`.
- Transparent Huge Pages, reserved huge pages against `shared_buffers` (`--shared-buffers`), NUMA `vm.zone_reclaim_mode`.
- I/O scheduler per disk (SSD/NVMe vs HDD) and mount options: atime mode, write barriers, filesystem type; bind mounts reported once.
- Open files and process limits of the database user (`--db-user`) from a running process or `limits.conf`, `fs.file-max`, CPU governor, tuned profile.
- Suggested PostgreSQL settings from RAM, CPUs and disk type, with the reasoning and a `postgresql.conf` snippet (`--max-connections`, `--storage`).
- OK / WARN / CRIT / SKIP per check with a fix, exit code = worst status, `--json` output.
- `--sysroot` to check a snapshot of another host; fixture hosts and `tests/run-fixtures.sh`.
- CI: ShellCheck, fixtures, JSON, and real runs on Rocky Linux 9, Ubuntu 24.04 and Debian 12.

[0.1.0]: https://github.com/ihebooo/linux-db-tuning-check/releases/tag/v0.1.0
