#!/usr/bin/env bash
set -euo pipefail

fail() {
    echo "[ERROR] $*" >&2
    exit 1
}

[[ $EUID == 0 ]] || fail 'Run setup as root inside the container.'
: "${AGENT_HOME:?Use the Compose environment.}"
: "${AGENT_UPLOAD_DIR:?}" "${AGENT_KEY_PATH:?}" "${AGENT_LOG_DIR:?}"
source_app=/workspace/agent-app-leak/agent-leak-app-arm64
app=$AGENT_HOME/agent-leak-app-arm64
key_file=$AGENT_KEY_PATH/secret.key

# Check the platform and the tools used by all three scripts.
[[ -f $source_app ]] || fail 'Missing ARM64 application.'
[[ $(uname -m) == aarch64 ]] || fail 'Use linux/arm64.'
source /etc/os-release
[[ $ID == ubuntu && $VERSION_ID == 22.04 ]] || fail 'Use Ubuntu 22.04.'
for tool in awk cmp find getconf install ldd ps readlink runuser sed setsid ss stat top useradd; do
    command -v "$tool" >/dev/null || fail "Missing tool: $tool"
done
listeners=$(ss -H -ltn 'sport = :15034')
[[ -z $listeners ]] || fail 'Port 15034 is already in use.'
dependencies=$(ldd "$source_app")
printf '%s\n' "$dependencies"
[[ $dependencies != *'not found'* ]] || fail 'Install missing runtime libraries.'

# Reject conflicting data before creating or installing anything.
if [[ -e $key_file || -L $key_file ]]; then
    [[ -f $key_file && ! -L $key_file ]] || fail 'secret.key must be a regular file.'
    printf 'agent_api_key_test\n' | cmp -s "$key_file" - || fail 'Existing secret.key differs.'
fi
if [[ -e $app || -L $app ]]; then
    [[ -f $app && ! -L $app ]] || fail 'Installed app must be a regular file.'
    cmp -s "$source_app" "$app" || fail 'Existing application differs.'
fi

# Prepare only the required account and persistent directories.
if ! id agent >/dev/null 2>&1; then
    useradd -m -u 2001 -s /bin/bash agent
fi
[[ $(id -u agent) != 0 ]] || fail 'agent must be an ordinary account.'
for directory in "$AGENT_HOME" "$AGENT_UPLOAD_DIR" "$AGENT_KEY_PATH" \
    "$AGENT_LOG_DIR" "$AGENT_HOME/evidence"; do
    install -d -o agent -g agent -m 700 "$directory"
done

if [[ ! -e $key_file ]]; then
    printf 'agent_api_key_test\n' > "$key_file"
fi
chown agent:agent "$key_file"
chmod 600 "$key_file"
# Keep an identical installed binary and its modification time on repeated setup.
if [[ ! -e $app ]]; then
    install -p -o agent -g agent -m 700 "$source_app" "$app"
fi
chown agent:agent "$app"
chmod 700 "$app"

# Check access through the account that will actually run the experiments.
runuser -u agent -- bash -euo pipefail -c '
    test -x "$AGENT_HOME/agent-leak-app-arm64"
    test -r "$AGENT_KEY_PATH/secret.key"
    printf "agent_api_key_test\n" | cmp -s "$AGENT_KEY_PATH/secret.key" -
    for directory in "$AGENT_UPLOAD_DIR" "$AGENT_KEY_PATH" "$AGENT_LOG_DIR" "$AGENT_HOME/evidence"; do
        test -d "$directory" && test -x "$directory"
    done
    probe=$(mktemp "$AGENT_LOG_DIR/.write-check.XXXXXX")
    rm "$probe"
    test -w "$AGENT_UPLOAD_DIR"
    test -w "$AGENT_HOME/evidence"
'
stat -c '%U:%G %a %n' "$app" "$key_file"
echo '[OK] Preparation complete; application startup has not been verified.'
