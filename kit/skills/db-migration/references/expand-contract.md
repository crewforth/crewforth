# Expand/contract: changing a live schema without downtime

The rule behind every step: **at any moment, the code that is running and the code you might roll back to must
both work against the schema as it is.** During a rolling deploy two versions run at once; after a rollback the
older one runs against the newer schema. A step that breaks either is a step that causes an outage.

## Example: rename `users.email` → `users.contact_email`

| Release | Migration | Code |
|---|---|---|
| 1 · expand | `ADD COLUMN contact_email` (nullable) | unchanged — still reads and writes `email` |
| 2 · dual-write | none | writes `email` AND `contact_email`; reads `email` |
| — · backfill | none (a job) | copies `email` → `contact_email` where it is null, in batches of a few thousand rows, resumable |
| 3 · switch reads | optional: `NOT NULL` once the backfill is verified complete | reads `contact_email`; still writes both |
| 4 · stop writing | none | reads and writes `contact_email` only |
| 5 · contract | `DROP COLUMN email` — **separately approved** | unchanged |

The drop comes a release AFTER the last code that touches `email`: in a rolling deploy, release-3 instances still
write it while release 4 starts. And it waits until nothing that reads `email` (release 2 or older) can be rolled
back to. Dropping earlier lands a running or restored artefact on a column that is gone.

## Type changes and new constraints
- **Type change** (`text` → `integer`): the same shape — a new column of the new type, dual-write with the
  conversion, backfill, switch, drop. `ALTER COLUMN … TYPE` in place rewrites the table under a lock on most
  engines.
- **New `NOT NULL`**: add the column nullable (or with a default), backfill, then add the constraint. Where the
  engine supports it, add the check as not validated first and validate it in a second step, so the long scan does
  not hold the write lock.
- **New foreign key** on a large table: the same two-step add-then-validate where the engine has it.

## Indexes
A plain `CREATE INDEX` blocks writes for the length of the build. Build online: `CREATE INDEX CONCURRENTLY` on
PostgreSQL (it cannot run inside a transaction, so most tools need the migration marked non-transactional), an
online index build on the engines that offer one. Check the result: a concurrent build that fails leaves an
invalid index behind, which has to be dropped and built again.

## Backfills
- Batches with a bounded size and a pause between them; never one statement over the whole table.
- Idempotent (`WHERE contact_email IS NULL`), so a stopped job is resumed by running it again.
- Outside the deploy: a backfill in a migration holds the deploy open for as long as the table is large.
- Verify it finished (a count of the rows still to do is 0) before the release that depends on it.

## Deprecating an API or a feature
The same discipline one level up: never remove what a caller still uses.
- **Advisory → compulsory.** First announce: a deprecation header or log line, a date, the replacement. Measure who
  still calls it. Remove only when the measured use is zero, or when the date the users were given has passed.
- **Adapter.** Keep the old interface as a thin shim over the new implementation, so there is one code path to
  maintain while the old callers move.
- **Strangler.** Route a growing share of traffic to the new implementation behind the old entry point, until the
  old one serves nothing.
- **Remove the zombie code.** Once nothing calls it, delete it — the handler, its tests, its flag, its config.
  Code nobody calls still has to be read, kept compiling and kept secure.
