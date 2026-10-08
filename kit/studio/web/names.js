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
