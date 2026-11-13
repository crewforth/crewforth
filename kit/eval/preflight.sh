#!/usr/bin/env bash
# Preflight — name the tools this machine is missing BEFORE they turn into a surprise mid-session.
#
# Why this exists. Crewforth is written to degrade rather than break: sha256sum -> shasum -> cksum for digests,
# and so on. (It no longer needs jq or python at all — every JSON read and write is one bash/awk path on every
# OS — so neither is reported here: a row for a tool nothing uses would send people to install it.) That is the right design, and it is also
# why a missing tool never announces itself — the fallback runs, something is quietly worse, and the user finds
# out later from a symptom that points somewhere else. A Windows Git Bash install with no jq and no python is
# the normal case, not the exotic one, and it was where every surprise in this project came from.
#
# So: report, do not install. Nothing here writes to the machine or blocks a run. The user asked for exactly
# that boundary — a scaffolding tool that silently installs software on someone's workstation is a worse problem
# than the one it solves, and on a managed corporate machine it simply fails in a new way.
#
# Called from start.sh and adopt.sh (before the install summary) and from doctor.sh (so it stays re-runnable).
#   bash preflight.sh            # human-readable report, always exit 0
#   bash preflight.sh --quiet    # print only what is missing; exit 1 if any REQUIRED tool is absent
set -uo pipefail
# The 2.x names of the variables a user can set still work (one helper: eval/lib/crew-env.sh).
_crew_d="${BASH_SOURCE//\\//}"; _crew_d="${_crew_d%/*}"; [ "$_crew_d" = "${BASH_SOURCE//\\//}" ] && _crew_d=.
[ -f "$_crew_d/lib/crew-env.sh" ] && . "$_crew_d/lib/crew-env.sh"; unset _crew_d

QUIET=0
case "${1:-}" in --quiet|-q) QUIET=1 ;; esac
# A machine-readable question, so a caller can branch on one tool without parsing
# the display output or restating the rule. `--has node` answers with an exit
# code and prints nothing. The rule it answers with is works(), the same one the
# report uses — the version floor and the does-it-actually-run probe live in one
# place, and a second copy could drift from it silently.
HAS=""
case "${1:-}" in --has) HAS="${2:-}" ;; esac

B=""; D=""; R=""; YE=""; GR=""
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then B=$'\033[1m'; D=$'\033[2m'; R=$'\033[0m'; YE=$'\033[33m'; GR=$'\033[32m'; fi

MISSING_REQ=""; MISSING_OPT=""

have(){ command -v "$1" >/dev/null 2>&1; }
# `have` answers "is it on PATH", which is the wrong question for an interpreter on Windows. Windows puts
# %LOCALAPPDATA%\Microsoft\WindowsApps\python3 on PATH BY DEFAULT: the Microsoft Store redirector stub, which
# passes `command -v`, writes "Python was not found" to stderr and exits 49. Measured on a stock Windows 11
# desktop, this preflight printed "✓ jq or python → python3 · Everything Crewforth wants is here" on a machine
# with no Python at all — and the settings merge that line is about cannot run there. So for the interpreters,
# ask whether they RUN. Everything else is a plain binary where presence is the whole question.
#
# The probe always passes arguments. An ARGLESS run of that stub is the one that opens the Microsoft Store,
# which is why doctor.sh warns against calling it unconditionally; `-c …` makes it print and exit instead.
works(){
  have "$1" || return 1
  case "$1" in
      # The panel needs 18+, and a name that resolves is not an interpreter that runs: the Windows Store ships a
      # python3 that satisfies `command -v` and then exits 49. So run node, read the major it reports, and hold
      # the floor. A node that cannot execute fails here rather than at first use.
      node)              v="$("$1" -p 'process.versions.node.split(".")[0]' 2>/dev/null)" || return 1
                         case "$v" in ''|*[!0-9]*) return 1 ;; esac
                         [ "$v" -ge 18 ] ;;
    *)                 return 0 ;;
  esac
}
# printf's %-Ns pads by bytes, and a translated label ("sha256 aracı") is longer in bytes than in characters,
# so its column came out one short. Count characters: drop UTF-8 continuation bytes under C, pad the rest.
padr() {   # $1 = text, $2 = width; sets PADDED
  local LC_ALL=C n
  n="${1//[$'\200'-$'\277']/}"; n=$(( $2 - ${#n} ))
  PADDED="$1"
  while [ "$n" -gt 0 ]; do PADDED="$PADDED "; n=$((n-1)); done
}
# any_of "label" "why it matters" "fix hint" cmd...
any_of(){
  # label, why and fix are ENGLISH keys, translated here so no call site forks. A tool name passes through.
  _mt "$1"; label="$_M"; _mt "$2"; why="$_M"; _mt "$3"; fix="$_M"; shift 3
  found=""
  for c in "$@"; do works "$c" && { found="$c"; break; }; done
  if [ -n "$found" ]; then
    [ "$QUIET" = 1 ] || { padr "$label" 22; printf '  %s✓%s %s %s%s%s\n' "$GR" "$R" "$PADDED" "$D" "$found" "$R"; }
    return 0
  fi
  padr "$label" 22
  printf '  %s✗%s %s %s\n' "$YE" "$R" "$PADDED" "$why"
  _mt 'fix: '; printf '      %s%s%s%s\n' "$D" "$_M" "$fix" "$R"
  return 1
}

  if [ -n "$HAS" ]; then
    works "$HAS" && exit 0 || exit 1
  fi

# ---- CREW-I18N ------------------------------------------------------------------------------------------
# This script prints during the install, so it speaks the installer's language. Same contract as start.sh:
# the English string is the key, a missing translation prints English, and TOOL NAMES ARE NEVER TRANSLATED —
# `bash`, `git`, `jq`, `node` are identifiers, not words. Only the prose around them is.
case "${CREW_LANG:-}" in tr|en) ;; *)
  _loc="${LC_ALL:-}"; [ -n "$_loc" ] || _loc="${LC_MESSAGES:-}"; [ -n "$_loc" ] || _loc="${LANG:-}"
  case "$_loc" in tr*|TR*) CREW_LANG=tr ;; *) CREW_LANG=en ;; esac ;;
