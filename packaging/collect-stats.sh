#!/usr/bin/env bash
# Distribution reach, captured before GitHub deletes it.
#
# GitHub's traffic API keeps only a FOURTEEN DAY window: clone and view counts older than that are gone, and
# nothing in this repo was writing them down. Every other number the project reports is either derivable from
# the tree (agent/skill counts) or permanent (npm totals); traffic is the one that evaporates. This script is
# the capture step — `.github/workflows/stats.yml` runs it weekly and appends the row to the `stats` branch.
#
# Emits ONE JSON object on stdout (a JSONL row). Everything else goes to stderr, so the caller can redirect
# stdout straight into the ledger.
#
# Sources, and what each is worth:
#   npm downloads      permanent, but almost entirely MIRROR NOISE — every published version, including ones
#                      nobody installs, draws a similar few-downloads-a-week baseline. The signal is the SPIKE
#                      on the current version against that baseline, which is why per-version numbers are kept
#                      rather than a single total.
#   release assets     permanent, cumulative, and a real install signal (a tarball download is deliberate).
#   traffic            EPHEMERAL — the whole reason this exists. Daily arrays are stored, not just the totals,
#                      so the resolution survives even though the runs overlap.
#   installs           the one count `npx crewforth init` sends per project (bin/cli.js → Telemetry), read from
#                      the Worker's /count with its READ_KEY in INSTALL_COUNT_READ_KEY. The closest number to
#                      "projects that installed it", still a lower bound. Versions `0.0.0-*` are the endpoint's
#                      own deploy checks and are left out of `last_week`; the full map is kept as it came.
#
# Auth: the traffic endpoints require push access, and `administration` is NOT a permission the workflow's
# automatic GITHUB_TOKEN can be granted — so traffic needs a fine-grained PAT (Administration: read) in
# STATS_TOKEN. Releases work with either token. When traffic cannot be read the row records WHY, and the
# workflow warns: a ledger that silently writes nothing where the numbers should be would read, a year later,
# exactly like a repo nobody cloned.
#
# Usage:
#   bash packaging/collect-stats.sh                    # token from STATS_TOKEN, else GITHUB_TOKEN, else `gh`
#   REPO=owner/name bash packaging/collect-stats.sh    # defaults to Crewforth/crewforth
#
# Exit 0 a row was written (traffic may be absent, and says so) · 1 every source failed — no row, no silent
# empty entry · 2 a prerequisite is missing (curl / jq).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"

REPO="${REPO:-Crewforth/crewforth}"
PKG="crewforth"
PKG_ENC="crewforth"

for tool in curl jq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "collect-stats: $tool is required" >&2; exit 2; }
done

# Token: STATS_TOKEN (traffic-capable) is preferred; GITHUB_TOKEN still gets releases; `gh` covers a local run.
# TOKEN_SRC names the one in use, because an error that blames the wrong token sends the reader to the wrong fix:
# for five weeks the row said "the automatic GITHUB_TOKEN cannot read traffic" while STATS_TOKEN, scoped to the
# repository's old owner, was the token being refused, and releases were lost with it.
TOKEN="${STATS_TOKEN:-${GITHUB_TOKEN:-}}"
TOKEN_SRC="$([ -n "${STATS_TOKEN:-}" ] && echo STATS_TOKEN || { [ -n "${GITHUB_TOKEN:-}" ] && echo GITHUB_TOKEN; })"
if [ -z "$TOKEN" ] && command -v gh >/dev/null 2>&1; then TOKEN="$(gh auth token 2>/dev/null || true)"; [ -n "$TOKEN" ] && TOKEN_SRC="gh auth token"; fi
API="${STATS_API_URL:-https://api.github.com}"

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
VERSION="$(cat VERSION 2>/dev/null || echo unknown)"

# Every request is bounded. curl waits indefinitely by default, and this script runs unattended on a weekly
# schedule, so a hung request is not a slow run — it is a lost week: the GitHub traffic API only keeps 14 days,
# and a snapshot that never completes cannot be taken again later. The failure path already exists and is
# graceful (an empty body becomes `null` in the row below), so bounding the wait turns a silent stall into a
# recorded gap. Same reasoning and the same knob as board.sh's `_gitnet`: CREW_NET_TIMEOUT, read here rather
# than redefined, because one name for one thing is what keeps the two from drifting to different values.
CURL_T="${CREW_NET_TIMEOUT:-15}"

# gh_api <path> [token] -> body on stdout, empty on failure (the caller decides whether that is fatal).
gh_api() {
  local tok="${2:-$TOKEN}"
  [ -n "$tok" ] || return 1
  curl -sf --connect-timeout 10 --max-time "$CURL_T" \
          -H "Authorization: Bearer $tok" \
          -H "Accept: application/vnd.github+json" \
          -H "X-GitHub-Api-Version: 2022-11-28" \
          "$API/repos/$REPO/$1" 2>/dev/null
}
npm_api() { curl -sf --connect-timeout 10 --max-time "$CURL_T" "https://api.npmjs.org/$1" 2>/dev/null; }

json_or_null() { # a body is only usable if it parses AND is an object
  jq -e 'type == "object"' >/dev/null 2>&1 <<<"$1" && printf '%s' "$1" || printf 'null'
}

OK=0

# --- npm ---------------------------------------------------------------------------------------------------
NPM_POINT="$(json_or_null "$(npm_api "downloads/point/last-week/$PKG")")"
NPM_RANGE="$(json_or_null "$(npm_api "downloads/range/last-week/$PKG")")"
NPM_VERS="$(json_or_null "$(npm_api "versions/$PKG_ENC/last-week")")"
[ "$NPM_POINT" != null ] && OK=1 || echo "collect-stats: npm download point unavailable" >&2

