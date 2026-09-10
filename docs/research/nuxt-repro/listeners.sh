#!/usr/bin/env bash
# print LISTEN sockets with owning pid/cmd, parsed from /proc (no ss/lsof in image)
declare -A inode2pid
for fd in /proc/[0-9]*/fd/*; do
  l=$(readlink "$fd" 2>/dev/null) || continue
  case "$l" in socket:\[*\]) i=${l#socket:[}; i=${i%]}; p=${fd#/proc/}; p=${p%%/*}; inode2pid[$i]=$p;; esac
done
for f in /proc/net/tcp /proc/net/tcp6; do
  tail -n +2 "$f" | while read -r sl local rem st rest; do
    [ "$st" = "0A" ] || continue
    inode=$(echo "$rest" | awk '{print $6}')
    port=$((16#${local##*:}))
    addr=${local%%:*}
    pid=${inode2pid[$inode]:-?}
    cmd=$(tr '\0' ' ' < /proc/$pid/cmdline 2>/dev/null | cut -c1-120)
    printf '%s\tport=%s\taddr=%s\tinode=%s\tpid=%s\tcmd=%s\n' "${f##*/}" "$port" "$addr" "$inode" "$pid" "$cmd"
  done
done
