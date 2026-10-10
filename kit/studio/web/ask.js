// The two requests that are not answered with allow or deny: a question the model asks, and a plan it wants
// approved. This file draws the form for each and hands back what the viewer chose.
//
// A form is built once for a request and kept while the request waits. The dock and the List redraw around it every
// second; a form rebuilt on each of those would lose what was picked, and what was being typed.
import { answersOf, PLAN_CHOICES } from './approvals.js';

function mk(tag, cls, text) {
  const n = document.createElement(tag);
  if (cls) n.className = cls;
  if (text != null) n.textContent = text;
  return n;
}

export class AskForms {
  /** @param onDecide (item, verdict, extra) => void — 'answer' with { answers }, 'plan' with { mode }, or 'deny' */
  constructor(onDecide) {
    this.onDecide = onDecide ?? (() => {});
    this.forms = new Map();     // request key -> { el, sent(on) }
  }

  /** The form for a request, the same element every time it is asked for. Null for an ordinary tool call. */
  get(item) {
    if (!item?.ask) return null;
    let f = this.forms.get(item.key);
    if (!f) {
      f = item.ask.kind === 'plan' ? this.#plan(item) : this.#questions(item);
      this.forms.set(item.key, f);
    }
    return f.el;
  }

  /** An answer was sent, or could not be delivered: the form's controls go off, or come back. */
  setSent(key, on) { this.forms.get(key)?.sent(on); }

  /** Forget the forms of requests that are no longer waiting. */
  keep(keys) {
    const alive = new Set(keys);
    for (const k of [...this.forms.keys()]) if (!alive.has(k)) this.forms.delete(k);
  }

  #questions(item) {
    const el = mk('div', 'ask');
    const picked = new Map();   // question -> Set of labels
    const typed = new Map();    // question -> the viewer's own text
    const controls = [];
    const send = mk('button', 'btn sm primary', 'Send answers');
    const refresh = () => { send.disabled = send.dataset.sent === '1' || answersOf(item.ask, picked, typed) === null; };

    for (const q of item.ask.questions) {
      picked.set(q.question, new Set());
      const box = mk('div', 'ask-q');
      const head = mk('div', 'ask-head');
      if (q.header) head.append(mk('span', 'ask-tag', q.header));
      head.append(mk('span', 'ask-text', q.question));
      if (q.multiSelect) head.append(mk('span', 'sub', 'choose any'));
      const opts = mk('div', 'ask-opts');
      opts.setAttribute('role', q.multiSelect ? 'group' : 'radiogroup');
      const buttons = [];
      for (const o of q.options) {
        const b = mk('button', 'ask-opt', o.label);
        b.type = 'button';
        b.title = o.description;
        b.setAttribute('role', q.multiSelect ? 'checkbox' : 'radio');
        b.setAttribute('aria-checked', 'false');
        b.addEventListener('click', () => {
          const set = picked.get(q.question);
          if (q.multiSelect) { if (set.has(o.label)) set.delete(o.label); else set.add(o.label); } else {
            // One answer: choosing an option takes the place of anything typed, and of the option chosen before.
            set.clear(); set.add(o.label);
            own.value = ''; typed.delete(q.question);
          }
          for (const x of buttons) x.el.setAttribute('aria-checked', String(set.has(x.label)));
          refresh();
        });
        buttons.push({ el: b, label: o.label });
        controls.push(b);
        opts.append(b);
      }
      // The model's options do not always hold the answer: the viewer's own words are an answer too.
      const own = mk('input', 'ask-own');
      own.type = 'text';
      own.placeholder = q.multiSelect ? 'Something else, as well…' : 'Something else…';
      own.setAttribute('aria-label', `Your own answer to: ${q.question}`);
      own.addEventListener('input', () => {
        typed.set(q.question, own.value);
        if (!q.multiSelect && own.value.trim()) {
          picked.get(q.question).clear();
          for (const x of buttons) x.el.setAttribute('aria-checked', 'false');
        }
        refresh();
      });
      controls.push(own);
      box.append(head, opts, own);
      el.append(box);
    }

    const acts = mk('div', 'ask-acts');
    const dismiss = mk('button', 'btn sm', 'Dismiss');
    dismiss.type = 'button';
    dismiss.title = 'Refuse the question. The model is told nobody answered and may ask in words instead.';
    send.type = 'button';
    send.addEventListener('click', () => {
      const answers = answersOf(item.ask, picked, typed);
      if (answers) this.onDecide(item, 'answer', { answers });
    });
    dismiss.addEventListener('click', () => this.onDecide(item, 'deny', {}));
    controls.push(dismiss);
    acts.append(dismiss, send);
    el.append(acts);
    refresh();
    return { el, sent: (on) => { send.dataset.sent = on ? '1' : '0'; for (const c of controls) c.disabled = on; refresh(); } };
  }

  #plan(item) {
    const el = mk('div', 'ask');
    const plan = mk('pre', 'ask-plan', item.ask.plan || 'The plan was not included in the request.');
    plan.tabIndex = 0;
    const acts = mk('div', 'ask-acts');
    const keep = mk('button', 'btn sm', 'Keep planning');
    keep.type = 'button';
    keep.title = 'Refuse to leave plan mode. The model stays in it and goes on planning.';
    keep.addEventListener('click', () => this.onDecide(item, 'deny', {}));
    const controls = [keep];
    acts.append(keep);
    PLAN_CHOICES.forEach((c, i) => {
      const b = mk('button', i === PLAN_CHOICES.length - 1 ? 'btn sm primary' : 'btn sm', c.label);
      b.type = 'button';
      b.title = c.title;
      b.addEventListener('click', () => this.onDecide(item, 'plan', { mode: c.mode }));
      controls.push(b);
      acts.append(b);
    });
    el.append(plan, acts);
    return { el, sent: (on) => { for (const c of controls) c.disabled = on; } };
  }
}
