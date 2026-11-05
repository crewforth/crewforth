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
[ "${1:-}" = write ] || exec "$NODE" "$d/findings.mjs" "$@"

# A write is also one REVIEW ROUND, and the round is logged here, not in findings.mjs (which reads no repository on
# purpose): one line per written document in the git directory, so it is never committed —
#   <time> <branch> <name> <round> <critical> <high> <medium> <low> <info>
# The round is 1 + the lines already there for the same branch and name. It is what tells whether the late rounds of
# a review still find anything above low (/crew-review § Rounds). Outside a repository nothing is logged; a --root
# inside one logs there. Two writes at the same moment may share a round number: a log, not a lock.
"$NODE" "$d/findings.mjs" "$@"; rc=$?
[ "$rc" = 0 ] || exit "$rc"
root=.; name=""; shift
while [ $# -gt 0 ]; do case "$1" in --root) root="${2:-.}"; shift ;; --verified) ;; *) [ -z "$name" ] && name="$1" ;; esac; shift; done
log="$(git -C "$root" rev-parse --path-format=absolute --git-path crewforth-review-rounds.tsv 2>/dev/null)" || exit 0
# A git before 2.31 echoes the unknown --path-format back on a line of its own: that is no path to write to.
case "$log" in *$'\n'*|-*|'') exit 0 ;; esac
# symbolic-ref, not rev-parse: it names a branch with no commit yet too. Never empty: an empty tab-separated field
# collapses when the line is read back, and every round then counted as the first (found by the self-check).
br="$(git -C "$root" symbolic-ref --short -q HEAD 2>/dev/null)" || br=""; [ -n "$br" ] || br=-
# Any branch name git allows is logged; only a tab or a newline, which would split the line, is not.
case "$br" in *$'\t'*|*$'\n'*) exit 0 ;; esac
n=1; [ -f "$log" ] && while IFS=$'\t' read -r _ b nm _; do [ "$b" = "$br" ] && [ "$nm" = "$name" ] && n=$((n+1)); done < "$log"
sev="$("$NODE" -e 'const f=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).findings||[];const c={critical:0,high:0,medium:0,low:0,info:0};for(const x of f)if(x.severity in c)c[x.severity]++;process.stdout.write([c.critical,c.high,c.medium,c.low,c.info].join("\t"))' "$root/.crewforth/$name.json" 2>/dev/null)" || exit 0
printf '%s\t%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$br" "$name" "$n" "$sev" >> "$log" 2>/dev/null
exit 0
