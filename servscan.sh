#!/usr/bin/env bash
#
# =============================================================================
#  server_triage.sh
# =============================================================================
#  Production-grade, multi-threaded server diagnostic & triage collector.
#
#  Architectural pillars:
#    1. Zero external dependencies  -> native binaries + graceful fallbacks.
#    2. Non-blocking execution      -> controlled background jobs w/ timeouts.
#    3. Idempotent & self-cleaning  -> trap-driven cleanup on SIGINT/SIGTERM.
#
#  Output:
#    /var/log/triage_<host>_<ts>.tar.gz   (ultra-compressed payload bundle)
#
#  Author : SRE Architecture
#  License: MIT
# =============================================================================
#
#  DESIGN NOTES
#  ------------
#  * `set -uo pipefail` is intentionally used WITHOUT `set -e`. A triage
#    collector MUST survive the failure of any single diagnostic tool;
#    aborting the whole sweep because `iostat` is absent would defeat the
#    purpose. Each tool is wrapped by `exec_task()` which records a
#    discrete status (SUCCESS / FAILED / SKIPPED) and always returns 0.
#  * The four diagnostic LAYERS run concurrently as background subshells
#    (controlled 4-way parallelism). Within a layer, tasks run sequentially
#    so that per-task status remains deterministic and race-free.
#  * All per-task status records are serialized through `flock` to a single
#    status ledger, which is later rendered into the dashboard table.
#
# =============================================================================

set -uo pipefail

# -----------------------------------------------------------------------------
#  Global tunables
# -----------------------------------------------------------------------------
readonly SCRIPT_VERSION="2.4.0"
readonly SCRIPT_NAME="$(basename -- "${BASH_SOURCE[0]}")"
readonly TS="$(date +%Y%m%d_%H%M%S)"
readonly HOST="${HOSTNAME:-unknown-host}"

# Secured output directory + final archive (archive is a SIBLING of the dir
# so tar never tries to archive its own output file).
readonly TRIAGE_ROOT="/var/log/triage_${HOST}_${TS}"
readonly ARCHIVE_PATH="/var/log/triage_${HOST}_${TS}.tar.gz"

readonly MAX_CAPTURE_PACKETS=500        # tcpdump packet cap
readonly MIN_FREE_MB=512                 # minimum free space on /var/log (MB)
readonly TASK_TIMEOUT=60                 # generic per-tool timeout (seconds)
readonly SAMPLE_TIMEOUT=20               # for sampled tools (vmstat/iostat)
readonly LOG_TIMEOUT=90                  # journalctl / dmesg
readonly PCAP_TIMEOUT=90                # tcpdump hard cap

# Mutable globals (assigned at runtime)
STATUS_DIR=""                            # mktemp dir for the status ledger
ARCHIVE_OK=0                             # flipped to 1 after successful pack
LAYER_A_PID="" LAYER_B_PID="" LAYER_C_PID="" LAYER_D_PID=""

# -----------------------------------------------------------------------------
#  ANSI palette (auto-disabled when stdout is not a TTY -> cron-safe)
# -----------------------------------------------------------------------------
if [[ -t 1 ]]; then
    readonly C_RESET="\033[0m"   C_BOLD="\033[1m"
    readonly C_RED="\033[31m"    C_GREEN="\033[32m"
    readonly C_YELLOW="\033[33m" C_BLUE="\033[34m"
    readonly C_MAGENTA="\033[35m" C_CYAN="\033[36m"
    readonly C_GRAY="\033[90m"
else
    readonly C_RESET="" C_BOLD="" C_RED="" C_GREEN="" C_YELLOW=""
    readonly C_BLUE="" C_MAGENTA="" C_CYAN="" C_GRAY=""
fi

# =============================================================================
#  LOGGING / STATUS PRIMITIVES
# =============================================================================

