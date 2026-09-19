# servscan.sh

**Production-grade, multi-threaded server diagnostic & triage collector for Linux.**

`servscan.sh` runs a comprehensive, concurrent diagnostic sweep across four
layers — **Compute & Memory**, **Storage & I/O**, **Network**, and **Kernel
Logs** — isolates every tool's output into a dedicated file inside a
secured `0700` directory, then packs the result into an ultra-compressed
`.tar.gz` bundle and self-cleans the raw directory.

Designed for SREs and sysadmins who need a single-command, zero-dependency
triage payload they can hand off, archive, or diff against a baseline.

---

## Table of Contents

- [Features](#features)
- [Architecture](#architecture)
- [Requirements](#requirements)
- [Installation](#installation)
- [Usage](#usage)
- [Output Structure](#output-structure)
- [Diagnostic Matrix](#diagnostic-matrix)
- [How It Works](#how-it-works)
- [Troubleshooting](#troubleshooting)
- [Contributing](#contributing)
- [License](#license)

---

## Features

- **Zero external dependencies** — uses native/standard Linux binaries.
  Missing optional tools degrade gracefully to a `[ SKIPPED ]` status;
  the run never aborts.
- **Multi-threaded execution** — four diagnostic layers run concurrently as
  background subshells (controlled 4-way parallelism), each with per-tool
  `timeout` guards so a hung command can never stall the sweep.
- **Idempotent & self-cleaning** — `trap` handlers on `SIGINT`/`SIGTERM`/
  `EXIT` kill lingering jobs and wipe all partial state, so a re-run always
  starts from a clean slate.
- **Strict output isolation** — every tool writes to its own dedicated
  `.log` file; nothing is interleaved.
- **Executive terminal dashboard** — live status indicators
  (`[ RUNNING ]`, `[ SUCCESS ]`, `[ FAILED ]`, `[ SKIPPED ]`) with a
  summary table and ok/failed/skipped totals.
- **Compressed payload** — the triage directory is packed via
  `tar | gzip -9` (max compression) into a single `.tar.gz`, with the
  uncompressed dir erased instantly post-archive.
- **Integrity reporting** — prints the absolute path, human-readable size,
  and SHA-256 checksum of the final bundle.
- **Root-safe** — validates root privileges, core binary availability, and
  free disk space before touching anything.

---

## Architecture

```
                         ┌─────────────────────┐
                         │     servscan.sh      │
                         │   (root preflight)   │
                         └──────────┬──────────┘
                                    │
                    ┌───────────────┼───────────────┐
                    │               │               │
              ┌─────▼─────┐   ┌─────▼─────┐   ┌─────▼─────┐
              │  Layer A  │   │  Layer B  │   │  Layer C  │  ...
              │ Compute &  │   │ Storage &  │   │ Network &  │
              │  Memory    │   │   I/O      │   │  Traffic   │
              └─────┬─────┘   └─────┬─────┘   └─────┬─────┘
                    │               │               │
         ┌──────────┼──────┐        │        ┌──────┼──────┐
         │          │      │        │        │      │      │
      uptime    lscpu  vmstat    iostat    ss    ip    tcpdump
         │          │      │        │        │      │      │
         └──────────┴──┬───┴────────┴────────┴──────┴──────┘
                       │
                  ┌────▼────┐
                  │  flock  │  ← thread-safe status ledger
                  │ ledger  │
                  └────┬────┘
                       │
              ┌────────▼────────┐
              │  MANIFEST.txt    │
              │  + status.txt    │
              └────────┬────────┘
                       │
              ┌────────▼────────┐
              │  tar | gzip -9  │
              └────────┬────────┘
                       │
              ┌────────▼────────────────────────┐
              │  triage_<host>_<ts>.tar.gz      │
              │  (raw dir erased post-archive)  │
              └─────────────────────────────────┘
```

**Concurrency model:** The four layers launch as concurrent background
subshells (`layer_* &`). Within each layer, tasks run sequentially so that
per-task status remains deterministic and race-free. All per-task status
records are serialized through `flock` to a single status ledger, which is
later rendered into the dashboard table.

---

## Requirements

See **[requirements.txt](requirements.txt)** for the full dependency list
with per-distro install commands.

**Mandatory** (script won't start without these):

| Binary | Package (Debian/Ubuntu) |
|--------|------------------------|
| `bash` ≥ 4.0 | `bash` |
| `timeout` | `coreutils` |
| `flock` | `util-linux` |
| `tar`, `gzip` | `tar`, `gzip` |
| `grep`, `awk` | `grep`, `gawk` |
| `sha256sum` | `coreutils` |
| `ip` | `iproute2` |

**Optional** (degrade to `[ SKIPPED ]` if absent — the run continues):

| Binary | Package | Layer |
|--------|---------|-------|
| `uptime`, `vmstat`, `free`, `ps` | `procps-ng` | Compute |
| `lscpu` | `util-linux` | Compute |
| `iostat` | `sysstat` | Storage |
| `findmnt` | `util-linux` | Storage |
| `ss` | `iproute2` | Network |
| `tcpdump` | `tcpdump` | Network |
| `journalctl` | `systemd` | Logs |
| `dmesg` | `util-linux` | Logs |

---

## Installation

```bash
# Clone
git clone https://github.com/<your-user>/servscan.git
cd servscan

# Make executable
chmod +x servscan.sh

# (Optional) symlink to /usr/local/sbin for system-wide access
sudo ln -sf "$(pwd)/servscan.sh" /usr/local/sbin/servscan
```

---

## Usage

```bash
# Full diagnostic sweep (requires root)
sudo ./servscan.sh

# Show help
./servscan.sh --help

# Show version
./servscan.sh --version
```

### What happens during a run

1. **Preflight** — validates root, core binaries, and ≥ 512 MB free on
   `/var/log`.
2. **Secured output directory** — creates `/var/log/triage_<host>_<ts>/`
   with `0700` permissions.
3. **Concurrent sweep** — launches 4 background layers (compute, storage,
   network, logs) with a live progress spinner.
4. **Dashboard** — prints a per-task status table with totals.
5. **Packaging** — writes a `MANIFEST.txt`, packs everything with
   `tar | gzip -9`, erases the raw directory.
6. **Final report** — prints the archive path, size, and SHA-256 checksum.

---

## Output Structure

```
triage_<host>_<timestamp>.tar.gz
│
├── MANIFEST.txt                    ← host, kernel, arch, artifact listing
├── _status_ledger.txt              ← raw task status records
│
├── compute_uptime.log              ┐
├── compute_lscpu.log               │
├── cpu_vmstat.log                  │ Layer A: Compute & Memory
├── mem_free.log                    │
├── proc_top.log                    ┘
│
├── storage_df.log                  ┐
├── storage_iostat.log              │ Layer B: Storage & I/O
├── storage_findmnt.log             ┘
│
├── net_sockets.log                 ┐
├── net_ip_link.log                │ Layer C: Network
├── network_snapshot.pcap          │ (raw 500-packet tcpdump capture)
├── network_snapshot.log           │ (tcpdump console diagnostics)
│                                   ┘
│
├── logs_journalctl.log             ┐
├── logs_dmesg.log                  │ Layer D: Kernel Logs
├── logs_auth_patterns.log         │ (regex: denied|segfault|OOM-killer|failed)
├── logs_syslog_patterns.log       ┘
```

---

## Diagnostic Matrix

| Layer | Command | Output File |
|-------|---------|-------------|
| **A · Compute** | `uptime` | `compute_uptime.log` |
| | `lscpu` | `compute_lscpu.log` |
| | `vmstat 1 5` | `cpu_vmstat.log` |
| | `free -w` (fallback: `free -m`) | `mem_free.log` |
| | `ps -eo pid,ppid,cmd,%mem,%cpu --sort=-%cpu \| head -20` | `proc_top.log` |
| **B · Storage** | `df -hT --local` | `storage_df.log` |
| | `iostat -xz 1 5` | `storage_iostat.log` |
| | `findmnt` | `storage_findmnt.log` |
| **C · Network** | `ss -tumpnaex` | `net_sockets.log` |
| | `ip -s -d link` | `net_ip_link.log` |
| | `tcpdump -c 500 -nn -vv -w` | `network_snapshot.pcap` |
| **D · Logs** | `journalctl -p 0..3 --since '2 hours ago'` | `logs_journalctl.log` |
| | `dmesg -T --level=err,crit,alert,emerg` | `logs_dmesg.log` |
| | regex on `/var/log/auth.log` | `logs_auth_patterns.log` |
| | regex on `/var/log/syslog` | `logs_syslog_patterns.log` |

---

## How It Works

### Defensive programming

- **Root check** — exits `126` if not root (needed for `journalctl`,
  `dmesg`, `tcpdump`, `/var/log/auth.log`).
- **Core binary check** — exits `127` if mandatory tools are missing.
- **Free space check** — exits `137` if `/var/log` has less than 512 MB.
- **Signal traps** — `SIGINT`/`SIGTERM` trigger `on_interrupt()`, which
  kills all background jobs and wipes partial state; `EXIT` triggers
  `on_exit()` for final cleanup.

### Tolerant execution (`set -uo pipefail` without `-e`)

The script uses `set -uo pipefail` — **without** `set -e` — deliberately.
A triage collector must survive the failure of any single diagnostic tool;
aborting the whole sweep because `iostat` is absent would defeat the
purpose. Each tool is wrapped by `exec_task()`, which records a discrete
status and always returns `0`.

### Thread-safe status ledger

Per-task status records from the four concurrent layers are serialized
through `flock` to a single `status.txt` ledger:

```bash
record_status() {
    local ledger="${STATUS_DIR}/status.txt"
    {
        flock 9
        printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" >&9
    } 9>>"${ledger}"
}
```

### ANSI color safety

Colors are auto-disabled when stdout is not a TTY (e.g., cron, piped to a
file), so the script produces clean output in all contexts.

---

## Troubleshooting

### `C_CYAN: unbound variable` (or any `C_*: unbound variable`)

**Fixed in v2.4.1.** This was caused by a missing space in the ANSI color
`readonly` declaration, which prevented `C_CYAN` from being defined. With
`set -u` active, the first reference to `${C_CYAN}` (in the ASCII banner)
crashed the script. If you encounter this with an older copy, update to
the latest version.

### `[ SKIPPED ]` for a tool

The tool's binary isn't installed. Install the corresponding package (see
[Requirements](#requirements)) and re-run. `[ SKIPPED ]` is not an error —
the script continues and notes it in the dashboard.

### `[ FAILED ]` for a tool

The tool ran but returned a non-zero exit code, or it timed out. Open the
corresponding `.log` file inside the archive to see the stderr capture.

### `[ FAILED ]` for `tcpdump`

Common causes:
- No active network interface detected (check `ip route`).
- `tcpdump` lacks permissions (are you root?).
- The capture timeout was reached (check `network_snapshot.log` for details;
  a partial `.pcap` may still be present).

### Archive not produced

The script exits `1` if `tar | gzip` fails. Check:
- Sufficient free space on `/var/log` (≥ 512 MB required).
- Write permissions on `/var/log`.
- The triage directory (if not auto-cleaned, inspect it at
  `/var/log/triage_<host>_<ts>/`).

### Script killed by `SIGINT` (Ctrl+C)

This is expected — the trap handler cleans up all partial state and exits
`130`. No artifacts are left behind.

---

## Contributing

1. Fork the repository.
2. Create a feature branch: `git checkout -b feature/my-improvement`.
3. Test with `bash -n servscan.sh` (syntax) and `shellcheck servscan.sh`
   (static analysis).
4. Commit with a clear message.
5. Open a pull request.

**Coding conventions:**
- Every new diagnostic tool must go through `exec_task()` — never call a
  diagnostic binary directly.
- Always provide a fallback or accept `[ SKIPPED ]` for optional tools.
- Add inline comments explaining *why*, not *what*.

---

## License

MIT License. See the header in `servscan.sh` for the full notice.

---

*Built for SREs who need answers fast, in a single compressed payload.*
