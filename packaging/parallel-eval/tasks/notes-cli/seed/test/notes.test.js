import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'notes-'));
process.chdir(dir);
const { add, list } = await import('../notes.js');

test('add stores a note and list returns it', () => {
  add('buy milk');
  assert.deepEqual(list().map((n) => n.text), ['buy milk']);
});
test('add refuses an empty note', () => { assert.throws(() => add('  ')); });
