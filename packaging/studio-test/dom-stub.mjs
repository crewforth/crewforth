// The smallest DOM that lets the browser modules evaluate.
//
// Written because two bugs in one afternoon were of a kind no syntax check
// sees: a const read inside its temporal dead zone, and an identifier used
// after its declaration was deleted. Both parse cleanly and both took the whole
// page down on load. Evaluating each module against a stub catches exactly that
// class, and nothing here pretends to be a rendering engine.

class El {
  constructor(tag = 'div') {
    this.tagName = String(tag).toUpperCase();
    this.children = [];
    this.style = new Proxy({ setProperty() {}, getPropertyValue: () => '' }, {
      get: (t, k) => (k in t ? t[k] : ''),
      set: (t, k, v) => { t[k] = v; return true; },
    });
    this.dataset = {};
    this.classList = {
      _s: new Set(),
      add: (...c) => c.forEach((x) => this.classList._s.add(x)),
      remove: (...c) => c.forEach((x) => this.classList._s.delete(x)),
      toggle: (c, on) => { if (on === undefined) { if (this.classList._s.has(c)) this.classList._s.delete(c); else this.classList._s.add(c); } else if (on) this.classList._s.add(c); else this.classList._s.delete(c); },
      contains: (c) => this.classList._s.has(c),
    };
    this.hidden = false;
    this.textContent = '';
    this.value = '';
    this.disabled = false;
    this.scrollTop = 0;
    this.scrollHeight = 0;
    this.clientHeight = 0;
  }
  set innerHTML(v) { this._html = v; }
  get innerHTML() { return this._html ?? ''; }
  set className(v) { this._cls = v; for (const c of String(v).split(/\s+/)) if (c) this.classList._s.add(c); }
  get className() { return this._cls ?? ''; }
  append(...n) { this.children.push(...n); }
  prepend(...n) { this.children.unshift(...n); }
  remove() {}
  replaceChildren(...n) { this.children = n; }
  // Listeners are kept, so a test can do what a pointer does and read what happened.
  addEventListener(type, fn) { (this._on ??= {})[type] ??= []; this._on[type].push(fn); }
  removeEventListener() {}
  emit(type, ev = {}) {
    const e = { target: this, button: 0, stopPropagation() {}, preventDefault() {}, ...ev };
    for (const fn of this._on?.[type] ?? []) fn(e);
  }
  setAttribute(k, v) { this[`attr_${k}`] = v; }
  getAttribute(k) { return this[`attr_${k}`] ?? null; }
  setPointerCapture() {}
  focus() {}
  click() {}
  closest() { return null; }
  querySelector() { return new El(); }
  querySelectorAll() { return []; }
  getBoundingClientRect() { return { x: 0, y: 0, top: 0, left: 0, right: 0, bottom: 0, width: 800, height: 600 }; }
}

export function installDom() {
  const doc = {
    documentElement: new El('html'),
    body: new El('body'),
    createElement: (t) => new El(t),
    createElementNS: (_ns, t) => new El(t),
    createTextNode: (t) => ({ nodeValue: t, textContent: t }),
    createDocumentFragment: () => new El('fragment'),
    getElementById: () => new El(),
    querySelector: () => new El(),
    querySelectorAll: () => [],
    addEventListener: () => {},
    visibilityState: 'visible',
  };
  const store = new Map();

  const g = globalThis;
  g.document = doc;
  g.window = g;
  g.location = { href: 'http://127.0.0.1:7777/?token=stub', search: '?token=stub' };
  g.localStorage = {
    getItem: (k) => (store.has(k) ? store.get(k) : null),
    setItem: (k, v) => store.set(k, String(v)),
    removeItem: (k) => store.delete(k),
  };
  g.getComputedStyle = () => ({ getPropertyValue: () => '260px' });
  // A wide, dark-preferring window: no query matches, and none ever changes.
  g.matchMedia = () => ({ matches: false, addEventListener() {}, removeEventListener() {} });
  g.addEventListener = () => {};
  g.removeEventListener = () => {};
  g.CSS = { escape: (s) => String(s) };
  // Nothing may reach the network or keep the process alive.
  g.fetch = () => Promise.resolve({ ok: true, json: () => Promise.resolve({}) });
  g.EventSource = class { constructor() {} addEventListener() {} close() {} };
  g.requestAnimationFrame = (fn) => setTimeout(fn, 0);
  g.atob = (b) => Buffer.from(b, 'base64').toString('binary');
  g.btoa = (b) => Buffer.from(b, 'binary').toString('base64');
  g.KeyboardEvent = class {};
  g.Event = class {};
  // node defines navigator as a getter-only property, so it is patched rather
  // than replaced.
  if (!globalThis.navigator?.clipboard) {
    try {
      Object.defineProperty(g, 'navigator', {
        value: { ...(globalThis.navigator ?? {}), clipboard: { writeText: () => Promise.resolve() } },
        configurable: true,
      });
    } catch { /* a navigator without a clipboard is enough to evaluate */ }
  }

  const timers = [];
  const realInterval = g.setInterval;
  g.setInterval = (fn, ms) => { const t = realInterval(fn, ms); timers.push(t); if (t.unref) t.unref(); return t; };
  return () => { for (const t of timers) clearInterval(t); };
}
