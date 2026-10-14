#!/usr/bin/env bash
# crew-map.sh — the shell entry to scan.mjs. It does one thing: find a Node that RUNS and hand over.
#
#   bash crew-map.sh [--root DIR] [--stdout | --check]      the arguments and exit codes of scan.mjs (0, 1, 2)
#       rc 3 = no usable Node here, so nothing was scanned. Not a pass: a caller must not read 3 as a fresh map.
#
# The same resolution as findings.sh beside it: ask node for its version (the Windows Store's stub resolves and
# then exits 49), and when PATH has none, ask the panel's resolver. This file never installs anything.
set -u
# Cut at either separator: on Windows a caller may name this file with backslashes.
d="${BASH_SOURCE%[/\\]*}"; [ "$d" = "${BASH_SOURCE}" ] && d=.
FLOOR=18

usable(){ local v; v="$("$1" -p 'process.versions.node.split(".")[0]' 2>/dev/null)" || return 1
  case "$v" in ''|*[!0-9]*) return 1 ;; esac; [ "$v" -ge "$FLOOR" ]; }

NODE=""
if usable node; then NODE=node
elif [ -f "$d/../../../studio/ensure-node.sh" ]; then
  n="$(bash "$d/../../../studio/ensure-node.sh" 2>/dev/null)" && [ -n "$n" ] && usable "$n" && NODE="$n"
fi
if [ -z "$NODE" ]; then
  echo "crew-map: no Node $FLOOR+ that runs was found, so nothing was scanned (this is not a pass)" >&2
  exit 3
fi
exec "$NODE" "$d/scan.mjs" "$@"
