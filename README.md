# Substrate

A shell-script container runtime that dispatches [Claude Code](https://docs.anthropic.com/en/docs/claude-code) agents into sandboxed Docker containers. Give it a repo and a task, and it handles the rest.

## The Problem

Claude Code is powerful, but running it with full permissions (`--dangerously-skip-permissions`) on your host machine is exactly what it sounds like. You also can't easily run multiple agents in parallel against the same repo without them stepping on each other's files.

## The Solution

Substrate wraps each agent invocation in three layers of isolation:

- **Docker container** -- the agent runs inside a sandboxed container with capped CPU and memory, so it can't touch your host filesystem or run away with resources.
- **Git worktree** -- each agent gets its own copy of your repo on a dedicated branch. Multiple agents can work on the same codebase simultaneously without conflicts.
- **tmux session** -- each container runs inside a tmux session, so you can attach to watch the agent work in real time, or let it run in the background.

## How It Works

When you run `substrate run`, here's what happens:

1. **Creates a git worktree** at `/tmp/substrate/<name>-<id>` on a new branch forked from your repo's HEAD. This is a lightweight copy -- it shares git history with your repo but has its own working directory.

2. **Stages your Claude credentials** by copying `~/.claude/.credentials.json` into the worktree. Claude CLI's credentials file has strict permissions (owner-only), so we copy it and loosen read permissions so the container can access it.

3. **Writes your prompt to a file** in the worktree (`.substrate-prompt`). This avoids shell escaping issues that come with passing complex prompts through Docker, tmux, and bash.

4. **Launches a Docker container** with:
   - Your worktree mounted at `/workspace`
   - Credentials mounted read-only at `/tmp/substrate-auth`
   - CPU and memory limits (default: 2 CPUs, 4GB RAM)

5. **The container's entrypoint** (running as root) copies credentials into the agent user's home directory with correct ownership, fixes workspace permissions, then drops to a non-root `agent` user via `gosu` before launching Claude CLI. This dance is necessary because Claude CLI refuses to run as root, but Docker volume mounts inherit host file ownership which won't match the container's user.

6. **Claude CLI starts** with `--dangerously-skip-permissions` and your prompt. It reads, writes, runs commands, and commits -- all inside the container against the worktree branch.

7. **When the agent finishes**, its commits live on the worktree branch. You can review them, merge them, or throw them away.

## Prerequisites

- **Docker** -- install from [docker.com](https://docs.docker.com/get-docker/)
- **tmux** -- `sudo apt install tmux` (Debian/Ubuntu) or `brew install tmux` (macOS)
- **git** -- you almost certainly have this already
- **Claude Code** -- must be installed and logged in on the host (`claude` command should work)

## Installation

Clone the repo and build the Docker image:

```bash
git clone https://github.com/drewdunne/substrate.git ~/repos/substrate
cd ~/repos/substrate
docker build -t substrate:latest .
```

Add `substrate` to your PATH:

```bash
ln -sf ~/repos/substrate/substrate.sh ~/.local/bin/substrate
```

Make sure `~/.local/bin` is in your PATH. If `which substrate` doesn't return anything, add this to your `~/.bashrc` or `~/.zshrc`:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

## Usage

### Start an agent

```bash
substrate run \
    --repo ~/repos/my-project \
    --name fix-tests \
    --prompt "Fix the failing unit tests in src/api/"
```

### Watch it work

```bash
substrate attach fix-tests-a3f2
```

Detach with `Ctrl+B` then `D` (standard tmux).

### List running agents

```bash
substrate list
```

### Stop an agent

```bash
substrate stop fix-tests-a3f2
```

### Review the agent's work

After the agent finishes, its commits are on a branch in your repo:

```bash
cd ~/repos/my-project
git log substrate/fix-tests-a3f2 --oneline
git diff main..substrate/fix-tests-a3f2
```

### Clean up

Remove the worktree and branch when you're done:

```bash
git worktree remove /tmp/substrate/fix-tests-a3f2
git branch -D substrate/fix-tests-a3f2
```
