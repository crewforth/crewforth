// What an agent is called on screen.
//
// An agent's type is a file name: `crew-test-expert`, `general-purpose`. Drawn as it is, a column of cards reads
// "crew-…-expert" twelve times and the word that tells them apart is cut off first. The views show the role
// instead ("Test", "General Purpose"); the type itself is in the inspector and on hover, and nothing is renamed
// anywhere but on screen. Keys, ids and comparisons use the type.

// A word that is not written the way capitalising its first letter would write it.
const WORD = { devops: 'DevOps' };

/** The type as the transcript has it; an agent with none is said to have none. */
export const typeOf = (n) => n?.agentType ?? 'unknown agent';

/**
 * `crew-backend-expert` → Backend · `crew-session-manager` → Session Manager · `general-purpose` → General Purpose.
 * Crewforth's own prefix and its `-expert` / `-agent` suffix go; what is left is the role. A name that is not
 * made of hyphenated words (it has a space, or nothing to split) is returned as it came.
 */
export function roleName(type) {
  if (typeof type !== 'string' || !type || /\s/.test(type)) return type ?? '';
  const crew = type.startsWith('crew-');
  const core = crew ? type.slice(5).replace(/-(expert|agent)$/, '') : type;
  if (!core) return type;
  return core.split('-').filter(Boolean)
    .map((w) => WORD[w] ?? (w[0].toUpperCase() + w.slice(1)))
    .join(' ');
}

/** The name a node is drawn with. */
export const shownType = (n) => roleName(typeOf(n));

/** What hovering an agent says: the type as it is declared, and its task in full, since both are cut on screen. */
export const hoverOf = (n) => [n?.agentType ?? null, n?.description ?? null].filter(Boolean).join('\n');

/**
 * Where an agent stands among the ones the session called, as a tag: "#3 · 09:14". The number is the order of
 * the calls; the time is when the call was made, in the viewer's own zone. An agent the session's transcript did
 * not call has no place to state, and gets no tag.
 * @param clock  (ms) => "HH:MM"
 */
export function orderTag(n, clock = null) {
  if (n?.order == null) return '';
  return `#${n.order}${clock && n.calledAt != null ? ` · ${clock(n.calledAt)}` : ''}`;
}

/* ---------------------------------------------------------------- models --- */

const MODEL_FAMILIES = ['haiku', 'sonnet', 'opus', 'fable', 'mythos'];

/** The family a model belongs to, from its id or from the short name a call asks with: 'sonnet'. Null when none. */
export function modelFamily(model) {
  if (typeof model !== 'string') return null;
  return model.toLowerCase().split(/[^a-z]+/).find((w) => MODEL_FAMILIES.includes(w)) ?? null;
}

/**
 * A model as a badge says it: `claude-haiku-5-5` → Haiku 5.5 · `claude-haiku-4-5-20251001` → Haiku 4.5 ·
 * `sonnet` → Sonnet. The vendor prefix and a snapshot date go; the words lead and the numbers follow with a dot.
 * A name that is not made of such parts is returned as it came.
 */
export function modelName(model) {
  if (typeof model !== 'string' || !model) return '';
  const parts = model.replace(/^claude-/, '').replace(/-\d{8}$/, '').split('-');
  if (!parts.every((p) => /^[a-z]+$/.test(p) || /^\d+$/.test(p))) return model;
  const words = parts.filter((p) => /^[a-z]+$/.test(p)).map((w) => w[0].toUpperCase() + w.slice(1));
  const nums = parts.filter((p) => /^\d+$/.test(p));
  return [words.join(' '), nums.join('.')].filter(Boolean).join(' ');
}

/**
 * What a node ran on and what its call asked for, and whether the two agree.
 * A call asks with a family ("sonnet") or with an id; it agrees with what ran when the family is the same and,
 * if it named an id, the id is. A call that named nothing asked for the agent's default, and agrees with anything.
 * @returns { ran, asked, differs, title } — `ran` and `asked` are badge words, '' when not known
 */
export function modelOf(n) {
  const ran = modelName(n?.model);
  const asked = n?.modelAsked ? modelName(n.modelAsked) : '';
  const differs = Boolean(n?.model && n?.modelAsked)
    && (modelFamily(n.model) !== modelFamily(n.modelAsked) || (n.modelAsked.includes('-') && n.modelAsked !== n.model));
  const title = [
    `Ran on: ${n?.model ?? 'not recorded'}`,
    `Asked for: ${n?.modelAsked ?? 'no model named (the agent\'s default)'}`,
    differs ? 'The two differ.' : null,
  ].filter(Boolean).join('\n');
  return { ran, asked, differs, title };
}

/** "2 Sonnet, 1 Opus": how many of a group's agents ran on each family, most first. */
export function modelMix(members) {
  const counts = new Map();
  for (const m of members ?? []) {
    const f = modelFamily(m.model);
    const word = f ? f[0].toUpperCase() + f.slice(1) : (m.model ? modelName(m.model) : null);
    if (word) counts.set(word, (counts.get(word) ?? 0) + 1);
  }
  return [...counts].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0])).map(([w, c]) => `${c} ${w}`).join(', ');
}
