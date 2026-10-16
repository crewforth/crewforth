#!/usr/bin/env bash
# SessionStart hook (startup only) — when a newer kit version is published, have Claude ASK the user whether to
# update now (Update · Later · Skip this version), and never make the session wait to find out.
#
# The gap it closes: a fix only reaches a project when somebody REMEMBERS to run /crew-update. Nothing surfaces a
# release, so shipped fixes sit unused in installs that would want them.
#
# The rule that shapes every line below: **this hook performs no network I/O in the foreground.** A SessionStart
# hook blocks the session until it returns, its timeout is 60s, and the version lookup is exactly the kind of call
# that hangs behind a corporate proxy or an offline machine. That is the same class of failure as the route-hint
# fork storm (2.0.1): Crewforth spending the user's session-open budget and getting blamed on the CLI. So:
#   - the foreground reads ONE cache file and exits — no curl, no npm, no subshell loop;
#   - when that cache is older than a day it starts a DETACHED refresher whose result is used by the NEXT session.
#     A version notice is not urgent; being one session late costs nothing, blocking costs everything.
#   - if the refresher is killed (session ends first) nothing is written and the next startup simply tries again.
#     The worst case is a notice that arrives late or not at all — never a hang, never a wrong version.
#
# Deliberate scope:
#   - `startup` ONLY. On resume/clear/compact this would re-announce the same thing inside one session, and the
#     session-start channel also carries the rehydrate and trust notices — training the user to skim it is a cost
#     paid by those two, not by this one.
#   - BOTH editions, each on its own channel. A project install compares `.claude/VERSION` against the npm dist-tag
#     and points at `/crew-update`; a plugin install compares its own `.claude-plugin/plugin.json` against the
#     marketplace repo's copy — the number that will actually reach it — and points at `claude plugin update`.
#     The plugin's cache is user-level (`$XDG_CACHE_HOME`), the one case where Crewforth's "everything inside the
#     repo" rule cannot apply, because a plugin install is not inside one. With both present the project install
#     wins and the plugin copy stays quiet, so one release is never announced twice.
#   - A QUESTION, never an action. Nothing in this file installs anything: no npx, no npm, no updater — the update
#     runs only when the user picks "Update", through /crew-update (or the plugin command). A silent auto-update is
#     ruled out on purpose: it rewrites the very gates Crewforth is made of (hooks, settings.json, the discipline), a
#     compromised package would run itself in every project, and a team sharing .claude/ would get a diff nobody
#     asked for. smoke-test.sh pins that this file runs none of those commands.
#   - Asked at most once a day per version. Asking is recorded when the question goes out, so a question the user
#     closes without answering counts as "Later". `--answer later|skip <version>` records the reply (Claude runs
#     it, the hook cannot see the answer): "skip" silences that version for good — a newer one asks again.
#   - Silent when nobody can answer: CI set, CREW_NO_UPDATE_CHECK=1, or a session Claude Code marks unattended
#     (CLAUDE_CODE_SESSION_ATTENDED=0 — measured: `claude -p` sets 0, the terminal and desktop app set 1; the
#     variable is undocumented, so the question text also tells Claude not to ask when nobody can answer).
#   - Opt out entirely with CREW_NO_UPDATE_CHECK=1 — an outbound request nobody asked for is not acceptable in every
#     environment, and the answer to that is a switch, not a justification.
#
# The version string is treated as untrusted input: it comes off the network, is filtered to [0-9A-Za-z.-], and must
# look like a release before it is ever printed into the model's context.
set -uo pipefail
# The 2.x names of the variables a user can set still work (one helper: eval/lib/crew-env.sh).
_crew_d="${BASH_SOURCE%/*}"; [ "$_crew_d" = "${BASH_SOURCE}" ] && _crew_d=.
[ -f "$_crew_d/../eval/lib/crew-env.sh" ] && . "$_crew_d/../eval/lib/crew-env.sh"
# How an install's own version is read and ordered (an rc before its final): one definition, eval/lib/version.sh.
[ -f "$_crew_d/../eval/lib/version.sh" ] && . "$_crew_d/../eval/lib/version.sh"; unset _crew_d

URL="${CREW_UPDATE_URL:-https://registry.npmjs.org/-/package/crewforth/dist-tags}"
# plugin-stable, not main: the marketplace installs the plugin from that branch, and only an approved release
# moves it forward. Reading main would announce a release before the plugin channel can deliver it.
PLUGIN_URL="${CREW_UPDATE_URL:-https://raw.githubusercontent.com/Crewforth/crewforth/plugin-stable/plugin/.claude-plugin/plugin.json}"
MAX_AGE="${CREW_UPDATE_MAX_AGE:-86400}"      # one day between checks

