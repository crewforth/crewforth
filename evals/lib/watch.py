# Watches a run's event stream while it is written and stops the run early. Started by evals/run.sh beside the CLI.
#   STOP_WHEN  the case has its answer: the run stops and is graded on what it left (e.g. the debugging skill loaded)
#   FORBID     the run did what the case forbids: it stops at once and the runner adds a FAIL for it
#   MAX_TURNS  a ceiling on main-thread assistant messages: past it the run is stopped and not graded (class timeout)
# A spec is space-separated terms: skill:<name> · agent:<type> · tool:<Name> · tool:<Name>~<regex on its input JSON>.
# Terms are split on spaces, so a regex spells a space as `\s` (FORBID='tool:Bash~git\spush'), never as a blank.
# Writes one line to the reason file when it stops a run: `stop <term>`, `forbid <term>` or `maxturns <n>`.
import json, os, re, signal, sys, time
stream, pid, reason_file = sys.argv[1], int(sys.argv[2]), sys.argv[3]
stop = os.environ.get('STOP_WHEN', '').split()
forbid = os.environ.get('FORBID', '').split()
max_turns = int(os.environ.get('MAX_TURNS', '0') or 0)

def hit(term, c):
    kind, _, rest = term.partition(':')
    name = c.get('name'); inp = c.get('input') or {}
    if kind == 'skill': return name == 'Skill' and str(inp.get('skill', '')).split(':')[-1] == rest
    if kind == 'agent': return name in ('Agent', 'Task') and str(inp.get('subagent_type', '')).split(':')[-1] == rest
    if kind == 'tool':
        tname, _, rx = rest.partition('~')
        return name == tname and (not rx or re.search(rx, json.dumps(inp)) is not None)
    return False

def alive():
    try: os.kill(pid, 0); return True
    except OSError: return False

def end(why):
    open(reason_file, 'w').write(why + '\n')
    # The CLI process only, never its group: without job control the group is the runner's own, and stopping the
    # group stopped the whole eval (measured with a stand-in CLI: the runner died with rc 144).
    try: os.kill(pid, signal.SIGTERM)
    except OSError: sys.exit(0)   # the run had already ended: nothing left to stop
    sys.exit(0)

pos = 0; buf = ''; turns = set()
while True:
    running = alive()
    try:
        with open(stream, errors='replace') as f:
            f.seek(pos); data = f.read(); pos = f.tell()
    except OSError: data = ''
    buf += data
    *lines, buf = buf.split('\n')
    for line in lines:
        try: e = json.loads(line)
        except Exception: continue
        if e.get('type') != 'assistant': continue
        m = e.get('message') or {}
        if not e.get('parent_tool_use_id') and m.get('id'): turns.add(m['id'])
        for c in m.get('content') or []:
            if not (isinstance(c, dict) and c.get('type') == 'tool_use'): continue
            for t in forbid:
                if hit(t, c): end('forbid ' + t)
            for t in stop:
                if hit(t, c): end('stop ' + t)
        if max_turns and len(turns) > max_turns: end('maxturns %d' % max_turns)
    if not running: break
    time.sleep(0.2)
