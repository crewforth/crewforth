// A stand-in for the claude CLI in the review bench's selfcheck (CREW_BENCH_CLAUDE): no model, no network.
// It records its argv and the files the working directory held, solves the task when FAKE_SOLVE names a reference
// file, and prints a stream-json run: one advisor call shown twice (as a stream repeats a message), and a result
// whose modelUsage has two models.
import fs from 'node:fs';
import path from 'node:path';

const argv = process.argv.slice(2);
if (argv[0] === '--version') { console.log('0.0.0 (fake)'); process.exit(0); }
const log = process.env.FAKE_LOG;
const seen = []; const walk = (d) => { for (const e of fs.readdirSync(d, { withFileTypes: true })) { if (e.name === '.git') continue; const p = path.join(d, e.name); if (e.isDirectory()) walk(p); else seen.push(path.relative('.', p).split(path.sep).join('/')); } };
walk('.');
fs.writeFileSync(path.join(log, 'argv.json'), JSON.stringify(argv));
fs.writeFileSync(path.join(log, 'seen.json'), JSON.stringify(seen.sort()));
if (process.env.FAKE_SOLVE) fs.copyFileSync(process.env.FAKE_SOLVE, path.join('src', 'duration.js'));
const call = { type: 'assistant', message: { id: 'm1', content: [{ type: 'server_tool_use', id: 't1', name: 'advisor', input: {} }] } };
console.log(JSON.stringify(call)); console.log(JSON.stringify(call));
console.log(JSON.stringify({ type: 'result', subtype: 'success', is_error: false, total_cost_usd: 0.2, num_turns: 3, duration_ms: 1000, result: 'done',
  modelUsage: { 'claude-sonnet-5-5': { costUSD: 0.05, inputTokens: 4, outputTokens: 30 }, 'claude-opus-5-5': { costUSD: 0.15, inputTokens: 32000, outputTokens: 200 } } }));