_log() { local lvl="$1"; shift; printf "%b[%-7s]%b %s\n" "${C_GRAY}" "${lvl}" "${C_RESET}" "$*"; }
_info() { _log "INFO"  "$@"; }
_note() { _log "NOTE"  "$@"; }
_warn() { printf "%b[WARN  ]%b %s\n"  "${C_YELLOW}" "${C_RESET}" "$*" >&2; }
_fatal(){ printf "%b[FATAL ]%b %s\n"  "${C_RED}"    "${C_RESET}" "$*" >&2; }

# Right-pad a string to a fixed visible width (used for table alignment).
pad() {
    local s="$1" w="$2"
    while (( ${#s} < w )); do s="${s} "; done
    printf '%s' "$s"
}

# Colored status tag for the live console stream.
tag_status() {
    case "$1" in
        SUCCESS) printf "%b[ SUCCESS ]%b" "${C_GREEN}"  "${C_RESET}";;
        FAILED)  printf "%b[ FAILED  ]%b" "${C_RED}"    "${C_RESET}";;
        SKIPPED) printf "%b[ SKIPPED ]%b" "${C_CYAN}"    "${C_RESET}";;
        RUNNING) printf "%b[ RUNNING ]%b" "${C_YELLOW}" "${C_RESET}";;
        *)       printf "[ %-7s ]" "$1";;
    esac
}

# =============================================================================
#  ASCII STRUCTURAL HEADER
# =============================================================================

print_banner() {
    printf "%b" "${C_BOLD}${C_CYAN}"
    cat <<'BANNER'
  ___ ____ ___  ___ _   _ _____ ____   ___  _   _
 / __|_ _/ _ \/ __| | | |_   _|  _ \ / _ \| | | |
 \__ \ | | (_) \__ \ |_| | | | | |_) | | | | |_| |
 |___/___\___/|___/\___/  |_| |____/|_| |_|\___/
BANNER
    printf "%b" "${C_RESET}"
    printf "%b  Server Triage Engine%b  |  v%s  |  host=%s  |  ts=%s\n" \
        "${C_BOLD}" "${C_RESET}" "${SCRIPT_VERSION}" "${HOST}" "${TS}"
    printf "%b  Multi-threaded diagnostic collector & compressed payload packager%b\n\n" \
        "${C_GRAY}" "${C_RESET}"
}

# =============================================================================
#  STATUS LEDGER (thread-safe append via flock)
# =============================================================================

# record_status <layer> <task> <status> <outfile>
record_status() {
    local ledger="${STATUS_DIR}/status.txt"
    {
        flock 9
        printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" >&9
    } 9>>"${ledger}"
}

# =============================================================================
#  TASK EXECUTION ENGINE
# =============================================================================

# exec_task <layer> <task> <timeout_sec> <outfile> <cmd-string>
#
#   * Resolves the leading binary; if missing -> SKIPPED (never aborts the run).
#   * Runs the command under `timeout` inside `bash -c` so pipelines & quoted
#     args (e.g. --since '2 hours ago') survive intact.
#   * Captures stdout+stderr to <outfile>, records a status record, returns 0.
exec_task() {
    local layer="$1" task="$2" tmo="$3" out="$4"
    local cmd="$5"
    local bin="${cmd%% *}"   # first whitespace-delimited token = binary

    # Dependency probe (external binary or shell builtin).
    if ! command -v "${bin}" >/dev/null 2>&1 && ! type -t "${bin}" >/dev/null 2>&1; then
        record_status "${layer}" "${task}" "SKIPPED" "${out}"
        printf '[exec_task] SKIPPED: missing dependency "%s"\n' "${bin}" > "${out}"
        _warn "SKIPPED '${task}': '${bin}' not found"
        return 0
    fi

    # Run with bounded timeout; capture both streams.
    timeout --signal=TERM "${tmo}" bash -c "${cmd}" >"${out}" 2>&1
    local rc=$?

    case "${rc}" in
        0)
            record_status "${layer}" "${task}" "SUCCESS" "${out}"
            ;;
        124|137)
            # 124 = timeout killed it, 137 = SIGKILL (fallback). Treat as FAILED.
            printf '\n[exec_task] TIMEOUT after %ss\n' "${tmo}" >> "${out}"
            record_status "${layer}" "${task}" "FAILED" "${out}"
            _warn "TIMEOUT '${task}' (${tmo}s)"
            ;;
        *)
            printf '\n[exec_task] NONZERO rc=%d\n' "${rc}" >> "${out}"
            record_status "${layer}" "${task}" "FAILED" "${out}"
            _warn "FAILED  '${task}' (rc=${rc})"
            ;;
    esac
    return 0
}

