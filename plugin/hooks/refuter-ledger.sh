#!/usr/bin/env bash
# refuter-ledger.sh - the record of what crew-refuter concluded, written by the hook and not by the session.
#
# WHY. A findings document can say a finding was verified. That sentence is the session's own; the ledger is not.
# When a crew-refuter agent stops, this hook reads the TASK it was given (the first record of its own transcript)
# and the ANSWER it ended with (last_assistant_message), and adds one line when the two agree on the finding and
# the lens:
#
#   ts  session  agent_id  finding  lens  verdict              .claude/state/crew-refuter.tsv
#
# kit/eval/lib/findings/findings.mjs `validate --ledger` holds a document to it: a medium-or-higher finding needs
# verifiers, and every verifier it names must be a line here, with the same finding, lens and verdict.
#
# Wired to SubagentStop with a matcher on the agent type, so it starts for crew-refuter only; the type is checked
# again here. It works whatever CREW_MODEL_ROUTING says: this is not model routing.
# THIS NEVER BLOCKS. It exits 0 on every path: a stop hook that failed closed would keep an agent running.
# The ledger is protected from the session the way the routing records are (guard-bash.sh, guard-write.sh): a plain
# attempt to write it is refused; a determined one (an interpreter, a name built from pieces) is not, and that is
# the stated scope of those guards.
set -uo pipefail
export LC_ALL=C
_rl_here="${BASH_SOURCE%[/\\]*}"; [ "$_rl_here" = "${BASH_SOURCE}" ] && _rl_here=.
[ -f "$_rl_here/guard-agent-model.sh" ] || exit 0
. "$_rl_here/guard-agent-model.sh"
declare -F _json_slice >/dev/null 2>&1 || exit 0

IFS= read -r -d '' INPUT || true
_json_slice "$INPUT" hook_event_name >/dev/null; [ "$_JS" = SubagentStop ] || exit 0
_json_slice "$INPUT" agent_type >/dev/null; [ "${_JS##*:}" = crew-refuter ] || exit 0
_json_slice "$INPUT" agent_id >/dev/null; AID="$_JS"
case "$AID" in ''|*[!A-Za-z0-9._-]*) exit 0 ;; esac
_json_slice "$INPUT" session_id >/dev/null; SID="$_JS"
case "$SID" in ''|*[!A-Za-z0-9._-]*) SID=- ;; esac

# One field of a text: the value after "<key>:" at the start of a line, first occurrence, trimmed.
_rl_field(){  # $1 text, $2 key (any case) -> _RLF
  local line k; _RLF=""
  while IFS= read -r line; do
    line="${line%$'\r'}"; line="${line#"${line%%[![:space:]]*}"}"
    k="${line%%:*}"; [ "$k" = "$line" ] && continue
    shopt -s nocasematch
    if [[ "$k" == "$2" ]]; then shopt -u nocasematch
      _RLF="${line#*:}"; _RLF="${_RLF#"${_RLF%%[![:space:]]*}"}"; _RLF="${_RLF%"${_RLF##*[![:space:]]}"}"; return 0
    fi
    shopt -u nocasematch
  done <<< "$1"
  return 1
}

# The task: the first record of the agent's own transcript (a string, or a list whose first block holds the text).
_json_slice "$INPUT" agent_transcript_path >/dev/null; _json_unescape "$_JS" >/dev/null; ATP="${_JU//\\//}"
[ -f "$ATP" ] || exit 0
L1=""; IFS= read -r L1 < "$ATP" || true
_json_slice "$L1" content >/dev/null; TXT="$_JS"
[ -n "$TXT" ] || { _json_slice "$L1" text >/dev/null; TXT="$_JS"; }
_json_unescape "${TXT:0:8000}" >/dev/null; TASK="$_JU"
_rl_field "$TASK" finding || exit 0; F_TASK="$_RLF"
_rl_field "$TASK" lens || exit 0; L_TASK="$_RLF"

# The answer, and it must be about the same finding and lens.
_json_slice "$INPUT" last_assistant_message >/dev/null; _json_unescape "$_JS" >/dev/null; ANS="$_JU"
_rl_field "$ANS" finding || exit 0; F_ANS="$_RLF"
_rl_field "$ANS" lens || exit 0; L_ANS="$_RLF"
_rl_field "$ANS" verdict || exit 0; V="$_RLF"
[ "$F_TASK" = "$F_ANS" ] && [ "$L_TASK" = "$L_ANS" ] || exit 0
[[ "$F_TASK" =~ ^[a-z0-9][a-z0-9._:-]*$ ]] && [ "${#F_TASK}" -le 200 ] || exit 0
case "$L_TASK" in reachability|protection|reproduction|exclusion|blast-radius|claim) ;; *) exit 0 ;; esac
case "$V" in TRUE_POSITIVE|FALSE_POSITIVE|CANNOT_VERIFY) ;; *) exit 0 ;; esac

P="${CLAUDE_PROJECT_DIR:-$PWD}"; P="${P//\\//}"; P="${P%/}"
D="$P/.claude/state"; T="$D/crew-refuter.tsv"
mkdir -p "$D" 2>/dev/null || exit 0
# An agent that is resumed stops again: it answered once, and that answer stands.
if [ -f "$T" ]; then
  while IFS=$'\t' read -r _ _ a _; do [ "$a" = "$AID" ] && exit 0; done < "$T"
fi
[ -s "$T" ] || printf 'ts\tsession\tagent_id\tfinding\tlens\tverdict\n' > "$T" 2>/dev/null
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"; case "$TS" in [0-9][0-9][0-9][0-9]-*Z) ;; *) TS=- ;; esac
printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$TS" "$SID" "$AID" "$F_TASK" "$L_TASK" "$V" >> "$T" 2>/dev/null
exit 0
