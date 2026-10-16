#!/usr/bin/env bash
set -eEuo pipefail
export LC_ALL=C
umask 077

fail() { echo "[ERROR] $*" >&2; exit 1; }
[[ $(id -un) == agent ]] || fail 'Run experiments as agent inside the container.'
export AGENT_HOME=/home/agent/agent-leak-app
export AGENT_PORT=15034
export AGENT_UPLOAD_DIR=$AGENT_HOME/upload_files
export AGENT_KEY_PATH=$AGENT_HOME/api_keys
export AGENT_LOG_DIR=$AGENT_HOME/logs
app=$AGENT_HOME/agent-leak-app-arm64
for tool in awk cat cp date find getconf mktemp ps readlink setsid ss stat top; do
    command -v "$tool" >/dev/null || fail "Missing tool: $tool"
done
[[ -x $app && -r $AGENT_KEY_PATH/secret.key ]] || fail 'Run setup first.'
printf 'agent_api_key_test\n' | cmp -s "$AGENT_KEY_PATH/secret.key" - || fail 'Invalid fixture.'
for directory in "$AGENT_UPLOAD_DIR" "$AGENT_KEY_PATH" "$AGENT_LOG_DIR" "$AGENT_HOME/evidence"; do
    [[ -d $directory && -x $directory ]] || fail "Cannot access $directory"
done
[[ -w $AGENT_LOG_DIR && -w $AGENT_HOME/evidence ]] || fail 'Log/evidence directories are not writable.'
session_dir=$(mktemp -d "$AGENT_HOME/evidence/$(date +%Y%m%dT%H%M%S)-XXXXXX")
echo "Evidence: $session_dir"
run_dir=
launcher_pid=
monitor_pid=

group_alive() {
    ps -eo pgid=,stat= | awk -v group="$launcher_pid" \
        '$1 == group && $2 !~ /^[ZX]/ {found=1} END {exit !found}'
}

diagnostics() {
    date --iso-8601=seconds
    cat /proc/self/cgroup
    for name in memory.events memory.max memory.peak cpu.max cpu.stat pids.max; do
        if [[ -r /sys/fs/cgroup/$name ]]; then
            echo "[$name]"
            cat "/sys/fs/cgroup/$name"
        else
            echo "[$name unavailable]"
        fi
    done
    if ! dmesg 2>&1; then echo '[kernel diagnostics unavailable]'; fi
}

finish_run() {
    local reason=$1 app_status=0 monitor_status=0
    trap - ERR INT TERM
    set +e
    # Stop observation with a final live snapshot before requested app termination.
    if [[ -n $monitor_pid ]]; then
        kill -TERM "$monitor_pid" 2>/dev/null
        wait "$monitor_pid"
        monitor_status=$?
    fi
    if group_alive; then
        printf '%s requested SIGTERM pgid=%s\n' "$(date --iso-8601=seconds)" "$launcher_pid" >> "$run_dir/cleanup.log"
        kill -TERM -- "-$launcher_pid" || reason=automation_failure
        for ((grace=0; grace<5; grace++)); do
            group_alive || break
            sleep 1
        done
        if group_alive; then
            printf '%s forced SIGKILL pgid=%s\n' "$(date --iso-8601=seconds)" "$launcher_pid" >> "$run_dir/cleanup.log"
            kill -KILL -- "-$launcher_pid" || reason=automation_failure
        fi
    fi
    wait "$launcher_pid"
    app_status=$?
    # All remaining writes are checked even after an earlier collection failure.
    set -e
    [[ $monitor_status == 0 ]] || reason=automation_failure
    if group_alive; then reason=automation_failure; fi
    diagnostics > "$run_dir/diagnostics-after.txt"
    ps -eo pid,ppid,pgid,user,stat,comm > "$run_dir/processes-after.txt"
    ss -ltnp 'sport = :15034' > "$run_dir/listener-after.txt"
    cp -a "$AGENT_LOG_DIR" "$run_dir/application-logs"
    printf 'end=%s\nelapsed_s=%s\nreason=%s\nlauncher_exit=%s\nmonitor_exit=%s\n' \
        "$(date --iso-8601=seconds)" "$((SECONDS-start_seconds))" "$reason" \
        "$app_status" "$monitor_status" > "$run_dir/result.txt"
    echo "[$case_name] $reason; exit=$app_status; elapsed=$((SECONDS-start_seconds))s"
    launcher_pid=
    monitor_pid=
    [[ $reason != automation_failure && $reason != startup_failure ]]
}

