---
name: a11y
description: |
  Frontend accessibility audit (WCAG): semantic HTML, keyboard access, focus management, contrast, ARIA, screen readers.
  Use when building or changing UI, or before shipping a user-facing screen.
---

# Accessibility (a11y)

<!-- routing-eval reads the next line; why it sits in the body: AGENT_TEMPLATE.md -->
Trigger phrases: "a11y", "accessibility", "WCAG", "screen reader", "keyboard navigation", "contrast", "ARIA", "keyboard only", "with a keyboard", "keyboard focus", "without a mouse", "focus ring", "tab order", "alt text", "color blind", "colour blind", "voiceover", "talkback", "reduced motion"

Goal: make the interface usable by **everyone**, including keyboard, screen reader, and low vision. Baseline target: **WCAG 2.1 AA**.
Stack-agnostic (web/React/RN); do a web search when needed for framework-specific APIs.

## Checklist
- [ ] **Semantic HTML**: `button`/`a`/`nav`/`main`/`h1..h6` correct; no `div`-buttons
- [ ] **Keyboard**: every interaction reachable via Tab, sensible order, visible **focus ring**
- [ ] **Focus management**: focus moves on modal/route change, focus trap correct
- [ ] **Contrast**: text ≥ 4.5:1, large text ≥ 3:1
- [ ] **Alt text**: `alt` on meaningful images; `alt=""` on decorative images
- [ ] **Forms**: every input has a `label`; error message programmatically linked (`aria-describedby`)
- [ ] **ARIA**: only when needed; wrong ARIA is worse than no ARIA; role/name/state correct
- [ ] **Motion/animation**: respect `prefers-reduced-motion`
- [ ] **Language**: `<html lang>` correct (coordinate with i18n)

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
