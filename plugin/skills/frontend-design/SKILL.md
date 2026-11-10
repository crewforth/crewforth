---
name: frontend-design
description: |
  Use when a screen should look more considered: polishing a UI, setting up or following a design system,
  or fixing a layout whose spacing, type or colour feels off.
---

# Frontend Design (visual & UX quality)

<!-- routing-eval reads the next line; why it sits in the body: AGENT_TEMPLATE.md -->
Trigger phrases: "visual design", "design system", "make it look good", "UI polish", "page layout", "the layout is", "spacing", "typography"

`frontend` decides how the code is structured; `a11y` decides whether everyone can use it; **this skill decides
whether it looks considered and feels right.** The through-line: **a few consistent decisions, applied everywhere,
read as "designed" — many one-off decisions read as "assembled".** Design is subtraction and rhythm, not adding flourish.

> **Crewforth adaptation (local, .claude/):** Stack-agnostic. **Detect and respect the project's existing design system**
> (tokens, component library, brand) — never impose a personal aesthetic or a new library. Accessibility is a floor,
> not a trade-off: apply `a11y` alongside (contrast, focus, motion). §4 Prohibitions apply.

## The six levers (order = impact; fix hierarchy before you touch color)
1. **Hierarchy** — the eye must land on the one primary thing first. Establish it with size, weight, and space — not with more color. One primary action per view; everything else is visibly secondary.
2. **Spacing & rhythm** — consistent spacing from a single scale (e.g. 4/8px steps). Group related things with *less* space, separate groups with *more*. Whitespace is the cheapest way to look premium.
3. **Typography** — one or two families, a small scale (≈4–6 steps), consistent line-height (~1.5 body). Limit weights. Measure ~45–75 chars per line. Type does most of the hierarchy work.
4. **Color** — a restrained system: 1 brand/accent, a neutral ramp, semantic states (success/warn/error). Accent is for *action and emphasis*, not decoration. Verify contrast (→ `a11y`) on the pair as it renders, alpha and the surface under it included; a failing pair is reported, not recoloured unasked, and the first fix is lightness, not hue.
5. **Layout & composition** — align to a grid; consistent alignment edges. Respect proximity/similarity (Gestalt). Responsive by *intent* (reflow, not just shrink); design the breakpoints, don't inherit them by accident.
6. **State & polish** — design loading / empty / error / disabled / hover / focus as first-class, not afterthoughts. Motion is restrained and purposeful: ~150–250ms, `ease-out` for enter and exit (never `ease-in` on UI), a strong custom curve rather than the built-in `ease`; it honors `prefers-reduced-motion`. Durations, easing, interruption and gestures: `references/motion.md`. The words on buttons, errors and empty states: `references/ui-copy.md`.

## When the project gives no design direction
Look for the project's own system first: a token file, a theme, the components it already has. If there is one,
follow it; the list below only fills a gap. With none, do not fall into these defaults on your own (use one when
the user asks for it):
- a cream or off-white ground with serif headings and a terracotta accent
- a purple-to-blue gradient hero on white
- a black ground with a single neon accent
- an italic accent word in headings
- "01 / 02 / 03" section numbers that tell no real sequence
- monospace labels on everything
- pill buttons and the same shadow everywhere
- emoji as section markers
- cards with a colored stripe along one edge

"Avoid a generic look" alone swaps one default for another; naming the patterns is what works. After the first
result, look at which default crept in and add it to this list for the project — iterate, don't restart.

**Two passes, not one.** Before building, write the plan in a few lines: the named colours, the type roles, the
layout, the one or two principles it follows. Then ask of that plan: "would I produce this for any similar prompt?"
Where the answer is yes, revise it toward this product. Build the revised plan, and say what the second pass changed.

## Checklist
- [ ] One clear primary action; hierarchy readable at a glance (squint test)
- [ ] All spacing from one scale; related grouped, groups separated
- [ ] Type scale limited and consistent; line length and line-height comfortable
- [ ] Color restrained; accent reserved for action; contrast passes (`a11y`)
- [ ] Aligned to a grid; responsive by intent with designed breakpoints
- [ ] Loading / empty / error / disabled states designed, not default
- [ ] Motion purposeful, reduced-motion honored
- [ ] Existing design tokens/system reused — nothing one-off invented
- [ ] Copy: buttons say what happens, errors say how to fix, empty states offer one next step (`references/ui-copy.md`)
- [ ] The greppable patterns in `references/detection.md` are absent from the diff

## Symptom → cause → fix
| Symptom | Usual cause | Fix |
|---|---|---|
| Everything looks equally loud | hierarchy carried by colour | size, weight and space first; one accent |
| "Assembled, not designed" | one-off spacing and radius values | pull every value from the scale |
| Text overflows its card on real data | fixed height, or a flex child without `min-width: 0` | let the box grow; `min-width: 0` / `minmax(0, 1fr)` |
| Animation feels sluggish | `ease-in`, or a duration over 300 ms on a small element | `ease-out`, 150–250 ms (`references/motion.md`) |
| Page jumps while it loads | images and embeds without reserved space | `width`/`height` or `aspect-ratio` on media |

---

## Tokens, scales, and a heuristic design review
Spacing/type/color scale systems, turning ad-hoc values into tokens, dark-mode and density variants, the UI
blockers that are always high, and a squint-test / heuristic-review pass to run before handing UI back:
**`references/design-review.md`**. A greppable pattern → fix table per lever: **`references/detection.md`**.

## Coordination
Architecture, state, and folder structure → `frontend`. Accessibility gate (contrast, focus, ARIA) → `a11y`.
Applied by **crew-frontend-expert** on any stack; the stack-specific "how" stays in the project's frontend skill.

## Invariant rules
1. **Hierarchy before decoration** — fix what the eye sees first before adding any color or flourish.
2. **One scale per dimension** — spacing, type, and radius each come from a single defined scale.
3. **Reuse the project's system** — detect existing tokens/components; never impose a new aesthetic or library.
4. **Accessibility is a floor** — contrast, focus, and reduced-motion are non-negotiable, not a style trade-off.
5. **Every state is designed** — loading/empty/error/disabled are part of the design, not defaults.