# detect_primary_iface -> echoes the default-route interface, falling back to
# the first non-loopback interface that is UP.
detect_primary_iface() {
    local iface
    iface="$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')"
    if [[ -z "${iface}" ]]; then
        iface="$(ip -o link show up 2>/dev/null | awk -F': ' '!/lo/ {print $2; exit}')"
    fi
    printf '%s' "${iface}"
}

# run_tcpdump <triage_dir> <iface>
#   Special-cased because tcpdump writes the .pcap via -w (raw binary) while
#   its own console diagnostics must go to a companion .log.
run_tcpdump() {
    local D="$1" iface="$2"
    local pcap="${D}/network_snapshot.pcap"
    local logf="${D}/network_snapshot.log"

    if ! command -v tcpdump >/dev/null 2>&1; then
        record_status "NETWORK" "tcpdump" "SKIPPED" "${pcap}"
        _warn "SKIPPED 'tcpdump': binary not found"
        return 0
    fi
    if [[ -z "${iface}" ]]; then
        record_status "NETWORK" "tcpdump" "SKIPPED" "${pcap}"
        _warn "SKIPPED 'tcpdump': no active interface detected"
        return 0
    fi

    _note "tcpdump: capturing up to ${MAX_CAPTURE_PACKETS} packets on '${iface}'..."
    timeout --signal=TERM "${PCAP_TIMEOUT}" \
        tcpdump -c "${MAX_CAPTURE_PACKETS}" -nn -vv -i "${iface}" -w "${pcap}" >"${logf}" 2>&1
    local rc=$?

    # rc 0   -> captured exactly N packets and exited cleanly.
    # rc 124 -> hit timeout with a partial capture (still valuable telemetry).
    if [[ ${rc} -eq 0 || ${rc} -eq 124 ]]; then
        record_status "NETWORK" "tcpdump" "SUCCESS" "${pcap}"
        if [[ ${rc} -eq 124 ]]; then
            _note "tcpdump: partial capture (timeout reached)."
        fi
    else
        record_status "NETWORK" "tcpdump" "FAILED" "${pcap}"
        _warn "FAILED 'tcpdump' (rc=${rc})"
    fi
    return 0
}

# parse_log_patterns <outfile> <source_log>
#   Targeted regex triage: denied | segfault | OOM-killer | failed.
#   Head/tail bounded to keep the payload compact & deterministic.
parse_log_patterns() {
    local out="$1" src="$2"
    local name; name="$(basename -- "${src}")"

    if [[ ! -r "${src}" ]]; then
        record_status "LOGS" "${name}" "SKIPPED" "${out}"
        printf '[parse] source %s not readable (permissions/path missing)\n' "${src}" > "${out}"
        _warn "SKIPPED '${name}': not readable"
        return 0
    fi

    local pattern='denied|segfault|OOM-killer|failed'
    {
        echo "# ============================================================"
        echo "# regex triage  pattern='${pattern}'"
        echo "# source         = ${src}"
        echo "# generated_utc  = $(date -u +%FT%TZ 2>/dev/null || date -u)"
        echo "# ============================================================"
        echo
        grep -iEn "${pattern}" "${src}" 2>/dev/null | tail -n 500
        echo
        echo "# --------------------------------------------------------------"
        local cnt
        cnt="$(grep -iEc "${pattern}" "${src}" 2>/dev/null || true)"
        echo "# total matches (tail-bounded above to 500): ${cnt}"
    } > "${out}" 2>&1

    record_status "LOGS" "${name}" "SUCCESS" "${out}"
    return 0
}

# =============================================================================
#  DIAGNOSTIC LAYERS
# =============================================================================

