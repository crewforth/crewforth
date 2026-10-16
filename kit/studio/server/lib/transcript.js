// Incremental JSONL reading.
//
// Transcripts are append-only and grow to megabytes, so re-parsing from byte
// zero on every change is not an option. Each reader keeps a byte offset and
// consumes only what was appended.
//
// A single record can itself be enormous (a pasted payload), so lines are
// assembled from a carry buffer rather than assumed to fit in one read.

import fsp from 'node:fs/promises';

export class JsonlReader {
  constructor(file) {
    this.file = file;
    this.offset = 0;
    this.carry = '';
    this.malformed = 0; // counted, never silently swallowed
  }

  /** Read everything appended since the last call. Returns parsed records.
   *
   * Async because a transcript read has stalled for tens of seconds on a Windows
   * machine, and this sits under the stream tick — see the note at the top of
   * projects.js. The read is no faster; it just no longer stops the loop.
   */
  async read() {
    let st;
    try { st = await fsp.stat(this.file); } catch { return []; }

    // A shrunk file means it was replaced, not appended to. Start over rather
    // than reading from a stale offset into the middle of a record.
    if (st.size < this.offset) {
      this.offset = 0;
      this.carry = '';
    }
    if (st.size === this.offset) return [];

    let chunk;
    let fh;
    try {
      fh = await fsp.open(this.file, 'r');
      const len = st.size - this.offset;
      const buf = Buffer.allocUnsafe(len);
      const { bytesRead } = await fh.read(buf, 0, len, this.offset);
      chunk = buf.subarray(0, bytesRead).toString('utf8');
      this.offset += bytesRead;
    } catch {
      return [];
    } finally {
      if (fh !== undefined) try { await fh.close(); } catch { /* already gone */ }
    }

    const text = this.carry + chunk;
    const lines = text.split('\n');
    // The last element is either '' (clean boundary) or a partial record.
    this.carry = lines.pop() ?? '';

    const out = [];
    for (const line of lines) {
      if (!line) continue;
      try {
        out.push(JSON.parse(line));
      } catch {
        this.malformed += 1;
      }
    }
    return out;
  }
}

/** One-shot full read. Used for files we do not intend to follow. */
export async function readAll(file) {
  const r = new JsonlReader(file);
  const records = await r.read();
  return { records, malformed: r.malformed };
}

/**
 * Session context fill, measured the way Crewforth measures it.
 *
 * The trap this avoids cost Crewforth a 92%-full context reported as 0.9%: when
 * a subagent returns, its tool_result lands in the MAIN transcript as a
 * `type:"user"` record carrying `toolUseResult.usage`. That is the SUBAGENT's
 * spend, not the session's. Only `.message.usage` on a non-sidechain assistant
 * record counts.
 */
export function contextFill(records) {
  let total = null;
  for (const r of records) {
    if (r?.isSidechain === true) continue;
    if (r?.type !== 'assistant') continue;
    const u = r?.message?.usage;
    if (!u || u.cache_read_input_tokens == null) continue;
    total =
      (u.input_tokens ?? 0) +
      (u.cache_read_input_tokens ?? 0) +
      (u.cache_creation_input_tokens ?? 0);
  }
  return total;
}

/**
 * What the context is made of since the last compaction: the share of its text that is tool output, and how many
 * times the session was compacted, with the last one's tokens before and after. Measured in characters of the main
 * session's records (text, a tool call's input, a tool's result), not tokens: the transcript keeps no per-block
 * token count. A compaction is the transcript's own `compact_boundary` record.
 */
export function contextMix(records) {
  let start = 0; let compactions = 0; let last = null;
  records.forEach((r, i) => {
    if (r?.isSidechain !== true && r?.type === 'system' && r?.subtype === 'compact_boundary') { start = i + 1; compactions += 1; last = r.compactMetadata ?? null; }
  });
  const size = (b) => {
    if (typeof b === 'string') return b.length;
    if (b?.type === 'text') return String(b.text ?? '').length;
    if (b?.type === 'tool_use') return JSON.stringify(b.input ?? {}).length;
    if (b?.type === 'tool_result') return typeof b.content === 'string' ? b.content.length : (Array.isArray(b.content) ? b.content.reduce((n, x) => n + (x?.type === 'text' ? String(x.text ?? '').length : 0), 0) : 0);
    return 0;
  };
  let tool = 0; let all = 0;
  for (let i = start; i < records.length; i += 1) {
    const r = records[i];
    if (r?.isSidechain === true || (r?.type !== 'user' && r?.type !== 'assistant')) continue;
    const c = r?.message?.content;
    for (const b of Array.isArray(c) ? c : [c]) { const n = size(b); all += n; if (b?.type === 'tool_result') tool += n; }
  }
  return {
    toolShare: all ? Math.round((100 * tool) / all) : null,
    compactions,
    lastCompact: last ? { trigger: last.trigger ?? null, before: last.preTokens ?? null, after: last.postTokens ?? null } : null,
  };
}
