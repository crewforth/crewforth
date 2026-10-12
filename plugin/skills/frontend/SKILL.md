---
name: frontend
description: |
  Stack-agnostic frontend discipline (web · mobile · desktop): component structure, state, data fetching,
  loading/empty/error states, i18n, accessibility, performance. crew-frontend-expert applies it on every stack.
---

# Frontend Discipline (stack-agnostic)

<!-- routing-eval reads the next line; why it sits in the body: AGENT_TEMPLATE.md -->
Trigger phrases: "in the frontend", "frontend code", "frontend'de", "screen size", "component", "page", "the UI", "UI component", "UI bug", "state management", "interface"

Web, mobile (native iOS/Android, Flutter, React Native, .NET MAUI, KMP) or desktop — shared principles.
The stack-specific "how" (native bridge, router choice, etc.) lives in the relevant project skill; this skill applies to all of them.

## Client stack — resolve it before the first line, in this order; stop at the first answer
There is no default client stack, and none is suggested: the user chooses. **Model discipline, not a gate.**
1. **The request says it.** "Add a Flutter screen" is an answer. Use it; record it if `## Stack` was empty.
2. **`CLAUDE.md ## Stack` → `Client:` says it.** A filled line is a decision: follow it.
3. **The repo says it** — manifests at the root and one level down (`app/`, `mobile/`, `web/`, `client/`, `apps/*`):

   | Manifest | Client |
   |:--|:--|
   | `package.json` | web (framework from its dependencies); React Native/Expo if it depends on `react-native` or `expo` |
   | `pubspec.yaml` | Flutter |
   | `*.xcodeproj` / `Package.swift` | native iOS (Swift / SwiftUI) |
   | `build.gradle(.kts)` with the Android plugin | native Android (Kotlin / Compose); KMP if it applies `kotlin("multiplatform")` |
   | `*.csproj` with `<UseMaui>` | .NET MAUI |
4. **Still open (a new project) → ask, once.** A few questions at most (which platforms · which client stack), the
   options listed plainly — **no option marked recommended and no "Decide for me"**: the stack is the user's call.
   This is the one decision where the discipline's "give a clear recommendation" does NOT apply: state each option's
   trade-off and stop there. That Crewforth ships layers for two stacks (`frontend-rn-expo`, `frontend-flutter`) is
   not a reason to favour either (measured: the first version of this step still got "React Native + Expo (recommended)", because of it).
   No one to ask (headless) → write the questions as text and stop; do not start client code on a guessed stack.

**Record it** in the `Client:` line of `CLAUDE.md ## Stack`, plus an ADR (`adr` skill). **Never ask twice** — a
recorded client stack changes only when the user asks. Then apply this skill on that stack; an RN/Expo project
also applies `frontend-rn-expo`, a Flutter project `frontend-flutter`.

## Architecture
- **Presentation / logic separation:** component/view is pure and thin; business logic lives in the hook/composable/service layer.
- **Reusability:** repeated UI is factored out; the prop contract is clear and typed.
- **Folder:** feature-based (`features/<name>/`) — view, logic, and test together.

## State & data
- **Local state first** (`useState`/signal); if global is needed, the project's choice (store/context) — nothing imposed.
- **Data fetching:** cache + error + loading states are considered; race/abort are handled.

## State-complete UI (design it from the start)
Every data-bound view covers **four states**: **loading · empty · error · full**.
Don't code only the "full" case; empty/error/loading are part of the experience.

## i18n & accessibility (default, not decoration)
- User-visible text comes from the language file (project languages); no hard-coded strings (`i18n-integrity`).
- Meaningful labels/roles, sufficient contrast, keyboard/screen-reader access, appropriate touch/click target.

## Visual & UX quality
This skill covers *structure*; the **visual/UX design layer** — hierarchy, spacing rhythm, typographic scale, a
restrained color system, and polished states — lives in **`frontend-design`**. Apply it when the work is about how the
interface *looks and feels*, not just how it's wired.

## Responsive & performance
- Works across the target screen/device matrix (responsive/adaptive).
- Unnecessary renders (memo/callback), bundle size, lazy loading, virtualization for long lists.

## Verify at runtime (contract)
Prove a change works by **observing the running UI**, structured — not by interpreting a screenshot. Have components
emit `data-verify-*` state attributes, register verifiable units with fixtures + invariants (≥1 adversarial `probe`
each), expose `window.__verify`, and adopt the `PASS/FAIL/BLOCKED/SKIP` taxonomy (when in doubt, FAIL). Then drive
the browser to check it. The full convention: **`references/verify-contract.md`**.

## DoD (this skill's contribution)
- `/simplify`; no dead styles/unused props.
- The four states are covered; `i18n-integrity` clean; accessibility passes the baseline matrix.
- `crew-review-agent` clean.

## Constraints
- Surgical change; follow existing conventions, do not impose a stack/preference.
- Do not present data the platform does not provide as if it existed; do not promise a capability that isn't there.
- §4 applies: no AI trace or vendor template name in code/comments/strings.
