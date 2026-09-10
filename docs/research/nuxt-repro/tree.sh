#!/usr/bin/env bash
# process tree of everything node-ish, with pgid/sid
ps -eo pid,ppid,pgid,sid,stat,etimes,cmd --forest | grep -E "PID|node|nuxt|pnpm|sleep|zsh|bash" | grep -v grep | cut -c1-160
