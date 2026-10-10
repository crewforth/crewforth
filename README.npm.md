<p align="center"><img src="https://raw.githubusercontent.com/Crewforth/crewforth/main/assets/logo.svg" alt="Crewforth" width="420"></p>

**Crewforth is your engineering crew for Claude Code.** It adds subagents, skills, commands and hooks to Claude Code: 12 specialist agents that each own a domain, 40 skills that hold the method, 10 commands you start with `/crew-…`, and hooks that enforce the rules that matter.

```bash
npx crewforth init              # set up a new project
npx crewforth adopt             # hand it over onto an existing repository, on a branch
npx crewforth add <agent|skill> # copy one agent or skill into ./.claude
npx crewforth studio            # open the Studio panel; installs nothing
```

Then open Claude Code and run `/crew-doctor` to confirm the setup. Requires bash and git; on Windows, use Git Bash (the gates run only when Claude Code finds it; when it does not, the tools that write or run commands are stopped and `/crew-doctor` names the path to set).

[![npm](https://img.shields.io/npm/v/crewforth?style=flat-square&color=6D28D9)](https://www.npmjs.com/package/crewforth)
[![License](https://img.shields.io/badge/license-MIT-5c6472?style=flat-square)](https://github.com/Crewforth/crewforth/blob/main/LICENSE)

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/Crewforth/crewforth/main/assets/flow-en-dark.svg">
  <source media="(prefers-color-scheme: light)" srcset="https://raw.githubusercontent.com/Crewforth/crewforth/main/assets/flow-en-light.svg">
  <img src="https://raw.githubusercontent.com/Crewforth/crewforth/main/assets/flow-en-light.svg" alt="Command flow: /crew-plan, the specialists, /crew-review, /crew-ship with your approval, /crew-handoff" width="880">
</picture>

## Why Crewforth

- **Work goes to a specialist.** An unclear request is planned first, server work goes to `crew-backend-expert`, and a risky change is reviewed by `crew-security-expert` before it closes.
- **The rules that matter are enforced by gates, not remembered.** A destructive command is refused before it runs, a commit waits for your approval, and a leaked key or an AI-authorship trace never reaches history.
- **Every result is measured and published, including the ones that did not hold.** The method and every result are in the repository's `evals/README.md`.

## What you get

- **12 specialist agents**, from `crew-planner` to `crew-commit-agent`, each owning one domain.
- **40 skills** holding the method: testing, migrations, API contracts, observability, accessibility, deployment.
- **12 commands**, each started with its `/crew-…` name: `/crew-plan`, `/crew-review`, `/crew-ship`, `/crew-handoff`, `/crew-brainstorm`, `/crew-update`, `/crew-doctor`, `/crew-gates`, `/crew-skill`, `/crew-studio`, `/crew-approve`, `/crew-loosen`.
- **Safe adoption.** `adopt` lands everything on a branch, staged and uncommitted; `main` is never touched.

## Updating

When a new version is published, Claude asks once at the start of a session whether to update; it never updates on its own. Run `/crew-update` inside a session, or `npx crewforth@latest update`.

## Links

Documentation: [crewforth.com](https://crewforth.com) · Source and issues: [github.com/Crewforth/crewforth](https://github.com/Crewforth/crewforth) · Licence: MIT
