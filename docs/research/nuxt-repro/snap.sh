#!/usr/bin/env bash
echo "== $(date +%T) $1 =="; echo "-- tree --"; bash /workspaces/nuxt-repro/probe/tree.sh; echo "-- listeners --"; bash /workspaces/nuxt-repro/probe/listeners.sh; echo "-- nuxt.lock --"; cat /workspaces/nuxt-repro/.nuxt/nuxt.lock 2>/dev/null || echo "(none)"; echo
