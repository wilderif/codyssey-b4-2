#!/usr/bin/env bash
# Run the six fixed cases as agent and preserve separate evidence for each run.
set -euo pipefail
export LC_ALL=C
# Keep newly created evidence readable and writable only by its owner.
umask 077

# Print the supplied error message to stderr and stop this script with status 1.
fail() {
    echo "[ERROR] $*" >&2
    exit 1
}

# Common paths come from Compose; only case-specific settings change below.
[[ $(id -un) == agent ]] || fail 'Run experiments as agent inside the container.'
: "${AGENT_HOME:?Use the Compose environment.}" "${AGENT_PORT:?}"
: "${AGENT_UPLOAD_DIR:?}" "${AGENT_KEY_PATH:?}" "${AGENT_LOG_DIR:?}"
[[ $AGENT_PORT == 15034 ]] || fail 'Use port 15034.'
app=$AGENT_HOME/agent-leak-app-arm64
key_file=$AGENT_KEY_PATH/secret.key
[[ -x $app && -f $key_file && ! -L $key_file && -r $key_file ]] || fail 'Run setup first.'
printf 'agent_api_key_test\n' | cmp -s "$key_file" - || fail 'Invalid secret.key.'
for directory in "$AGENT_UPLOAD_DIR" "$AGENT_KEY_PATH" "$AGENT_LOG_DIR" "$AGENT_HOME/evidence"; do
    [[ -d $directory && -x $directory ]] || fail "Cannot access $directory"
done
[[ -w $AGENT_LOG_DIR && -w $AGENT_HOME/evidence ]] || fail 'Log/evidence directories are not writable.'

# Use a unique session directory so repeated invocations retain earlier evidence.
session_dir=$(mktemp -d "$AGENT_HOME/evidence/$(date +%Y%m%dT%H%M%S)-XXXXXX")
echo "Evidence: $session_dir"
run_dir=
launcher_pid=
monitor_pid=

# Check launcher_pid's process group: return 0 if a live member exists, else 1.
group_alive() {
    # The launcher can exit before its worker. Ignore zombies, but include live children.
    ps -eo pgid=,stat= | awk -v group="$launcher_pid" \
        '$1 == group && $2 !~ /^[ZX]/ {found=1} END {exit !found}'
}

# Write current cgroup limits/counters and kernel messages to the caller's output.
# Mark unavailable checks explicitly; cgroup counters can include other processes.
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
    if ! dmesg 2>&1; then
        echo '[kernel diagnostics unavailable]'
    fi
}

# Take a termination reason, stop this run's monitor/group and save final evidence.
# Use the current run_dir, launcher_pid and monitor_pid; retain the app exit status.
# Return nonzero for startup/automation failure so no subsequent case is started.
finish_run() {
    local reason=$1 app_status=0 monitor_status=0 grace
    # Avoid recursive cleanup; finish the current group even if evidence writing fails.
    trap - EXIT
    trap '' INT TERM

    # Stop observation with a final live snapshot before requested app termination.
    if [[ -n $monitor_pid ]]; then
        if kill -0 "$monitor_pid" 2>/dev/null; then
            kill -TERM "$monitor_pid" || reason=automation_failure
        fi
        wait "$monitor_pid" || monitor_status=$?
    fi
    # Request TERM only for this run's group, then allow five seconds before KILL.
    if group_alive; then
        printf '%s requested SIGTERM pgid=%s\n' \
            "$(date --iso-8601=seconds)" "$launcher_pid" >> "$run_dir/cleanup.log" \
            || reason=automation_failure
        kill -TERM -- "-$launcher_pid" || reason=automation_failure
        for ((grace=0; grace<5; grace++)); do
            group_alive || break
            sleep 1
        done
        if group_alive; then
            printf '%s forced SIGKILL pgid=%s\n' \
                "$(date --iso-8601=seconds)" "$launcher_pid" >> "$run_dir/cleanup.log" \
                || reason=automation_failure
            kill -KILL -- "-$launcher_pid" || reason=automation_failure
        fi
    fi
    # A nonzero app exit is evidence, not a collection failure.
    wait "$launcher_pid" || app_status=$?
    [[ $monitor_status == 0 ]] || reason=automation_failure
    if group_alive; then
        reason=automation_failure
    fi

    # Save post-exit evidence too. A failed write stops the remaining cases.
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
    # Restore default signal handling after this run is fully recorded.
    trap - INT TERM
    [[ $reason != automation_failure && $reason != startup_failure ]]
}

