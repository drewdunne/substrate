FROM node:22-bookworm

# System dependencies
RUN apt-get update && apt-get install -y \
    git \
    curl \
    jq \
    && rm -rf /var/lib/apt/lists/*

# Install pnpm via corepack
RUN corepack enable && corepack prepare pnpm@9 --activate

# Create non-root agent user
RUN useradd -m -s /bin/bash agent

# Switch to agent for Claude CLI install
USER agent
WORKDIR /home/agent

# Install Claude CLI via official installer
RUN curl -fsSL https://claude.ai/install.sh | bash

# Git config for commits
RUN git config --global user.name "Substrate Agent" && \
    git config --global user.email "substrate@sunny"

# Pre-create .claude directory for credential mount
RUN mkdir -p /home/agent/.claude

# Add claude to PATH
ENV PATH="/home/agent/.local/bin:${PATH}"

# Workspace is mounted at runtime
WORKDIR /home/agent/workspace

ENTRYPOINT ["claude", "--dangerously-skip-permissions"]