# DIGITS AND DOTS, exactly three fields — nothing else survives to be printed. Deliberately stricter than semver:
# the value arrives off the network and ends up inside a MODEL's context, and `latest` is never a pre-release, so
# accepting `9.9.9-<anything>` would buy nothing and hand a compromised endpoint a sentence to write. The control
# characters go first (a newline would let one response become several lines), then the shape decides.
sane_version(){
  v="${1:-}"; v="${v//[!0-9A-Za-z.-]/}"   # same character class `tr -cd` kept, without the process
  case "$v" in
    *[!0-9.]*)              return 1 ;;   # letters, dashes, anything but a number
    [0-9]*.[0-9]*.[0-9]*.*) return 1 ;;   # four or more fields
    [0-9]*.[0-9]*.[0-9]*)   printf '%s' "$v" ;;
    *)                      return 1 ;;
  esac
}

# ---- detached half: fetch and cache. Runs with no terminal, no stdout, nobody waiting on it. ------------------
# Takes its target explicitly (`--refresh <state-dir> [url] [json-key]`) because the two editions ask different
# endpoints different questions: the installer edition asks npm for the `latest` dist-tag, the plugin edition asks
# the marketplace repo's own plugin.json for its `version`. Each edition therefore learns about the release on the
# channel that will actually deliver it, rather than through a number that merely tends to match.
if [ "${1:-}" = "--refresh" ]; then
  ST="${2:-}"
  RURL="${3:-$URL}"
  RKEY="${4:-latest}"
  [ -d "$ST" ] || exit 0
  command -v curl >/dev/null 2>&1 || exit 0
  BODY="$(curl -fsS --max-time 10 "$RURL" 2>/dev/null)" || exit 0
  V="$(sane_version "$(printf '%s' "$BODY" | sed -n "s/.*\"$RKEY\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1)")" || exit 0
  T="$(date +%s 2>/dev/null || echo 0)"
  # Written whole or not at all: a refresher killed mid-flight must never leave a half-line the next startup reads.
  TMP="$ST/.update-check.$$"
  printf '%s %s\n' "$V" "$T" > "$TMP" 2>/dev/null && mv -f "$TMP" "$ST/update-check" 2>/dev/null
  rm -f "$TMP" 2>/dev/null
  exit 0
fi

# Where this edition keeps its state: the project install next to its hooks (.claude/.state); the plugin edition,
# which serves every project and has no repo to write into, at user level.
HERE="$(cd "$(dirname "$0")" && pwd)"
SELF="$HERE/$(basename "$0")"
IS_PLUGIN=0; [ -f "$HERE/../.claude-plugin/plugin.json" ] && IS_PLUGIN=1   # which COPY of this file is running
if [ "$IS_PLUGIN" = 1 ]; then PSTATE="${XDG_CACHE_HOME:-$HOME/.cache}/crewforth"
else PSTATE="$HERE/../.state"; fi

# ---- the reply: `--answer later|skip <version>`, run by Claude after the user chose. ---------------------------
# Validated like everything else that came near the network: a version that is not a release number is refused.
if [ "${1:-}" = "--answer" ]; then
  AV="$(sane_version "${3:-}")" || { echo "session-update-check: not a version: ${3:-}" >&2; exit 2; }
  mkdir -p "$PSTATE" 2>/dev/null || exit 1
  case "${2:-}" in
    later) printf '%s %s\n' "$AV" "$(date +%s 2>/dev/null || echo 0)" > "$PSTATE/update-asked" ;;
    skip)  printf '%s\n' "$AV" > "$PSTATE/update-skip" ;;
    *) echo "usage: session-update-check.sh --answer later|skip <version>" >&2; exit 2 ;;
  esac
  exit 0
fi

# ---- foreground half: one file read, then a decision. ---------------------------------------------------------
[ -n "${CREW_NO_UPDATE_CHECK:-}" ] && exit 0
[ -n "${CI:-}" ] && exit 0                                   # a runner has nobody to ask
[ "${CLAUDE_CODE_SESSION_ATTENDED:-}" = 0 ] && exit 0      # claude -p / an SDK run: nobody to ask

IN=""
[ ! -t 0 ] && IN="$(cat 2>/dev/null || true)"
# `startup` only. The matcher already says so; this is the same rule in the hook itself, so a wiring that also
# matched resume, clear, compact or fork (a forked session, Claude Code 2.1.214+) cannot ask the question again.
case "$IN" in *'"source"'*) _src="${IN#*\"source\"}"; _src="${_src#*\"}"; _src="${_src%%\"*}"
  [ "$_src" = startup ] || exit 0 ;; esac