# Use the six fixed assignment settings without changing other variables.
for settings in \
    'oom-before       50  100 false' \
    'oom-after       512  100 false' \
    'cpu-before      512   10 false' \
    'cpu-after       512  100 false' \
    'deadlock-before 512  100 true' \
    'deadlock-after  512  100 false'; do
    # Export this case's settings for the app; reject an occupied port before launch.
    read -r case_name MEMORY_LIMIT CPU_MAX_OCCUPY MULTI_THREAD_ENABLE <<< "$settings"
    export MEMORY_LIMIT CPU_MAX_OCCUPY MULTI_THREAD_ENABLE
    listeners=$(ss -H -ltn 'sport = :15034')
    [[ -z $listeners ]] || fail 'Port 15034 is already in use.'

    # Prepare a separate evidence directory before starting any process.
    run_dir=$session_dir/$case_name
    mkdir "$run_dir"
    start_seconds=$SECONDS
    printf '%s\n' \
        "start=$(date --iso-8601=seconds)" \
        "AGENT_HOME=$AGENT_HOME" \
        "AGENT_PORT=$AGENT_PORT" \
        "AGENT_UPLOAD_DIR=$AGENT_UPLOAD_DIR" \
        "AGENT_KEY_PATH=$AGENT_KEY_PATH" \
        "AGENT_LOG_DIR=$AGENT_LOG_DIR" \
        "MEMORY_LIMIT=$MEMORY_LIMIT" \
        "CPU_MAX_OCCUPY=$CPU_MAX_OCCUPY" \
        "MULTI_THREAD_ENABLE=$MULTI_THREAD_ENABLE" > "$run_dir/settings.txt"
    diagnostics > "$run_dir/diagnostics-before.txt"
    find "$AGENT_LOG_DIR" -type f -printf '%p %s %T+\n' > "$run_dir/logs-before.txt"

    # setsid scopes TERM/KILL to this run, including the binary's worker child.
    setsid "$app" > "$run_dir/application.out" 2>&1 &
    launcher_pid=$!
    # Unexpected exits collect failure evidence; INT/TERM retain interruption status.
    trap 'finish_run automation_failure' EXIT
    trap 'finish_run interrupted; exit 130' INT
    trap 'finish_run interrupted; exit 143' TERM
    printf 'launcher_pid=%s\n' "$launcher_pid" > "$run_dir/launcher.txt"
    echo "[$case_name] launcher=$launcher_pid"

    # Wait up to 30 seconds for the actual listener; measure its worker only.
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

    # Require the expected executable/owner, this run's group and its launcher parent.
    [[ $app_pid =~ ^[1-9][0-9]*$ ]]
    [[ $(readlink "/proc/$app_pid/exe") == "$app" ]]
    [[ $(stat -c %u "/proc/$app_pid") == "$EUID" ]]
    identity=$(ps -o ppid=,pgid= -p "$app_pid")
    read -r parent_pid process_group <<< "$identity"
    [[ $process_group == "$launcher_pid" ]]
    [[ $app_pid == "$launcher_pid" || $parent_pid == "$launcher_pid" ]]
    grep -q '0.0.0.0:15034' "$run_dir/listener.txt"
    ps -eo pid,ppid,pgid,user,stat,comm > "$run_dir/processes-start.txt"
    # Preserve the actual boot output; do not assume another app's success messages.
    cp "$run_dir/application.out" "$run_dir/boot.out"
    find "$AGENT_LOG_DIR" -type f -printf '%p %s %T+\n' > "$run_dir/logs-start.txt"

    # Observe the verified worker until app exit, collection failure or the time limit.
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
        if (( SECONDS-start_seconds >= 600 )); then
            reason=timeout
            break
        fi
        sleep 1
    done
    # A timeout is an observation limit; the saved app status is recorded separately.
    finish_run "$reason"
done

echo '[OK] Six runs recorded; assess fault reproduction from the evidence.'
