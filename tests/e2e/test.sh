#!/bin/bash
# Tier 3 — e2e requirements checklist (spec: issue #28). Runs INSIDE a live
# container brought up with `devcontainer up` from an `adc init` project, via
# `devcontainer exec` — so mounts, features, and lifecycle hooks are the real
# ones from the image metadata, not simulated. CI has no forwarded SSH agent
# and no gh auth, so `adc doctor` is asserted line-by-line, not all-pass.
# Usage (in-container): tests/e2e/test.sh <base|node>
set -euo pipefail

if [ $# -ne 1 ]; then
    echo "Usage: $0 <base|node>" >&2
    exit 1
fi
VARIANT="$1"

# shellcheck source=tests/lib/test-utils.sh
. "$(cd "$(dirname "$0")" && pwd)/../lib/test-utils.sh"

check_login_shell_zsh() {
    local shell
    shell="$(getent passwd vscode | cut -d: -f7)"
    case "$shell" in
        *zsh) return 0 ;;
        *)
            echoStderr "login shell for vscode is '$shell', expected zsh"
            return 1
            ;;
    esac
}

check_zsh_startup_silent() {
    local startup_output
    startup_output="$(zsh -ilc 'true' 2>&1 || true)"
    if [ -n "$startup_output" ]; then
        echoStderr "unexpected output from interactive zsh startup:"
        echoStderr "$startup_output"
        return 1
    fi
}

# the shared volumes declared in the image metadata must be live mounts,
# not plain directories
check_volume_mounts() {
    local targets target missing=0
    targets=(
        /home/vscode/.local/state/history
        /home/vscode/.local/share/identity
        /home/vscode/.claude
        /home/vscode/.config/gh
        /home/vscode/.local/share/claude
        /home/vscode/.local/bin
    )
    if [ "$VARIANT" = "node" ]; then
        targets+=(/home/vscode/.local/share/pnpm-store)
    fi
    for target in "${targets[@]}"; do
        if ! awk '{print $2}' /proc/mounts | grep -qx "$target"; then
            echoStderr "no mount at $target"
            missing=1
        fi
    done
    return "$missing"
}

# onCreateCommand ran claude-bootstrap.sh: the shared install volume is
# populated and the claude launcher landed on the claude-bin volume
check_claude_bootstrap_ran() {
    [ -n "$(ls -A "$HOME/.local/share/claude" 2>/dev/null)" ] || {
        echoStderr "claude install volume is empty — onCreateCommand did not run?"
        return 1
    }
    [ -x "$HOME/.local/bin/claude" ] || {
        echoStderr "no executable claude at ~/.local/bin/claude"
        return 1
    }
}

check_adc_doctor_shape() {
    local output rc=0
    output="$(adc doctor 2>&1)" || rc=$?
    if [ "$rc" -eq 0 ]; then
        echoStderr "adc doctor passed entirely — impossible in CI (no SSH agent, no gh auth):"
        echoStderr "$output"
        return 1
    fi
    local expected shape_ok=0
    expected=(
        "adc doctor (container)"
        "ok    Claude Code installed"
        "ok    docker reachable"
        "FAIL  SSH agent forwarded"
        "FAIL  identity applied"
        "FAIL  gh authenticated"
    )
    for line in "${expected[@]}"; do
        if ! grep -qF "$line" <<< "$output"; then
            echoStderr "adc doctor output is missing '$line'"
            shape_ok=1
        fi
    done
    if [ "$shape_ok" -ne 0 ]; then
        echoStderr "full output:"
        echoStderr "$output"
    fi
    return "$shape_ok"
}

check_env_brief() {
    [ -s /etc/claude-code/CLAUDE.md ] || return 1
    if [ "$VARIANT" = "node" ]; then
        grep -q '^## Node toolchain' /etc/claude-code/CLAUDE.md || return 1
    fi
}

check "running as vscode" test "$(whoami)" = vscode
check "login shell is zsh" check_login_shell_zsh
check "interactive zsh starts with zero output" check_zsh_startup_silent
check "shared volumes mounted ($VARIANT set)" check_volume_mounts
check "onCreateCommand ran claude-bootstrap" check_claude_bootstrap_ran
check "docker-in-docker reachable" docker info
check "adc doctor has the expected CI pass/fail shape" check_adc_doctor_shape
check "environment brief at /etc/claude-code/CLAUDE.md" check_env_brief

reportResults
