// owned-stream.js — the conversations of several owned sessions, replayed then followed, on ONE connection.
//
// A browser holds six connections to one host over HTTP/1.1, and a pane per stream reached them at five panes
// beside the page's own: the panel kept painting, but a message sent and every request the page made itself waited
// until a pane was closed (measured on Windows, Claude Code 2.1.301: a send did not arrive in 35 s, then in 8 s once
// two panes closed). Each event and state carries the session id it belongs to.
//   ids=a,b,c          the sessions (at most MAX_STREAM_IDS; an unknown id is answered with `gone`)
//   after=a:12,b:3     resume each where the client last was, so a reconnect neither replays nor drops

export const MAX_STREAM_IDS = 32;

/** Read `ids` and `after` from a URL: the ids, de-duplicated and capped, and each one's resume point. */
export function parseOwnedQuery(url) {
  const ids = [...new Set((url.searchParams.get('ids') ?? '').split(',').filter(Boolean))].slice(0, MAX_STREAM_IDS);
  const after = new Map();
  for (const part of (url.searchParams.get('after') ?? '').split(',')) {
    const at = part.lastIndexOf(':');
    if (at > 0) after.set(part.slice(0, at), Number(part.slice(at + 1)) || 0);
  }
  return { ids, after };
}

/**
 * @param getSession  id -> an owned session ({ summary(), subscribe(fn, after) }) or null
 * @param stateAfter  the record types after which a session's summary is sent again
 * @param beatMs      how often every summary is sent regardless
 */
export function streamOwned(req, res, url, { getSession, stateAfter = new Set(), beatMs = 15000 }) {
  const { ids, after } = parseOwnedQuery(url);
  res.writeHead(200, {
    'content-type': 'text/event-stream; charset=utf-8',
    'cache-control': 'no-store',
    connection: 'keep-alive',
    'x-accel-buffering': 'no',
  });
  const write = (event, data) => {
    try { res.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`); } catch { /* client gone */ }
  };
  const unsubscribes = [];
  for (const id of ids) {
    const s = getSession(id);
    if (!s) { write('gone', { id }); continue; }
    write('state', { id, session: s.summary() });
    unsubscribes.push(s.subscribe((ev) => {
      write('event', { id, ev });
      if (stateAfter.has(ev.rec?.type)) write('state', { id, session: s.summary() });
    }, after.get(id) ?? 0));
  }
  const beat = setInterval(() => {
    for (const id of ids) { const s = getSession(id); if (s) write('state', { id, session: s.summary() }); }
  }, beatMs);
  const stop = () => { clearInterval(beat); for (const u of unsubscribes) u(); try { res.end(); } catch { /* gone */ } };
  req.on('close', stop);
  req.on('error', stop);
  return stop;
}
