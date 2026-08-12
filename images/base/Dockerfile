# agent-devcontainer base — stack-agnostic, agent-ready devcontainer image.
# Prebuilt via `devcontainer build` (see devcontainer.json alongside), which
# also applies the docker-in-docker Feature and embeds metadata (mounts,
# onCreateCommand, containerEnv) into image labels.
# Build context is the repo root.
FROM debian:trixie-slim

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# sheldon is not packaged in Debian; pinned upstream static musl build
ARG SHELDON_VERSION=0.8.5
ARG USERNAME=vscode
ARG USER_UID=1000
ARG USER_GID=$USER_UID

ENV LANG=en_US.UTF-8

# apt baseline (rolling, no pins) + locale; trixie ships no locales by default
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl wget gnupg2 openssh-client jq procps less \
        unzip zip man-db locales sudo libstdc++6 libgcc-s1 \
        zsh git git-lfs python3 python3-venv fzf zoxide starship nano \
    && echo 'en_US.UTF-8 UTF-8' >> /etc/locale.gen \
    && locale-gen \
    && rm -rf /var/lib/apt/lists/*

# gh from GitHub's official apt repo — trixie's own package is over a year stale
RUN install -d -m 755 /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# sheldon static musl binary, both arches
RUN arch="$(dpkg --print-architecture)" \
    && case "$arch" in \
        amd64) triple="x86_64-unknown-linux-musl" ;; \
        arm64) triple="aarch64-unknown-linux-musl" ;; \
        *) echo "unsupported architecture: $arch" >&2; exit 1 ;; \
    esac \
    && curl -fsSL "https://github.com/rossmacarthur/sheldon/releases/download/${SHELDON_VERSION}/sheldon-${SHELDON_VERSION}-${triple}.tar.gz" \
        | tar -xz -C /usr/local/bin sheldon

# non-root user: UID/GID 1000, zsh login shell, passwordless sudo
# (VS Code's updateRemoteUserUID remaps UID/GID at container start)
RUN groupadd --gid "$USER_GID" "$USERNAME" \
    && useradd --uid "$USER_UID" --gid "$USER_GID" -m -s /usr/bin/zsh "$USERNAME" \
    && echo "$USERNAME ALL=(root) NOPASSWD:ALL" > "/etc/sudoers.d/$USERNAME" \
    && chmod 0440 "/etc/sudoers.d/$USERNAME"

# pre-create volume mount points and XDG dirs with vscode ownership:
# ~/.local/state/history seeds the shared command-history volume;
# the claude/gh dirs are mount points for the shared auth volumes
RUN install -d -o "$USER_UID" -g "$USER_GID" \
        "/home/$USERNAME/.config" \
        "/home/$USERNAME/.config/sheldon" \
        "/home/$USERNAME/.config/gh" \
        "/home/$USERNAME/.local" \
        "/home/$USERNAME/.local/state" \
        "/home/$USERNAME/.local/state/history" \
        "/home/$USERNAME/.local/state/history/zoxide" \
        "/home/$USERNAME/.local/share" \
        "/home/$USERNAME/.local/share/claude" \
        "/home/$USERNAME/.local/bin" \
        "/home/$USERNAME/.claude"

# vendored dotfiles straight into home at XDG defaults — runtime volume mounts
# only cover subdirs of home, so these are never shadowed
COPY --chown=$USER_UID:$USER_GID dotfiles/zshrc /home/$USERNAME/.zshrc
COPY --chown=$USER_UID:$USER_GID dotfiles/sheldon/plugins.toml /home/$USERNAME/.config/sheldon/plugins.toml
COPY --chown=$USER_UID:$USER_GID dotfiles/starship.toml /home/$USERNAME/.config/starship.toml

# Claude Code first-run bootstrap (wired as onCreateCommand in devcontainer.json)
COPY images/base/claude-bootstrap.sh /usr/local/share/agent-devcontainer/claude-bootstrap.sh
RUN chmod 755 /usr/local/share/agent-devcontainer/claude-bootstrap.sh

# prefetch sheldon plugins so the first shell opens instantly
USER $USERNAME
RUN HOME="/home/$USERNAME" sheldon lock

# login shells must not clobber the image PATH (common-utils parity shim)
USER root
RUN echo "export PATH=${PATH//$/\\$}" > /etc/profile.d/00-restore-env.sh \
    && chmod +x /etc/profile.d/00-restore-env.sh

USER $USERNAME
