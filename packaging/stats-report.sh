#!/usr/bin/env bash
# Reads the stats ledger. A measurement nobody looks at is not a measurement.
#
# `collect-stats.sh` writes rows; this turns them into something answerable. Three questions it exists to
# settle, none of which the raw JSONL answers at a glance:
#
#   1. Is anyone actually using this?  Stars are a social signal — someone approving of the idea. Unique
#      clones are a usage signal. They are different numbers and only one of them means the kit was run.
#   2. Which npm downloads are real?  Every published version, including ones nobody installs, draws a
#      similar weekly baseline from registry mirrors. So the absolute total is meaningless; a version
#      standing well above the median of all versions is not. That ratio is the actual adoption signal.
#   3. Is it growing?  Only visible across captures, which is the whole reason the ledger is append-only.
#
# The daily traffic series is rebuilt across every capture and deduplicated by date, which is where the
# ledger earns its keep: GitHub only ever shows a fourteen-day window, and this reconstructs an unbroken
# daily history longer than that window from the overlapping snapshots.
#
# Usage:
#   bash packaging/stats-report.sh                 # reads origin/stats (fetches it if missing)
#   bash packaging/stats-report.sh path.jsonl      # or a local ledger file
#   bash packaging/stats-report.sh --days 30       # limit the daily table (default 21)
#
# Exit 0 report printed · 1 no ledger could be read · 2 a prerequisite is missing (jq).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"

command -v jq >/dev/null 2>&1 || { echo "stats-report: jq is required" >&2; exit 2; }

DAYS=21; SRC=""
while [ $# -gt 0 ]; do
  case "$1" in
    --days) DAYS="${2:-21}"; shift 2 ;;
    *)      SRC="$1"; shift ;;
  esac
done

LEDGER=""
if [ -n "$SRC" ]; then
  [ -f "$SRC" ] || { echo "stats-report: no such file: $SRC" >&2; exit 1; }
  LEDGER="$(cat "$SRC")"
else
  git rev-parse --verify -q origin/stats >/dev/null 2>&1 || GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never git fetch -q origin stats 2>/dev/null || true
  LEDGER="$(git cat-file -p origin/stats:stats.jsonl 2>/dev/null || true)"
  [ -n "$LEDGER" ] || { echo "stats-report: no ledger on origin/stats (has the workflow run yet?)" >&2; exit 1; }
fi