ROOT="${CLAUDE_PROJECT_DIR:-}"
[ -n "$ROOT" ] || { _r="${IN#*\"cwd\"}"; [ "$_r" != "$IN" ] && { _r="${_r#*\"}"; ROOT="${_r%%\"*}"; }; }
[ -n "$ROOT" ] || ROOT="$PWD"
# Windows hands this over as a native path, and the stdin copy arrives JSON-encoded on top (`C:\\Repos\\app`).
# Undo the escaping, then fold the separators; both are no-ops on POSIX. Skipping this is how a hook resolves a
# directory that cannot exist and then reports nothing, forever.
ROOT="${ROOT//\\\\//}"; ROOT="${ROOT//\\//}"

# Which edition is asking, and therefore: what is installed, what counts as published, and how the user updates.
# A project install ALWAYS wins — when both are present the plugin copy of this hook goes quiet rather than
# asking about the same release a second time from the other direction.
CL="$ROOT/.claude"
PR_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
PR_ROOT="${PR_ROOT//\\\\//}"; PR_ROOT="${PR_ROOT//\\//}"
PJSON="$PR_ROOT/.claude-plugin/plugin.json"

# Both SessionStart hooks run at once, so "the project wins" has to be decided by each copy on its own: the
# plugin's copy steps aside whenever a project install is present, instead of asking the project's question too.
if [ "$IS_PLUGIN" = 1 ] && [ -f "$CL/VERSION" ]; then exit 0; fi
if [ -f "$CL/VERSION" ]; then
  # The install's own file, so an rc (X.Y.Z-rc.N) is a version here; what npm answers is still held to X.Y.Z.
  read -r _cv < "$CL/VERSION" 2>/dev/null || _cv=""
  declare -F crew_local_version >/dev/null || exit 0
  CUR="$(crew_local_version "$_cv")" || exit 0
  STATE="$CL/.state"                                            # repo-local: the install lives in the repo
  FEED="${CREW_UPDATE_URL:-$URL}"; KEY=latest; EDITION=project
  ANSWER='bash .claude/hooks/session-update-check.sh --answer'
elif [ -n "$PR_ROOT" ] && [ -f "$PJSON" ]; then
  # The plugin edition has a version too — its own manifest — and the number that will actually reach it is the one
  # in the marketplace repo, not npm's. They are bumped by the same release commit, but "tends to match" is not a
  # source: a channel should be told about the release by the channel that delivers it.
  CUR="$(sane_version "$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$PJSON" 2>/dev/null | head -1)")" || exit 0
  # No repo to write into (a plugin serves every project), so the cache is user-level. This is the one place
  # Crewforth's "everything stays inside the repo" rule does not apply, because a plugin install is not inside one.
  STATE="${XDG_CACHE_HOME:-$HOME/.cache}/crewforth"
  FEED="${CREW_UPDATE_URL:-$PLUGIN_URL}"; KEY=version; EDITION=plugin
  ANSWER="bash \"$PR_ROOT/hooks/session-update-check.sh\" --answer"
else
  exit 0                                                        # neither edition -> nothing to compare
fi

# The cache must be ONE line, `<version> <epoch>`, and nothing else. Reading only its first line let a second line
# ride along unchecked: `3.1.0` on line one passed, and whatever followed it was never looked at. A file that is
# not exactly that shape is ignored whole (the refresher rewrites it whole).
CACHE="$STATE/update-check"
LATEST=""; STAMP=0; _raw=""
if [ -f "$CACHE" ]; then
  IFS= read -r -d '' _raw < "$CACHE" 2>/dev/null || true
  _raw="${_raw%$'\n'}"
  case "$_raw" in
    *$'\n'*|*$'\r'*) _raw="" ;;                                   # more than one line: not ours
  esac
  LATEST="${_raw%% *}"; STAMP="${_raw#* }"
  [ "$LATEST" = "$_raw" ] && STAMP=""
  STAMP="${STAMP//[!0-9]/}"
fi
[ -n "$STAMP" ] || STAMP=0

NOW="$(date +%s 2>/dev/null || echo 0)"
if [ "$NOW" -gt 0 ] && [ "$((NOW - STAMP))" -gt "$MAX_AGE" ] && command -v curl >/dev/null 2>&1; then
  mkdir -p "$STATE" 2>/dev/null || true
  # stdin/stdout/stderr all detached. An inherited stdout keeps the hook's pipe open after it exits, and a caller
  # reading to EOF then waits on a curl that has nothing to do with it — a background job that blocks anyway.
  if [ -d "$STATE" ]; then bash "$SELF" --refresh "$STATE" "$FEED" "$KEY" </dev/null >/dev/null 2>&1 & fi
