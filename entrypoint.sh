#!/usr/bin/env bash
set -euo pipefail

# Match container agent UID/GID to host user so bind-mounted files keep correct ownership
HOST_UID="${HOST_UID:-1000}"
HOST_GID="${HOST_GID:-1000}"
groupmod -g "$HOST_GID" -o agent 2>/dev/null
usermod -u "$HOST_UID" -o agent 2>/dev/null
chown -R agent:agent /home/agent

# Copy credentials with correct ownership
if [[ -f /tmp/substrate-auth/.credentials.json ]]; then
    cp /tmp/substrate-auth/.credentials.json /home/agent/.claude/.credentials.json
    cp /tmp/substrate-auth/settings.json /home/agent/.claude/settings.json 2>/dev/null || true
    chown -R agent:agent /home/agent/.claude
fi

# Drop to agent user and run Claude
exec gosu agent claude --dangerously-skip-permissions "$@"
