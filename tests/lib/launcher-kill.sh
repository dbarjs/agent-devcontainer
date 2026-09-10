#!/bin/bash
# Launcher-kill probe (ADR-0011, issue #59). Runs INSIDE a node-image
# container with node/pnpm/npm on PATH. Scaffolds a throwaway project whose
# `dev` script starts a listener on PORT, starts it through the given
# launcher, SIGTERMs the *launcher* pid, and asserts what is left listening:
#   --expect clean   (default) nothing listens — the signal reached the server
#   --expect orphan  the server survived — the negative control that proves
#                    the probe can tell the difference
# Listeners are read from /proc/net/tcp* (the image has no ss/lsof), and any
# survivor is killed on the way out so the port is free for the next run.
# --pm pins packageManager in the throwaway package.json (corepack then runs
# exactly that pnpm), so a check names the pnpm major it proves.
# Usage: launcher-kill.sh [--expect clean|orphan] [--port N] [--pm pnpm@X.Y.Z] <node|vite> <launcher...>
#   e.g. launcher-kill.sh --pm pnpm@11.21.0 node pnpm run dev
#        launcher-kill.sh vite npm run dev
set -euo pipefail

expect=clean
port=3000
pm=""
while [ $# -gt 0 ]; do
    case "$1" in
        --expect) expect="$2"; shift 2 ;;
        --port) port="$2"; shift 2 ;;
        --pm) pm="$2"; shift 2 ;;
        --) shift; break ;;
        *) break ;;
    esac
done
if [ $# -lt 2 ]; then
    echo "Usage: $0 [--expect clean|orphan] [--port N] [--pm pnpm@X.Y.Z] <node|vite> <launcher...>" >&2
    exit 2
fi
server="$1"
shift
launcher=("$@")

port_hex="$(printf '%04X' "$port")"

# LISTEN (state 0A) sockets on the port, as "inode" lines
listen_inodes() {
    awk -v p=":$port_hex" '$2 ~ p"$" && $4 == "0A" { print $10 }' \
        /proc/net/tcp /proc/net/tcp6 2>/dev/null
}

# pids owning the given socket inodes, resolved through /proc/*/fd
inode_owners() {
    local inodes="$1" fd link inode pid
    [ -n "$inodes" ] || return 0
    for fd in /proc/[0-9]*/fd/*; do
        link="$(readlink "$fd" 2>/dev/null)" || continue
        case "$link" in
            socket:\[*\])
                inode="${link#socket:[}"
                inode="${inode%]}"
                if grep -qx "$inode" <<< "$inodes"; then
                    pid="${fd#/proc/}"
                    echo "${pid%%/*}"
                fi
                ;;
        esac
    done | sort -u
}

describe_listeners() {
    local inodes pid
    inodes="$(listen_inodes)"
    for pid in $(inode_owners "$inodes"); do
        printf '    pid %s: %s\n' "$pid" \
            "$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | cut -c1-120)"
    done
}

wait_until() { # $1 = seconds, rest = predicate
    local deadline=$(( $(date +%s) + $1 ))
    shift
    while ! "$@"; do
        [ "$(date +%s)" -lt "$deadline" ] || return 1
        sleep 0.5
    done
}
is_listening() { [ -n "$(listen_inodes)" ]; }
# shellcheck disable=SC2317,SC2329 # invoked through wait_until
not_listening() { ! is_listening; }

if is_listening; then
    echo "port $port is already in use before the probe started:" >&2
    describe_listeners >&2
    exit 2
fi

project="$(mktemp -d)"
cd "$project"
pm_field=""
[ -z "$pm" ] || pm_field="$(printf ',"packageManager":"%s"' "$pm")"
case "$server" in
    node)
        printf '{"name":"launcher-kill","private":true%s,"scripts":{"dev":"node srv.js"}}\n' \
            "$pm_field" > package.json
        printf 'require("net").createServer().listen(%s, "127.0.0.1", () => console.log("listening"));\nsetInterval(() => {}, 1000);\n' \
            "$port" > srv.js
        ;;
    vite)
        printf '{"name":"launcher-kill","private":true%s,"scripts":{"dev":"vite --host 127.0.0.1 --port %s --strictPort"}}\n' \
            "$pm_field" "$port" > package.json
        printf '<!doctype html><title>launcher-kill</title>\n' > index.html
        pnpm add -D vite > pnpm-add.log 2>&1 || {
            echo "pnpm add -D vite failed:" >&2
            cat pnpm-add.log >&2
            exit 2
        }
        ;;
    *)
        echo "unknown server '$server' (node|vite)" >&2
        exit 2
        ;;
esac

# a simple command in the background is exec'd by bash, so $! is the launcher
"${launcher[@]}" > launcher.log 2>&1 &
launcher_pid=$!

if ! wait_until 60 is_listening; then
    echo "server never listened on $port via '${launcher[*]}':" >&2
    cat launcher.log >&2
    kill -TERM "$launcher_pid" 2>/dev/null || true
    exit 1
fi

# shellcheck disable=SC2317,SC2329 # invoked through wait_until
launcher_gone() { ! kill -0 "$launcher_pid" 2>/dev/null; }
kill -TERM "$launcher_pid"
if wait_until 10 launcher_gone; then
    wait "$launcher_pid" 2>/dev/null || true
else
    echo "note: launcher pid $launcher_pid still alive 10 s after SIGTERM" >&2
fi

rc=0
if wait_until 10 not_listening; then
    outcome=clean
else
    outcome=orphan
fi
if [ "$outcome" = "$expect" ]; then
    echo "ok: '${launcher[*]}' + SIGTERM(launcher) -> $outcome"
else
    echo "expected $expect, got $outcome after SIGTERM to '${launcher[*]}' (pid $launcher_pid)" >&2
    if [ "$outcome" = orphan ]; then
        echo "  still listening on $port:" >&2
        describe_listeners >&2
    fi
    echo "  launcher output:" >&2
    sed 's/^/    /' launcher.log >&2
    rc=1
fi

# leave the port free whatever happened
for pid in $(inode_owners "$(listen_inodes)"); do
    kill -KILL "$pid" 2>/dev/null || true
done
exit "$rc"