fi

# Nothing cached yet (first run, or every refresh so far failed) -> stay silent. Never guess a version.
[ -n "$LATEST" ] || exit 0
LATEST="$(sane_version "$LATEST")" || exit 0

# One awk, eval/lib/version.sh's order: 3.2.0 is newer than an installed 3.2.0-rc.1, so the rc's user is asked.
awk -v a="$LATEST" -v b="$CUR" "${CREW_VCMP_AWK:-}"' BEGIN { exit !(vcmp(a, b) > 0) }' 2>/dev/null || exit 0

# Skipped for good? Asked (or answered "later") within the last day?
if [ -f "$STATE/update-skip" ]; then read -r _sk < "$STATE/update-skip" 2>/dev/null || _sk=""; [ "${_sk//[!0-9.]/}" = "$LATEST" ] && exit 0; fi
if [ -f "$STATE/update-asked" ]; then
  read -r _av _at < "$STATE/update-asked" 2>/dev/null || { _av=""; _at=0; }
  _at="${_at//[!0-9]/}"; [ -n "$_at" ] || _at=0
  [ "${_av//[!0-9.]/}" = "$LATEST" ] && [ "$((NOW - _at))" -lt 86400 ] && exit 0
fi
mkdir -p "$STATE" 2>/dev/null || true
printf '%s %s\n' "$LATEST" "$NOW" > "$STATE/update-asked" 2>/dev/null || true   # asked = "later" until answered

# The question speaks the install's language: CREW_LANG, then kit.conf's lang=, then the locale; English otherwise.
_lg="${CREW_LANG:-}"
[ -n "$_lg" ] || { [ -f "$CL/kit.conf" ] && _lg="$(sed -n 's/^lang=//p' "$CL/kit.conf" 2>/dev/null | head -1 | tr -d '\r')"; }
if [ -z "$_lg" ]; then _loc="${LC_ALL:-}"; [ -n "$_loc" ] || _loc="${LC_MESSAGES:-}"; [ -n "$_loc" ] || _loc="${LANG:-}"
  case "$_loc" in tr*|TR*) _lg=tr ;; esac; fi
MAJOR=0; [ "${LATEST%%.*}" -gt "${CUR%%.*}" ] 2>/dev/null && MAJOR=1
if [ "$_lg" = tr ]; then
  Q="Crewforth v$LATEST yayında (kurulu: v$CUR). Şimdi güncelleyelim mi?"; O1="Güncelle"; O2="Sonra"; O3="Bu sürümü atla"
  QM="Major sürüm: kırıcı değişiklik içerebilir; güncellemeden önce CHANGELOG'a bakın."
else
  Q="Crewforth v$LATEST is out (installed: v$CUR). Update now?"; O1="Update"; O2="Later"; O3="Skip this version"
  QM="Major version: it may contain breaking changes; check the CHANGELOG before updating."
fi
if [ "$EDITION" = plugin ]; then
  DO="run \`claude plugin update crewforth@crewforth\`, then tell the user to restart Claude Code — the update applies on restart"
else
  DO="run /crew-update now; only when it has finished, go on to the user's request"
fi

printf 'Crewforth update available: v%s is installed, v%s is published.\n' "$CUR" "$LATEST"
printf 'Before you answer the user'"'"'s first message, ask them ONE multiple-choice question with your question tool (AskUserQuestion), worded exactly:\n'
printf '  "%s"%s\n' "$Q" "$( [ "$MAJOR" = 1 ] && printf ' — %s' "$QM" )"
printf '  options: "%s" · "%s" · "%s"\n' "$O1" "$O2" "$O3"
printf -- '- "%s" -> %s.\n' "$O1" "$DO"
printf -- '- "%s", or no answer -> run `%s later %s` (Bash tool, not PowerShell), then go on with their request.\n' "$O2" "$ANSWER" "$LATEST"
printf -- '- "%s" -> run `%s skip %s` (Bash tool, not PowerShell), then go on with their request.\n' "$O3" "$ANSWER" "$LATEST"
# An urgent first message (an error, a broken build) is answered first: the question waits for the end of that reply.
printf 'Exception: if their first message is an error or an urgent fix, answer that first and ask this question at the end of that reply.\n'
printf 'Never update unless the user picks "%s". If this session is non-interactive (nobody can answer, e.g. claude -p), do not ask and do not mention it.\n' "$O1"
printf 'CREW_NO_UPDATE_CHECK=1 turns this check off.\n'
exit 0
