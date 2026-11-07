# Accessibility recipes: focus, forms, announcements

Loaded from the `a11y` skill when a change moves focus, validates a form or tells the user something happened.
Stack-neutral; the React Native and Flutter equivalents are named in the skill.

## Focus
- **Where focus goes after an action.** Opening a dialog: to its first meaningful control, or to the dialog itself
  when it starts with text. Closing it: back to the control that opened it. Deleting the focused row: to the next
  row, or the previous one when it was the last. A route change: to the new page's `h1` (`tabindex="-1"`), or to a
  skip target, so the reader starts at the content and not at the top of the navigation.
- **Visible focus.** Style `:focus-visible`, never remove `outline` without a replacement of at least 2 px with 3:1
  contrast against what surrounds it. A sticky header must not cover the focused element: set `scroll-padding-top`
  to its height.
- **Traps.** Only a modal traps focus, and Escape always leaves it. `inert` on the background is the simplest trap
  where it is supported.

## Forms
- Every field has a visible `label` tied by `for`/`id`; a placeholder is not a label.
- Validate on submit (and on blur for a field the user has left), not on every keystroke.
- On a failed submit: put a summary at the top that names how many errors there are and links to each field, move
  focus to it, and tie each field's message to the field with `aria-describedby` and `aria-invalid="true"`.
- Keep the submit button enabled; a disabled button cannot be focused and does not say what is missing.
- Required fields say so in text, not only with a colour or an asterisk the reader skips.
- Known personal data carries its `autocomplete` token (`name`, `email`, `tel`, `street-address`, `one-time-code`,
  `current-password`, `new-password`).

## Announcements: the cheapest channel that works
Use the first rung that fits; each one further down interrupts more.
1. **Move focus** when the user must act next (a dialog opened, an error summary).
2. **`aria-describedby`** when the message belongs to one control (a field hint, a field error).
3. **`role="status"`** (polite) for a result the user should hear without being interrupted: "Saved", "3 results".
4. **`role="alert"`** (assertive) only for something that cannot wait: a session about to expire, a failed payment.

Rules that make the live regions work:
- Render the region **empty** when the page loads and change its text later. A region that arrives together with its
  text is often not announced.
- One polite region per page is usually enough; reuse it instead of adding one per component.
- Do not announce what focus already says. Moving focus to an error summary and also putting it in an alert reads it
  twice.
- Toasts that disappear on their own need a status region and enough time to read (at least 5 s, longer for longer
  text), or a way to bring them back.