esac
# `_mt` writes into _M with printf -v: a `$(m …)` call site is a fork, ~50 ms each on Git Bash.
m() { _mt "$@"; printf '%s' "$_M"; }
_mt() {
  # An empty key must still ASSIGN: bash 3.2's `printf -v _M ""` leaves _M holding the previous translation.
  [ -n "${1:-}" ] || { _M=""; return 0; }
  local s="$1"; shift
  if [ "$CREW_LANG" = tr ]; then
    case "$s" in
      "Preflight — what this machine has") s='Ön kontrol — bu makinede neler var' ;;
      "Missing REQUIRED:") s='Eksik ZORUNLU araçlar:' ;;
      "— install these first.") s='— önce bunları kurun.' ;;
      "All required tools present.") s='Zorunlu araçların hepsi kurulu.' ;;
      "Optional gaps above are safe but worth closing.") s='Yukarıdaki isteğe bağlı eksikler sorun çıkarmaz ama gidermeye değer.' ;;
      "Everything Crewforth needs is here.") s="Crewforth'un ihtiyaç duyduğu her şey kurulu." ;;
      "is the panel only — every gate still holds without it.") s='yalnızca panel için gerekli — o olmadan da tüm kapılar çalışır.' ;;
      "Or let Crewforth get one (Bash tool, not PowerShell): %s") s='İsterseniz Crewforth sizin için indirebilir (PowerShell değil, Bash aracıyla): %s' ;;
      "fix: ") s='çözüm: ' ;;
      "node 18+") s='node 18+' ;;
      "sha256 tool") s='sha256 aracı' ;;
      "all of Crewforth is bash") s="Crewforth'un tamamı bash ile yazıldı" ;;
      "Windows: install Git for Windows (git-scm.com) and run Claude Code from Git Bash") s="Windows: Git for Windows'u kurun (git-scm.com) ve Claude Code'u Git Bash'ten çalıştırın" ;;
      "context measurement, routing, doctor") s='bağlam ölçümü, yönlendirme ve doctor için' ;;
      "Windows: ships with Git Bash · macOS: preinstalled · Linux: apt install gawk") s='Windows: Git Bash ile gelir · macOS: hazır gelir · Linux: apt install gawk' ;;
      "the commit-time trace/secret gates are git hooks") s="commit anındaki iz ve gizli bilgi kapıları git hook'u olarak çalışır" ;;
      "the Crewforth Studio panel (/crew-studio); the gates themselves are bash and do not need it") s='Crewforth Studio paneli (/crew-studio) için; kapılar bash ile çalışır, Node gerektirmez' ;;
      "the skill-trust gate falls back to cksum (catches accidental edits, not crafted ones)") s="skill güven kapısı cksum'a düşer (kazara değişiklikleri yakalar, kasıtlı olanları yakalayamaz)" ;;
      "Windows/Linux: coreutils (sha256sum) · macOS: shasum is preinstalled") s='Windows/Linux: coreutils (sha256sum) · macOS: shasum hazır gelir' ;;
      "bash") ;;   # identifier, printed as is
      "awk") ;;   # identifier, printed as is
      "git") ;;   # identifier, printed as is
      "nodejs.org · Windows: winget install OpenJS.NodeJS.LTS · macOS: brew install node · Linux: apt install nodejs") ;;   # identifier, printed as is
      "git-scm.com · macOS: xcode-select --install · Linux: apt install git") ;;   # identifier, printed as is
      # No row: the line prints in English. CREW_I18N_MISS (set by e2e case 18) collects every such key, so a
      # missing translation is caught by NAME rather than guessed from which English words it happens to contain.
      *) [ -n "${CREW_I18N_MISS:-}" ] && printf '%s\n' "$s" >> "$CREW_I18N_MISS" ;;
    esac
  fi
  # shellcheck disable=SC2059
  printf -v _M "$s" "$@"
}
# ---- /CREW-I18N -----------------------------------------------------------------------------------------

