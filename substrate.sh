#!/usr/bin/env bash
set -euo pipefail

# --- Configuration ---
SUBSTRATE_IMAGE="substrate:latest"
SUBSTRATE_WORKTREE_BASE="/tmp/substrate"
CLAUDE_CONFIG_DIR="${HOME}/.claude"
DEFAULT_CPUS="2"
DEFAULT_MEMORY="4g"

# --- Helpers ---

usage() {
    cat <<EOF
substrate - Container runtime for Claude Code agents

Usage: substrate <command> [options]

Commands:
    run       Start an agent in a container
    attach    Attach to a running agent session
    list      List running agents
    stop      Stop a running agent and clean up

Run options:
    --repo <path>      Path to the git repository (required)
    --name <name>      Human-readable name for the task (required)
    --prompt <text>    The prompt/task for the agent (required)
    --attach           Immediately attach to the agent after starting

Examples:
    substrate run --repo ~/repos/tinyhost --name fix-tests --prompt "Fix failing tests"
    substrate attach fix-tests-a3f2
    substrate list
    substrate stop fix-tests-a3f2
EOF
}

generate_id() {
    head -c 2 /dev/urandom | xxd -p
}

# --- Commands ---

cmd_run() {
    local repo="" name="" prompt="" do_attach=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repo) repo="$2"; shift 2 ;;
            --name) name="$2"; shift 2 ;;
            --prompt) prompt="$2"; shift 2 ;;
            --attach) do_attach=true; shift ;;
            *) echo "Error: Unknown option: $1" >&2; exit 1 ;;
        esac
    done

    # Validate required args
    if [[ -z "$repo" ]]; then echo "Error: --repo is required" >&2; exit 1; fi
    if [[ -z "$name" ]]; then echo "Error: --name is required" >&2; exit 1; fi
    if [[ -z "$prompt" ]]; then echo "Error: --prompt is required" >&2; exit 1; fi

    # Validate repo exists and is a git repo
    if [[ ! -d "$repo/.git" ]]; then
        echo "Error: $repo is not a git repository" >&2; exit 1
    fi

    # Resolve to absolute path
    repo=$(cd "$repo" && pwd)

    # Validate credentials exist
    if [[ ! -f "$CLAUDE_CONFIG_DIR/.credentials.json" ]]; then
        echo "Error: Claude credentials not found at $CLAUDE_CONFIG_DIR/.credentials.json" >&2; exit 1
    fi

    local id
    id=$(generate_id)
    local full_name="${name}-${id}"
    local session_name="substrate-${full_name}"
    local branch="substrate/${full_name}"
    local worktree_path="${SUBSTRATE_WORKTREE_BASE}/${full_name}"

    # Create worktree base directory
    mkdir -p "${SUBSTRATE_WORKTREE_BASE}"

    # Create git worktree on new branch
    echo "Creating worktree: ${worktree_path} (branch: ${branch})"
    git -C "$repo" worktree add "$worktree_path" -b "$branch"

    # Write prompt to file in worktree (avoids shell escaping hell)
    echo "$prompt" > "${worktree_path}/.substrate-prompt"

    # Write the run script (avoids nested quoting issues with tmux)
    local run_script
    run_script=$(mktemp /tmp/substrate-run-XXXXXX.sh)
    cat > "$run_script" <<RUNSCRIPT
#!/usr/bin/env bash
docker run -it --rm \\
    --name "${session_name}" \\
    --cpus ${DEFAULT_CPUS} \\
    --memory ${DEFAULT_MEMORY} \\
    -v "${worktree_path}:/home/agent/workspace" \\
    -v "${CLAUDE_CONFIG_DIR}:/home/agent/.claude:ro" \\
    ${SUBSTRATE_IMAGE} \\
    -p "\$(cat ${worktree_path}/.substrate-prompt)"

echo ""
echo "=== Agent finished. Press enter to close. ==="
read -r
rm -f "${run_script}"
RUNSCRIPT
    chmod +x "$run_script"

    # Start container wrapped in tmux session
    tmux new-session -d -s "$session_name" "$run_script"

    echo ""
    echo "Agent started:"
    echo "  Session:  ${session_name}"
    echo "  Branch:   ${branch}"
    echo "  Worktree: ${worktree_path}"
    echo "  Attach:   substrate attach ${full_name}"

    if $do_attach; then
        tmux attach -t "$session_name"
    fi
}

cmd_attach() {
    if [[ -z "${1:-}" ]]; then
        echo "Usage: substrate attach <name>" >&2; exit 1
    fi
    local target="substrate-${1}"
    if ! tmux has-session -t "$target" 2>/dev/null; then
        echo "Error: No session found: ${target}" >&2
        echo "Run 'substrate list' to see active agents." >&2
        exit 1
    fi
    tmux attach -t "$target"
}

cmd_list() {
    echo "Active agents:"
    tmux ls 2>/dev/null | grep "^substrate-" | sed 's/^substrate-/  /' || echo "  (none)"
}

cmd_stop() {
    if [[ -z "${1:-}" ]]; then
        echo "Usage: substrate stop <name>" >&2; exit 1
    fi
    local name="$1"
    local session="substrate-${name}"

    # Stop container
    docker stop "$session" 2>/dev/null && echo "Container stopped." || echo "No container found (may have already exited)."

    # Kill tmux session
    tmux kill-session -t "$session" 2>/dev/null && echo "Session closed." || echo "No session found."

    echo "Stopped: ${name}"
}

# --- Main ---

case "${1:-}" in
    run)    shift; cmd_run "$@" ;;
    attach) shift; cmd_attach "$@" ;;
    list)   cmd_list ;;
    stop)   shift; cmd_stop "$@" ;;
    -h|--help) usage ;;
    *)      usage ;;
esac
