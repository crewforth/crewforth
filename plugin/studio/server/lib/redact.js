// redact.js — what a viewer whose link hides transcripts is sent.
//
// Text that came from a transcript (a prompt, a reply, a tool's input or output, the short task an agent was given,
// a session's title) is not sent to such a viewer at all. Hiding it in the page would not do: it would still be on
// the wire and in the phone's memory.
//
// AN ALLOW-LIST, NOT A DENY-LIST. Transcript text only ever travels as a string, so every string in an answer is
// dropped unless its key is one of the few below, which name things that do not come from a transcript: ids,
// states, model and agent-type names, tool names, times as text. A field added to an answer tomorrow is therefore
// hidden until someone decides it is safe and adds its key here. Numbers, booleans and the shape of an answer pass,
// so the viewer still sees the agents, their states, their timing and what they cost.
//
// A few routes are nothing but transcript (a conversation, an agent's detail, the live conversation of a session
// the panel runs): those are refused outright rather than sent empty.

/** Keys whose string values are not transcript text. Checked by key name, wherever in the answer they are. */
export const SAFE_STRING_KEYS = new Set([
  // identity and links between things
  'id', 'sessionId', 'agentId', 'parentId', 'toolUseId', 'workflowId', 'workflow', 'source', 'target', 'origin',
  // kinds and states
  'kind', 'status', 'launchStatus', 'trigger', 'role', 'reason',
  // which model and which kind of agent, and which tool (a tool's NAME, never its input)
  'model', 'modelAsked', 'models', 'unpriced', 'agentType', 'toolName', 'lastTool', 'version',
  // where, as the machine knows it rather than as anybody wrote it
  'cwd', 'gitBranch', 'dir', 'url', 'read', 'at',
]);

// `label` is safe only where the server writes it from one of the safe things above (a session's short id, an agent
// type, 'workflow'); measured in lib/graph.js. Anywhere else it is dropped like any other string.
const LABEL_SAFE_KINDS = new Set(['session', 'agent', 'workflow']);

/** Routes that are nothing but transcript: refused for a viewer whose link hides transcripts. */
export function transcriptOnly(pathname) {
  return /^\/api\/session\/[^/]+\/(conversation|agent\/[^/]+)$/.test(pathname)
    || pathname === '/api/owned' || pathname === '/api/owned-events' || /^\/api\/owned\/[^/]+(\/.*)?$/.test(pathname);
}

/** The answer with every string that may be transcript text removed. A new object; the input is not touched. */
export function redact(value, key = null, parent = null) {
  if (typeof value === 'string') {
    if (SAFE_STRING_KEYS.has(key)) return value;
    if (key === 'label' && parent && LABEL_SAFE_KINDS.has(parent.kind)) return value;
    // A machine's name (an origin: no sessionId of its own). A session's `name` is its title, written from its
    // first prompt, and is dropped.
    if (key === 'name' && parent && parent.sessionId === undefined && typeof parent.local === 'boolean') return value;
    return undefined;
  }
  if (Array.isArray(value)) {
    return value.map((x) => redact(x, key, parent)).filter((x) => x !== undefined);
  }
  if (value && typeof value === 'object') {
    const out = {};
    for (const [k, v] of Object.entries(value)) {
      const r = redact(v, k, value);
      if (r !== undefined) out[k] = r;
    }
    return out;
  }
  return value;
}
