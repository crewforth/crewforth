#!/usr/bin/env bash
# review-bench.sh — how right the review is, on labelled cases: precision, recall and every false alarm by name.
# The shell entry to eval/lib/review-bench/bench.mjs; it finds a Node that RUNS and hands over.
#
#   bash review-bench.sh --cases DIR [--arm prepass|agent] [--split all|train|holdout] [--only id,id]
#                        [--model sonnet] [--advisor opus] [--case-budget 0.75] [--max-cost 12] [--floors FILE]
#                        [--out FILE] [--no-tools]
#
# --arm prepass (the default) runs no model and costs nothing. --arm agent runs Claude Code headless as
# crew-review-agent on every case and SPENDS TOKENS: each case is capped by --case-budget (US dollars) and the run
# by --max-cost; ask the person paying before running it. rc 3 = no usable Node here (not a pass).
set -u
d="${BASH_SOURCE%[/\\]*}"; [ "$d" = "${BASH_SOURCE}" ] && d=.
FLOOR=18
usable(){ local v; v="$("$1" -p 'process.versions.node.split(".")[0]' 2>/dev/null)" || return 1
  case "$v" in ''|*[!0-9]*) return 1 ;; esac; [ "$v" -ge "$FLOOR" ]; }
NODE=""
if usable node; then NODE=node
elif [ -f "$d/../studio/ensure-node.sh" ]; then
  n="$(bash "$d/../studio/ensure-node.sh" 2>/dev/null)" && [ -n "$n" ] && usable "$n" && NODE="$n"
fi
if [ -z "$NODE" ]; then
  echo "review-bench: no Node $FLOOR+ that runs was found, so nothing was measured (this is not a pass)" >&2
  exit 3
fi
exec "$NODE" "$d/lib/review-bench/bench.mjs" "$@"
