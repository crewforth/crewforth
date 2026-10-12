#!/usr/bin/env bash
# Should npm's `next` dist-tag move to a final release that was just published?
#
# A final publishes as `latest`, an rc as `next`. After a final, `next` still names whatever rc (or older final) it
# named before, so `crewforth@next` would install something OLDER than `crewforth@latest`. This says whether to move it.
#
# Usage: bash packaging/npm-next-tag.sh <published-version> <what-next-names-now>
# Prints `move` (next is older, or names nothing) or `keep` (next is the same or newer: an rc of a later version).
# Exit 0 either way · 2 usage, or a version that is not X.Y.Z or X.Y.Z-rc.N (nothing is guessed about other shapes).
set -euo pipefail
NEW="${1:-}"; CUR="${2:-}"
[ -n "$NEW" ] || { echo "usage: npm-next-tag.sh <published-version> <what-next-names-now>" >&2; exit 2; }
[ -n "$CUR" ] || { echo move; exit 0; }
RE='^([0-9]+)\.([0-9]+)\.([0-9]+)(-rc\.([0-9]+))?$'
key(){  # X.Y.Z[-rc.N] -> four numbers; a final sorts after every rc of its own version
  [[ "$1" =~ $RE ]] || { echo "npm-next-tag: '$1' is not X.Y.Z or X.Y.Z-rc.N" >&2; exit 2; }
  if [ -n "${BASH_REMATCH[4]}" ]; then K=("${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" 0 "${BASH_REMATCH[5]}")
  else K=("${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" 1 0); fi
}
key "$NEW"; A=("${K[@]}"); key "$CUR"; B=("${K[@]}")
for i in 0 1 2 3 4; do
  if [ "${B[i]}" -lt "${A[i]}" ]; then echo move; exit 0; fi
  if [ "${B[i]}" -gt "${A[i]}" ]; then echo keep; exit 0; fi
done
echo keep
