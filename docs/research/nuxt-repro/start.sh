#!/usr/bin/env bash
# start `pnpm dev $@` detached in its own session, log to probe/logs/<name>.log
name=$1; shift
mkdir -p /workspaces/nuxt-repro/probe/logs
export PATH=/home/vscode/.nvm/versions/node/v24.20.0/bin:$PATH
cd /workspaces/nuxt-repro
setsid nohup pnpm dev "$@" > probe/logs/$name.log 2>&1 &
echo "launcher pid=$!"