# ---- Layer A: Compute & Memory (Resource Exhaustion Triage) ----------------
layer_compute_memory() {
    local D="${TRIAGE_ROOT}"
    exec_task "COMPUTE" "uptime"        "${TASK_TIMEOUT}"   "${D}/compute_uptime.log" "uptime"
    exec_task "COMPUTE" "lscpu"         "${TASK_TIMEOUT}"   "${D}/compute_lscpu.log"  "lscpu"
    exec_task "COMPUTE" "vmstat_1_5"    "${SAMPLE_TIMEOUT}" "${D}/cpu_vmstat.log"     "vmstat 1 5"
    exec_task "COMPUTE" "free_w"        "${TASK_TIMEOUT}"   "${D}/mem_free.log"       "free -w 2>/dev/null || free -m"
    exec_task "COMPUTE" "top_processes" "${TASK_TIMEOUT}"   "${D}/proc_top.log"       "ps -eo pid,ppid,cmd,%mem,%cpu --sort=-%cpu | head -n 20"
    return 0
}

# ---- Layer B: Storage & I/O Telemetry --------------------------------------
layer_storage_io() {
    local D="${TRIAGE_ROOT}"
    exec_task "STORAGE" "df_local"  "${TASK_TIMEOUT}"   "${D}/storage_df.log"      "df -hT --local"
    exec_task "STORAGE" "iostat_xz" "${SAMPLE_TIMEOUT}" "${D}/storage_iostat.log"  "iostat -xz 1 5"
    exec_task "STORAGE" "findmnt"   "${TASK_TIMEOUT}"   "${D}/storage_findmnt.log" "findmnt"
    return 0
}

# ---- Layer C: Network Layer & Real-Time Traffic Analysis -------------------
layer_network() {
    local D="${TRIAGE_ROOT}"
    exec_task "NETWORK" "ss_sockets" "${TASK_TIMEOUT}" "${D}/net_sockets.log"   "ss -tumpnaex"
    exec_task "NETWORK" "ip_link"    "${TASK_TIMEOUT}" "${D}/net_ip_link.log"   "ip -s -d link"
    local iface; iface="$(detect_primary_iface)"
    _note "primary interface detected: '${iface:-none}'"
    run_tcpdump "${D}" "${iface}"
    return 0
}

# ---- Layer D: Log Mining & Kernel Anomalies --------------------------------
layer_logs() {
    local D="${TRIAGE_ROOT}"
    exec_task "LOGS" "journalctl_crit" "${LOG_TIMEOUT}" "${D}/logs_journalctl.log" \
        "journalctl -p 0..3 --since '2 hours ago' --no-pager"
    exec_task "LOGS" "dmesg_err"        "${LOG_TIMEOUT}" "${D}/logs_dmesg.log" \
        "dmesg -T --level=err,crit,alert,emerg"
    parse_log_patterns "${D}/logs_auth_patterns.log"   "/var/log/auth.log"
    parse_log_patterns "${D}/logs_syslog_patterns.log"  "/var/log/syslog"
    return 0
}

# =============================================================================
#  CONCURRENCY ORCHESTRATOR
# =============================================================================

