---
name: a11y
description: |
  Frontend accessibility audit (WCAG): semantic HTML, keyboard access, focus management, contrast, ARIA, screen readers.
  Use when building or changing UI, or before shipping a user-facing screen.
---

# Accessibility (a11y)

<!-- routing-eval reads the next line; why it sits in the body: AGENT_TEMPLATE.md -->
Trigger phrases: "a11y", "accessibility", "WCAG", "screen reader", "keyboard navigation", "contrast", "ARIA", "keyboard only", "with a keyboard", "keyboard focus", "without a mouse", "focus ring", "tab order", "alt text", "color blind", "colour blind", "voiceover", "talkback", "reduced motion", "target size", "focus not obscured", "focus is hidden", "WCAG 2.2"

Goal: make the interface usable by **everyone**, including keyboard, screen reader, and low vision. Baseline target: **WCAG 2.2 AA**.
Stack-agnostic (web/React/RN); do a web search when needed for framework-specific APIs.

## Checklist
- [ ] **Semantic HTML**: `button`/`a`/`nav`/`main`/`h1..h6` correct; no `div`-buttons
- [ ] **Keyboard**: every interaction reachable via Tab, sensible order, visible **focus ring**
- [ ] **Focus management**: focus moves on modal/route change, focus trap correct
- [ ] **Contrast**: text ≥ 4.5:1, large text ≥ 3:1
- [ ] **Alt text**: `alt` on meaningful images; `alt=""` on decorative images
- [ ] **Forms**: every input has a `label`; error message programmatically linked (`aria-describedby`)
- [ ] **ARIA**: only when needed; wrong ARIA is worse than no ARIA; role/name/state correct
- [ ] **Motion/animation**: respect `prefers-reduced-motion`; anything that moves for more than 5 s can be paused (2.2.2)
- [ ] **Language**: `<html lang>` correct (coordinate with i18n)

WCAG 2.2 added these; a 2.1 checklist misses all of them:
- [ ] **Focus not obscured** (2.4.11): a focused element is never fully hidden under a sticky header, footer or banner
- [ ] **Dragging** (2.5.7): every drag has a single-pointer alternative (buttons, a menu)
- [ ] **Target size** (2.5.8): pointer targets ≥ 24×24 CSS px, or spaced so a 24 px circle on each does not overlap another
- [ ] **Redundant entry** (3.3.7): information already given in the same flow is filled in or selectable, not asked again
- [ ] **Accessible authentication** (3.3.8): no memory or puzzle test to sign in without an alternative; paste and
  password managers work

Commonly missed, all checkable in the markup:
- [ ] **Autocomplete** (1.3.5): personal-data inputs carry the right `autocomplete` token
- [ ] **No paste blocking** on any input, passwords and confirmations included
- [ ] **Submit stays enabled**: a disabled-until-valid button hides why; validate on submit and say what is wrong
- [ ] **Zoom and reflow** (1.4.4, 1.4.10): usable at 200% text and at 320 CSS px wide; no `maximum-scale=1` or
  `user-scalable=no` in the viewport meta

## How
1. **Start with semantics** — the right element solves 80%. Use `button` instead of `role="button"`+`div`.
2. **Navigate with the keyboard** — drop the mouse, run the whole flow with Tab/Shift-Tab/Enter/Escape; is focus visible and its order sensible.
3. **Naming** — does every interactive element have an accessible name (`aria-label` on visual-only icon buttons).
4. **Contrast** — check color pairs against the ratio; don't convey meaning by color alone (add an icon/text).
5. **Dynamic content** — notify the screen reader via a live region (`aria-live`); manage modal focus.
6. **Automated + manual** — tools like linters/axe are the baseline; but manual keyboard+reader testing is essential (tools don't catch 100%).

## React / RN note
- Web React: semantic element in JSX + `htmlFor`/`aria-*`; use `button` instead of a clickable `div`.
- React Native: `accessible`, `accessibilityLabel`, `accessibilityRole`, `accessibilityState` (coordinate with `frontend-rn-expo`).
- Flutter: the guideline test (`meetsGuideline` with the tap-target, label and contrast guidelines) on every new screen (coordinate with `frontend-flutter`).

## Invariant rules
1. **Semantics first, ARIA second** — wrong ARIA does harm.
2. Must be **fully usable by keyboard** — without a mouse.
3. **Color cannot be the sole carrier of meaning.**
4. **Automated tools are not enough** — manual keyboard+reader testing.
5. **Follow the existing design system** — if there is a component library, keep its accessible pattern.
