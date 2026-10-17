#!/usr/bin/env bash
# advisor-bench/run.sh — Sonnet with an Opus advisor against Opus alone, on the same review cases and task.
# SPENDS TOKENS: ask the person paying first. Runs are interleaved (A1 B1 A2 B2 …) so a cap that stops the run
# stops both arms at the same depth.
#
#   bash packaging/advisor-bench/run.sh --out DIR [--runs 2] [--cap 10] [--case-budget 1]
#                                       [--review id,id] [--task-only] [--review-only] [--arms a,b]
#   arms: a = sonnet + opus advisor · b = opus alone
# One JSON per arm, run and kind in DIR (review-bench's own --out); summary.mjs reads them.
set -u
cd "$(dirname "$0")/../.." || exit 2
OUT=""; RUNS=2; CAP=10; CB=1; ARMS="a,b"; KINDS="review task"
REVIEW="printf-option-key,regex-not-import,sigpipe-grep-q,clean-board-refusals,pattern-clean"
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;; --runs) RUNS="$2"; shift 2 ;; --cap) CAP="$2"; shift 2 ;;
    --case-budget) CB="$2"; shift 2 ;; --review) REVIEW="$2"; shift 2 ;; --arms) ARMS="$2"; shift 2 ;;
    --task-only) KINDS="task"; shift ;; --review-only) KINDS="review"; shift ;;
    *) echo "advisor-bench: unknown argument $1" >&2; exit 2 ;;
  esac
done
[ -n "$OUT" ] || { echo "advisor-bench: --out DIR is required" >&2; exit 2; }
mkdir -p "$OUT"
spent(){ node -e 'const fs=require("fs"),p=require("path");let n=0;for(const f of fs.readdirSync(process.argv[1]))if(f.endsWith(".json"))n+=JSON.parse(fs.readFileSync(p.join(process.argv[1],f))).cost||0;console.log(n.toFixed(2))' "$OUT"; }
r=1
while [ "$r" -le "$RUNS" ]; do
  for arm in ${ARMS//,/ }; do
    case "$arm" in a) M=(--model sonnet --advisor opus) ;; b) M=(--model opus) ;; *) echo "advisor-bench: arm $arm?" >&2; exit 2 ;; esac
    for kind in $KINDS; do
      f="$OUT/$arm-$r-$kind.json"; [ -f "$f" ] && continue
      left="$(node -e 'console.log((+process.argv[1]-+process.argv[2]).toFixed(2))' "$CAP" "$(spent)")"
      if [ "$kind" = review ]; then set -- --cases packaging/review-bench/cases --only "$REVIEW"; else set -- --cases packaging/advisor-bench/tasks; fi
      echo "== arm $arm · run $r · $kind · \$$left of \$$CAP left"
      bash kit/eval/review-bench.sh "$@" --arm agent "${M[@]}" --case-budget "$CB" --max-cost "$left" --out "$f"
    done
  done
  r=$((r + 1))
done
echo "spent \$$(spent) of \$$CAP"
