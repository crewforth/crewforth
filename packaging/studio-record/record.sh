#!/usr/bin/env bash
# Re-record the four Studio pictures in assets/ from a synthetic fixture:
#   studio-panels.gif  the panel in use (the Studio page)
#   studio-graph.png   the finished graph (the Studio page)
#   studio-models.png  the Models view with one agent's task card (the Studio page)
#   studio-map.png     the Map view of the session's project, drawn from the scanner's own output (the Studio page)
# and leave the flow take's frames for scene.py, which puts them into the overview video.
#
# No model session and no real transcript: every project, path, session and sentence is invented. The panel runs
# with its own projects root, runtime directory and temp directory, and a feed that answers the release version.
# The `claude` it finds on PATH is a stand-in (standin-claude.mjs): its `agents --json` lists the fixture's
# sessions and not this machine's, and a session the panel starts is played from a script through the real
# approval hook. Chrome is launched headless from a throwaway profile, so no banner or other window reaches a
# frame, and each take fails if the page shows this machine's home directory, user or name.
# macOS only (the ~/… shortening of /Users/Shared); needs node, ffmpeg and a Chrome, which stage.mjs finds.
#
#   bash packaging/studio-record/record.sh            # both, written into assets/
#   VERSION_SHOWN=3.1.0 bash packaging/…/record.sh    # the version the pictures are for
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
VERSION_SHOWN="${VERSION_SHOWN:-$(tr -d '[:space:]' < "$REPO/VERSION")}"
T="${CREW_RECORD_TMP:-${TMPDIR:-/tmp}/crewforth-studio-record}"
SNAP="$T/snapshot"; FILM="$T/film"; TOUR="$T/tour"
PORT="${CREW_RECORD_PORT:-7802}"; TOKEN="studio-record"
URL="http://127.0.0.1:$PORT/?token=$TOKEN"
WORK="/Users/Shared/dev"
# The panel shows where a transcript is, so the fixture's projects root is on screen. It lives beside the working
# directories, where it reads as ~/.claude/projects and names nobody; a root under this user's home would put the
# user's name in the picture, and the takes would rightly fail.
ROOT="${CREW_RECORD_ROOT:-/Users/Shared/.claude/projects}"
case "$ROOT" in "$HOME"|"$HOME"/*|*"$(id -un)"*) echo "record: the projects root $ROOT names this machine's user — choose another with CREW_RECORD_ROOT" >&2; exit 1 ;; esac
HERO="7f3c1d20-9a4e-4b6f-8c21-5d0e2a41b9c7"
ASKING="2b8e64f1-70c3-4a19-9e55-1c8d3f0b7a24"

for t in node ffmpeg ffprobe; do command -v "$t" >/dev/null || { echo "record: $t is not on PATH" >&2; exit 1; }; done

PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done; }
trap cleanup EXIT

mkdir -p "$T"
echo "record: fixture ($VERSION_SHOWN) -> $ROOT"
node "$HERE/fixture.mjs" "$ROOT" "$VERSION_SHOWN" >/dev/null
rm -rf "$SNAP"
node "$HERE/grow.mjs" --root "$ROOT" --snapshot "$SNAP" --resnapshot --reset >/dev/null

# The stand-in CLI: what is open on "this machine", and what a session started here says and asks for.
rm -rf "$T/bin"; mkdir -p "$T/bin"
printf '#!/bin/sh\nexec node "%s/standin-claude.mjs" "$@"\n' "$HERE" > "$T/bin/claude"
chmod +x "$T/bin/claude"
cat > "$T/fleet.json" <<JSON
[{"sessionId":"$HERO","pid":4101,"cwd":"$WORK/acme-payments-api","kind":"interactive","name":"payment-retries","status":"busy","startedAt":1790871817000},
 {"sessionId":"5c9d7e02-4b31-48af-a7c6-0d21e9f4a831","pid":4102,"cwd":"$WORK/acme-web-client","kind":"interactive","name":"bundle","status":"waiting","waitingFor":"approve Bash","startedAt":1790872227000},
 {"sessionId":"3a6f92c4-8e07-4d15-93b2-7c40ab1d5e69","pid":4103,"cwd":"$WORK/acme-data-platform","kind":"interactive","name":"rollups","status":"idle","startedAt":1790865117000}]
JSON
cat > "$T/turn.json" <<'JSON'
[{"at":0.3,"say":[{"type":"text","text":"Running the rotation tests before I go on."}]},
 {"at":0.6,"gate":{"id":"toolu_record_01","tool":"Bash","agentId":"a95c2708","agentType":"crew-test-expert","input":{"command":"npm test -- webhooks/rotation","description":"Run the rotation tests"}}}]
JSON

# The panel, isolated: its projects root is the fixture, its runtime state and its temp directory live under $T,
# and the version feed is a data: URL, so nothing is read from the network and no real session can appear.
# It is given a name of its own, so the one it would take from this machine is never on screen.
rm -rf "$T/runtime" "$T/tmp"; mkdir -p "$T/runtime" "$T/tmp"
PATH="$T/bin:$PATH" TMPDIR="$T/tmp" CREW_RECORD_FLEET="$T/fleet.json" CREW_RECORD_TURN="$T/turn.json" \
  CREW_STUDIO_TOKEN="$TOKEN" CREW_STUDIO_PROJECTS_ROOT="$ROOT" CREW_STUDIO_RUNTIME="$T/runtime" \
  CREW_UPDATE_URL="data:application/json,{\"latest\":\"$VERSION_SHOWN\"}" \
  node "$REPO/kit/studio/server/index.js" --port "$PORT" --name "demo-laptop" >"$T/server.log" 2>&1 &
PIDS+=($!)
for _ in $(seq 1 40); do curl -fs -o /dev/null "$URL" && break; sleep 0.25; done
curl -fs -o /dev/null "$URL" || { echo "record: the panel did not start — see $T/server.log" >&2; exit 1; }

# Take 1: the delegation grows while Chrome films it.
node "$HERE/grow.mjs" --root "$ROOT" --snapshot "$SNAP" --lead 8 --delay 1.5 --hold forever --heartbeat 8 >"$T/grow.log" 2>&1 &
GROW=$!; PIDS+=($GROW)
sleep 0.4
node "$HERE/shoot.mjs" --url "$URL" --secs 30 --fps 10 --w 1600 --h 833 --session "$HERO" --out "$FILM" --profile "$T/chrome-flow"
kill "$GROW" 2>/dev/null || true

# frames-dir width out: every frame of a take as one GIF.
gif() {
  ffmpeg -y -loglevel error -framerate 10 -i "$1/f%04d.png" \
    -vf "fps=10,scale=$2:-1:flags=lanczos,palettegen=max_colors=128:stats_mode=diff" "$T/pal.png"
  ffmpeg -y -loglevel error -framerate 10 -i "$1/f%04d.png" -i "$T/pal.png" \
    -lavfi "fps=10,scale=$2:-1:flags=lanczos [x]; [x][1:v] paletteuse=dither=none:diff_mode=rectangle" -loop 0 "$3"
}
# The last frame is the finished graph, and it is the still.
LAST="$(ls "$FILM"/f*.png | tail -1)"
cp "$LAST" "$REPO/assets/studio-graph.png"

# Take 2: the panel in use, on the finished fixture with its running agents kept live.
node "$HERE/grow.mjs" --root "$ROOT" --snapshot "$SNAP" --reset >/dev/null
bash "$HERE/refresh-running.sh" "$ROOT" >/dev/null
node "$HERE/tour.mjs" --url "$URL" --session "Duplicate settlements" --asking "$ASKING" --asking-cwd "$WORK/acme-payments-api" \
  --out "$TOUR" --profile "$T/chrome-tour"
gif "$TOUR" 1600 "$REPO/assets/studio-panels.gif"

# Take 3: the Models view, with the task card of the agent whose card ran again one model up.
node "$HERE/models.mjs" --url "$URL" --session "Duplicate settlements" --out "$REPO/assets/studio-models.png" --profile "$T/chrome-models"
node "$HERE/map.mjs" --url "$URL" --session "Duplicate settlements" --out "$REPO/assets/studio-map.png" --profile "$T/chrome-map"

for f in studio-panels.gif studio-graph.png studio-models.png studio-map.png; do
  printf 'record: assets/%-18s %9s bytes  %s\n' "$f" "$(wc -c < "$REPO/assets/$f" | tr -d ' ')" \
    "$(ffprobe -v error -select_streams v:0 -count_frames -show_entries stream=width,height,nb_read_frames -of csv=p=0 "$REPO/assets/$f")"
done
echo "record: the take for the overview video is in $FILM (python3 $HERE/scene.py --film $FILM …)"
