// lan.js — the listener on this machine's Wi-Fi address, for viewers on the same network.
//
// It exists only while a viewer does: index.js calls sync() with the number of live viewers, and with none it is
// closed and every connection on it is ended, so nothing beyond 127.0.0.1 is listening. Every request it takes is
// marked `crewLan`, and the request gate (index.js) answers such a request only for a viewer's token — the panel's
// own token is not accepted from the network.
//
// Which address: the private IPv4 addresses of this machine's interfaces (10/8, 172.16/12, 192.168/16): the ranges a
// home or office Wi-Fi hands out. A public, link-local or carrier-grade address is not listened on. There is no
// tunnel here and no way to reach the panel from outside the network.
import http from 'node:http';
import os from 'node:os';

const PRIVATE = (a) => /^10\./.test(a) || /^192\.168\./.test(a) || /^172\.(1[6-9]|2\d|3[01])\./.test(a);

/** This machine's private IPv4 addresses. CREW_STUDIO_LAN_ADDR names one instead (the self-check uses loopback). */
export function lanAddresses(env = process.env, ifaces = os.networkInterfaces()) {
  if (env.CREW_STUDIO_LAN_ADDR) return [env.CREW_STUDIO_LAN_ADDR];
  const out = [];
  for (const list of Object.values(ifaces ?? {})) {
    for (const i of list ?? []) {
      const v4 = i.family === 'IPv4' || i.family === 4;
      if (v4 && !i.internal && PRIVATE(i.address) && !out.includes(i.address)) out.push(i.address);
    }
  }
  return out;
}

/**
 * The listener, opened and closed by the number of live viewers.
 * @param handler  the server's own request handler; a request is marked `req.crewLan = true` before it is called
 * @param port     the panel's port (CREW_STUDIO_LAN_PORT overrides it, for the self-check)
 */
export function lanListener({ handler, port, env = process.env, addresses = null }) {
  let servers = [];
  let errors = [];
  let pending = null;
  const lanPort = env.CREW_STUDIO_LAN_PORT !== undefined ? Number(env.CREW_STUDIO_LAN_PORT) : port;
  // The port actually listened on: the asked one, or the one the system picked for 0 (the self-check).
  const portOf = (e) => e.server.address()?.port ?? lanPort;

  const open = () => {
    const addrs = addresses ?? lanAddresses(env);
    errors = [];
    servers = addrs.map((addr) => {
      const sockets = new Set();
      const s = http.createServer((req, res) => { req.crewLan = true; handler(req, res); });
      s.on('connection', (c) => { sockets.add(c); c.on('close', () => sockets.delete(c)); });
      const entry = { addr, server: s, sockets, listening: false };
      s.on('error', (e) => { errors.push(`${addr}: ${e.code ?? e.message}`); entry.listening = false; });
      s.listen(lanPort, addr, () => { entry.listening = true; });
      return entry;
    });
    return new Promise((resolve) => { let n = servers.length; if (!n) resolve(); for (const e of servers) { e.server.once('listening', () => --n || resolve()); e.server.once('error', () => --n || resolve()); } });
  };

  const close = () => {
    const was = servers; servers = [];
    return Promise.all(was.map((e) => new Promise((resolve) => {
      for (const c of e.sockets) c.destroy();
      if (!e.listening) return resolve();
      e.server.close(() => resolve());
    })));
  };

  return {
    /** Open with at least one live viewer, close with none. Resolves once the change has happened. */
    sync(liveViewers) {
      pending = (pending ?? Promise.resolve()).then(() => {
        if (liveViewers > 0 && !servers.length) return open();
        if (liveViewers === 0 && servers.length) return close();
        return undefined;
      });
      return pending;
    },
    state() {
      const on = servers.filter((e) => e.listening);
      return { listening: on.length > 0, port: on.length ? portOf(on[0]) : lanPort,
        addresses: servers.filter((e) => e.listening).map((e) => e.addr), errors: [...errors] };
    },
    /** The link a viewer opens on the phone, one per address listened on. */
    urls(token) {
      return servers.filter((e) => e.listening).map((e) => `http://${e.addr}:${portOf(e)}/?token=${encodeURIComponent(token)}`);
    },
    close,
  };
}