jq -sr --argjson days "$DAYS" '
  # ---- helpers -------------------------------------------------------------------------------------------
  def pad(n): tostring | (" " * (n - length) + .);
  def padr(n): tostring | (. + " " * (n - length));
  def signed: if . == null then "    ·" elif . > 0 then "+\(.)" elif . == 0 then "0" else "\(.)" end;

  . as $rows
  | ($rows | length) as $n
  | $rows[-1] as $last
  | ($rows[-2] // null) as $prev

  # ---- daily series, deduplicated by date across every capture -------------------------------------------
  | (reduce $rows[] as $r ({};
       reduce ($r.github.traffic.clones.daily // [])[] as $d (.;
         .[$d.timestamp[0:10]] = ((.[$d.timestamp[0:10]] // {}) + {c: $d.count, cu: $d.uniques}))
     )) as $clones
  | (reduce $rows[] as $r ({};
       reduce ($r.github.traffic.views.daily // [])[] as $d (.;
         .[$d.timestamp[0:10]] = ((.[$d.timestamp[0:10]] // {}) + {v: $d.count, vu: $d.uniques}))
     )) as $views
  | ([($clones | keys), ($views | keys)] | add | unique | sort) as $dates

  # ---- npm signal vs mirror noise ------------------------------------------------------------------------
  | ($last.npm.by_version // {}) as $bv
  | ($bv | to_entries | map(.value) | sort) as $sorted
  | (if ($sorted | length) > 0 then $sorted[($sorted | length / 2 | floor)] else 0 end) as $baseline
  | ($bv | to_entries | max_by(.value)) as $top

  # ---- output ---------------------------------------------------------------------------------------------
  | "== stats ledger ==  \($n) capture\(if $n == 1 then "" else "s" end)"
    + "  ·  \($rows[0].captured_at[0:10]) → \($last.captured_at[0:10])"
  , ""
  , "Latest  (\($last.captured_at[0:10]) · kit \($last.kit_version))"
  , (if $last.github.traffic then
       "  clones      \($last.github.traffic.clones.count | pad(6))  total"
       + "   \($last.github.traffic.clones.uniques | pad(5))  unique"
       + (if $prev and $prev.github.traffic then
            "   (uniq w/w \($last.github.traffic.clones.uniques - $prev.github.traffic.clones.uniques | signed))"
          else "" end)
     else "  clones      not measured — \($last.github.traffic_error // "unknown reason")" end)
  , (if $last.github.traffic then
       "  views       \($last.github.traffic.views.count | pad(6))  total"
       + "   \($last.github.traffic.views.uniques | pad(5))  unique"
     else empty end)
  , "  npm         \($last.npm.total // 0 | pad(6))  downloads/week"
    + (if $prev then "   (w/w \(($last.npm.total // 0) - ($prev.npm.total // 0) | signed))" else "" end)
  , (if $last.installs.last_week != null then
       "  installs    \($last.installs.last_week | pad(6))  inits/week"
       + (if $prev and ($prev.installs.last_week // null) != null then
            "   (w/w \($last.installs.last_week - $prev.installs.last_week | signed))" else "" end)
     else "  installs    not measured — \($last.installs.error // "row predates the install count")" end)
  , "  releases    \($last.github.releases // [] | length | pad(6))  tagged"
    + "   \([$last.github.releases // [] | .[].assets[]?.downloads] | add // 0 | pad(5))  asset downloads"
  , ""
  , "npm — signal vs mirror noise"
  , "  mirror baseline (median of all \($bv | length) versions)   \($baseline | pad(5)) /week"
  , (if $top then
       "  busiest version  \($top.key | padr(28))\($top.value | pad(5)) /week"
       + (if $baseline > 0 then "   = \(($top.value / $baseline) | floor)× baseline" else "" end)
     else empty end)
  , (if ($bv[$last.kit_version] // null) != null then
       "  current \($last.kit_version | padr(36))\($bv[$last.kit_version] | pad(5)) /week"
       + (if $bv[$last.kit_version] <= $baseline then "   (at or below baseline — no real pull yet)" else "" end)
     else "  current \($last.kit_version) not in the window yet (npm closes its week before a fresh release)" end)
  , ""
  , (if ($dates | length) > 0 then
       "Daily traffic  (deduplicated across captures · last \([$days, ($dates|length)] | min) of \($dates | length) days)"
     else "Daily traffic  (none captured)" end)
  , (if ($dates | length) > 0 then "  date          clones  uniq   views  uniq" else empty end)
  , ( $dates[-$days:][]
      | . as $d
      | "  \($d)  \(($clones[$d].c // "·") | pad(7))\(($clones[$d].cu // "·") | pad(6))"
        + "\(($views[$d].v // "·") | pad(8))\(($views[$d].vu // "·") | pad(6))" )
  , ""
  , (if $n < 2 then
       "Trend needs a second capture — the ledger has one row so far. The weekly job adds the next on Monday."
     else
       "Captures        clones/uniq      views/uniq       npm/week"
     end)
  , (if $n >= 2 then
       ($rows[] | "  \(.captured_at[0:10])  "
         + "\((.github.traffic.clones.count // "·") | pad(7))/\((.github.traffic.clones.uniques // "·") | padr(6))"
         + "\((.github.traffic.views.count // "·") | pad(8))/\((.github.traffic.views.uniques // "·") | padr(6))"
         + "\((.npm.total // "·") | pad(9))")
     else empty end)
' <<<"$LEDGER"
