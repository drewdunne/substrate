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
    clean     Remove worktree and branch for a stopped agent

Run options:
    --repo <path>      Path to the git repository (required)
    --name <name>      Human-readable name for the task (required)
    --prompt <text>    The prompt/task for the agent (required)
    --attach           Immediately attach to the agent after starting

Clean options:
    <name>             Clean a specific agent's worktree and branch
    --all              Clean all stopped substrate worktrees/branches
    --force            Stop running container before cleaning

Examples:
    substrate run --repo ~/repos/tinyhost --name fix-tests --prompt "Fix failing tests"
    substrate attach fix-tests-a3f2
    substrate list
    substrate stop fix-tests-a3f2
    substrate clean fix-tests-a3f2
    substrate clean --all
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

    # Stage credentials for the entrypoint to copy with correct ownership
    mkdir -p "${worktree_path}/.substrate-auth"
    cp "${CLAUDE_CONFIG_DIR}/.credentials.json" "${worktree_path}/.substrate-auth/"
    cp "${CLAUDE_CONFIG_DIR}/settings.json" "${worktree_path}/.substrate-auth/" 2>/dev/null || true
    chmod -R a+r "${worktree_path}/.substrate-auth"

    # Write the run script (avoids nested quoting issues with tmux)
    local run_script
    run_script=$(mktemp /tmp/substrate-run-XXXXXX.sh)
    cat > "$run_script" <<RUNSCRIPT
#!/usr/bin/env bash
docker run -it --rm \\
    --name "${session_name}" \\
    --cpus ${DEFAULT_CPUS} \\
    --memory ${DEFAULT_MEMORY} \\
    -e HOST_UID=\$(id -u) \\
    -e HOST_GID=\$(id -g) \\
    -v "${repo}/.git:${repo}/.git" \\
    -v "${worktree_path}:/workspace" \\
    -v "${worktree_path}/.substrate-auth:/tmp/substrate-auth:ro" \\
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

cmd_clean() {
    local force=false
    local clean_all=false
    local name=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all) clean_all=true; shift ;;
            --force) force=true; shift ;;
            *) name="$1"; shift ;;
        esac
    done

    if ! $clean_all && [[ -z "$name" ]]; then
        echo "Usage: substrate clean <name> [--force]" >&2
        echo "       substrate clean --all [--force]" >&2
        exit 1
    fi

    if $clean_all; then
        # Find all substrate worktrees
        local found=false
        for worktree_path in "${SUBSTRATE_WORKTREE_BASE}"/*/; do
            [[ -d "$worktree_path" ]] || continue
            found=true
            local entry
            entry=$(basename "$worktree_path")
            _clean_one "$entry" "$force"
        done
        if ! $found; then
            echo "No substrate worktrees found."
        fi
    else
        _clean_one "$name" "$force"
    fi
}

_clean_one() {
    local name="$1"
    local force="$2"
    local session="substrate-${name}"
    local worktree_path="${SUBSTRATE_WORKTREE_BASE}/${name}"
    local branch="substrate/${name}"

    # Check if container is still running
    if [[ -n "$(docker ps --filter "name=${session}" -q 2>/dev/null)" ]]; then
        if [[ "$force" == "true" ]]; then
            echo "Force-stopping running container: ${session}"
            cmd_stop "$name"
        else
            echo "Error: Container ${session} is still running. Use --force to stop it first." >&2
            return 1
        fi
    fi

    # Detect parent repo from worktree (must happen before removing the directory)
    local parent_repo=""
    if [[ -d "$worktree_path" ]]; then
        parent_repo=$(cd "$worktree_path" && git rev-parse --show-superproject-working-tree 2>/dev/null) || true
        # Fallback: resolve git-common-dir (may be relative, so resolve from worktree)
        if [[ -z "$parent_repo" ]]; then
            local common_dir
            common_dir=$(cd "$worktree_path" && realpath "$(git rev-parse --git-common-dir)" 2>/dev/null) || true
            if [[ -n "$common_dir" ]]; then
                parent_repo=$(dirname "$common_dir")
            fi
        fi
    fi

    # Remove worktree
    if [[ -d "$worktree_path" ]]; then
        if [[ -n "$parent_repo" ]]; then
            git -C "$parent_repo" worktree remove "$worktree_path" --force 2>/dev/null \
                && echo "Worktree removed: ${worktree_path}" \
                || echo "Warning: Could not remove worktree via git, removing directory."
        fi
        # Ensure directory is gone even if git worktree remove failed
        if [[ -d "$worktree_path" ]]; then
            rm -rf "$worktree_path"
            echo "Worktree directory removed: ${worktree_path}"
        fi
        # Prune stale worktree entries after manual removal
        if [[ -n "$parent_repo" ]]; then
            git -C "$parent_repo" worktree prune 2>/dev/null
        fi
    else
        echo "Warning: Worktree not found: ${worktree_path} (already removed?)"
    fi

    # Delete branch from parent repo
    if [[ -n "$parent_repo" ]]; then
        git -C "$parent_repo" branch -D "$branch" 2>/dev/null \
            && echo "Branch deleted: ${branch}" \
            || echo "Warning: Branch not found: ${branch} (already deleted?)"
    else
        echo "Warning: Could not determine parent repo; branch ${branch} not deleted."
    fi

    echo "Cleaned: ${name}"
}

# --- Main ---

case "${1:-}" in
    run)    shift; cmd_run "$@" ;;
    attach) shift; cmd_attach "$@" ;;
    list)   cmd_list ;;
    stop)   shift; cmd_stop "$@" ;;
    clean)  shift; cmd_clean "$@" ;;
    -h|--help) usage ;;
    *)      usage ;;
esac
