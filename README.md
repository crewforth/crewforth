<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/logo.svg">
  <source media="(prefers-color-scheme: light)" srcset="assets/logo-light.svg">
  <img src="assets/logo.svg" alt="Crewforth" width="420">
</picture>

![Version](https://img.shields.io/badge/version-3.1.0-6D28D9?style=flat-square)
![License](https://img.shields.io/badge/license-MIT-5c6472?style=flat-square)

🇬🇧 English · [🇹🇷 Türkçe](README.tr.md)

**Crewforth is your engineering crew for Claude Code.**

It adds subagents, skills, commands and hooks to Claude Code: 12 specialist agents that each own a domain,<br>
40 skills that hold the method, 10 commands you start with `/crew-…`, and hooks that enforce the rules that matter.

https://github.com/user-attachments/assets/ce17e971-c447-4147-8b33-6f4bda419821

Also on [crewforth.com](https://crewforth.com/#overview)

</div>

## Why Crewforth

- **Work goes to a specialist.** An unclear request is planned before any code is written, server work goes to `crew-backend-expert`, and a risky change is reviewed by `crew-security-expert` before it closes. A routing hook names the owner beside your request.
- **The rules that matter are enforced by gates, not remembered.** A destructive command is refused before it runs, a commit waits for your approval, and a leaked key never reaches history.
- **Every result is measured and published, including the ones that did not hold.** The same prompt is run with Crewforth and without it, and graded on what each left on disk. See [How we measure](#how-we-measure).

## Quick start

```bash
npx crewforth init              # set up a new project
npx crewforth add <agent|skill> # add one agent or skill only
npx crewforth studio            # open the Studio panel
```

You approve a summary before anything is written, and `add` copies into `./.claude` without the full install. For an existing repository, `npx crewforth adopt` lands everything on a separate branch, staged and uncommitted; `main` is never touched. Then run `/crew-doctor` in Claude Code to confirm the setup.

## How a session flows

<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/flow-en-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="assets/flow-en-light.svg">
    <img src="assets/flow-en-light.svg" alt="Command flow: /crew-plan, the specialists, /crew-review, /crew-ship with your approval, /crew-handoff" width="880">
  </picture>
</div>

| Step | Command | What happens |
|:--|:--|:--|
| Plan | `/crew-plan` | `crew-planner` turns the request into tasks with acceptance criteria |
| Build | (routed) | the owning agent writes the change and applies its skills |
| Review | `/crew-review` | security, privacy, performance and test audits run in parallel |
| Ship | `/crew-ship` | `crew-review-agent` records a clean review; `crew-commit-agent` proposes the commit and waits for you |
| Hand off | `/crew-handoff` | `handoff` writes the state down for the next session |

**10 commands** in all, each started with its `/crew-…` name: `/crew-plan`, `/crew-review`, `/crew-ship`, `/crew-handoff`, `/crew-brainstorm`, `/crew-update`, `/crew-doctor`, `/crew-gates`, `/crew-skill`, `/crew-studio`.

## The agents

**12 specialist agents**, each saying who owns the work and when. The method lives in the skills: [crewforth.com/skills](https://crewforth.com/skills).

| Agent | Owns |
|:--|:--|
| `crew-planner` | scope and acceptance criteria when a request is unclear |
| `crew-backend-expert` | server, API and business logic, in any stack |
| `crew-database-expert` | schema, migrations, indexes and caching |
| `crew-frontend-expert` | UI, components and client work, on web and mobile |
| `crew-devops-expert` | deployment, CI pipelines and incidents |
| `crew-security-expert` | auth, injection and secrets; required for security-critical changes |
| `crew-privacy-agent` | personal data under KVKK, GDPR and declared regimes |
| `crew-test-expert` | tests, coverage and regressions |
| `crew-performance-expert` | hot paths, queries, rendering and payloads |
| `crew-review-agent` | the code-health review a commit needs |
| `crew-commit-agent` | the commit proposal, which waits for your approval |
| `crew-session-manager` | session fill and the handoff |

## Gates

| Rule | Enforced by |
|:--|:--|
| Commit and push need your approval, in every permission mode; in `auto` and `dontAsk` it is your own message, `approve: commit`. If the gate says the approval path is closed (the recording hook is not wired, as in a worktree on an older Crewforth), press Shift+Tab or commit in your own terminal | `guard-bash.sh` and `prompt-approval.sh` |
| A commit needs a clean review of that exact diff | `guard-bash.sh` and the record `crew-review-agent` writes |
| Destructive commands (`reset --hard`, force push, `rm -rf`, `--no-verify`) are refused | `guard-bash.sh` |
| No AI-authorship trace reaches a commit | `pre-commit` and `commit-msg` git hooks |
| No API key, token or private key reaches a commit | `pre-commit` secret scan |
| A gate file cannot be edited or deleted to switch the gate off | `guard-write.sh` |

Every hook and rule: [crewforth.com/gates](https://crewforth.com/gates). Gates stop accidents, not determined attempts; for a hard boundary, use a devcontainer or a VM.

## Studio

Studio is a local panel that draws a delegation as it happens, in three views: a graph of who started whom, a timeline of the same agents against the clock, and a list sorted by what needs you. Selecting an agent opens what it is doing, what it has spent and what it reported. Each session shows its time, its tokens and an estimate of their cost at API list price. A session started from the panel asks before every tool call, in an approval dock; an unanswered request is denied. A session started in a terminal answers there, and the panel says which call it is waiting on. It reads every Claude Code session on the machine, opens with `/crew-studio` or `npx crewforth studio`, and binds to `127.0.0.1` only. More: [crewforth.com/studio](https://crewforth.com/studio).

## Install and update

| Channel | Command |
|:--|:--|
| npx | `npx crewforth init` for a new project, `npx crewforth adopt` for an existing one |
| Claude Code plugin | `/plugin marketplace add Crewforth/crewforth`, then `/plugin install crewforth@crewforth` |
| No Node | The GitHub release archive, see [crewforth.com/install](https://crewforth.com/install) |

**Requirements:** Claude Code 2.1.214 or later (tested on 2.1.282), and Node.js 20 or later for `npx` (22 or 24 recommended).

**Coming from the 2.x plugin?** The plugin and its marketplace were renamed, so a 2.x install does not update to 3.0 on its own. Switch once:

```
/plugin uninstall claude-starter-kit
/plugin marketplace add Crewforth/crewforth
/plugin install crewforth@crewforth
```

When a new version is published, Claude asks once, at the start of a session, whether to update now, later or never for that version; it never updates on its own. `/crew-update` runs the update and reports what changed, and `./CLAUDE.md` is never touched. What an older version installed and Crewforth no longer ships is moved to `.claude/.legacy-backup/` if it is unchanged, with a one-line restore; anything you edited stays where it is and is named. The three files Crewforth owns under `.claude/` (`DISCIPLINE.md`, `AGENT_TEMPLATE.md`, `README.md`) are refreshed on every update; a copy you edited is kept in `.claude/.legacy-backup/` first, and named. On Windows, use Git Bash; the gates run only when Claude Code finds it. When it does not, the tools that write or run commands are stopped, and the message and `/crew-doctor` name the path to set. Every option: [crewforth.com/install](https://crewforth.com/install).

## How we measure

We run the same prompt in a project with Crewforth and in a bare one, and grade each on what it left on disk. The rule a result must meet is written down before the run. Every result is published with its reasoning, including the ones where that rule did not hold: [`evals/README.md`](evals/README.md).

## Contributing, licence and links

Issues and pull requests are welcome at [github.com/Crewforth/crewforth](https://github.com/Crewforth/crewforth). A new agent or skill follows the contract in `kit/AGENT_TEMPLATE.md`, and `bash packaging/verify.sh` must pass.

MIT, see [LICENSE](LICENSE).

- **Documentation:** [crewforth.com](https://crewforth.com)
- **Sessions and cost:** [crewforth.com/sessions-and-cost](https://crewforth.com/sessions-and-cost)
- **Verification:** [crewforth.com/verification](https://crewforth.com/verification)
- **Extending:** [crewforth.com/extending](https://crewforth.com/extending)
