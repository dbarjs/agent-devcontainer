# Shell config vendored in-repo; identity synced from a private repo

Terminal configuration and personal identity travel by different routes, on purpose. The rc files (zshrc, sheldon plugins.toml, starship.toml) are **vendored dotfiles**: container-adapted copies kept in this public repo and baked into the image home at build — no `dotfiles.repository` install step, no clone at container start. Git + SSH identity (host aliases, public keys, conditional-include gitconfigs) is private, so it lives in the separate **identity repo** ([dbarjs/identity](https://github.com/dbarjs/identity)) as final-form files, synced by `adc` onto a shared identity volume and applied into each container's home with tight permissions — fresh containers apply offline from the volume.

The predecessor `dbarjs/devcontainer-dotfiles` generated dotfiles from templates and proved hard to maintain; both halves of this decision reject generation — every file is stored exactly as it will exist in the container.

Decided in [issue #9](https://github.com/dbarjs/agent-devcontainer/issues/9) and the [map v1](https://github.com/dbarjs/agent-devcontainer/issues/1) charting constraints.
