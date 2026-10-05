#!/bin/bash
# system_health.sh - Check system health and save a report to a log file.
#
# Usage:  ./system_health.sh [service ...]
# Example: ./system_health.sh sshd apache2 docker
#
# The report is printed to the terminal and appended to /var/log/system_health.log
# (sudo is used automatically if the log file is not writable).

# Force a predictable output format (decimal points, English labels).
export LC_ALL=C

LOG_FILE="/var/log/system_health.log"
DISK_THRESHOLD=80
PING_TARGET="google.com"

# Services to check: taken from the arguments, or this default list.
if [ "$#" -gt 0 ]; then
    SERVICES=("$@")
else
    SERVICES=(sshd apache2 cron)
fi

TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

# ---------- 1. System info ----------
system_info() {
    local os
    if command -v lsb_release >/dev/null 2>&1; then
        os=$(lsb_release -ds 2>/dev/null)
    elif [ -r /etc/os-release ]; then
        os=$(. /etc/os-release && echo "$PRETTY_NAME")
    else
        os=$(uname -s)
    fi

    echo "--- System Info ---"
    echo "Hostname: $(hostname)"
    echo "OS: $os"
    echo "Kernel: $(uname -r)"
    echo "Uptime: $(uptime -p 2>/dev/null | sed 's/^up //')"
}

# ---------- 2. CPU and memory ----------
cpu_memory() {
    local idle cpu_used

    # "top" prints the idle percentage; used = 100 - idle.
    # Two samples are taken because the first one is an average since boot.
    # Commas become spaces so that "ni,100.0 id" is split correctly.
    idle=$(top -bn2 -d 1 | grep 'Cpu(s)' | tail -n 1 | tr ',' ' ' |
        awk '{ for (i = 1; i <= NF; i++) if ($i == "id") print $(i - 1) }')
    cpu_used=$(awk -v idle="${idle:-0}" 'BEGIN { printf "%.0f", 100 - idle }')

    echo "--- CPU and Memory ---"
    echo "CPU Usage: ${cpu_used}%"
    echo "Memory Usage: $(free -h | awk '/^Mem:/ { print $3 " / " $2 }')"
    echo "Top 5 CPU-consuming processes:"
    ps -eo pid,user,%cpu,%mem,comm --sort=-%cpu | head -n 6 | sed 's/^/  /'
}

# ---------- 3. Disk usage ----------
disk_usage() {
    echo "--- Disk Usage ---"
    # Skip pseudo filesystems (tmpfs, snap loop images) that are not real partitions.
    df -hP -x tmpfs -x devtmpfs -x squashfs | awk -v limit="$DISK_THRESHOLD" '
        NR == 1 { next }
        {
            use = $5
            sub(/%/, "", use)
            printf "Disk: %s %s%% used (%s free, mounted on %s)\n", $1, use, $4, $6
            if (use + 0 > limit)
                printf "WARNING: %s is above %s%% usage!\n", $1, limit
        }'
}

# ---------- 4. Network ----------
network_status() {
    local ip_addr ping_result

    ip_addr=$(ip -4 addr show scope global 2>/dev/null | awk '/inet / { print $2 }' | cut -d/ -f1 | head -n 1)
    # Fallback for minimal systems where the "ip" command is missing.
    [ -z "$ip_addr" ] && ip_addr=$(hostname -I 2>/dev/null | awk '{ print $1 }')

    if ping -c 2 -W 3 "$PING_TARGET" >/dev/null 2>&1; then
        ping_result="OK (ping success)"
    else
        ping_result="FAILED (ping $PING_TARGET unreachable)"
    fi

    echo "--- Network ---"
    echo "Network: ${ip_addr:-no IP address} - $ping_result"
}

# ---------- 5. Services ----------
services_status() {
    local svc unit state summary=""

    echo "--- Services ---"
    if ! command -v systemctl >/dev/null 2>&1; then
        echo "Services: systemctl not available on this system"
        return
    fi

    for svc in "${SERVICES[@]}"; do
        unit="$svc"
        # On Debian/Ubuntu the SSH server unit is called "ssh", not "sshd".
        if [ "$svc" = "sshd" ] && ! systemctl cat sshd >/dev/null 2>&1; then
            unit="ssh"
        fi

        state=$(systemctl is-active "$unit" 2>/dev/null)
        # A unit that does not exist is also reported as "inactive".
        if [ "$state" = "inactive" ] && ! systemctl cat "$unit" >/dev/null 2>&1; then
            state="not installed"
        fi
        summary+="$svc ${state:-unknown}, "
    done
    echo "Services: ${summary%, }"
}

# ---------- Build the report ----------
generate_report() {
    echo "===== SYSTEM HEALTH REPORT ====="
    echo "Date: $(date)"
    system_info
    cpu_memory
    disk_usage
    network_status
    services_status
}

REPORT=$(generate_report)

# ---------- 6. Output and logging ----------
# Terminal: the report as is.
echo "$REPORT"

# Log file: every line is prefixed with the timestamp of this run.
LOG_ENTRY=$(echo "$REPORT" | sed "s/^/[$TIMESTAMP] /")

if [ -w "$LOG_FILE" ] || { [ ! -e "$LOG_FILE" ] && [ -w "$(dirname "$LOG_FILE")" ]; }; then
    echo "$LOG_ENTRY" >> "$LOG_FILE"
    saved=$?
else
    echo "$LOG_ENTRY" | sudo tee -a "$LOG_FILE" >/dev/null
    saved=$?
fi

if [ "$saved" -eq 0 ]; then
    echo "Report saved to $LOG_FILE"
else
    echo "ERROR: could not write to $LOG_FILE" >&2
fi
echo "================================"
