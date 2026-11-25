// settings-plan.js — what the project settings dialog shows, from /api/project-settings (DECISIONS 2026-11-17, N45).
// No DOM, so the self-check can hold it. The dialog (app.js) draws these rows and posts a change back.
//
// A setting says what was meant; git says what happens. Each sharing row carries what git does with the files today,
// and says so plainly when the two disagree — the panel never edits .gitignore, the user does.
import { t } from './i18n.js';

const word = (g) => (!g ? t('unknown') : g.tracked ? t('tracked') : g.ignored ? t('ignored') : t('untracked'));

/** The git line under a sharing row: `{ tone: 'ok'|'warn'|'muted', text }`. */
export function gitNote(kind, value, git) {
  if (!git) return { tone: 'muted', text: t('Not a git repository: nothing is committed either way.') };
  if (kind === 'visibility') {
    const parts = [git.claude, git.claudeMd];
    const list = `.claude/ ${word(git.claude)} · CLAUDE.md ${word(git.claudeMd)}`;
    if (value === 'shared' && parts.some((g) => g?.ignored && !g?.tracked)) {
      return { tone: 'warn', text: t('git: {list}. Git ignores what is meant to be shared; it is committed only once .gitignore stops ignoring it.', { list }) };
    }
    if (value !== 'shared' && parts.some((g) => g?.tracked)) {
      return { tone: 'warn', text: t('git: {list}. Files already committed stay in the repository until they are removed from it.', { list }) };
    }
    return { tone: 'ok', text: t('git: {list}.', { list }) };
  }
  const d = git.docs;
  const list = `docs/ ${word(d)}`;
  if (value === 'shared' && d?.ignored && !d?.tracked) {
    return { tone: 'warn', text: t('git: {list}. Git ignores what is meant to be shared; it is committed only once .gitignore stops ignoring it.', { list }) };
  }
  if (value !== 'shared' && d?.tracked) {
    return { tone: 'warn', text: t('git: {list}. Files already committed stay in the repository until they are removed from it.', { list }) };
  }
  return { tone: 'ok', text: t('git: {list}.', { list }) };
}

/** The dialog's rows. `null` when there is nothing to set (no install, or no answer). */
export function settingsRows(s) {
  if (!s || s.ok === false || !s.installed) return null;
  return [
    {
      key: 'visibility', label: t('Sharing'),
      help: t('Whether .claude/ and CLAUDE.md are committed with the project. A session reads it when it starts.'),
      choices: [{ value: 'shared', label: t('With the team') }, { value: 'private', label: t('Only me') }],
      value: s.visibility, unset: s.visibility === null,
      note: gitNote('visibility', s.visibility ?? 'private', s.git),
    },
    {
      key: 'docs', label: 'docs/',
      help: t('Whether the working documents under docs/ are committed. A session reads it when it starts.'),
      choices: [{ value: 'shared', label: t('Committed') }, { value: 'private', label: t('Private') }],
      value: s.docs, unset: s.docs === null,
      note: gitNote('docs', s.docs ?? 'private', s.git),
    },
    {
      key: 'profile', label: t('Gates'),
      help: t('Light: a clean commit or a push to a work branch is not asked. Takes effect at once.'),
      choices: [{ value: 'light', label: t('Light') }, { value: 'standard', label: t('Standard') }, { value: 'strict', label: t('Strict') }],
      value: s.profile, unset: false, note: null,
    },
    {
      key: 'verifyTimeout', label: t('Verify limit'),
      help: t("How long an agent's verify command may run, in seconds, from 1 to {max}. Takes effect at once.", { max: s.verifyMax }),
      number: { min: 1, max: s.verifyMax, fallback: s.verifyDefault },
      value: s.verifyTimeout, unset: s.verifyTimeout === null, note: null,
    },
  ];
}

/** May this navigator row open the dialog: a project on this machine, still there, with Crewforth in it. */
export const hasSettings = (p) => Boolean(p) && p.local !== false && Boolean(p.exists) && Boolean(p.kit?.installed);
