#!/bin/bash
# Claude Code first-run bootstrap, wired as onCreateCommand in the base image
# metadata. The install lives on a shared named volume (~/.local/share/claude),
# not in the image — a baked install would be shadowed by the mount and go
# stale. Installs only when the volume is empty; `claude update` in any
# container upgrades every container sharing the volume.
set -euo pipefail

install_dir="${HOME}/.local/share/claude"

if [ -n "$(ls -A "${install_dir}" 2>/dev/null)" ]; then
  echo "claude-bootstrap: existing install in ${install_dir}; skipping."
  exit 0
fi

echo "claude-bootstrap: ${install_dir} is empty; installing Claude Code..."
curl -fsSL https://claude.ai/install.sh | bash
echo "claude-bootstrap: done. Run 'claude' to log in (auth persists on the shared volume)."
