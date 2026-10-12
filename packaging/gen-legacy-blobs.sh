#!/usr/bin/env bash
# Generate kit/legacy-blobs.tsv: every agents/commands/skills file Crewforth shipped in v1.0.0–v2.x whose component is
# not in the payload today, with the git blob id of each version that shipped. The updater decides "the kit's own,
# untouched" by these ids: a file whose bytes (or bytes with CR removed — a Windows editor, an autocrlf copy) hash to
# one of its path's ids is exactly what an old installer wrote, anything else is the user's and is left alone.
# From git, never by hand: a guessed "unchanged" moves a user's edit aside.
#
#   bash packaging/gen-legacy-blobs.sh                  # rewrite kit/legacy-blobs.tsv and kit/owned-blobs.tsv
#   bash packaging/gen-legacy-blobs.sh --stdout         # print the legacy list (the smoke check compares it to the shipped file)
#   bash packaging/gen-legacy-blobs.sh --stdout-owned   # print the owned list (the same check)
#
# THE SECOND LIST, kit/owned-blobs.tsv: the three flat files Crewforth owns and still ships — .claude/AGENT_TEMPLATE.md,
# .claude/README.md and .claude/DISCIPLINE.md — with the blob id of every version a final release shipped. The updater
# rewrites them on every run; with this list it can tell a copy nobody touched (refresh it, say nothing) from one the
# user edited (keep it in .claude/.legacy-backup/ first, and name it). DISCIPLINE.md is not a file of the payload: an
# installer writes it as the part of CLAUDE.md above the `<!-- KIT:DISCIPLINE-END` line, so its id is the hash of that
# part (releases before v1.1.0 have no such line and wrote no DISCIPLINE.md). Measured before the list was trusted: the
# real installers of v1.0.0, v1.4.0, v1.8.0, v2.13.0, v3.0.0 and v3.0.3 wrote each of the three exactly as that.
# Releases BELOW the VERSION file only: the version being prepared is compared with the payload itself, and the list
# then changes exactly when VERSION moves, in the commit that moves it, not when a tag appears.
#
# Measured before the list was trusted: seven installs by the real installers (v1.0.0, v1.4.0, v1.8.0, v2.13.0;
# dotnet, generic, frontend) wrote every legacy file byte-for-byte as its tag's blob, with one exception this
# script folds in — a generic install copies agents-optional/backend-expert-generic.md over the backend agent.
# 2.x renamed devarch-module to cqrs-aop-module keeping its content, so devarch's blobs are valid under the new
# path too. No shipped blob contains a CR (checked here on every run), so "strip CR, then hash" is sound.
# cqrs-aop-module / devarch-module rows are for ONE decision only — whether the updater may vouch for the pattern skill
# (3.0 keeps it as the project's own). The legacy sweep must never move them aside; it excludes both by name.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
OUT="$ROOT/kit/legacy-blobs.tsv"; OWNED="$ROOT/kit/owned-blobs.tsv"; TO_STDOUT=0
case "${1:-}" in --stdout) TO_STDOUT=1 ;; --stdout-owned) TO_STDOUT=2 ;; '') ;; *) echo "usage: gen-legacy-blobs.sh [--stdout | --stdout-owned]" >&2; exit 2 ;; esac
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Final releases before 3.0 only (no rc/beta). Every one of them kept the payload in claude-starter/ (66 of 66);
# kit/ is matched too so the rule does not depend on that.
TAGS=(); while IFS= read -r t; do TAGS+=("$t"); done < <(git tag -l 'v1.*' 'v2.*' --sort=v:refname | grep -E '^v[12]\.[0-9]+\.[0-9]+$')
[ "${#TAGS[@]}" -gt 0 ] || { echo "gen-legacy-blobs: no v1/v2 tags in this clone (shallow?) — nothing to generate from" >&2; exit 2; }

