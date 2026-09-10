#!/bin/bash
# Runs inside the node image. For each launcher x config, start a sleeper via the launcher,
# SIGTERM the launcher, report whether the node child survives.
set -u
export PATH="$HOME/.nvm/versions/node/$(ls $HOME/.nvm/versions/node | tail -1)/bin:$PATH"
cd /tmp && rm -rf proj && mkdir proj && cd proj
cat > package.json <<'J'
{"name":"proj","private":true,"packageManager":"pnpm@10.15.0","scripts":{"srv":"node srv.js"}}
J
echo 'setInterval(()=>{},1000); console.log("srv up", process.pid)' > srv.js
touch pnpm-lock.yaml
echo "sh -> $(readlink -f /bin/sh); $(dash -c 'echo dash' 2>/dev/null || echo 'no dash bin'); node $(node -v) pnpm $(pnpm -v) npm $(npm -v) nr $(command -v nr >/dev/null && echo yes || echo no)"
SIG=TERM
run() { # $1 label, $2 launcher cmd, rest env
  local label=$1 cmd=$2; shift 2
  env "$@" bash -c "$cmd" >/tmp/out.$$ 2>&1 &
  local bp=$!
  sleep 3
  # launcher pid = the direct child of our bash -c (bash may have exec'd it)
  local lp=$bp
  local chain; chain=$(ps -o pid=,ppid=,comm=,args= -e | awk -v root=$bp 'BEGIN{keep[root]=1} {if(keep[$2]){keep[$1]=1; print}}' | sed 's/^ *//' | cut -c1-90 | tr '\n' '|')
  local srv; srv=$(pgrep -f 'node srv.js' | head -1)
  kill -$SIG "$lp" 2>/dev/null; sleep 2
  local alive=no; [ -n "$srv" ] && kill -0 "$srv" 2>/dev/null && alive=YES
  printf '%-34s | $SIG->%-6s | srv survives: %-3s | chain: %s\n' "$label" "$lp" "$alive" "$chain"
  pkill -f 'node srv.js' 2>/dev/null; sleep 0.5
}
for SIG in TERM KILL; do
run "pnpm run (default)"            "pnpm run srv"
run "pnpm run shell-emulator"       "pnpm run srv" npm_config_shell_emulator=true
run "pnpm run script-shell=bash"    "pnpm run srv" npm_config_script_shell=/bin/bash
run "npm run (default)"             "npm run srv"
run "npm run script-shell=bash"     "npm run srv" npm_config_script_shell=/bin/bash
run "nr (default)"                  "nr srv"
run "nr shell-emulator"             "nr srv" npm_config_shell_emulator=true
run "pnpm exec node"                "pnpm exec node srv.js"
run "sh -c (bare dash)"             "sh -c 'node srv.js'"
done
