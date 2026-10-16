#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

fail() {
    echo "[ERROR] $*" >&2
    exit 1
}

[[ $# == 2 && $1 =~ ^[1-9][0-9]*$ ]] || fail 'Usage: monitor.sh <pid> <evidence_dir>'
app_pid=$1
evidence_dir=$2
[[ $(id -un) == agent ]] || fail 'Run the monitor as agent inside the container.'
[[ -d $evidence_dir && -w $evidence_dir ]] || fail 'Evidence directory is not writable.'
[[ ! -e $evidence_dir/samples.tsv ]] || fail 'Samples already exist.'
clock_ticks=$(getconf CLK_TCK)
expected_exe=$AGENT_HOME/agent-leak-app-arm64
start_ticks=

# Return 1 for process exit, 2 for an unreadable or replaced process.
read_sample() {
    local proc_stat
    if ! proc_stat=$(cat "/proc/$app_pid/stat" 2>/dev/null); then
        [[ ! -e /proc/$app_pid ]] && return 1
        return 2
    fi
    # Remove pid/comm, including spaces in comm. The array starts at stat field 3.
    read -r -a fields <<< "${proc_stat##*) }"
    [[ ${fields[0]} != Z && ${fields[0]} != X ]] || return 1
    # Field 22 (starttime) detects PID reuse; fields 14/15 are utime/stime.
    [[ -z $start_ticks || ${fields[19]} == "$start_ticks" ]] || return 2
    cpu_ticks=$((fields[11] + fields[12]))
    if ! rss_kib=$(awk '/^VmRSS:/ {print $2}' "/proc/$app_pid/status" 2>/dev/null); then
        [[ ! -e /proc/$app_pid ]] && return 1
        return 2
    fi
    # Exit can remove VmRSS between reading stat and status.
    if [[ -z $rss_kib ]]; then
        [[ ! -e /proc/$app_pid/stat ]] && return 1
        read -r proc_stat < "/proc/$app_pid/stat" || return 1
        [[ $proc_stat == *') Z '* || $proc_stat == *') X '* ]] && return 1
        return 2
    fi
    read -r uptime _ < /proc/uptime
}

# Keep auxiliary process/thread evidence and the last application log lines.
snapshot() {
    {
        date --iso-8601=seconds
        ps -p "$app_pid" -o pid,ppid,pgid,user,stat,etimes,rss,comm || [[ ! -e /proc/$app_pid ]]
        ps -L -p "$app_pid" -o pid,ppid,tid,stat,wchan:32,time,comm || [[ ! -e /proc/$app_pid ]]
        top -b -n 1 -p "$app_pid"
        # Size/mtime and tail preserve whether application logs are still advancing.
        find "$AGENT_LOG_DIR" -type f -printf '%p %s %T+\n' -exec tail -n 5 {} +
    } >> "$evidence_dir/system.log"
}

if read_sample; then
    start_ticks=${fields[19]}
else
    sample_status=$?
    [[ $sample_status == 1 ]] && exit 0
    fail 'Cannot read process measurements.'
fi
[[ $(readlink "/proc/$app_pid/exe") == "$expected_exe" ]] || fail 'Unexpected executable.'
[[ $(stat -c %u "/proc/$app_pid") == "$EUID" ]] || fail 'Unexpected process owner.'
printf 'pid=%s start_ticks=%s executable=%s owner=%s\n' \
    "$app_pid" "$start_ticks" "$expected_exe" "$(id -un)" > "$evidence_dir/measured_process.txt"
printf 'timestamp\telapsed_s\tpid\tcpu_pct\trss_mib\n' > "$evidence_dir/samples.tsv"

# The first sample has no preceding interval, so its CPU value is NA.
baseline_uptime=$uptime
previous_uptime=$uptime
previous_ticks=$cpu_ticks
cpu_pct=NA
last_snapshot=-10
trap 'snapshot; exit 0' INT TERM

while :; do
    elapsed=$(awk -v now="$uptime" -v start="$baseline_uptime" \
        'BEGIN {printf "%.2f", now-start}')
    rss_mib=$(awk -v rss="$rss_kib" 'BEGIN {printf "%.2f", rss/1024}')
    printf '%s\t%s\t%s\t%s\t%s\n' "$(date --iso-8601=seconds)" \
        "$elapsed" "$app_pid" "$cpu_pct" "$rss_mib" >> "$evidence_dir/samples.tsv"
    if (( ${elapsed%.*} - last_snapshot >= 10 )); then
        snapshot
        last_snapshot=${elapsed%.*}
    fi

    # Include command overhead in the actual interval, while targeting one-second samples.
    read -r now _ < /proc/uptime
    delay=$(awk -v now="$now" -v prior="$uptime" \
        'BEGIN {remaining=1-(now-prior); print (remaining>0 ? remaining : 0)}')
    sleep "$delay"

    if read_sample; then
        cpu_pct=$(awk -v ticks="$cpu_ticks" -v prior="$previous_ticks" \
            -v now="$uptime" -v before="$previous_uptime" -v hz="$clock_ticks" \
            'BEGIN {printf "%.2f", 100*(ticks-prior)/hz/(now-before)}')
        previous_uptime=$uptime
        previous_ticks=$cpu_ticks
    else
        sample_status=$?
        [[ $sample_status == 1 ]] && break
        fail 'Cannot read process measurements.'
    fi
done
snapshot
