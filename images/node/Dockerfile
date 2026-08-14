# agent-devcontainer node — base image + NVM-managed Node LTS.
# Globals are NVM-native (per Node version); no NPM_CONFIG_PREFIX, which
# conflicts with NVM. Switching Node versions means re-running
# `npm i -g @antfu/ni` — ni is the only shipped global.
ARG BASE_IMAGE=ghcr.io/dbarjs/agent-devcontainer/base:latest
FROM ${BASE_IMAGE}

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG NVM_VERSION=v0.40.6
ENV NVM_DIR=/home/vscode/.nvm

USER vscode
# PROFILE=/dev/null keeps the installer from appending to the vendored
# ~/.zshrc, which already sources nvm.sh when present
RUN mkdir -p "$NVM_DIR" \
    && curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" \
        | PROFILE=/dev/null bash \
    && source "$NVM_DIR/nvm.sh" \
    && nvm install --lts \
    && nvm alias default 'lts/*' \
    && corepack enable \
    && npm install -g @antfu/ni \
    && nvm cache clear

# Shared pnpm store: the workspace is usually a bind mount on another
# filesystem, so pnpm's same-disk store default would drop .pnpm-store into
# the project root. Point the store at the pnpm-store volume instead (across
# filesystems pnpm copies rather than hard-links — the price of one shared,
# persistent store). Written as files, not npm_config_* env, which npm warns
# on; both dialects because pnpm <=9 reads the ini rc, pnpm >=10 config.yaml.
RUN store=/home/vscode/.local/share/pnpm-store \
    && mkdir -p "$store" /home/vscode/.config/pnpm \
    && printf 'store-dir=%s\n' "$store" > /home/vscode/.config/pnpm/rc \
    && printf 'storeDir: %s\n' "$store" > /home/vscode/.config/pnpm/config.yaml

# append the Node section to the base image's environment brief (ADR-0010);
# managed CLAUDE.md has no drop-in directory, so variants extend the same file
USER root
COPY environment-brief.node.md /tmp/environment-brief.node.md
RUN { echo; cat /tmp/environment-brief.node.md; } >> /etc/claude-code/CLAUDE.md \
    && rm /tmp/environment-brief.node.md
USER vscode
