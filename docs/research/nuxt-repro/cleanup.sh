#!/usr/bin/env bash
pkill -9 -f "nuxt|pnpm dev" ; sleep 1; ps -eo pid,cmd | grep -E "node|nuxt" | grep -v grep || echo "(clean)"; rm -f /workspaces/nuxt-repro/.nuxt/nuxt.lock
