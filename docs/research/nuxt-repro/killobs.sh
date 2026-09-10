#!/usr/bin/env bash
# usage: killobs.sh <label> <signal> <target>   (target may be a pid or -pgid)
label=$1; sig=$2; target=$3
cd /workspaces/nuxt-repro
echo "== BEFORE ($label) =="; ps -eo pid,ppid,pgid,stat,cmd | grep -E "node|nuxt" | grep -v grep | cut -c1-110
echo ">> kill -$sig $target"; kill -$sig -- $target; echo "rc=$?"
sleep 4
echo "== AFTER +4s =="; echo "-- surviving node/nuxt processes --"; ps -eo pid,ppid,pgid,stat,cmd | grep -E "node|nuxt" | grep -v grep | cut -c1-110 || true
echo "-- listeners --"; bash probe/listeners.sh
echo "-- unix nuxt sockets --"; grep nuxt /proc/net/unix || echo "(none)"
echo "-- log tail --"; tail -n 5 probe/logs/$label.log
echo "-- curl 3000 --"; curl -s -o /dev/null --max-time 3 -w "%{http_code}\n" http://localhost:3000/ || echo "conn failed"
