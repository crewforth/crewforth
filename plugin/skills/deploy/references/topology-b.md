# Topology B — managed platform (phases B1-B4)

Read this only when Phase 0 answered **B**: you have an API/CLI and no shell on the box, a release is an immutable
artefact, and rollback means re-pointing the environment at the previous one. On topology A read
`references/topology-a.md` instead — never both.

The invariant rules in SKILL.md hold over everything here, including the two that are B's alone: never rebuild to
roll back, and the platform's own status is not the health gate.

## Phase B1 — Build once, and know what you built
The artefact is produced **once**, and the same one moves through every environment. Rebuilding for production
means the thing you tested is not the thing you shipped — the inputs moved underneath you (a floating base
image, a lockfile resolved a minute later, a different builder). Two consequences:
- **Address it immutably.** A digest or a build id, never a moving tag. `latest`, `main` and a branch name all
  name different bytes on different days, which makes both promotion and rollback unverifiable.
- **Record which artefact is in which environment.** If nobody can answer "what exactly is running in
  production", rollback is a guess and the health gate has nothing to compare against.

## Phase B2 — Promote, do not rebuild
Deploying to the next environment means pointing that environment at an artefact that already exists and has
already passed the previous gate. Configuration is injected per environment, never baked into the artefact — the
same bytes must be able to run in staging and in production, or you are back to rebuilding. Secrets come from
the platform's own store; a secret inside the artefact ships to everyone who can pull it.

**Approval is per environment (§4.4), and per topology.** Promoting to a user-facing environment is a deploy,
whatever the platform calls it.

## Phase B3 — Health gate, from outside
Identical in spirit to Phase 4 (A) and worth stating because platforms invite the opposite: **the platform
reporting "deployed", "healthy" or "active" is not the verification.** It reports that its own reconciliation
finished. Check the thing users touch — a request through the public entry point, a real response body, the
version endpoint returning the version you promoted. Give it the same failure rule: if the gate does not pass,
go back before investigating.

## Phase B4 — Roll back by re-pointing
Rollback is promoting the previous artefact, not rebuilding the previous commit — a rebuild is a new artefact
with new inputs and it may not even reproduce the bug you are escaping. So:
- Keep the previous artefacts addressable for at least as long as you promise to be able to roll back. A
  retention policy that deletes them is a rollback policy that does not work.
- Rolling back **code** does not roll back a **migration**. If the release included an irreversible schema
  change, the old artefact may not run against the new schema — that is `db-migration`'s "Breaking change
  across deploys — expand/contract" section, and it has to be answered before the deploy, not during the incident.
- After a rollback, the environment is running an artefact older than the recorded state. Say so plainly to
  whoever is watching; a silent rollback is how two people fix the same outage twice.
