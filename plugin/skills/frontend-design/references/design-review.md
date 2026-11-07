# Tokens, scales, and heuristic review

Loaded on demand. The SKILL.md levers are the method; this is the concrete scales and the review pass.

## Scales — turn ad-hoc values into a system

**Spacing** — one base unit, multiples only. A 4px (or 8px) base: `4 · 8 · 12 · 16 · 24 · 32 · 48 · 64`. Every margin/padding/gap picks from this list — never `13px` because it "looked right". Consistency is what reads as designed.

**Type scale** — a small set of steps from a ratio (~1.2–1.25). Example: `12 · 14 · 16 · 20 · 24 · 32 · 40`. Body ~16, line-height ~1.5; headings tighter (~1.2). Limit weights to 2–3 (e.g. 400/600/700). One or two families max.

**Radius / border / shadow** — also scales, not one-offs: e.g. radius `4 · 8 · 16 · full`; elevation as 2–3 defined shadow steps. Consistent elevation communicates depth; random shadows look noisy.

**Color ramp** — a neutral scale (e.g. 50→900) plus one accent and semantic colors (success/warning/error/info), each with an on-color that meets contrast. Don't hand-pick greys per component; pull from the ramp.

## Tokens — name the decisions

Once the scales exist, name them as tokens (CSS custom properties / theme object / design-token file) so a change is one edit, not fifty: `--space-4`, `--text-lg`, `--color-accent`, `--radius-md`. **First detect the project's existing token layer and extend it**; only introduce tokens where none exist, and match the project's naming. Semantic tokens (`--color-surface`, `--color-text-muted`) layer over primitive ones and make dark-mode/theming a token swap rather than a rewrite.

## Dark mode & density

- **Dark mode** is not "invert" — it's a second set of semantic token values. Surfaces get lighter with elevation (not pure black); reduce saturation; re-check contrast in both themes.
- **Density** — if the product needs compact/comfortable modes, drive them from the spacing scale (a density multiplier), not per-component overrides.

## The heuristic review pass (run before handing UI back)

- **Squint test** — blur your eyes (or literally squint): does the primary action still stand out? If everything is equally loud, hierarchy failed.
- **Grayscale test** — remove color: does it still communicate hierarchy and state? If it only works in color, you're leaning on color to do type/space's job (and it will fail for color-blind users).
- **Spacing audit** — are there any values not on the scale? Any inconsistent gaps between similar groups?
- **Alignment audit** — do elements share alignment edges, or is everything slightly off? One stray alignment reads as sloppy.
- **State sweep** — force loading, empty, error, disabled, long-text, and tiny/huge viewport. Each should look intentional.
- **Consistency sweep** — same button in two places identical? Same card padding everywhere? Divergence is the top "assembled, not designed" tell.
- **Restraint check** — can anything be *removed*? A border that a gap already implies, a color that space already separates, a shadow doing nothing. Subtraction usually improves it.

Report design findings the way `crew-review-agent` expects: concrete (element + which lever + the fix), not "make it prettier".

## UI blockers: always high, never averaged down
A screen with one of these is not passable however polished the rest is:
- an interactive element with no accessible name
- no visible focus
- a task that only a pointer can finish (drag only, hover only)
- motion that ignores `prefers-reduced-motion`
- content clipped or overlapping at 320 px wide or at 200% zoom
- text that fails its contrast ratio
- meaning carried by colour alone
- a destructive action with neither a confirmation nor an undo
- text truncated with no way to read the rest
- an error the user cannot recover from on the screen where it happened

**The cheaper fix first.** Before adding anything: can it be deleted? Does the platform already do it (a native
`<dialog>`, `<details>`, a system font)? Is there a project token or component for it? Is it only a wrong value?
Only then add something new.

**Say what was looked at.** Name the screens, states and widths you inspected, and mark the rest "not reviewed".
An area nobody opened is never called clean, and a check that could not run (no browser, no data) is "not
verified", never a finding.