run_all_layers() {
    mkdir -p "${STATUS_DIR}"
    : > "${STATUS_DIR}/status.txt"

    _info "Launching 4 concurrent diagnostic layers..."
    printf "  %s %s\n" "$(tag_status RUNNING)" "COMPUTE  :: uptime, lscpu, vmstat, free, top-procs"
    printf "  %s %s\n" "$(tag_status RUNNING)" "STORAGE  :: df, iostat, findmnt"
    printf "  %s %s\n" "$(tag_status RUNNING)" "NETWORK  :: ss, ip-link, tcpdump(500pkts)"
    printf "  %s %s\n" "$(tag_status RUNNING)" "LOGS     :: journalctl, dmesg, auth/syslog regex"
    echo

    # Controlled 4-way parallelism: each layer is a background subshell.
    layer_compute_memory & LAYER_A_PID=$!
    layer_storage_io     & LAYER_B_PID=$!
    layer_network        & LAYER_C_PID=$!
    layer_logs           & LAYER_D_PID=$!

    # Live spinner while the four layers are still alive.
    local spin='|/-\' i=0 idx
    while kill -0 "${LAYER_A_PID}" 2>/dev/null \
       || kill -0 "${LAYER_B_PID}" 2>/dev/null \
       || kill -0 "${LAYER_C_PID}" 2>/dev/null \
       || kill -0 "${LAYER_D_PID}" 2>/dev/null; do
        idx=$(( i % 4 )); i=$(( i + 1 ))
        printf "\r  %s collecting telemetry  %b%c%b" \
            "$(tag_status RUNNING)" "${C_GRAY}" "${spin:$idx:1}" "${C_RESET}"
        sleep 0.2
    done
    printf "\r  %s collection complete.          %b\n" "$(tag_status SUCCESS)" "${C_RESET}"
    echo

    # Reap exit codes (best-effort; failures are already recorded per-task).
    wait "${LAYER_A_PID}" 2>/dev/null || true
    wait "${LAYER_B_PID}" 2>/dev/null || true
    wait "${LAYER_C_PID}" 2>/dev/null || true
    wait "${LAYER_D_PID}" 2>/dev/null || true
}

# =============================================================================
#  EXECUTIVE TERMINAL DASHBOARD
# =============================================================================

print_dashboard() {
    local ledger="${STATUS_DIR}/status.txt"
    local total=0 ok=0 fail=0 skip=0

    echo
    printf "%b%s%b\n" "${C_BOLD}${C_BLUE}" \
"──────────────────────────────────────────────────────────────────────────" "${C_RESET}"
    printf "%b DIAGNOSTIC LAYER STATUS DASHBOARD%b\n" "${C_BOLD}${C_BLUE}" "${C_RESET}"
    printf "%b%s%b\n" "${C_BOLD}${C_BLUE}" \
"──────────────────────────────────────────────────────────────────────────" "${C_RESET}"
    printf "  %-10s  %-26s  %s\n" "LAYER" "TASK" "STATUS"
    printf "%b%s%b\n" "${C_GRAY}" \
"──────────────────────────────────────────────────────────────────────────" "${C_RESET}"

    while IFS='|' read -r layer task status file; do
        [[ -z "${layer:-}" ]] && continue
        total=$(( total + 1 ))
        case "${status}" in
            SUCCESS) ok=$(( ok + 1 ));;
            FAILED)  fail=$(( fail + 1 ));;
            SKIPPED) skip=$(( skip + 1 ));;
        esac
        printf "  %-10s  %-26s  %s\n" \
            "${layer}" "$(pad "${task}" 26)" "$(tag_status "${status}")"
    done < "${ledger}"

    printf "%b%s%b\n" "${C_GRAY}" \
"──────────────────────────────────────────────────────────────────────────" "${C_RESET}"
    printf "  Totals: %b%d ok%b | %b%d failed%b | %b%d skipped%b | %d total\n" \
        "${C_GREEN}"  "${ok}"   "${C_RESET}" \
        "${C_RED}"    "${fail}" "${C_RESET}" \
        "${C_CYAN}"   "${skip}" "${C_RESET}" \
        "${total}"
    echo
}

# =============================================================================
#  PAYLOAD PACKAGING & SELF-CLEANING
# =============================================================================

