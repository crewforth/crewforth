#!/usr/bin/env bash
# workflow-check.sh — the repository's own GitHub workflows, held to four rules. Run by `verify.sh manifests`.
#
#   bash packaging/workflow-check.sh [workflow.yml ...]     (default: .github/workflows/*.yml)
#   rc 0 = every rule holds · 1 = a rule is broken (each one named, with file:line) · 2 = nothing to read
#
#   pin          every `uses:` of another repository names a full 40-character commit, with the version it is in a
#                `# vX.Y.Z` comment. A tag (`@v5`) moves when its owner moves it, and the next run executes that.
#   credentials  every actions/checkout sets `persist-credentials: false`, except in a workflow listed in PUSHERS:
#                a job that pushes needs them, and nothing else should leave a token in .git/config for a later
#                step to find.
#   permissions  every workflow names its token permissions at the top, and no level grants write-all. Without the
#                key the token gets the repository default, which may be write-all.
#   injection    no `${{ github.event.* }}`, `${{ github.head_ref }}`, `${{ inputs.* }}` or `${{ matrix.* }}` inside a
#                `run:` script: an issue title, a branch name, a dispatch input or a discovered matrix value is text
#                someone else wrote, and inside `run:` it becomes shell. Pass it through `env:` and quote the variable.
#                Not seen: a `${{` split from its name across two lines.
#
# YAML is read by line and indentation, which is what these files use; it is not a YAML parser, and a workflow that
# needs one to be read correctly should be written so this can read it.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
PUSHERS="stats.yml"

files=("$@")
[ "${#files[@]}" -gt 0 ] || { shopt -s nullglob; files=("$HERE"/.github/workflows/*.yml "$HERE"/.github/workflows/*.yaml); }
[ "${#files[@]}" -gt 0 ] || { echo "workflow-check: no workflow to read" >&2; exit 2; }

bad=""; nuses=0; nco=0
for f in "${files[@]}"; do
  base="${f##*/}"; pusher=0; case " $PUSHERS " in *" $base "*) pusher=1 ;; esac
  out="$(LC_ALL=C awk -v f="$base" -v pusher="$pusher" '
    function ind(s) { match(s, /[^ ]/); return RSTART - 1 }
    function flush_co() { if (co && !pc && !pusher) print "credentials " f ":" co ": actions/checkout without persist-credentials: false"; co = 0 }
    # Text someone else wrote: the event payload, a branch name, a dispatch input, a discovered matrix value.
    function untrusted(s) { return s ~ /\$\{\{[ ]*(github\.event\.|github\.head_ref|inputs\.|matrix\.)/ }
    { line = $0; sub(/\r$/, "", line) }
    line ~ /^[ ]*- / { dash = ind(line) }
    line ~ /^permissions:/ { perms = 1; if (line ~ /write-all/) print "permissions " f ":" NR ": write-all" }
    line ~ /^[ ]+permissions:[ ]*write-all/ { print "permissions " f ":" NR ": write-all" }
    # A checkout step ends at the next line indented no deeper than its own dash (the next step, or less).
    co && line !~ /^[ ]*$/ && NR > co && ind(line) <= codash { flush_co() }
    co && line ~ /^[ ]*persist-credentials:[ ]*["\047]?false["\047]?[ ]*(#.*)?$/ { pc = 1 }
    line ~ /^[ ]*(- )?uses:/ {
      u = line; sub(/^[ ]*(- )?uses:[ ]*/, "", u)
      if (u !~ /^\.\//) {
        print "count-uses"
        # A docker image is pinned by its digest; anything else by a commit, measured by length (`{40}` is not
        # understood by every awk).
        if (u ~ /^docker:\/\//) { if (u !~ /@sha256:[0-9a-f]+/) print "pin " f ":" NR ": " u }
        else {
          sha = u; sub(/^[^@]*@/, "", sha); sub(/[ #].*$/, "", sha)
          if (u !~ /^[A-Za-z0-9._-]+\/[A-Za-z0-9._\/-]+@[0-9a-f]+[ ]+#[ ]*v[0-9]/ || length(sha) != 40) print "pin " f ":" NR ": " u
        }
      }
      if (u ~ /^actions\/checkout@/) { flush_co(); co = NR; pc = 0; codash = dash; print "count-co" }
    }
    # run: scripts, inline or block. A block ends at the first line indented no deeper than the run: key itself,
    # so an env: written after it is not read as script.
    inrun && line !~ /^[ ]*$/ && ind(line) <= runkey { inrun = 0 }
    inrun && untrusted(line) { print "injection " f ":" NR ": " line }
    line ~ /^[ ]*(- )?run:/ {
      r = line; sub(/^[ ]*(- )?run:[ ]*/, "", r)
      runkey = ind(line) + (line ~ /^[ ]*- / ? 2 : 0)
      if (r ~ /^[|>]/) inrun = 1
      else if (untrusted(r)) print "injection " f ":" NR ": " line
    }
    END { flush_co(); if (!perms) print "permissions " f ": no top-level permissions key" }
  ' "$f")"
  nuses=$((nuses + $(printf '%s\n' "$out" | grep -c '^count-uses$')))
  nco=$((nco + $(printf '%s\n' "$out" | grep -c '^count-co$')))
  b="$(printf '%s\n' "$out" | grep -v '^count-' | grep . || true)"
  [ -n "$b" ] && bad="$bad$b"$'\n'
done

if [ "$nuses" -eq 0 ]; then echo "workflow-check: read ${#files[@]} workflow(s) and found no uses: line — the reader is broken, not the workflows" >&2; exit 1; fi
if [ -n "$bad" ]; then
  printf 'workflow-check: %s\n' "the workflows break a rule (pin · credentials · permissions · injection):"
  printf '%s' "$bad" | sed 's/^/  /'
  exit 1
fi
echo "workflow-check: ${#files[@]} workflows · $nuses uses: pinned to a commit · $nco checkouts drop their credentials (or push: $PUSHERS) · permissions named · no event or matrix text in run:"
exit 0
