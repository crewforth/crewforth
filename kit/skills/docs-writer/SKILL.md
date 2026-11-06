---
name: docs-writer
description: |
  Keeps documentation in sync with the code: README, usage and related docs when a public API or behavior
  changes. Leaves no dead or misleading docs behind.
---

# Documentation

<!-- routing-eval reads the next line; why it sits in the body: AGENT_TEMPLATE.md -->
Trigger phrases: "documentation", "docs", "update README", "API docs", "write docs", "document it", "write usage"

Goal: the docs must **match the code**. Wrong/stale docs are worse than no docs (they inspire trust and mislead).
Trigger: when a public API, command, configuration, or user-visible behavior changes.

## When it is mandatory
- A public function/endpoint/CLI signature or behavior changed.
- A new feature, configuration key, or environment variable was added.
- The install/run steps changed.
- A breaking change was made (also coordinate via `release`/CHANGELOG).

## Checklist
- [ ] Docs are up to date for the changed public surface
- [ ] Examples **work** (copy-paste tested / mentally traced)
- [ ] Dead/misleading wording removed (no leftover old name/parameter)
- [ ] New configuration/env documented (default + whether required)
- [ ] Scope minimal — not a repetition of the code, but "why/how to use it"
- [ ] No secret/real credential in the docs (use a placeholder)

## How
1. **Identify the changed surface** — extract the public signature/behavior diff from the diff.
2. **Find the right doc** — README, `docs/`, docstring, OpenAPI, command `--help`. If there is more than one, update them all.
3. **Write**: what it does · how it is called (example) · input/output · limits/error cases. Short and correct.
4. **Verify the examples** — does the command/code example actually run.
5. **Clean up the old** — delete references to removed APIs/parameters.
6. **Translation**: if the user-visible doc is multilingual, coordinate with `i18n-integrity`.

## Principles
- **Single source** — behavior lives in the code; the doc *explains* it, does not copy it (a copied doc goes stale).
- **Example > paragraph** — a working example beats three paragraphs.
- **Minimal** — don't write a giant doc no one will maintain; answer the most-asked question.

## Co-authoring a longer doc (guide, tutorial, README rewrite)
For a substantial doc the content lives in the author's head, not the diff — don't guess it. Interview for intent
and audience, draft in passes, and let the user steer before you polish. The collaborative workflow (audience/intent
questions, outline-first, section-by-section drafting, revision loop): **`references/coauthoring.md`**.

## Invariant rules
1. **Correctness > completeness** — don't write a wrong doc; if unsure, flag it/ask.
2. **Examples must work.**
3. **Leave no stale/dead docs.**
4. **No secret/real credential** — use a placeholder (aligned with §4).
5. **Don't repeat the code** — don't just copy the signature; explain the usage.
6. **An external fact carries its date** — a version, limit, price or behaviour of a product this repository does not
   own is written with `checked: YYYY-MM-DD` and the URL it was read from. Older than 90 days, it is re-checked
   before it is quoted as current (the `confidence-check` skill says how: its source-check reference).
