---
name: deploy
description: |
  Ship a build reversibly — to a host you manage or a platform that manages it. Pick the topology first, keep
  the previous version reachable, gate on health, roll back without rebuilding. Use when shipping anywhere
  users can reach.
---

# Deploy

<!-- routing-eval reads the next line; why it sits in the body: AGENT_TEMPLATE.md -->
Trigger phrases: "deploy", "push to the server", "to the server", "onto the server", "build on the server", "install on the VPS", "ship it to the server", "go to production", "to production", "go live"

A deploy has a single idea, and it does not depend on where you are deploying: **make the new version live in a
way you can undo.** Keep the previous version reachable until the new one has proved itself; if it fails the
health gate, go back to the old one and nobody notices.

**Two topologies implement that idea differently, and mixing them is where deploys go wrong.** On a host you
manage, "reversible" means the previous release still sits on disk and the swap is a pointer you can move back.
On a platform that manages the host for you, "reversible" means the previous *artefact* is still addressable and
you re-point the environment at it — you do not rebuild it. Phase 0 picks the branch; everything after follows.

> **Crewforth adaptation (local, .claude/):** Any backend runtime (Docker recommended). **Deploy requires explicit
> approval (§4.4)**; a backup before every swap and a health gate after are mandatory. If `.deploy.yml` carries server
> credentials it goes into `.gitignore`. §4 Prohibitions apply.

## Phase 0 — Which topology
Answer before anything else, because the rest of the skill forks here. Ask if it is not obvious; do not infer it
from the language or the framework.

| | **A · Self-managed host** | **B · Managed platform** |
|---|---|---|
| You have | SSH to a machine you own or rent | an API/CLI, and no shell on the box |
| A release is | a directory on that host | an immutable artefact (image digest, build id, bundle) |
| "Deploy" means | put the files in place and restart | promote an existing artefact to an environment |
| Rollback means | move the pointer back to the previous directory | re-point the environment at the previous artefact |
| Owned by | **`references/topology-a.md`** (phases 1–5) | **`references/topology-b.md`** (phases B1–B4) |

Signals for B: the platform builds from a push, or the runtime is described as containers/functions/dynos/pods
that you do not administer. Signals for A: you are given a host, a user and a port. A Kubernetes cluster is B
when a controller reconciles it from a manifest, and A only if you are genuinely hand-placing files on nodes.

**If both are in play** — a managed platform in front, a self-managed worker behind — run the branches
separately and gate each on its own health check. One approval does not cover two topologies.

## Checklist (A · self-managed host)
- [ ] Topology decided (Phase 0)
- [ ] Runtime + deploy method determined
- [ ] Config taken from `.deploy.yml`/the user, SSH verified
- [ ] Reverse proxy + (if there is a domain) SSL in place
- [ ] Running version backed up to `releases/`
- [ ] User approved the deploy, new version deployed
- [ ] Health gate passed (otherwise automatic rollback performed)
- [ ] Public contract snapshot (status codes, key headers, key routes) taken before and diffed after
- [ ] If requested, single-command scripts (`deploy.sh` / `adopt.sh`) generated

## Checklist (B · managed platform)
- [ ] Topology decided (Phase 0)
- [ ] Artefact built once and addressed immutably (digest / build id, not a moving tag)
- [ ] Which artefact is in which environment is recorded
- [ ] Config and secrets injected per environment, not baked into the artefact
- [ ] User approved the promotion to this environment
- [ ] Health gate passed from OUTSIDE — not the platform's own status
- [ ] Previous artefact still addressable, and the migration question settled before the deploy
- [ ] Public contract snapshot (status codes, key headers, key routes) taken before and diffed after

---

## The phases — read ONE branch

Phase 0 picked it; loading both is the mistake this skill opens with.

- **A · self-managed host** → **`references/topology-a.md`**: runtime/method detection, `.deploy.yml` + SSH,
  reverse proxy and SSL, the backup-then-swap for Docker and bare-metal, the health gate, the rollback.
- **B · managed platform** → **`references/topology-b.md`**: build once and address it immutably, promote
  without rebuilding, health-gate from outside the platform, roll back by re-pointing.

The invariant rules at the end of this file hold on both, and they are the half that must not be read from a
reference file: they are what an approval is checked against.

## A staged rollout: advance, hold or roll back
When the platform sends a share of traffic to the new version first (canary, percentage, ring), each step is read
against the old version's numbers over the same window, not against a feeling:

| Signal, new vs baseline | Decision |
|---|---|
| Error rate above 2x the baseline, or p95 latency more than 50% above it | Roll back now |
| Error rate 1.2x-2x, or p95 20-50% above | Hold at this share and look; do not advance |
| Within that band, and the error budget for the period is not spent | Advance to the next share |
| The error budget is spent | Hold every rollout until it recovers |

The numbers are defaults to tune per service, and the user approves the changed ones. A step with too little
traffic to compare says so and holds; it does not advance on silence.

## Single-command scripts (optional)

After a successful deploy, **ask** whether to generate project-specific `deploy.sh` / `adopt.sh` (single-command
deploy/update). Derive the steps from the real project (package.json / Dockerfile / Makefile / compose), never a
generic template. Full guidance + what each script contains: **`references/scripts.md`**.

---

## Invariant rules
These hold on BOTH branches; where the mechanism differs, the rule does not.
0. **The topology is decided, not assumed** — Phase 0, once, out loud. Everything downstream depends on it.
1. **No deploy without approval** — show the method/host/domain/port plan, wait for approval.
2. **Always back up before the swap** — timestamped into `releases/`; if the backup fails, abort.
3. **Always a health gate after the swap** — HTTP + process; if it doesn't pass, automatic rollback.
4. **Keep the last 3 versions** — don't delete them all.
5. **Don't deploy to prod without knowing the target** — host/deploy_path/domain must be approved.
6. **Verify SSH first** — if you can't connect, fail fast.
7. **Don't expose the port directly** — the app binds to `127.0.0.1`, outward only through the proxy.
8. **SSL is mandatory when there's a domain** — always set it up unless `ssl` is explicitly `false`.
9. **Never rebuild to roll back** (B) — promote the previous artefact. A rebuild is a different artefact.
10. **The platform's own status is not the health gate** (B) — verify from where a user stands.
11. **Rolling back code does not roll back a migration** — settle the schema question before the deploy.
12. **Check before creating anything outside** — nothing new to deploy (same artefact as the one running, an empty
    diff) means no release object, no tag, no environment change: say so and stop.
