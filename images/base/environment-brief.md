# Container environment (agent-devcontainer)

- Prebuilt devcontainer: Debian trixie, user `vscode` with passwordless sudo — install missing tools with `sudo apt-get install`.
- Docker-in-Docker: `docker` works against an isolated daemon inside this container; builds and containers are fine, nothing reaches the host daemon.
- `~/.claude`, `~/.config/gh`, `~/.local/state/history`, and the Claude Code install are named volumes shared across ALL containers from this image — auth and history persist, and deleting or reconfiguring there affects every project.
- No systemd: `systemctl`/`service` do not work; start processes directly.
- Claude Code autoupdate is disabled (shared install volume) — upgrade via `adc claude upgrade`, never `claude update`.
