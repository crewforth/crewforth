#!/usr/bin/env bash
# For a grader: did this run load a skill? Reads the run's event stream (.eval-stream.jsonl in the project) and
# prints one grade line: `PASS skill <name> was loaded` or `FAIL skill <name> was not loaded`, or `NOT_MEASURED` when
# there is no stream to read. It reads what the run DID (a Skill tool call), not what the reply says it did.
#   bash "$KIT_ROOT/evals/lib/skill-invoked.sh" systematic-debugging
set -uo pipefail
NAME="${1:?usage: skill-invoked.sh <skill-name>}"
[ -s .eval-stream.jsonl ] || { echo "NOT_MEASURED no event stream in this project, so a loaded skill cannot be seen"; exit 0; }
python3 - "$NAME" <<'PY'
import json, sys
want = sys.argv[1]; seen = False
for line in open('.eval-stream.jsonl', errors='replace'):
    try: e = json.loads(line)
    except Exception: continue
    if e.get('type') != 'assistant': continue
    for c in (e.get('message') or {}).get('content') or []:
        if isinstance(c, dict) and c.get('type') == 'tool_use' and c.get('name') == 'Skill' \
           and str((c.get('input') or {}).get('skill', '')).split(':')[-1] == want: seen = True
print(('PASS skill %s was loaded' if seen else 'FAIL skill %s was not loaded') % want)
PY
