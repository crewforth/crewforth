#!/usr/bin/env node
// A small notes CLI: notes live in notes.json beside the working directory.
import fs from 'node:fs';
import path from 'node:path';

export const FILE = () => path.join(process.cwd(), 'notes.json');
export function load() { try { return JSON.parse(fs.readFileSync(FILE(), 'utf8')); } catch { return []; } }
export function save(notes) { fs.writeFileSync(FILE(), JSON.stringify(notes, null, 2) + '\n'); }

export function add(text) {
  if (!text || !text.trim()) throw new Error('a note needs text');
  const notes = load();
  const note = { id: notes.length + 1, text: text.trim(), createdAt: new Date().toISOString() };
  notes.push(note); save(notes);
  return note;
}
export function list() { return load(); }

export function main(argv) {
  const [cmd, ...rest] = argv;
  switch (cmd) {
    case 'add': { const n = add(rest.join(' ')); console.log(`added #${n.id}`); return 0; }
    case 'list': { for (const n of list()) console.log(`#${n.id} ${n.text}`); return 0; }
    default: console.error('usage: notes <add|list> ...'); return 2;
  }
}
if (import.meta.url === `file://${process.argv[1]}`) process.exitCode = main(process.argv.slice(2));
