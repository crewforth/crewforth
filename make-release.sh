#!/usr/bin/env bash
# Produces a private release artifact: tar.gz's ONLY the distribution payload (start.sh +
# kit/ + VERSION). Uses `git archive HEAD` -> no uncommitted/secret file leaks; via the
# WHITELIST, root CLAUDE.md / docs/ / .github / make-release.sh / CHANGELOG / README NEVER get in
# (§4.3 privacy + §4.1/§4.2 trace scan -> "rule=gate": if a single file outside the whitelist
# appears, production STOPS).
#
# Usage:  bash make-release.sh          -> dist/crewforth-<VERSION>.tgz
#         bash make-release.sh 3.2.0-rc.1  -> dist/crewforth-3.2.0-rc.1.tgz whose VERSION says 3.2.0-rc.1 (an rc: the
#         repository keeps X.Y.Z, the archive carries the version it is, so an install knows it holds an rc)
# Publish (SEPARATE + EXPLICIT approval; does not bump the version, makes the existing tag downloadable):
#   gh release create v<VER> dist/crewforth-<VER>.tgz -R <owner>/<repo> \
#     --title "v<VER>" --notes-file CHANGELOG.md
# Consumer (with private access):
#   gh release download v<VER> -p '*.tgz' && tar xzf crewforth-*.tgz && bash start.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

[ -f VERSION ] || { echo "ERROR: root VERSION file is missing." >&2; exit 1; }
VER="$(tr -d ' \n\r' < VERSION)"
[ -n "$VER" ] || { echo "ERROR: VERSION is empty." >&2; exit 1; }
STAMP="${1:-}"
if [ -n "$STAMP" ]; then
  # Only an rc of the committed version: X.Y.Z-rc.N with X.Y.Z = VERSION. Anything else is a mistake, not a stamp.
  _n="${STAMP#"$VER"-rc.}"
  [ "$_n" != "$STAMP" ] && [ -n "$_n" ] && [ -z "${_n//[0-9]/}" ] \
    || { echo "ERROR: '$STAMP' is not an rc of VERSION $VER (X.Y.Z-rc.N)." >&2; exit 1; }
  VER="$STAMP"
fi
OUT="dist/crewforth-$VER.tgz"
mkdir -p dist

# Only tracked whitelist paths (from HEAD) — no leak even if the working tree is dirty. A stamped rc writes its
# VERSION as a virtual file in place of the committed one (git 2.39+).
if [ -n "$STAMP" ]; then
  git archive --format=tar.gz -o "$OUT" --add-virtual-file="VERSION:$VER"$'\n' HEAD start.sh adopt.sh kit
else
  git archive --format=tar.gz -o "$OUT" HEAD start.sh adopt.sh kit VERSION
fi

# GATE: there must be no entry outside the whitelist.
bad="$(tar tzf "$OUT" | grep -vE '^(start\.sh$|adopt\.sh$|kit($|/)|VERSION$)' || true)"
if [ -n "$bad" ]; then
  echo "ERROR: a file outside the whitelist leaked into the artifact (§4.3):" >&2
  printf '  %s\n' $bad >&2
  rm -f "$OUT"; exit 1
fi

echo "Produced: $OUT ($(du -h "$OUT" | cut -f1)) · $(tar tzf "$OUT" | wc -l | tr -d ' ') entries"
echo "Whitelist verified: only start.sh + adopt.sh + kit/ + VERSION"
echo
echo "To publish (SEPARATE approval — §4.4):"
echo "  gh release create v$VER \"$OUT\" -R Crewforth/crewforth --title \"v$VER\" --notes-file CHANGELOG.md"
