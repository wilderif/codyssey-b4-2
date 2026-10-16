#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

[[ $# == 2 && $1 =~ ^[0-9]+$ ]] || { echo 'Usage: monitor.sh <pid> <evidence_dir>' >&2; exit 1; }
app_pid=$1
evidence_dir=$2
[[ $EUID != 0 && -d $evidence_dir && -w $evidence_dir ]] || exit 1
clock_ticks=$(getconf CLK_TCK)
expected_exe=$AGENT_HOME/agent-leak-app-arm64
start_ticks=

# A vanished or zombie process is an outcome; a live but unreadable process is an error.
read_sample() {
    local proc_stat
    if ! proc_stat=$(cat "/proc/$app_pid/stat" 2>/dev/null); then
        [[ ! -e /proc/$app_pid ]] && return 1
        return 2
    fi
    read -r -a fields <<< "${proc_stat##*) }"
    [[ ${fields[0]} != Z && ${fields[0]} != X ]] || return 1
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

snapshot() {
    {
        date --iso-8601=seconds
        ps -p "$app_pid" -o pid,ppid,pgid,user,stat,etimes,rss,comm || [[ ! -e /proc/$app_pid ]]
        ps -L -p "$app_pid" -o pid,ppid,tid,stat,wchan:32,time,comm || [[ ! -e /proc/$app_pid ]]
        top -b -n 1 -p "$app_pid"
        # Size/mtime and tail preserve whether application logs are still advancing.
        find "$AGENT_LOG_DIR" -type f -printf '%p %s %T+\n' -exec tail -n 5 {} \;
    } >> "$evidence_dir/system.log"
}

if read_sample; then
    start_ticks=${fields[19]}
else
    sample_status=$?
    [[ $sample_status == 1 ]] && exit 0
    echo '[ERROR] Cannot read process measurements.' >&2
    exit 1
fi
[[ $(readlink "/proc/$app_pid/exe") == "$expected_exe" ]] || exit 1
[[ $(stat -c %u "/proc/$app_pid") == "$EUID" ]] || exit 1
printf 'pid=%s start_ticks=%s executable=%s owner=%s\n' \
    "$app_pid" "$start_ticks" "$expected_exe" "$(id -un)" > "$evidence_dir/measured_process.txt"
[[ ! -e $evidence_dir/samples.tsv ]] || { echo '[ERROR] Samples already exist.' >&2; exit 1; }
printf 'timestamp\telapsed_s\tpid\tcpu_pct\trss_mib\n' > "$evidence_dir/samples.tsv"
baseline_uptime=$uptime
previous_uptime=$uptime
previous_ticks=$cpu_ticks
cpu_pct=NA
last_snapshot=-10
trap 'snapshot; exit 0' INT TERM

while :; do
    elapsed=$(awk -v now="$uptime" -v start="$baseline_uptime" 'BEGIN {printf "%.2f", now-start}')
    rss_mib=$(awk -v rss="$rss_kib" 'BEGIN {printf "%.2f", rss/1024}')
    printf '%s\t%s\t%s\t%s\t%s\n' "$(date --iso-8601=seconds)" \
        "$elapsed" "$app_pid" "$cpu_pct" "$rss_mib" >> "$evidence_dir/samples.tsv"
    if (( ${elapsed%.*} - last_snapshot >= 10 )); then
        snapshot
        last_snapshot=${elapsed%.*}
    fi
    # Include command overhead in the actual interval, while targeting one-second samples.
    read -r now _ < /proc/uptime
    sleep "$(awk -v now="$now" -v prior="$uptime" 'BEGIN {d=1-(now-prior); print (d>0 ? d : 0)}')"
    if read_sample; then
        cpu_pct=$(awk -v ticks="$cpu_ticks" -v prior="$previous_ticks" \
            -v now="$uptime" -v before="$previous_uptime" -v hz="$clock_ticks" \
            'BEGIN {printf "%.2f", 100*(ticks-prior)/hz/(now-before)}')
        previous_uptime=$uptime
        previous_ticks=$cpu_ticks
    else
        sample_status=$?
        [[ $sample_status == 1 ]] && break
        echo '[ERROR] Cannot read process measurements.' >&2
        exit 1
    fi
done
snapshot
