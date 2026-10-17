const MS = { d: 86400000, h: 3600000, m: 60000, s: 1000, ms: 1 };
const ORDER = ['d', 'h', 'm', 's', 'ms'];
export function parseDuration(text) {
  if (typeof text !== 'string') throw new TypeError('not a string');
  if (text === '0') return 0;
  let t = text, sign = 1;
  if (t.startsWith('-')) { sign = -1; t = t.slice(1); }
  const re = /^(\d+(?:\.\d+)?)(ms|d|h|m|s)(?: ?)/;
  let total = 0, last = -1, any = false;
  while (t.length) {
    const m = t.match(re); if (!m) throw new TypeError('bad');
    const i = ORDER.indexOf(m[2]); if (i <= last) throw new TypeError('order');
    last = i; total += Number(m[1]) * MS[m[2]]; t = t.slice(m[0].length); any = true;
  }
  if (!any) throw new TypeError('empty');
  return sign * total;
}
