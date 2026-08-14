# Plain debian:trixie base instead of Microsoft devcontainer images

The obvious base is `mcr.microsoft.com/devcontainers/base`, which ships common-utils preconfigured. We build on plain `debian:trixie` instead: apt covers almost the whole toolchain (zsh, git, python3, fzf, zoxide, starship), and what it doesn't is sourced directly — gh from GitHub's own apt repo (trixie's package is stale), sheldon from upstream musl binaries, Claude Code via its native installer. The cost is hand-rolling common-utils parity ourselves: the `vscode` user at UID 1000 with sudo, the `en_US.UTF-8` locale, and a PATH shim. The win is a base with no opaque Microsoft layer, where every installed byte is traceable to a line in our Dockerfile.

Decided in [issue #3](https://github.com/dbarjs/agent-devcontainer/issues/3) ([map v1](https://github.com/dbarjs/agent-devcontainer/issues/1)).
