# Prebuilt image suite on GHCR, tiny per-project template

Projects could each own a Dockerfile, compose devcontainer Features per repo, or lean on a dotfiles installer at container start. Instead this repo prebuilds a layered image suite — stack-agnostic **base**, **node** variant on top — with the devcontainer CLI and publishes multi-arch (arm64 + amd64) to `ghcr.io/dbarjs/agent-devcontainer/{base,node}`; each project carries only a tiny `.devcontainer` template that references an image by tag. Prebuilding with the devcontainer CLI (not plain `docker build`) is load-bearing: it embeds Feature metadata in the image labels, so consuming projects inherit mounts, volumes, and container wiring without redeclaring them.

Rebuilds are weekly and deliberately cache-less — the cron exists to pull fresh apt security updates, which a reused apt layer would silently skip.

Decided on [map v1](https://github.com/dbarjs/agent-devcontainer/issues/1); image spec in [issue #7](https://github.com/dbarjs/agent-devcontainer/issues/7), publish workflow in [issue #11](https://github.com/dbarjs/agent-devcontainer/issues/11).
