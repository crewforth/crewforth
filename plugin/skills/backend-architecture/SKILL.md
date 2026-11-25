---
name: backend-architecture
description: |
  Decide, record and apply the backend stack and architecture pattern.
  Use when backend work starts with no recorded stack, or a framework/DB/pattern must be chosen.
---

# Backend Architecture (stack resolution + pattern)

<!-- routing-eval reads the next line; why it sits in the body: AGENT_TEMPLATE.md -->
Trigger phrases: "tech stack", "which framework", "choose a database", "backend pattern", "project structure", "new api", "new handler", "write a command", "add a query", "validator", "which stack should", "set up the project structure", "language or framework", "layered or", "vertical slice", "hexagonal", "clean architecture"

The "how" behind `crew-backend-expert`, and the stack step `crew-planner` and `crew-database-expert` rely on.
**Model discipline, not a gate:** no hook checks that the stack was resolved before code was written.

## When
- A backend task starts and `CLAUDE.md ## Stack` is empty or silent on the part the task needs.
- Someone asks which language, framework, database or pattern to use.
- A new service, API, module or handler is being shaped and the pattern is not obvious from neighbouring code.

## 1 · Stack resolution — in this order, stop at the first answer
1. **The request says it.** "Add a Go service…" is an answer. Use it; record it if the section was empty.
2. **`CLAUDE.md ## Stack` says it.** The project's own section (below Crewforth's `@.claude/DISCIPLINE.md` import),
   not `DISCIPLINE.md`. A filled section is a decision: follow it.
3. **The repo says it.** Look for manifests at the root and one level down (`backend/`, `server/`, `src/`, `apps/*`):

   | Manifest | Runtime |
   |:--|:--|
   | `package.json` | Node (TypeScript if `tsconfig.json`) |
   | `go.mod` | Go |
   | `pyproject.toml` / `requirements.txt` | Python |
   | `*.csproj` / `*.sln` | .NET |
   | `pom.xml` / `build.gradle*` | JVM (Java/Kotlin) |
   | `Cargo.toml` | Rust |
   | `composer.json` | PHP |
   | `Gemfile` | Ruby |

   The framework and database usually follow from the same manifest's dependencies and from config files
   (`docker-compose*.yml`, connection-string env names, migration folders). Two backends in one repo is a
   monorepo, not an ambiguity: record each with its path.
4. **Still open (a greenfield repo) → ask, once.** Use `AskUserQuestion` with **at most four** questions, only for
   what is still unknown: runtime/language · web framework · database · architecture pattern. **Every question has
   exactly one option whose label ends with `(Recommended)`** (its description gives the one-line reason) **and
   exactly one option labelled `Decide for me`, verbatim** — the user's way to hand the choice back to you.
   No `AskUserQuestion` in this session (headless, or the tool is off)? Write the same questions as text, with the
   same two labels on every question, and stop there.

**Record it.** Write the answer into the `## Stack` section of the project's `CLAUDE.md` (Runtime · Web framework ·
Database + migration tool · Architecture pattern), then record the choice with the `adr` skill (and `board.sh decide`
when the team board is in use). If "Decide for me" was picked, the ADR says so: *chosen by the agent at the user's
request*, with the reason for each pick.

**Never ask twice.** A recorded stack is followed, not re-litigated. It changes only when the user explicitly asks;
then update the section and supersede the ADR. Headless / non-interactive and nobody to ask → stop and report the
open question; do not guess a stack and start writing code.

## 2 · Pattern menu — default to the simplest one that fits (YAGNI)
| Pattern | Fits | Too much when |
|:--|:--|:--|
| **Layered** (controller → service → repository) | CRUD-heavy services, small teams, most first versions | rules sprawl across services and every change touches every layer |
| **Clean / hexagonal** (domain core, ports, adapters) | rich domain rules, several delivery channels or swappable infrastructure | the "domain" is mostly forms over tables |
| **Vertical slice** (one folder per feature, request → handler → response) | many independent features, teams owning features end to end | features share most of their logic |
| **CQRS** (separate command and query paths) | reads and writes that differ sharply in shape, load or consistency | reads and writes look the same — it doubles the code for no gain |

Existing code wins over this table: a repo already on a pattern keeps it, even where the table would pick another.
A change of pattern is an architecture decision → design summary + ADR, never a side effect of a feature.

## 3 · Rules that hold in any language
- **One error contract.** Every endpoint returns failures in the same envelope (e.g. RFC 9457 problem details or the
  project's own shape) with the correct status: 400 invalid input · 401 unauthenticated · 403 forbidden · 404 not
  found (also for another tenant's resource — do not leak existence) · 409 conflict · 422 rule violated · 5xx only for
  the server's own fault. No raw exceptions or stack traces in responses.
- **Validate at the edge.** Parse and validate input where it enters (request DTO + schema/validator), so the core
  only sees valid values. Business rules stay out of controllers/routes.
- **Cross-cutting concerns in one place** — logging, auth, transactions, caching, rate limits live in
  middleware / decorators / pipeline behaviours, not copied into each handler.
- **Dependencies are injected**, not constructed inside handlers; the composition root is the only place that knows
  concrete types.
- **Transaction boundaries are explicit**: one use case, one unit of work. No remote call inside an open DB transaction.
- **Idempotency** for anything a client may retry (payments, webhooks, create-with-client-id): an idempotency key or a
  natural unique constraint.
- **A shortcut is marked where it is taken:** `shortcut: <what was skipped> — remove when <condition>` in a comment,
  so `grep -rn "shortcut:"` lists the debt and its exit. A shortcut with no condition is a decision (see `adr`).
- **Secrets and personal data are never logged** — see `observability` for what to log and `privacy-compliance` for
  personal data.

## 4 · Ecosystem map — common choices, not requirements
| Runtime | Web | Validation | Data / migrations |
|:--|:--|:--|:--|
| .NET | ASP.NET Core (MediatR optional) | FluentValidation | EF Core |
| Node | NestJS / Fastify | zod | Prisma / Drizzle |
| Go | chi / echo | go-playground/validator | sqlc / GORM |
| Python | FastAPI | pydantic | SQLAlchemy / Alembic |
| JVM | Spring Boot | Bean Validation | JPA / Flyway |

The project's recorded choices beat this table. Adding a dependency that is not already in the repo → `dependency-audit`.

## 5 · Project override
A pattern skill the project ships under `.claude/skills/` wins over sections 2-4 — for example a `cqrs-aop-module`
kept from an older install, or one the team wrote (format: `.claude/AGENT_TEMPLATE.md`). Section 1 still applies:
the stack is resolved and recorded the same way.

## Not here — the single source is elsewhere
Schema and migrations → `db-migration` · tests → `testing` · review → `crew-code-review` · contracts and
versioning → `api-design` · logs/traces → `observability`.
