#!/usr/bin/env bash
set -euo pipefail

agent_home=/home/agent/agent-leak-app
source_app=/workspace/agent-app-leak/agent-leak-app-arm64
key_file=$agent_home/api_keys/secret.key

fail() {
    echo "[ERROR] $*" >&2
    exit 1
}

[[ $EUID == 0 ]] || fail 'Run setup as root inside the container.'
[[ -f $source_app ]] || fail 'Missing ARM64 application.'
[[ $(uname -m) == aarch64 ]] || fail 'Use linux/arm64.'
source /etc/os-release
[[ $ID == ubuntu && $VERSION_ID == 22.04 ]] || fail 'Use Ubuntu 22.04.'
for tool in awk cmp getconf install ldd ps readlink runuser setsid ss top useradd; do
    command -v "$tool" >/dev/null || fail "Missing tool: $tool"
done
[[ -z $(ss -H -ltn 'sport = :15034') ]] || fail 'Port 15034 is already in use.'
dependencies=$(ldd "$source_app")
printf '%s\n' "$dependencies"
[[ $dependencies != *'not found'* ]] || fail 'Install missing runtime libraries.'

# Reject conflicting data before creating or installing anything.
if [[ -e $key_file || -L $key_file ]]; then
    [[ -f $key_file && ! -L $key_file ]] || fail 'secret.key must be a regular file.'
    printf 'agent_api_key_test\n' | cmp -s "$key_file" - || fail 'Existing secret.key differs.'
fi
if ! id agent >/dev/null 2>&1; then
    useradd -m -u 2001 -s /bin/bash agent
fi
[[ $(id -u agent) != 0 ]] || fail 'agent must be an ordinary account.'
for directory in "$agent_home" "$agent_home/upload_files" "$agent_home/api_keys" \
    "$agent_home/logs" "$agent_home/evidence"; do
    install -d -o agent -g agent -m 700 "$directory"
done
if [[ ! -e $key_file ]]; then
    printf 'agent_api_key_test\n' > "$key_file"
fi
chown agent:agent "$key_file"
chmod 600 "$key_file"
install -o agent -g agent -m 700 "$source_app" "$agent_home/agent-leak-app-arm64"
cmp "$source_app" "$agent_home/agent-leak-app-arm64"

# Check access through the account that will actually run the experiments.
runuser -u agent -- bash -eu -c '
    test -x "$AGENT_HOME/agent-leak-app-arm64"
    test -r "$AGENT_KEY_PATH/secret.key"
    printf "agent_api_key_test\n" | cmp -s "$AGENT_KEY_PATH/secret.key" -
    for directory in "$AGENT_UPLOAD_DIR" "$AGENT_KEY_PATH" "$AGENT_LOG_DIR" "$AGENT_HOME/evidence"; do
        test -d "$directory" && test -x "$directory"
    done
    probe=$(mktemp "$AGENT_LOG_DIR/.write-check.XXXXXX")
    rm "$probe"
    test -w "$AGENT_UPLOAD_DIR" && test -w "$AGENT_HOME/evidence"
'
stat -c '%U:%G %a %n' "$agent_home/agent-leak-app-arm64" "$key_file"
echo '[OK] Preparation complete; application startup has not been verified.'
