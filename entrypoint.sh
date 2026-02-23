#!/usr/bin/env bash
set -euo pipefail

# Copy credentials with correct ownership
if [[ -f /tmp/substrate-auth/.credentials.json ]]; then
    cp /tmp/substrate-auth/.credentials.json /home/agent/.claude/.credentials.json
    cp /tmp/substrate-auth/settings.json /home/agent/.claude/settings.json 2>/dev/null || true
    chown -R agent:agent /home/agent/.claude
fi

# Fix workspace ownership so agent can write
chown -R agent:agent /workspace

# Drop to agent user and run Claude
exec gosu agent claude --dangerously-skip-permissions "$@"
