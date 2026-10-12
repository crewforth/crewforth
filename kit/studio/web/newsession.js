// The New session panel: where a session runs, how much it may do, and what it is asked first.
//
// The choices are the server's. The projects are the ones it listed; the modes are the ones it offers, and this
// file can describe a mode but cannot add one. Starting is guarded by a one-shot: two clicks start one session.
import { oneShot } from './convo.js';

/**
 * What each permission mode means for a session started HERE.
 *
 * Not the terminal's wording. In a terminal a mode decides what Claude Code asks about. Here every tool call
 * waits in the approval dock whatever the mode, and an answer given there is the approval: outside plan mode the
 * gate tells Claude Code so. That leaves two modes that behave alike in Studio, and the panel says that instead
 * of repeating a difference that only exists in a terminal.
 */
export const MODE_TEXT = {
  plan: { word: 'Plan', says: 'Reads and plans. Cannot change files.' },
  acceptEdits: { word: 'Accept edits', says: 'Edits files and runs commands, each one after you allow it in the approval dock.' },
  default: { word: 'Default', says: 'The same in Studio: every call waits for you. It differs from Accept edits only in a terminal.' },
};

const PREFERRED = 'plan';

/** The modes to offer: exactly the server's list, in its order, each with what is known about it. */
export function modeChoices(offered) {
  const list = Array.isArray(offered) ? offered.filter((m) => typeof m === 'string') : [];
  const initial = list.includes(PREFERRED) ? PREFERRED : (list[0] ?? null);
  return list.map((mode) => ({
    mode,
    // A mode this file has no words for is still the server's to offer: it is shown under its own name.
    word: MODE_TEXT[mode]?.word ?? mode,
    says: MODE_TEXT[mode]?.says ?? null,
    initial: mode === initial,
  }));
}

/** The projects a session can be started in: on this machine, with a directory that is still there. */
export function projectChoices(projects, preferKey = null) {
  const list = (projects ?? []).filter((p) => p.local !== false && p.exists && p.cwd);
  const initial = list.find((p) => p.key === preferKey) ?? list.find((p) => p.current) ?? list[0] ?? null;
  return list.map((p) => ({
    key: p.key,
    cwd: p.cwd,
    label: p.label ?? p.cwd,
    branch: p.branch ?? null,
    kit: p.kit?.installed ? (p.kit.version ?? 'installed') : null,
    initial: p === initial,
  }));
}

/** "Runs in <path> on branch <branch>." — the branch only when the server read one. */
export function runsIn(choice, shorten = (p) => p) {
  if (!choice) return null;
  return { path: shorten(choice.cwd), branch: choice.branch };
}

function mk(tag, cls, text) {
  const n = document.createElement(tag);
  if (cls) n.className = cls;
  if (text != null) n.textContent = text;
  return n;
}

export class NewSession {
  /**
   * @param onStart  ({ cwd, permissionMode, first }) => Promise<{ ok, reason? }>
   * @param onClose  () => void
   * @param shorten  path => the short form the rest of the panel uses
   */
  constructor(root, { onStart, onClose, shorten } = {}) {
    this.root = root;
    this.onClose = onClose ?? (() => {});
    this.shorten = shorten ?? ((p) => p);
    this.projects = [];
    this.modes = [];
    this.mode = null;
    // Spent by the first click and re-armed only by opening the panel again, or by a start that was refused.
    this.start = oneShot((args) => (onStart ?? (() => ({ ok: false, reason: 'nothing to start' })))(args));
    this.#build();
  }

  #build() {
    const head = mk('div', 'np-head');
    const close = mk('button', 'btn icon sm ghost');
    close.type = 'button';
    close.setAttribute('aria-label', 'Close');
    close.innerHTML = '<svg class="ic" viewBox="0 0 16 16" aria-hidden="true"><path d="M4 4l8 8M12 4l-8 8"/></svg>';
    close.addEventListener('click', () => this.close());
    head.append(mk('h2', 'np-title', 'New session'), mk('span', 'row-fill'), close);

    const form = mk('form', 'np-body');
    form.addEventListener('submit', (e) => { e.preventDefault(); this.submit(); });

    const projWrap = mk('div', 'np-field');
    const projLabel = mk('label', 'np-label', 'Project');
    projLabel.htmlFor = 'np-project';
    this.projectEl = mk('select', 'np-select');
    this.projectEl.id = 'np-project';
    this.projectEl.addEventListener('change', () => this.paintRunsIn());
    this.runsEl = mk('span', 'sub np-runs');
    projWrap.append(projLabel, this.projectEl, this.runsEl);

    this.modesEl = mk('fieldset', 'np-modes');

