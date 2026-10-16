#!/usr/bin/env bash
# prepass.sh — the shell entry to prepass.mjs, the review's deterministic first pass. It finds a Node that RUNS
# and hands over; the arguments and exit codes are prepass.mjs's (0, 1, 2).
#
#   bash prepass.sh [--root DIR] [--base REF] [--stdout]
#       rc 3 = no usable Node here, so nothing was checked. Not a pass: the review then reads the diff without it.
#
# The Node is found the way findings.sh finds it (one rule): asked for its version, never trusted by name.
set -u
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
  echo "review-prepass: no Node $FLOOR+ that runs was found, so nothing was checked (this is not a pass)" >&2
  exit 3
fi
exec "$NODE" "$d/prepass.mjs" "$@"
