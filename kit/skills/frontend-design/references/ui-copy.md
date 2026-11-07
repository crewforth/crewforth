# UI copy

Loaded from `frontend-design` when a change adds or rewords text the user reads inside the product: buttons,
labels, errors, empty states, confirmations, status messages.

## Before writing
List the words the product already uses for its things and actions (grep the UI strings). One thing has one name
through the whole flow; a new word for an old thing is a bug.

## Buttons and links
- A button says what happens, as a verb and its object: "Save draft", "Delete 3 files", "Send invoice". Not
  "OK", "Submit", "Yes".
- The same verb carries through the flow: "Publish" → "Publishing…" → "Published".
- A link says where it goes; "click here" says nothing to a screen-reader user listing links.

## Errors
- Say what went wrong and how to fix it, next to the field it is about: "Enter a date after today", not
  "Invalid input".
- Never blame the user, never apologise at length, never stay vague ("Something went wrong") when the cause is
  known. When it is not known, say what the user can do: retry, or where to get help.
- Keep what the user typed.

## Confirm or undo
- Prefer undo for anything that can be reversed: do it at once and offer "Undo" for a few seconds.
- Confirm only what cannot be undone or is expensive. The dialog names the action and the object ("Delete the
  project 'Atlas' and its 12 files?"), and the confirming button repeats the verb ("Delete project"), never "OK".

## Empty states
An empty state says what will appear here and offers the one action that fills it ("No invoices yet. Create your
first invoice."). A first-use empty state, a no-results state and an error state are three different messages.

## Status
- Parallel states are written the same way: "Draft · Scheduled · Published", not "Draft · Will go out later ·
  Live now".
- Numbers carry their unit and the right plural form (use the project's i18n plural rules, never `n === 1`).