for settings in 'oom-before 50 100 false' 'oom-after 512 100 false' \
    'cpu-before 512 10 false' 'cpu-after 512 100 false' \
    'deadlock-before 512 100 true' 'deadlock-after 512 100 false'; do
    read -r case_name MEMORY_LIMIT CPU_MAX_OCCUPY MULTI_THREAD_ENABLE <<< "$settings"
    [[ $MEMORY_LIMIT =~ ^[0-9]+$ && $MEMORY_LIMIT -ge 50 && $MEMORY_LIMIT -le 512 ]] || fail 'Invalid MEMORY_LIMIT.'
    [[ $CPU_MAX_OCCUPY =~ ^[0-9]+$ && $CPU_MAX_OCCUPY -ge 10 && $CPU_MAX_OCCUPY -le 100 ]] || fail 'Invalid CPU_MAX_OCCUPY.'
    [[ $MULTI_THREAD_ENABLE == true || $MULTI_THREAD_ENABLE == false ]] || fail 'Invalid MULTI_THREAD_ENABLE.'
    export MEMORY_LIMIT CPU_MAX_OCCUPY MULTI_THREAD_ENABLE
    [[ -z $(ss -H -ltn 'sport = :15034') ]] || fail 'Port 15034 is already in use.'
    run_dir=$session_dir/$case_name
    mkdir "$run_dir"
    start_seconds=$SECONDS
    printf 'start=%s\nAGENT_HOME=%s\nAGENT_PORT=%s\nAGENT_UPLOAD_DIR=%s\nAGENT_KEY_PATH=%s\nAGENT_LOG_DIR=%s\nMEMORY_LIMIT=%s\nCPU_MAX_OCCUPY=%s\nMULTI_THREAD_ENABLE=%s\n' \
        "$(date --iso-8601=seconds)" "$AGENT_HOME" "$AGENT_PORT" "$AGENT_UPLOAD_DIR" \
        "$AGENT_KEY_PATH" "$AGENT_LOG_DIR" "$MEMORY_LIMIT" "$CPU_MAX_OCCUPY" "$MULTI_THREAD_ENABLE" > "$run_dir/settings.txt"
    diagnostics > "$run_dir/diagnostics-before.txt"
    find "$AGENT_LOG_DIR" -type f -printf '%p %s %T+\n' > "$run_dir/logs-before.txt"
    setsid "$app" > "$run_dir/application.out" 2>&1 &
    launcher_pid=$!
    printf 'launcher_pid=%s\n' "$launcher_pid" > "$run_dir/launcher.txt"
    trap 'finish_run automation_failure; exit 1' ERR
    trap 'finish_run interrupted; exit 130' INT
    trap 'finish_run interrupted; exit 143' TERM
    echo "[$case_name] launcher=$launcher_pid"
    app_pid=
    while group_alive && (( SECONDS-start_seconds < 30 )); do
        ss -H -ltnp 'sport = :15034' > "$run_dir/listener.txt"
        app_pid=$(sed -n 's/.*pid=\([0-9]*\).*/\1/p' "$run_dir/listener.txt")
        [[ -z $app_pid ]] || break
        sleep 1
    done
    if [[ -z $app_pid ]]; then
        finish_run startup_failure
        exit 1
    fi
    [[ $(readlink "/proc/$app_pid/exe") == "$app" ]]
    [[ $(stat -c %u "/proc/$app_pid") == "$EUID" ]]
    [[ $(ps -o pgid= -p "$app_pid" | tr -d ' ') == "$launcher_pid" ]]
    grep -q '0.0.0.0:15034' "$run_dir/listener.txt"
    ps -eo pid,ppid,pgid,user,stat,comm > "$run_dir/processes-start.txt"
    # Preserve the actual boot output; do not assume another app's success messages.
    cp "$run_dir/application.out" "$run_dir/boot.out"
    find "$AGENT_LOG_DIR" -type f -printf '%p %s %T+\n' > "$run_dir/logs-start.txt"
    bash /workspace/scripts/monitor.sh "$app_pid" "$run_dir" > "$run_dir/monitor.out" 2>&1 &
    monitor_pid=$!
    reason=app_exit
    while group_alive; do
        if ! kill -0 "$monitor_pid" 2>/dev/null; then
            # A worker may exit a moment before its launcher exits.
            if [[ -r /proc/$app_pid/stat ]] && [[ $(ps -o stat= -p "$app_pid") != Z* ]]; then
                reason=automation_failure
                break
            fi
        fi
        if (( SECONDS-start_seconds >= 600 )); then reason=timeout; break; fi
        sleep 1
    done
    finish_run "$reason"
done
echo '[OK] Six runs recorded; assess fault reproduction from the evidence.'
