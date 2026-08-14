## Node toolchain

- Node LTS via NVM; corepack enabled (pnpm/yarn through corepack).
- npm globals are per-Node-version — `ni` (@antfu/ni) is the only shipped global; re-install globals after `nvm install`.
- pnpm store lives on a shared volume at `~/.local/share/pnpm-store` (cross-filesystem, so pnpm copies rather than hard-links) — a missing `.pnpm-store/` in the project root is intentional.