# 1) path <TAB> blob <TAB> tag, for every shipped file and every generic-variant copy
for t in "${TAGS[@]}"; do
  git ls-tree -r "$t" | awk -v t="$t" -F'\t' '
    { split($1, m, " "); p = $2
      if (p ~ /^(claude-starter|kit)\/(agents|commands|skills)\//) { sub(/^(claude-starter|kit)\//, "", p); print p "\t" m[3] "\t" t "\tshipped" }
      else if (p ~ /^(claude-starter|kit)\/agents-optional\/backend-expert-generic\.md$/) {
        split(substr(t, 2), v, "."); a = (v[1] == 1 && v[2] == 0 && v[3] <= 4) ? "agents/backend-expert-cck.md" : "agents/backend-expert-csk.md"
        print a "\t" m[3] "\t" t "\tgeneric-variant" } }'
done > "$TMP/all"

# 2) devarch-module renamed in place to cqrs-aop-module (content kept): its blobs are valid there as well
awk -F'\t' '$1 ~ /^skills\/devarch-module\// { p = $1; sub(/^skills\/devarch-module\//, "skills/cqrs-aop-module/", p); print p "\t" $2 "\t" $3 "\tdevarch-renamed" }' "$TMP/all" >> "$TMP/all"

# 3) components the payload ships today are refreshed by the updater, not "legacy"
{ for d in kit/skills/*/; do d="${d%/}"; echo "${d#kit/}"; done
  for f in kit/agents/*.md; do echo "${f#kit/}"; done
  for f in kit/commands/*.md; do [ -e "$f" ] || continue; echo "${f#kit/}"; done; } | sort -u > "$TMP/now"   # `&&` as the last test would fail the pipeline under set -e
awk -F'\t' 'NR == FNR { now[$1] = 1; next }
  { n = split($1, a, "/"); c = (a[1] == "skills") ? a[1] "/" a[2] : $1; if (!(c in now)) print c "\t" $0 }' "$TMP/now" "$TMP/all" > "$TMP/legacy"

# 4) no shipped blob may carry a CR — the updater's CR-stripped comparison rests on it
bad=0; while IFS= read -r b; do
  [ "$(git cat-file -p "$b" | tr -dc '\r' | wc -c | tr -d ' ')" = 0 ] || { echo "gen-legacy-blobs: blob $b contains CR — a CR-stripped match would be wrong for it" >&2; bad=1; }
done < <(cut -f3 "$TMP/legacy" | sort -u)
[ "$bad" = 0 ] || exit 1

# 5) one row per (install path, blob): the first and last tag that shipped it, and how it got there
{ printf '# Generated by packaging/gen-legacy-blobs.sh from git tags %s..%s — do not edit by hand.\n' "${TAGS[0]}" "${TAGS[${#TAGS[@]}-1]}"
  printf '# skills/cqrs-aop-module and skills/devarch-module rows decide trust only; the legacy sweep never moves them.\n'
  printf '# component\tinstall_path\tblob_sha1\tfirst_tag\tlast_tag\tsource\n'
  # First/last by version, not by row order: a devarch blob that equals a cqrs-aop-module blob arrives out of order.
  awk -F'\t' 'function vk(t,  v) { split(substr(t, 2), v, "."); return v[1] * 1000000 + v[2] * 1000 + v[3] }
    { k = $2 "\t" $3; if (!(k in f)) { f[k] = $4; l[k] = $4; c[k] = $1; s[k] = $5; o[++n] = k }
      if (vk($4) < vk(f[k])) f[k] = $4; if (vk($4) > vk(l[k])) l[k] = $4
      if (index("+" s[k] "+", "+" $5 "+") == 0) s[k] = s[k] "+" $5 }
    END { for (i = 1; i <= n; i++) { k = o[i]; split(k, x, "\t"); print c[k] "\t.claude/" x[1] "\t" x[2] "\t" f[k] "\t" l[k] "\t" s[k] } }' "$TMP/legacy" \
    | LC_ALL=C sort -t "$(printf '\t')" -k2,2 -k3,3
} > "$TMP/out"

# 6) the owned list: the three flat files, from every final release below VERSION
VER="$(tr -d ' \r\n' < VERSION)"
OTAGS=(); while IFS= read -r t; do OTAGS+=("$t"); done < <(git tag -l 'v[0-9]*' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' \
  | awk -v cur="$VER" 'function vk(s,  v) { split(s, v, "."); return v[1] * 1000000 + v[2] * 1000 + v[3] } vk(substr($0, 2)) < vk(cur)' | sort -t. -k1.2,1n -k2,2n -k3,3n)
[ "${#OTAGS[@]}" -gt 0 ] || { echo "gen-legacy-blobs: no final release tag below VERSION $VER in this clone — the owned list cannot be generated" >&2; exit 2; }
for t in "${OTAGS[@]}"; do
  for d in kit claude-starter; do
    git rev-parse -q --verify "$t:$d" >/dev/null 2>&1 || continue
    for f in AGENT_TEMPLATE.md README.md; do
      b="$(git rev-parse -q --verify "$t:$d/$f" 2>/dev/null)" && printf '.claude/%s\t%s\t%s\n' "$f" "$b" "$t"
    done
    if git cat-file -e "$t:$d/CLAUDE.md" 2>/dev/null; then
      git show "$t:$d/CLAUDE.md" > "$TMP/claude.md"
      if grep -q '^<!-- KIT:DISCIPLINE-END' "$TMP/claude.md"; then
        awk '/^<!-- KIT:DISCIPLINE-END/{exit} {print}' "$TMP/claude.md" > "$TMP/disc.md"
        [ "$(tr -dc '\r' < "$TMP/disc.md" | wc -c | tr -d ' ')" = 0 ] || { echo "gen-legacy-blobs: the discipline of $t contains CR" >&2; exit 1; }
        printf '.claude/DISCIPLINE.md\t%s\t%s\n' "$(git hash-object --stdin < "$TMP/disc.md")" "$t"
      fi
    fi
  done
done > "$TMP/oall"
bad=0; while IFS= read -r b; do
  git cat-file -e "$b" 2>/dev/null || continue                      # a discipline id is a hash of text, not an object of the repository
  [ "$(git cat-file -p "$b" | tr -dc '\r' | wc -c | tr -d ' ')" = 0 ] || { echo "gen-legacy-blobs: owned blob $b contains CR" >&2; bad=1; }
done < <(cut -f2 "$TMP/oall" | sort -u)
[ "$bad" = 0 ] || exit 1
{ printf '# Generated by packaging/gen-legacy-blobs.sh from the final release tags %s..%s (below VERSION %s) — do not edit by hand.\n' "${OTAGS[0]}" "${OTAGS[${#OTAGS[@]}-1]}" "$VER"
  printf '# The flat files Crewforth owns: a copy whose bytes (CR aside) are one of these ids was never edited.\n'
  printf '# install_path\tblob_sha1\tfirst_tag\tlast_tag\n'
  awk -F'\t' 'function vk(t,  v) { split(substr(t, 2), v, "."); return v[1] * 1000000 + v[2] * 1000 + v[3] }
    { k = $1 "\t" $2; if (!(k in f)) { f[k] = $3; l[k] = $3; o[++n] = k }
      if (vk($3) < vk(f[k])) f[k] = $3; if (vk($3) > vk(l[k])) l[k] = $3 }
    END { for (i = 1; i <= n; i++) { k = o[i]; print k "\t" f[k] "\t" l[k] } }' "$TMP/oall" \
    | LC_ALL=C sort -t "$(printf '\t')" -k1,1 -k2,2
} > "$TMP/owned"

case "$TO_STDOUT" in
  1) cat "$TMP/out" ;;
  2) cat "$TMP/owned" ;;
  *) cp "$TMP/out" "$OUT"; cp "$TMP/owned" "$OWNED" ;;
esac
echo "gen-legacy-blobs: $(grep -vc '^#' "$TMP/out") rows, $(grep -v '^#' "$TMP/out" | cut -f1 | sort -u | wc -l | tr -d ' ') components, ${#TAGS[@]} tags · owned: $(grep -vc '^#' "$TMP/owned") rows, ${#OTAGS[@]} tags below $VER" >&2
