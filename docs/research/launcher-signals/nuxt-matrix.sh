#!/bin/bash
set -u
export PATH="$HOME/.nvm/versions/node/v24.20.0/bin:$PATH"
cd /tmp && rm -rf proj && mkdir proj && cd proj
cat > package.json <<'J'
{"name":"proj","private":true,"type":"module","packageManager":"pnpm@10.15.0",
 "scripts":{"dev":"nuxt dev","srv":"node srv.js"},"dependencies":{"nuxt":"^4","vue":"^3"}}
J
echo 'setInterval(()=>{},1000); console.log("srv up", process.pid)' > srv.js
echo 'export default defineNuxtConfig({ compatibilityDate: "2025-01-01", devtools: { enabled: false }, telemetry: false })' > nuxt.config.ts
pnpm install --silent >/dev/null 2>&1 || { echo install failed; exit 1; }
echo "nuxt $(node -p 'require("nuxt/package.json").version') cli $(node -p 'require("@nuxt/cli/package.json").version')"
echo "--- pnpm SIGTERM handling in its dist:"
grep -o '[a-zA-Z_.]*SIGTERM[^;]\{0,100\}' "$(dirname "$(readlink -f "$(command -v pnpm)")")"/*.cjs 2>/dev/null | sort -u | head -8
pnpmdist=$(dirname "$(readlink -f "$(command -v pnpm)")"); ls "$pnpmdist" | head -3
alive() { kill -0 "$1" 2>/dev/null && echo YES || echo no; }
listen3000() { grep -q ':0BB8 ' /proc/net/tcp6 /proc/net/tcp 2>/dev/null && echo YES || echo no; }
run() { # label, script, signal, wait, env...
  local label=$1 script=$2 sig=$3 wait=$4; shift 4
  env "$@" setsid nohup pnpm run "$script" >/tmp/out.$$ 2>&1 &
  local bp=$!; sleep "$wait"
  local lp; lp=$(pgrep -xf "node .*pnpm run $script.*" | head -1)
  local sp; sp=$(pgrep -f 'nuxt.mjs dev|node srv.js' | head -1)
  local chain; chain=$(ps -o pid=,ppid=,args= -e | awk -v root=$lp 'BEGIN{keep[root]=1} {if(keep[$2]||$1==root){keep[$1]=1; print}}' | sed 's/^ *//' | cut -c1-60 | tr '\n' '|')
  kill -"$sig" "$lp"; sleep 4
  printf '%-40s | %s->pnpm(%s) | server survives: %-3s | :3000 listening: %s\n   chain before: %s\n' "$label" "$sig" "$lp" "$(alive "$sp")" "$(listen3000)" "$chain"
  pkill -f 'nuxt.mjs|node srv.js|@nuxt/cli' 2>/dev/null; sleep 1
}
run "sleeper, setsid nohup"               srv TERM 3
run "nuxt dev, setsid nohup"              dev TERM 14
run "nuxt dev --no-fork (via env TEST=1)" dev TERM 14 TEST=1
run "nuxt dev, shell-emulator"            dev TERM 14 npm_config_shell_emulator=true
run "nuxt dev, script-shell=bash"         dev TERM 14 npm_config_script_shell=/bin/bash
run "nuxt dev, shell-emulator, KILL"      dev KILL 14 npm_config_shell_emulator=true
