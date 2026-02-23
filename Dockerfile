FROM node:22-bookworm

# System dependencies (including gosu for entrypoint user switching)
RUN apt-get update && apt-get install -y \
    git \
    curl \
    jq \
    gosu \
    && rm -rf /var/lib/apt/lists/*

# Install pnpm via corepack
RUN corepack enable && corepack prepare pnpm@9 --activate

# Create non-root agent user
RUN useradd -m -s /bin/bash agent

# Install Claude CLI as agent
USER agent
WORKDIR /home/agent
RUN curl -fsSL https://claude.ai/install.sh | bash

# Git config for commits
RUN git config --global user.name "Substrate Agent" && \
    git config --global user.email "substrate@sunny"

# Pre-create .claude directory
RUN mkdir -p /home/agent/.claude

# Back to root for entrypoint (it drops to agent after setup)
USER root

# Add claude to PATH for all users
ENV PATH="/home/agent/.local/bin:${PATH}"

# Entrypoint runs as root, fixes permissions, then execs as agent
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

WORKDIR /workspace

ENTRYPOINT ["/entrypoint.sh"]
