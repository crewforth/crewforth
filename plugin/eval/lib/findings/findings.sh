#!/usr/bin/env bash
# findings.sh — the shell entry to findings.mjs. It does one thing: find a Node that RUNS and hand over.
#
#   bash findings.sh validate|stamp|write|schema …     the arguments and exit codes of findings.mjs (0, 1, 2)
#       rc 3 = no usable Node here, so nothing was checked. Not a pass: a caller must not read 3 as verified.
#
# A name that resolves is not a runtime that works: the Windows Store's stub satisfies `command -v` and then
# exits 49. So node is asked for its version and the answer is read. When PATH has none, the panel's own
# resolver is asked (it knows the places PATH does not reach, and the runtime Crewforth may have fetched). This
# file never installs anything.
set -u
# A caller on Windows may name this file with backslashes (Node's path.join does); cut at either separator,
# or the directory falls back to "." and findings.mjs is looked for in the caller's cwd.
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
  echo "findings: no Node $FLOOR+ that runs was found, so nothing was checked (this is not a pass)" >&2
  exit 3
fi
exec "$NODE" "$d/findings.mjs" "$@"
