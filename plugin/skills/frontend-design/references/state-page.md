# The state page — every component, every state, and the inputs that break it

Loaded from `SKILL.md` lever 6. A screen designed in its happy state is a screen that has been seen once. This page is
where the other states are seen before a user meets them.

## What it is
One page (a route behind a dev flag, a Storybook-like story, or a test fixture page) that renders each component of
the change in every state it can be in, side by side:

| State | What to render |
|---|---|
| loading | the first paint and a slow one (a delay you can set) |
| empty | no items, and the one next step the empty state offers |
| error | a failed request, a validation error, a permission refused |
| one, few, many | one item, a handful, a thousand (does the list virtualize, does the layout hold) |
| disabled, focus, hover | each interactive element, keyboard focus visible |

## The inputs that break it
Render the same components again with what real data sends:
- a very long word and a very long sentence (no space to wrap on), and an empty string
- a name with accents, right-to-left text, and an emoji
- a number at its largest and with a minus sign; a date in another locale
- the narrowest and the widest screen the product supports, and the browser zoomed to 200%

A component that overflows, clips or reflows wrongly here is a finding with the state that caused it.

## What it is not
Not a design system and not a test suite: it is the place a person (or a browser check driven through
`frontend/references/verify-contract.md`) looks at the states. Keep it next to the components it shows, so a new
state is added in the change that adds it.
