---
name: db-migration
description: |
  Apply schema migrations safely: detect the tool, classify the change by risk, gate destructive ones behind
  approval, back up in prod, preview-apply-verify, roll back on failure.
  Use when a schema change is about to be applied to any environment.
---

# Database Migration

<!-- routing-eval reads the next line; why it sits in the body: AGENT_TEMPLATE.md -->
Trigger phrases: "migration", "schema change", "update database", "add column", "create table", "alter table", "add a column to", "adding a column to", "drop a column", "rename the table", "change the column type", "backfill"

A migration is very often a **one-way gate**: once applied, going back is expensive or impossible
unless it was planned for. That is why the heart of the flow is not running a command, but **classifying
the change by risk class before it passes through the gate** — let the safe one flow through, stop and
get approval for the destructive one, and keep a rollback path ready in every case. The skill works with
all common ORM/migration tools.

> **Crewforth adaptation (local, .claude/):** Engine and tool come from `CLAUDE.md ## Stack` or repo detection
> (`backend-architecture`). `crew-database-expert` applies it; **a destructive migration requires explicit approval (§4.5)**, commit/push with explicit approval (§4.4). Authorization/IDOR
> impact → **crew-security-expert**; personal-data retention → **crew-privacy-agent**. §4 Prohibitions apply.

## Checklist
- [ ] Tool detected, pending migrations listed
- [ ] Every change classified (additive / destructive / ambiguous)
- [ ] Destructive/ambiguous changes approved by the user
- [ ] Backup taken (mandatory in prod, verified)
- [ ] Preview (dry-run) shown and approved
- [ ] Applied, schema verified post-apply
- [ ] Rollback path (tool or backup) ready

---

## 1. Detect the tool

Determine the tool from the file trace; if none is found, fall back to **raw SQL mode** (below); if several are found, ask the user.

| Trace | Tool |
|---|---|
| `prisma/schema.prisma` | Prisma |
| `knexfile.{js,ts}` | Knex |
| `.sequelizerc` / `config/config.json` + `models/` | Sequelize |
| `data-source.ts` (typeorm) / `ormconfig.ts` | TypeORM |
| `drizzle.config.ts` | Drizzle |
| `alembic.ini` / `alembic/` | Alembic |
| `manage.py` + `django` dependency | Django |
| `db/migrate/` + `rails` in Gemfile | Rails |
| `Microsoft.EntityFrameworkCore` in `*.csproj` + `Migrations/` | EF Core |

---

## 2. Classify the change — the heart of the flow

Extract the SQL to be applied (the "Preview" column in the matrix below) and place it into one of three classes:

| Class | Example operations | How it is handled |
|---|---|---|
| **Additive** (safe) | `CREATE TABLE`, nullable/defaulted `ADD COLUMN`, `CREATE INDEX`, non-destructive `ADD CONSTRAINT`, seed `INSERT` | Proceed in the normal flow |
| **Destructive** (dangerous) | `DROP TABLE/COLUMN/INDEX/CONSTRAINT`, `ALTER COLUMN … TYPE`, `TRUNCATE`, `DELETE` without WHERE, `RENAME` (breaks references) | **Always the approval gate** (below) |
| **Ambiguous** (human judgment) | `ALTER COLUMN`, `ADD COLUMN NOT NULL` without a default (blows up on a populated table), `UPDATE`, mixed migration | **Treat as destructive**, warn and ask |

**Approval gate (destructive/ambiguous):** list the operations one by one, show the environment and the target, wait for explicit approval. Even if "run" was said in the general flow, this gate requires separate approval.
```
WARNING — this migration contains a destructive operation:
  · DROP COLUMN "legacy_email" (table: users)
  · ALTER COLUMN "status" TYPE integer (table: orders)
CANNOT BE UNDONE without a backup.  Target: production (myapp_db @ db.example.com)
Continue? (yes / no)
```
If rejected, stop immediately and propose a safer path (e.g. a new column + background copy instead of changing the type).

### Breaking change across deploys — expand/contract
A rolling deploy runs the old and the new code against ONE schema at the same time, and a rollback runs the old
code against the new schema. So a rename, a type change or a new `NOT NULL` on a live table is never one
migration. It is a sequence, each step its own release:
1. **Expand** — additive only: the new column/table, nullable or defaulted. The old artefact must still run.
2. **Dual-write** — the code writes both shapes; reads stay on the old one.
3. **Backfill** in batches, outside the deploy, idempotent and resumable (never one `UPDATE` over the table).
4. **Switch reads** to the new shape; keep writing both until the rollback window has passed.
5. **Contract** — drop or rename the old shape in a LATER release, as its own migration through the approval gate
   above, approved separately: approving the expand does not approve the contract.

Build an index on a live table online (`CREATE INDEX CONCURRENTLY` on PostgreSQL, or the engine's equivalent); a
plain build locks writes. Each step with an example, and deprecating an API or a feature (warn → adapter →
removal, and deleting the code nobody calls any more): **`references/expand-contract.md`**.

---

## 3. Backup (mandatory in prod)

Back up before any migration; it cannot be skipped in prod, and can be skipped in dev with approval. Then verify
**the backup was created and is not empty** — otherwise abort:
```bash
[ -s "$BACKUP_FILE" ] || { echo "ERROR: Backup empty/not created — migration aborted."; exit 1; }
```
Backup + restore + post-apply verify commands **per engine** (PostgreSQL · MySQL · SQLite):
**`references/backup-restore.md`** — read the one for your database, not all three.

---

## 4. Tool × life-cycle matrix

Once classification and backup are complete: **Preview → (approval) → Apply → Verify**.

Per-tool commands for those four steps and for rollback — Prisma, Knex, Sequelize, TypeORM, Drizzle, Alembic, Django, Rails, EF Core: **`references/tool-matrix.md`**. Look up the one the project uses.

**Rules:** **Always** show the preview before applying and get it approved (if the tool does not support a dry-run, treat the migration file itself as the preview). A destructive migration is not applied without passing the approval gate (§2). Show the full apply output; if there is an error, roll back.

**Additional post-apply verification** — compare against the expected schema using your engine's inspect command (`references/backup-restore.md`).

---

## 5. Rollback

First the tool-specific rollback (last column of the matrix); if that fails, restore from the backup (per-engine
restore command in **`references/backup-restore.md`**); then re-verify. If neither works, warn the user with the full error detail.

---

## No tool — raw SQL mode

If no tool is detected, manage numbered up/down files (every `up` has a `down`, each SQL inside `BEGIN`/`COMMIT`)
with a `_migrations` tracking table. Full pattern + example + the apply loop: **`references/raw-sql.md`**.

---

## Invariant rules
1. **Classify first** — additive/destructive/ambiguous; treat the ambiguous as destructive.
2. **Destructive = human approval** — a separate gate even in an automated flow.
3. **Prod backup mandatory** — no apply without a verified backup.
4. **Preview on by default** — opting out requires an explicit request.
5. **Always verify after applying.**
6. **Rollback path always ready** — tool or backup.
7. **Show the target** — DB name/host/environment, before applying.
