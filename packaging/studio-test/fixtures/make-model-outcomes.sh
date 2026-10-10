#!/usr/bin/env bash
# Writes a model-outcomes.tsv with Crewforth's own hook, and prints it.
#
# The record Studio's Models view reads is written by kit/hooks/agent-outcome.sh when a crew agent stops. This
# script lets that hook write one in a scratch repository, for five agents: a card whose verify command fails (the
# hook sends the agent back once, then records the failure), the same card run again one model up, one that passes,
# one with no verify command, and one whose command the project's rules do not allow.
#
# model-outcomes.hook.tsv beside this file is its output, kept so the selfcheck reads what the hook really writes.
# The selfcheck also runs this script and compares, every column but the time.
#
#   make-model-outcomes.sh <repo root> <empty scratch directory>
set -u
REPO="$1"; WORK="$2"
HOOK="$REPO/kit/hooks/agent-outcome.sh"
[ -f "$HOOK" ] || { echo "no kit/hooks/agent-outcome.sh under $REPO" >&2; exit 3; }
mkdir -p "$WORK/.claude/state/crew-model/agents" || exit 3
cd "$WORK" || exit 3
git init -q . 2>/dev/null || { echo "git could not make the scratch repository" >&2; exit 3; }
printf 'verify ./ok.sh\nverify ./bad.sh\n' > .claude/crew-model-rules
printf 'exit 0\n' > ok.sh
printf 'exit 1\n' > bad.sh
chmod +x ok.sh bad.sh

card() {   # card <agent id> <agent> <model> <change> <risk> <card> <escalated from> <verify>
  printf 'agent=%s\ntier=%s\nasked=%s\nchange=%s\nrisk=%s\ncard=%s\nbg=false\nesc=%s\nverify=%s\n' \
    "$2" "$3" "$3" "$4" "$5" "$6" "$7" "$8" > ".claude/state/crew-model/agents/$1"
}
stop() {   # stop <agent id> <true when the agent was already sent back once>
  printf '{"session_id":"s","permission_mode":"auto","hook_event_name":"SubagentStop","agent_id":"%s","agent_type":"x","stop_hook_active":%s,"agent_transcript_path":"/none","last_assistant_message":"done"}' "$1" "$2" > payload.json
  CLAUDE_PROJECT_DIR="$PWD" bash "$HOOK" < payload.json > /dev/null 2>&1
}

card f1 crew-backend-expert sonnet feature normal idem - ./bad.sh
stop f1 false; stop f1 true
card f2 crew-backend-expert opus feature normal idem sonnet ./ok.sh
stop f2 false
card f3 crew-test-expert haiku test-run normal suite - ./ok.sh
stop f3 false
card f4 crew-frontend-expert sonnet feature normal banner - none
stop f4 false
card f5 crew-performance-expert opus audit critical batch - ./nope.sh
stop f5 false

[ -f .claude/state/model-outcomes.tsv ] || { echo "the hook wrote no record" >&2; exit 4; }
cat .claude/state/model-outcomes.tsv