# --- release assets ----------------------------------------------------------------------------------------
RELEASES="$(gh_api releases)"
# Releases need no special permission, so a STATS_TOKEN that cannot see the repository (expired, or scoped to
# another owner) must not take them down with traffic: retry with the workflow's own token.
REL_FALLBACK=""
if [ -z "$RELEASES" ] && [ "$TOKEN_SRC" = STATS_TOKEN ] && [ -n "${GITHUB_TOKEN:-}" ]; then
  RELEASES="$(gh_api releases "$GITHUB_TOKEN")"; [ -n "$RELEASES" ] && REL_FALLBACK=1
fi
if [ -n "$RELEASES" ] && jq -e 'type == "array"' >/dev/null 2>&1 <<<"$RELEASES"; then
  RELEASES="$(jq -c '[.[] | {tag: .tag_name, published: .published_at,
                             assets: [.assets[] | {name, downloads: .download_count}]}]' <<<"$RELEASES")"
  OK=1
else
  RELEASES=null; echo "collect-stats: release list unavailable" >&2
fi

# --- traffic (the perishable half) ---------------------------------------------------------------------------
TRAFFIC_ERR=null
CLONES="$(gh_api traffic/clones)"; VIEWS="$(gh_api traffic/views)"
if [ -n "$CLONES" ] && [ -n "$VIEWS" ]; then
  CLONES="$(json_or_null "$CLONES")"; VIEWS="$(json_or_null "$VIEWS")"
  [ "$CLONES" != null ] && [ "$VIEWS" != null ] && OK=1
else
  CLONES=null; VIEWS=null
  if [ -z "$TOKEN" ]; then
    TRAFFIC_ERR='"no token: set STATS_TOKEN (fine-grained PAT, Administration: read)"'
  else
    case "$TOKEN_SRC:$REL_FALLBACK" in
      STATS_TOKEN:1) TRAFFIC_ERR='"STATS_TOKEN was refused for this repository while GITHUB_TOKEN could read it: the PAT has expired or is scoped to another owner"' ;;
      STATS_TOKEN:*) TRAFFIC_ERR='"STATS_TOKEN lacks Administration: read on this repository (or has expired)"' ;;
      *)             TRAFFIC_ERR="\"$TOKEN_SRC cannot read traffic (it needs Administration: read): set STATS_TOKEN\"" ;;
    esac
  fi
  echo "collect-stats: traffic unavailable — $(jq -r . <<<"$TRAFFIC_ERR")" >&2
fi

# --- installs (bin/cli.js's one count per project) ------------------------------------------------------------
INSTALL_URL="${INSTALL_COUNT_URL:-https://ping.crewforth.com}"
INSTALLS=null; INSTALLS_ERR=null
if [ -n "${INSTALL_COUNT_READ_KEY:-}" ]; then
  INSTALLS="$(json_or_null "$(curl -sf --connect-timeout 10 --max-time "$CURL_T" \
                -H "Authorization: Bearer $INSTALL_COUNT_READ_KEY" "$INSTALL_URL/count" 2>/dev/null)")"
  if [ "$INSTALLS" != null ]; then OK=1
  else INSTALLS_ERR='"the count endpoint gave no JSON object (wrong key, or unreachable)"'; fi
else
  INSTALLS_ERR='"no key: set INSTALL_COUNT_READ_KEY (the Worker READ_KEY)"'
fi
[ "$INSTALLS_ERR" = null ] || echo "collect-stats: installs unavailable — $(jq -r . <<<"$INSTALLS_ERR")" >&2

if [ "$OK" -eq 0 ]; then
  echo "collect-stats: every source failed — writing no row (an empty row is indistinguishable from zero reach)" >&2
  exit 1
fi

jq -cn \
  --arg at "$NOW" --arg version "$VERSION" --arg repo "$REPO" \
  --argjson point "$NPM_POINT" --argjson range "$NPM_RANGE" --argjson vers "$NPM_VERS" \
  --argjson releases "$RELEASES" --argjson clones "$CLONES" --argjson views "$VIEWS" \
  --argjson traffic_error "$TRAFFIC_ERR" \
  --argjson installs "$INSTALLS" --argjson installs_error "$INSTALLS_ERR" \
  '{
     captured_at: $at,
     repo: $repo,
     kit_version: $version,
     npm: {
       window:      (if $point then {start: $point.start, end: $point.end} else null end),
       total:       (if $point then $point.downloads else null end),
       daily:       (if $range then $range.downloads else null end),
       by_version:  (if $vers  then $vers.downloads  else null end),
       current_version_downloads:
                    (if $vers then ($vers.downloads[$version] // 0) else null end)
     },
     github: {
       releases: $releases,
       traffic: (if $clones and $views
                 then {clones: {count: $clones.count, uniques: $clones.uniques, daily: $clones.clones},
                       views:  {count: $views.count,  uniques: $views.uniques,  daily: $views.views}}
                 else null end),
       traffic_error: $traffic_error
     },
     installs: {
       by_day_version: $installs,
       last_week: (if $installs then
                     (($at | fromdateiso8601) - 7 * 86400 | strftime("%Y-%m-%d")) as $from
                     | [$installs | to_entries[] | (.key | split("|")) as $k
                        | select($k[0] >= $from and ($k[1] | startswith("0.0.0") | not)) | .value] | add // 0
                   else null end),
       error: $installs_error
     }
   }'
