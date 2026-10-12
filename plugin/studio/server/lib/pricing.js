// API list prices, for the estimate the panel shows beside a session's tokens.
//
// THIS IS THE ONLY PLACE A PRICE IS WRITTEN. Everything is USD per million tokens, copied from the page named
// in SOURCE on the day named there. A model that is not in this table has no price here: its cost is not
// estimated from a neighbour, and the panel shows a dash.
//
// What the page says and this file follows:
//   - a cache write costs 1.25x the input price for the 5-minute cache and 2x for the 1-hour cache;
//   - a cache read costs 0.1x the input price, except where a model's row says otherwise (`cacheRead`);
//   - Claude Haiku 5.5 has a second set of prices for a prompt of over 100,000 tokens (`over`);
//   - fast mode has its own input and output prices (`fast`), and the cache multipliers apply on top of them;
//   - US-only inference multiplies every category by 1.1.
// What it does not cover: the Batch API discount, web search requests ($10 per 1,000), and prices on other
// cloud platforms. A session billed under any of those is estimated at the standard rate.

export const SOURCE = {
  url: 'https://platform.claude.com/docs/en/about-claude/pricing',
  read: '2026-10-08',
};

export const CACHE_WRITE_5M = 1.25;
export const CACHE_WRITE_1H = 2;
export const CACHE_READ = 0.1;
export const US_ONLY = 1.1;

// Keyed by the Claude API model id as a transcript records it. Only ids that were checked are here: the four
// current ones against the models overview page, and the four others against transcripts that name them.
export const PRICES = {
  'claude-fable-5-1': { input: 10, output: 50, cacheRead: 0.025 },
  'claude-opus-5-5': { input: 4, output: 20, cacheRead: 0.05, fast: { input: 8, output: 40 } },
  'claude-sonnet-5-5': { input: 2, output: 10, cacheRead: 0.05 },
  'claude-haiku-5-5': { input: 0.10, output: 0.50, over: { promptTokens: 100_000, input: 0.50, output: 2.50 } },
  'claude-opus-5': { input: 5, output: 25, fast: { input: 10, output: 50 } },
  'claude-opus-4-8': { input: 5, output: 25, fast: { input: 10, output: 50 } },
  'claude-sonnet-5': { input: 2, output: 10 },
  'claude-haiku-4-5': { input: 1, output: 5 },
};

/** The row for a model id, or null. A dated snapshot (`<id>-20260101`) is the same model; nothing else matches. */
export function priceOf(model) {
  if (typeof model !== 'string') return null;
  if (Object.hasOwn(PRICES, model)) return PRICES[model];
  const m = model.match(/^(.*)-\d{8}$/);
  return m && Object.hasOwn(PRICES, m[1]) ? PRICES[m[1]] : null;
}

/**
 * What one API response cost at list price, in USD. Null when the model has no row.
 * @param u { model, input, output, cacheWrite5m, cacheWrite1h, cacheRead, fast, usOnly } — token counts
 */
export function costOf(u) {
  const row = priceOf(u.model);
  if (!row) return null;
  const prompt = u.input + u.cacheWrite5m + u.cacheWrite1h + u.cacheRead;
  const tier = (u.fast && row.fast) || (row.over && prompt > row.over.promptTokens ? row.over : row);
  const read = row.cacheRead ?? CACHE_READ;
  const usd = (u.input * tier.input
    + u.cacheWrite5m * tier.input * CACHE_WRITE_5M
    + u.cacheWrite1h * tier.input * CACHE_WRITE_1H
    + u.cacheRead * tier.input * read
    + u.output * tier.output) / 1_000_000;
  return u.usOnly ? usd * US_ONLY : usd;
}
