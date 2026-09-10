#!/usr/bin/env bash
# usage: run-case.sh <label> <signal> <target: nuxt|pnpm|pgid> [extra nuxt dev args]
label=$1; sig=$2; which=$3; shift 3
cd /workspaces/nuxt-repro
bash probe/start.sh "$label" "$@"
sleep 12
case $which in
  nuxt) t=$(pgrep -f "nuxt.mjs dev" | head -1);;
  pnpm) t=$(pgrep -xf "node .*pnpm dev.*" | head -1);;
  pgid) t=-$(pgrep -xf "node .*pnpm dev.*" | head -1);;
esac
echo "target=$which -> $t"
bash probe/killobs.sh "$label" "$sig" "$t"
echo "== +20s =="; sleep 16
ps -eo pid,ppid,pgid,stat,etimes,cmd | grep -E "node|nuxt" | grep -v grep | cut -c1-120 || true
bash probe/listeners.sh
bash probe/cleanup.sh
