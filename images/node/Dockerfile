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
