# Agent Devcontainer

Prebuilt, agent-ready devcontainer images and a per-project template so any dbarjs repo opens in VS Code with a Mac-matching zsh terminal, authenticated Claude Code + gh, and YOLO agents that can spawn containers.

## Language

**Base image**:
The stack-agnostic prebuilt image (`debian:trixie` + terminal, git, Python, gh, Claude Code bootstrap, docker capability) that every variant layers on.
_Avoid_: Common image, root image

**Node image**:
The variant layered on the base image that adds NVM, a default Node LTS, and `ni`.
_Avoid_: JS image, node variant

**Prebuild**:
Building an image ahead of time with the devcontainer CLI so Feature metadata embeds in its labels and consuming projects inherit the wiring.
_Avoid_: Bake (reserved for file contents), image build

**Template**:
The tiny per-project `.devcontainer` folder that references a prebuilt image by tag.
_Avoid_: Boilerplate, starter

**Vendored dotfiles**:
The container-adapted rc files (zshrc, sheldon plugins.toml, starship.toml) kept in this repo and baked into the image's home directory at build.
_Avoid_: Dotfiles repo (that's the identity repo's old world)

**First-run bootstrap**:
An image-shipped script that installs a tool onto a shared volume only when that volume is empty — how Claude Code arrives.
_Avoid_: Seed install, postCreate install

**Shared volume**:
A named Docker volume mounted into every container at the same home subpath so state (auth, the Claude Code install, shell history) is written once and shared everywhere.
_Avoid_: Cache volume, persistent mount

**Command-history volume**:
The shared volume holding zsh history and the zoxide database, so one shell history spans all projects and survives rebuilds.
_Avoid_: History cache

**Identity repo**:
The separate private repo holding git + SSH identity (host aliases, public keys, conditional-include gitconfigs) as final-form files, synced into containers rather than baked into images.
_Avoid_: Dotfiles repo, secrets repo

**Identity volume**:
The shared volume holding the identity repo clone, so one sync serves every container and fresh containers can apply identity offline.
_Avoid_: Identity cache

**Sync**:
Pulling the identity repo onto the identity volume (needs the forwarded agent) and then applying it — the network half of identity delivery.
_Avoid_: Install, clone (alone)

**Apply**:
Copying identity files from the identity volume into a container's home with tight permissions — the offline half; runs automatically in fresh containers.
_Avoid_: Symlink, deploy

**adc**:
The environment-aware CLI this repo ships — baked into images and Sheldon-installable on the host — whose noun-grouped commands scaffold projects (`init`, variant auto-detected), sync and apply identity (`identity sync|apply`), upgrade the shared Claude Code (`claude upgrade`), and diagnose setup (`doctor`); container-only commands refuse to run on the host, and the v1 flat verbs hard-error with a pointer to their new names.
_Avoid_: Helper scripts, devcontainer CLI (that's the external `devcontainer` tool)

**Forwarded agent**:
The host SSH agent (1Password) reaching the container over the Dev Containers extension's own channel, keyed off the host's SSH_AUTH_SOCK — the root of trust for cloning, pushing, and commit signing.
_Avoid_: Mounted socket, agent socket mount