package_archive() {
    _info "Writing MANIFEST.txt ..."
    {
        echo "# ============================================================"
        echo "#  TRIAGE MANIFEST"
        echo "# ============================================================"
        echo "host            = ${HOST}"
        echo "timestamp       = ${TS}"
        echo "script_version  = ${SCRIPT_VERSION}"
        echo "generated_utc   = $(date -u +%FT%TZ 2>/dev/null || date -u)"
        echo "kernel          = $(uname -r 2>/dev/null)"
        echo "arch            = $(uname -m 2>/dev/null)"
        echo "distributor     = $( (. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}") 2>/dev/null || echo unknown)"
        echo "uptime          = $(uptime 2>/dev/null || echo n/a)"
        echo
        echo "# ---- collected artifacts -----------------------------------"
        (cd "${TRIAGE_ROOT}" 2>/dev/null && ls -la 2>/dev/null)
        echo
        echo "# ---- task status ledger ------------------------------------"
        [[ -f "${STATUS_DIR}/status.txt" ]] && cat "${STATUS_DIR}/status.txt"
    } > "${TRIAGE_ROOT}/MANIFEST.txt" 2>&1

    # Snapshot the ledger into the bundle too.
    cp -f "${STATUS_DIR}/status.txt" "${TRIAGE_ROOT}/_status_ledger.txt" 2>/dev/null || true

    _info "Compressing payload (gzip -9) ..."
    # tar via a pipe to gzip -9 => maximal compression, single pass.
    ( cd /var/log && tar -cf - "$(basename -- "${TRIAGE_ROOT}")" 2>/dev/null \
        | gzip -9 -c > "${ARCHIVE_PATH}" )

    if [[ -f "${ARCHIVE_PATH}" ]]; then
        _info "Archive written: ${ARCHIVE_PATH}"
        # Self-cleaning: erase the uncompressed directory instantly.
        rm -rf "${TRIAGE_ROOT}"
        ARCHIVE_OK=1
    else
        _fatal "Archive generation FAILED; leaving triage dir for inspection."
    fi
}

# =============================================================================
#  FINAL REPORT
# =============================================================================

final_report() {
    local size="N/A" sha="N/A" path="${ARCHIVE_PATH}"
    if [[ -f "${ARCHIVE_PATH}" ]]; then
        size="$(du -h "${ARCHIVE_PATH}" 2>/dev/null | awk '{print $1}')"
        sha="$(sha256sum "${ARCHIVE_PATH}" 2>/dev/null | awk '{print $1}')"
    fi
    echo
    printf "%b%s%b\n" "${C_BOLD}${C_GREEN}" \
"══════════════════════════════════════════════════════════════════════════" "${C_RESET}"
    printf "%b  TRIAGE BUNDLE GENERATED%b\n" "${C_BOLD}${C_GREEN}" "${C_RESET}"
    printf "%b%s%b\n" "${C_BOLD}${C_GREEN}" \
"══════════════════════════════════════════════════════════════════════════" "${C_RESET}"
    printf "  %bPath      %b : %s\n" "${C_CYAN}" "${C_RESET}" "${path}"
    printf "  %bSize      %b : %s\n" "${C_CYAN}" "${C_RESET}" "${size}"
    printf "  %bSHA-256   %b : %s\n" "${C_CYAN}" "${C_RESET}" "${sha}"
    printf "  %bGenerated %b : %s\n" "${C_CYAN}" "${C_RESET}" \
        "$(date -u +'%Y-%m-%d %H:%M:%S UTC' 2>/dev/null || date -u)"
    printf "%b%s%b\n" "${C_BOLD}${C_GREEN}" \
"══════════════════════════════════════════════════════════════════════════" "${C_RESET}"
    echo
}

# =============================================================================
#  DEFENSIVE BLOCKS
# =============================================================================

