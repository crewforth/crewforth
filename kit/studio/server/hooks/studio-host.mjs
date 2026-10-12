#!/usr/bin/env node
// The permission host of a session Studio starts: an MCP server over stdio with one tool, `approve`, named to
// Claude Code with --permission-prompt-tool.
//
// WHY IT EXISTS. In a `-p` run Claude Code offers the two tools that need a person, AskUserQuestion and
// ExitPlanMode, only when the run has a permission host. Measured on Claude Code 2.1.294: with no host neither
// is in the session's tool list; with this one both are. A session without them asked its question as prose and
// could not leave plan mode at all.
//
// WHAT IT ANSWERS. Nothing, with one exception. Every prompt that reaches it is DENIED: the place a call is
// allowed in Studio is the dock, through the PreToolUse hook (studio-gate.sh), before the call gets here. A call
// that reaches this host is one the hook said nothing about, and before there was a host Claude Code refused
// those itself, because nobody could answer. Denying here keeps that exactly.
//
// The exception is a plan the viewer approved WITH a change of mode. The hook cannot change the mode; the
// permission host can, in its answer (measured: `updatedPermissions: [{ type: "setMode", … }]` moved a session
// from plan to acceptEdits). So for that one case the hook stays silent, and this host finds what the viewer
// decided in the spool — `host/<tool_use_id>.json`, written by the server when the answer was given — and
// answers with it. The mode is one of two words, checked here as well as where it was written.
//
// No dependency: the protocol is three JSON-RPC methods on newline-delimited stdio.
//
// Usage: studio-host.mjs <spool-dir>
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const SPOOL = process.argv[2] ?? '';
const MODES = ['acceptEdits', 'default'];
const DENIED = 'Crewforth Studio: nobody answers this prompt here. A call is allowed in the Studio dock before it runs, or it is refused.';

const send = (o) => process.stdout.write(`${JSON.stringify(o)}\n`);
const text = (o) => ({ content: [{ type: 'text', text: JSON.stringify(o) }] });

/** What the viewer decided for this call, when the decision is one only the host can deliver. Read once. */
export function decisionFor(spool, toolName, toolUseId) {
  if (toolName !== 'ExitPlanMode' || typeof toolUseId !== 'string' || !/^[A-Za-z0-9_-]+$/.test(toolUseId) || !spool) return null;
  const file = path.join(spool, 'host', `${toolUseId}.json`);
  let said;
  try { said = JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return null; }
  try { fs.rmSync(file); } catch { /* answered once either way: the hook asks again for a new call */ }
  return MODES.includes(said?.mode) ? said.mode : null;
}

export function answer(spool, args) {
  const mode = decisionFor(spool, args?.tool_name, args?.tool_use_id);
  if (!mode) return { behavior: 'deny', message: DENIED };
  return {
    behavior: 'allow',
    updatedInput: args.input ?? {},
    updatedPermissions: [{ type: 'setMode', mode, destination: 'session' }],
  };
}

function serve() {
  let buf = '';
  process.stdin.on('data', (d) => {
    buf += d;
    let i;
    while ((i = buf.indexOf('\n')) !== -1) {
      const line = buf.slice(0, i).trim();
      buf = buf.slice(i + 1);
      if (!line) continue;
      let m;
      try { m = JSON.parse(line); } catch { continue; }
      if (m.method === 'initialize') {
        send({ jsonrpc: '2.0', id: m.id, result: { protocolVersion: m.params?.protocolVersion ?? '2025-06-18', capabilities: { tools: {} }, serverInfo: { name: 'crew-studio-host', version: '1' } } });
      } else if (m.method === 'tools/list') {
        send({
          jsonrpc: '2.0',
          id: m.id,
          result: { tools: [{
            name: 'approve',
            description: 'Answers a permission prompt of a session Crewforth Studio started.',
            inputSchema: { type: 'object', properties: { tool_name: { type: 'string' }, input: { type: 'object' }, tool_use_id: { type: 'string' } }, required: ['tool_name', 'input'] },
          }] },
        });
      } else if (m.method === 'tools/call') {
        send({ jsonrpc: '2.0', id: m.id, result: text(answer(SPOOL, m.params?.arguments)) });
      } else if (m.id !== undefined) {
        // Anything else that expects an answer gets an empty one; a notification gets none.
        send({ jsonrpc: '2.0', id: m.id, result: {} });
      }
    }
  });
}

// Imported by the selfcheck for `answer`; run by Claude Code as the server.
// Node names the main module by its real path, so the path it was started with is resolved the same way.
let main = false;
try { main = pathToFileURL(fs.realpathSync(process.argv[1])).href === import.meta.url; } catch { /* not started as a script */ }
if (main) serve();
