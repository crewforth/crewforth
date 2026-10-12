#!/usr/bin/env node
// A stand-in for the `claude` CLI, for recordings. No model, no network, no tokens.
//
// The panel asks the CLI two things. `claude agents --json` is which sessions are open on this machine: the
// real answer would put this machine's own sessions into the picture, so the stand-in answers with the fixture's.
// And a session the panel starts is a `claude -p` process that speaks stream-json: the stand-in answers each
// message with a scripted turn, and plays the turn's tool calls through the REAL approval hook named in the
// settings file the panel wrote, so the dock on screen is the product's own, waiting on the product's own gate.
//
//   CREW_RECORD_FLEET   a JSON file: what `agents --json` prints (default: an empty list)
//   CREW_RECORD_TURN    a JSON file: [{ at, say | gate | result }, …] played after each message
//                         say:    the content array of one assistant record
//                         gate:   { id, tool, input, agentId?, agentType? } — run the approval hook on it
//                         result: fields of the turn's closing `result` record
import fs from 'node:fs';
import { spawn } from 'node:child_process';

const argv = process.argv.slice(2);
const read = (file, fallback) => { try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return fallback; } };

if (argv[0] === 'agents') {
  process.stdout.write(`${JSON.stringify(read(process.env.CREW_RECORD_FLEET, []))}\n`);
  process.exit(0);
}

const arg = (k) => { const i = argv.indexOf(k); return i === -1 ? null : argv[i + 1]; };
const sid = arg('--session-id') ?? arg('--resume');
const settings = read(arg('--settings'), null);
const hook = settings?.hooks?.PreToolUse?.[0]?.hooks?.[0]?.command ?? null;
const turn = read(process.env.CREW_RECORD_TURN, []);
const out = (o) => process.stdout.write(`${JSON.stringify(o)}\n`);

out({ type: 'system', subtype: 'init', session_id: sid });

function gate(step) {
  if (!hook) return;
  const payload = {
    session_id: sid, hook_event_name: 'PreToolUse', permission_mode: arg('--permission-mode'),
    tool_name: step.tool, tool_use_id: step.id, tool_input: step.input ?? {},
  };
  if (step.agentId) { payload.agent_id = step.agentId; payload.agent_type = step.agentType ?? null; }
  out({ type: 'system', subtype: 'hook_started', hook_id: step.id, hook_name: `PreToolUse:${step.tool}`, hook_event: 'PreToolUse' });
  const child = spawn('bash', ['-c', hook], { stdio: ['pipe', 'ignore', 'ignore'] });
  child.stdin.end(JSON.stringify(payload));
  child.on('exit', (code) => out({
    type: 'system', subtype: 'hook_response', hook_id: step.id, hook_name: `PreToolUse:${step.tool}`, hook_event: 'PreToolUse',
    exit_code: code, outcome: code === 0 ? 'success' : 'blocked',
  }));
}

let turns = 0;
let buffer = '';
process.stdin.on('data', (chunk) => {
  buffer += chunk;
  let nl;
  while ((nl = buffer.indexOf('\n')) !== -1) {
    const line = buffer.slice(0, nl);
    buffer = buffer.slice(nl + 1);
    let rec;
    try { rec = JSON.parse(line); } catch { continue; }
    if (rec.type !== 'user') continue;
    turns += 1;
    out({ type: 'user', message: rec.message });                       // what --replay-user-messages does
    out({ type: 'stream_event', event: { type: 'message_start' } });
    for (const step of turn) {
      setTimeout(() => {
        if (step.say) out({ type: 'assistant', message: { role: 'assistant', content: step.say } });
        if (step.gate) gate(step.gate);
        if (step.result) out({ type: 'result', num_turns: turns, ...step.result });
      }, (step.at ?? 0) * 1000);
    }
  }
});
process.stdin.on('end', () => process.exit(0));