# ---- Preflight: root, core binaries, free space ----------------------------
preflight() {
    # Root check (journalctl, dmesg, tcpdump, ss -p, /var/log/auth.log all
    # require elevated privileges).
    if [[ "${EUID}" -ne 0 ]]; then
        _fatal "This script must be executed as root (uid 0). Re-run with: sudo ${SCRIPT_NAME}"
        exit 126
    fi

    # Core-binary sanity (these are mandatory; everything else degrades).
    local b missing=()
    for b in timeout tar gzip sha256sum awk grep flock ip; do
        if ! command -v "${b}" >/dev/null 2>&1; then
            missing+=("${b}")
        fi
    done
    if (( ${#missing[@]} > 0 )); then
        _fatal "Core binaries missing from PATH: ${missing[*]}"
        exit 127
    fi

    # Free-space check on the target filesystem.
    local free_mb
    free_mb="$(df -m /var/log 2>/dev/null | awk 'NR==2 {print $4}')"
    if [[ -z "${free_mb}" ]] || (( free_mb < MIN_FREE_MB )); then
        _fatal "Insufficient free space on /var/log (need ${MIN_FREE_MB}MB, have ${free_mb:-?}MB)."
        exit 137
    fi

    _info "Preflight OK: root=yes, cores=ok, ${free_mb}MB free on /var/log."
}

# ---- Trap handlers: idempotent cleanup on interrupt / exit -----------------

on_interrupt() {
    echo
    _warn "Interrupted by signal ${1:-UNKNOWN} -- tearing down partial state..."
    # Kill any lingering background jobs (the 4 layers + their children).
    local p
    for p in "${LAYER_A_PID}" "${LAYER_B_PID}" "${LAYER_C_PID}" "${LAYER_D_PID}"; do
        [[ -n "${p}" ]] && kill "${p}" 2>/dev/null || true
    done
    jobs -p 2>/dev/null | while read -r jp; do kill "${jp}" 2>/dev/null || true; done
    wait 2>/dev/null || true
    # Wipe everything partial so a re-run starts clean (idempotency).
    rm -rf "${TRIAGE_ROOT}" "${STATUS_DIR}" 2>/dev/null || true
    _warn "Aborted. No archive produced."
    exit $(( 128 + ${1:-2} ))
}

on_exit() {
    # Always remove the transient status ledger.
    rm -rf "${STATUS_DIR}" 2>/dev/null || true
    # If we never finished packaging, drop the partial triage dir too.
    if [[ "${ARCHIVE_OK}" != "1" && -d "${TRIAGE_ROOT}" ]]; then
        rm -rf "${TRIAGE_ROOT}" 2>/dev/null || true
    fi
}

trap 'on_interrupt 2' INT
trap 'on_interrupt 15' TERM
trap 'on_exit' EXIT

# =============================================================================
#  USAGE
# =============================================================================

usage() {
    cat <<EOF
${SCRIPT_NAME} v${SCRIPT_VERSION} -- server triage engine

USAGE:
    sudo ${SCRIPT_NAME} [options]

OPTIONS:
    -h, --help        Show this help and exit.
    -V, --version     Print version and exit.

DESCRIPTION:
    Runs a comprehensive, multi-threaded diagnostic sweep across four layers
    (compute, storage, network, logs), isolates every tool's output into a
    dedicated file inside a 0700-permission directory, then packs the result
    into an ultra-compressed .tar.gz bundle and self-cleans the raw dir.

OUTPUT:
    /var/log/triage_${HOST}_<timestamp>.tar.gz

REQUIRES:
    root privileges, and (optionally) sysstat, tcpdump, iproute2, systemd.
    Missing optional tools degrade gracefully to a [ SKIPPED ] status.
EOF
}

# =============================================================================
#  MAIN
# =============================================================================

main() {
    # Argument dispatch.
    case "${1:-}" in
        -h|--help)    usage; exit 0;;
        -V|--version) printf '%s v%s\n' "${SCRIPT_NAME}" "${SCRIPT_VERSION}"; exit 0;;
        "")           ;;
        *) _fatal "Unknown argument: $1"; usage; exit 2;;
    esac

    print_banner

    preflight

    # Transient ledger dir (cleaned on exit regardless of outcome).
    STATUS_DIR="$(mktemp -d /tmp/triage_status.XXXXXX)"
    chmod 0700 "${STATUS_DIR}" 2>/dev/null || true

    # Secured output directory (0700).
    mkdir -p "${TRIAGE_ROOT}"
    chmod 0700 "${TRIAGE_ROOT}"
    _info "Triage directory: ${TRIAGE_ROOT}"

    run_all_layers
    print_dashboard
    package_archive

    if [[ "${ARCHIVE_OK}" = "1" ]]; then
        final_report
        exit 0
    else
        _fatal "Triage completed with errors; archive was NOT produced."
        exit 1
    fi
}

main "$@"
