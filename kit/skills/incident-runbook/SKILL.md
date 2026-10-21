---
name: incident-runbook
description: |
  Incident response: diagnose → mitigate → resolve, then a blameless postmortem and a repeatable
  runbook. Stop the impact first, root cause second.
  Use when production is degraded or broken, an outage keeps recurring, or for the postmortem.
---

# Incident Response & Runbook

<!-- routing-eval reads the next line; why it sits in the body: AGENT_TEMPLATE.md -->
Trigger phrases: "incident", "incident response", "runbook", "postmortem", "root cause", "outage", "production incident", "post-incident"

Two modes: **live incident** (what to do right now) and **aftermath** (postmortem + runbook). Priority: stopping
user impact > finding the root cause. No panic, one ordered step at a time.

## Live incident — sequence
1. **Acknowledge & classify** — what is the impact (who, how much), severity (SEV1 full outage … SEV3 minor).
2. **Mitigate the impact FIRST** — rollback, turn off a feature flag, shift traffic, scale up. Without waiting on the root cause.
3. **Single coordinator** — it is clear who decides; communication goes through one channel.
4. **Diagnose** — last change? (deploy/migration/config) narrow it down with logs+metrics+traces (observability).
5. **Resolve** — the smallest safe fix; then verify (health check).
6. **Close** — confirm the impact is over; note the timeline (a postmortem input).

## Mitigation reflexes
- Last deploy suspect → **rollback** (deploy revert).
- Suspect feature → turn off the **feature flag**.
- After a destructive migration → restore from backup (db-migration).
- Dependency/service down → circuit breaker / graceful degradation.

## After the incident

Blameless postmortem + producing a durable runbook: **`references/postmortem.md`**.

## Invariant rules
1. **Stop the impact, then understand** — the root cause does not hold up the resolution.
2. **Blameless culture** — the postmortem questions the system, not the person.
3. **Actions are owned + dated** — no "we'll look at it later".
4. **The runbook is executable** — real commands/steps, not wishes.
5. **Make learning permanent** — the lesson goes into an adr/runbook/monitoring, it does not get lost.
