// Live, Stale or Offline: when did the panel last hear from its server.
//
// "Heard from" is any answer on any channel: the fleet poll, the project poll, an event on the graph stream. The
// fleet poll alone would be the wrong clock. Each of its answers waits on a `claude agents` spawn, which the server
// gives ten seconds, so a slow CLI stretches that poll while the rest of the panel is fed as usual.
//
// Measured, gaps between answers:
//   fleet poll, healthy       macOS 2.2 s quiet, 2.5 s under load · Windows 2.1 s quiet, 2.5 s under load
//   fleet poll, CLI takes 4 s      6.5 s
//   fleet poll, CLI takes 12 s    12.8 s   (every answer "not measured": the spawn timed out)
//   project poll, same two servers 5.2 s   (it does not wait on the CLI)
//
// So with every channel counted the longest healthy silence is one project poll, 5.2 s, and STALE_AFTER_MS is
// about twice that. Counting the fleet poll alone, ten seconds would have called a panel with a slow CLI stale
// while it was answering every five.
//
// Offline is not a longer silence. It is the last request failing: a refused connection answers at once, so there
// is nothing to wait for.
import { t } from './i18n.js';

export const STALE_AFTER_MS = 10000;

/**
 * @param nowMs        the clock
 * @param lastOkMs     when an answer last arrived, or null if none has
 * @param lastFailed   whether the most recent request failed
 * @returns { state: 'connecting' | 'live' | 'stale' | 'offline', word, detail, tone }
 */
export function liveness(nowMs, lastOkMs, lastFailed) {
  if (lastFailed) {
    return {
      state: 'offline',
      word: t('Offline'),
      tone: 'fail',
      detail: lastOkMs === null ? t('the server has not answered') : t('last update {time}', { time: clock(lastOkMs) }),
    };
  }
  if (lastOkMs === null) return { state: 'connecting', word: t('Connecting'), tone: null, detail: '' };
  const silence = Math.max(0, nowMs - lastOkMs);
  const said = t('{n}s ago', { n: Math.round(silence / 1000) });
  if (silence > STALE_AFTER_MS) return { state: 'stale', word: t('Stale'), tone: 'waiting', detail: said };
  return { state: 'live', word: t('Live'), tone: 'good', detail: said };
}

/**
 * What the stage says while the server is not answering: which picture is on screen, and when the next try is.
 *
 * The picture stays — it is the last thing known — and it is named as old. The countdown is to a request this
 * page is really going to make; "Retry now" makes it at once.
 *
 * @param state      liveness().state
 * @param nextTryMs  when the next poll is due, or null when none is scheduled
 */
export function offlineNote(state, lastOkMs, nextTryMs, nowMs) {
  if (state !== 'offline') return null;
  const left = nextTryMs == null ? null : Math.max(0, Math.ceil((nextTryMs - nowMs) / 1000));
  return {
    text: lastOkMs === null ? t('The server has not answered yet, so there is nothing to show.') : t('Showing the last update from {time}.', { time: clock(lastOkMs) }),
    retry: left == null ? t('Reconnecting') : left === 0 ? t('Reconnecting now') : t('Reconnecting in {n}s', { n: left }),
    stale: lastOkMs !== null,
  };
}

function clock(ms) {
  const d = new Date(ms);
  const two = (n) => String(n).padStart(2, '0');
  return `${two(d.getHours())}:${two(d.getMinutes())}`;
}

/**
 * Is the server older than the files it serves? The page is read from disk on every load; the server keeps the
 * code it started with. After an update the two disagree, and a view the old server has no route for answered
 * 404 (seen as "Not read — HTTP 404" on the Map view). /api/health says `code.changed` when the server's files
 * changed since it started; a server with no `code` at all predates the field, and is older than this page.
 * Returns the sentence to show, or null.
 */
export const RESTART_NOTE = t('Studio was updated after this server started, so it is running the old code. Restart it: stop it where it runs (Ctrl-C), then /crew-studio.');
export function staleServerNote(health) {
  if (!health || typeof health !== 'object') return null;
  if (!health.code || typeof health.code !== 'object') return RESTART_NOTE;
  return health.code.changed === true ? RESTART_NOTE : null;
}