    const firstWrap = mk('div', 'np-field');
    const firstLabel = mk('label', 'np-label', 'First message');
    firstLabel.htmlFor = 'np-first';
    this.firstEl = mk('textarea', 'np-first');
    this.firstEl.id = 'np-first';
    this.firstEl.rows = 5;
    this.firstEl.placeholder = 'What should this session do?';
    firstWrap.append(firstLabel, this.firstEl,
      mk('span', 'sub', 'Optional. You can also start empty and write in the conversation panel.'));

    // What starting here means, said before the button: a closed panel is a refusal.
    const note = mk('div', 'np-note');
    note.innerHTML = '<svg class="ic" viewBox="0 0 16 16" aria-hidden="true"><circle cx="8" cy="8" r="6"/><path d="M8 7.5v3.5M8 5h.01"/></svg>';
    note.append(mk('span', 'sub',
      'Every tool call in this session waits for your approval here in Studio. If Studio is closed, the request is denied.'));

    this.errorEl = mk('div', 'np-error');
    this.errorEl.setAttribute('role', 'alert');
    this.errorEl.hidden = true;

    form.append(projWrap, this.modesEl, firstWrap, note, this.errorEl);

    const foot = mk('div', 'np-foot');
    const cancel = mk('button', 'btn', 'Cancel');
    cancel.type = 'button';
    cancel.addEventListener('click', () => this.close());
    this.startEl = mk('button', 'btn primary', 'Start session');
    this.startEl.type = 'button';
    this.startEl.addEventListener('click', () => this.submit());
    foot.append(cancel, this.startEl);

    this.root.replaceChildren(head, form, foot);
  }

  get isOpen() { return !this.root.hidden; }

  /**
   * Show the panel. Opening one that is already open changes nothing — in particular it does not arm a second
   * start, so a second click on the bar's button cannot become a second session.
   */
  open({ projects, modes, preferKey } = {}) {
    if (this.isOpen) return false;
    this.projects = projectChoices(projects, preferKey);
    this.modes = modeChoices(modes);
    this.mode = this.modes.find((m) => m.initial)?.mode ?? null;
    this.firstEl.value = '';
    this.errorEl.hidden = true;
    this.start.arm();
    this.paint();
    this.root.hidden = false;
    return true;
  }

  close() {
    if (!this.isOpen) return;
    this.root.hidden = true;
    this.onClose();
  }

  get project() { return this.projects.find((p) => p.key === this.projectEl.value) ?? null; }

  paint() {
    this.projectEl.replaceChildren(...this.projects.map((p) => {
      const o = mk('option', null, p.kit ? `${p.label} · Crewforth ${p.kit}` : `${p.label} · no Crewforth`);
      o.value = p.key;
      o.selected = p.initial;
      return o;
    }));
    const initial = this.projects.find((p) => p.initial);
    if (initial) this.projectEl.value = initial.key;
    this.paintRunsIn();
    this.paintModes();
    this.paintStart();
  }

  paintRunsIn() {
    const r = runsIn(this.project, this.shorten);
    if (!r) {
      this.runsEl.textContent = 'No project on this machine to start a session in.';
      return;
    }
    const parts = ['Runs in ', mk('code', null, r.path)];
    if (r.branch) parts.push(' on branch ', mk('code', null, r.branch));
    parts.push('.');
    this.runsEl.replaceChildren(...parts);
  }

  paintModes() {
    const legend = mk('legend', 'np-label', 'Permission mode');
    const rows = this.modes.map((m) => {
      const row = mk('label', 'np-mode');
      const radio = mk('input');
      radio.type = 'radio';
      radio.name = 'np-mode';
      radio.value = m.mode;
      radio.checked = m.mode === this.mode;
      radio.addEventListener('change', () => { this.mode = m.mode; this.paintModes(); });
      row.classList.toggle('on', m.mode === this.mode);
      const text = mk('span', 'np-mode-text');
      const word = mk('span', 'np-mode-word', m.word);
      if (m.initial) word.append(mk('span', 'sub', ' · default'));
      text.append(word);
      if (m.says) text.append(mk('span', 'sub', m.says));
      row.append(radio, text);
      return row;
    });
    this.modesEl.replaceChildren(legend, ...rows, mk('span', 'sub', 'Modes that skip Crewforth\'s gates are not offered.'));
  }

  paintStart() {
    const busy = this.start.spent();
    this.startEl.disabled = busy || !this.project || !this.mode;
    this.startEl.textContent = busy ? 'Starting…' : 'Start session';
  }

  async submit() {
    const project = this.project;
    if (!project || !this.mode) return null;
    const pending = this.start({ cwd: project.cwd, permissionMode: this.mode, first: this.firstEl.value.trim() });
    this.paintStart();
    let out;
    try { out = await pending; } catch (e) { out = { ok: false, reason: e?.message ?? String(e) }; }
    if (out?.ok) {
      this.close();
    } else {
      this.errorEl.textContent = `Could not start a session — ${out?.reason ?? 'no reason given'}`;
      this.errorEl.hidden = false;
      this.paintStart();
    }
    return out;
  }
}