[ "$QUIET" = 1 ] || { _mt 'Preflight — what this machine has'; printf '\n  %s%s%s\n' "$B" "$_M" "$R"; }

# --- REQUIRED: without these Crewforth does not work at all -------------------------------------------------
# Hooks are wired in SHELL form on purpose, and `bash` is resolved by the shell Claude Code already runs them
# in — not off the Windows PATH. That distinction is not academic. On a Windows box checked during this work,
# `where bash` answered `C:\Windows\System32\bash.exe`, which is not Git Bash at all: it is the WSL launcher,
# living in a filesystem namespace where `C:\Repos\app` does not exist (`/mnt/c/Repos/app` does). A wiring that
# spawns `bash` by PATH name would have run THAT, or failed outright where WSL is not installed — every gate
# gone, with an error pointing nowhere near the cause. Hence shell form, and hence this note.
any_of "bash" 'all of Crewforth is bash' \
  'Windows: install Git for Windows (git-scm.com) and run Claude Code from Git Bash' bash || MISSING_REQ="$MISSING_REQ bash"
any_of "awk" 'context measurement, routing, doctor' \
  'Windows: ships with Git Bash · macOS: preinstalled · Linux: apt install gawk' awk gawk mawk || MISSING_REQ="$MISSING_REQ awk"
any_of "git" 'the commit-time trace/secret gates are git hooks' \
  "git-scm.com · macOS: xcode-select --install · Linux: apt install git" git || MISSING_REQ="$MISSING_REQ git"
  # Node is required for the panel and for nothing else: every gate in Crewforth is bash, and they all hold on a
  # machine that has never seen node. It sits in REQUIRED anyway, deliberately, because the panel now installs
  # into every project, and a component that silently does not start on some machines is worse than one that
  # says what it needs. The reason string names which half is affected, so the REQUIRED heading stays true.
  any_of 'node 18+' 'the Crewforth Studio panel (/crew-studio); the gates themselves are bash and do not need it' \
    "nodejs.org · Windows: winget install OpenJS.NodeJS.LTS · macOS: brew install node · Linux: apt install nodejs" \
    node || MISSING_REQ="$MISSING_REQ node"

# --- OPTIONAL: Crewforth falls back, but the fallback is worse in a way worth knowing about ------------------
any_of 'sha256 tool' 'the skill-trust gate falls back to cksum (catches accidental edits, not crafted ones)' \
  'Windows/Linux: coreutils (sha256sum) · macOS: shasum is preinstalled' sha256sum shasum || MISSING_OPT="$MISSING_OPT sha256"

if [ -n "$MISSING_REQ" ]; then
  _mt 'Missing REQUIRED:'; _a="$_M"; _mt '— install these first.'
  printf '\n  %s%s%s%s %s\n' "$YE$B" "$_a" "$R" "$MISSING_REQ" "$_M"
    case "$MISSING_REQ" in
      # Which half is gone. "Crewforth will not work" is false when only node is missing: every gate is bash and
      # still holds; what is lost is the panel.
      *node*) _mt 'is the panel only — every gate still holds without it.'; printf '    %snode%s %s\n' "$B" "$R" "$_M"
              # And it is not a dead end: Crewforth fetches a runtime for the panel itself, into one
              # directory under $HOME, verified against the published checksum. It asks first.
              printf '    %s\n' "$(m 'Or let Crewforth get one (Bash tool, not PowerShell): %s' "${B}bash .claude/studio/ensure-node.sh --plan${R}")" ;;
    esac
elif [ -n "$MISSING_OPT" ]; then
  [ "$QUIET" = 1 ] || { _mt 'All required tools present.'; _a="$_M"; _mt 'Optional gaps above are safe but worth closing.'
                        printf '\n  %s%s%s %s\n' "$GR" "$_a" "$R" "$_M"; }
else
  [ "$QUIET" = 1 ] || { _mt 'Everything Crewforth needs is here.'; printf '\n  %s%s%s\n' "$GR" "$_M" "$R"; }
fi

# Report-only by design: a missing OPTIONAL tool never fails. `--quiet` exits non-zero only for REQUIRED gaps,
# so a caller can branch on it without having to parse this output.
[ "$QUIET" = 1 ] && [ -n "$MISSING_REQ" ] && exit 1
exit 0
