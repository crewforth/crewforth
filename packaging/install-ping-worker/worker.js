// The endpoint behind Crewforth's install count (bin/cli.js, README → Telemetry).
//
//   GET /install?v=<version>   adds one to that version's count for the day (the server's own date). Answers 204.
//   GET /count                 every count, as JSON, to a caller holding the READ_KEY secret (Authorization:
//                              Bearer <key>); anyone else gets 404, as for any other path.
//
// What is kept: "<YYYY-MM-DD>|<version>" -> a number, in the COUNTS KV namespace. Nothing else is read from the request:
// not the IP, not a header (except Authorization on /count), not a cookie, and nothing is logged (observability is off
// in wrangler.toml). The version must look like one, so the store holds nothing a caller made up beyond a number.
// KV has no atomic increment: two installs in the same instant can be counted once. The figure is a lower bound,
// and a public counter can be inflated by anyone who calls it; neither changes what it is for — a weekly trend.
const VERSION = /^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$/;

export default {
  async fetch(req, env) {
    const url = new URL(req.url);
    if (req.method === 'GET' && url.pathname === '/install') {
      const v = url.searchParams.get('v') || '';
      if (v.length > 32 || !VERSION.test(v)) return new Response(null, { status: 400 });
      const key = `${new Date().toISOString().slice(0, 10)}|${v}`;
      const n = parseInt((await env.COUNTS.get(key)) || '0', 10) || 0;
      await env.COUNTS.put(key, String(n + 1));
      return new Response(null, { status: 204 });
    }
    if (req.method === 'GET' && url.pathname === '/count' && env.READ_KEY
        && req.headers.get('authorization') === `Bearer ${env.READ_KEY}`) {
      const out = {};
      let cursor;
      do {
        const page = await env.COUNTS.list({ cursor });
        for (const k of page.keys) out[k.name] = parseInt((await env.COUNTS.get(k.name)) || '0', 10) || 0;
        cursor = page.list_complete ? undefined : page.cursor;
      } while (cursor);
      return Response.json(out);
    }
    return new Response(null, { status: 404 });
  },
};
