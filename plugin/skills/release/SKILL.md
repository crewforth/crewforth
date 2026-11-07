---
name: release
description: |
  Versioning and CHANGELOG: SemVer mapped from Conventional Commits, Keep a Changelog format, tagging,
  pre-release gates.
  Use when cutting a version: bumping, writing the CHANGELOG entry, or tagging.
---

# Release & CHANGELOG

<!-- routing-eval reads the next line; why it sits in the body: AGENT_TEMPLATE.md -->
Trigger phrases: "release", "cut a release", "changelog", "version bump", "bump the version", "new version", "tag", "semver"

## SemVer mapping (derive from Conventional Commits)
- `fix:` → **PATCH** (x.y.Z)
- `feat:` → **MINOR** (x.Y.0)
- `BREAKING CHANGE:` / `feat!:` → **MAJOR** (X.0.0)

## CHANGELOG (Keep a Changelog)
Headings: **Added · Changed · Fixed · Removed · Security · Deprecated**.
Every version is dated; the `Unreleased` section can be auto-populated from commits.

## Pre-release gates (all must pass)
- [ ] **Something to release.** Commits since the last tag, and a version that is not on the registry yet. Nothing
      new → no tag, no draft release, no registry call: say so and stop. Every precondition here is checked before
      the first object outside the repository is created.
- [ ] Tests green + `sonarqube-check` PASSED
- [ ] `dependency-audit` clean (0 HIGH/CRITICAL)
- [ ] CHANGELOG up to date
- [ ] Version number conforms to SemVer
- [ ] **The release commit is a diff too (§4.6).** A `chore(release)` bump, a CHANGELOG-only edit and a docs-site
      version touch each stage a diff, and §4.6 exempts nothing by size — `crew-review-agent` runs over them like
      any other. A version that disagrees with the tag, a CHANGELOG entry naming the wrong one, a generated
      manifest edited by hand: that is what this review is for, and all three have shipped before.
- [ ] **Every distribution channel has a documented way to GET this version.** Publishing and reaching users are
      different events. A channel whose consumers pin at install time — an editor extension, a plugin, a vendored
      copy — leaves them on the version they installed until they ask for a new one, so a security fix ships and
      does not arrive. For each channel name the upgrade command in the README, and say plainly where it is not
      automatic.

## Tagging
```bash
git tag -a vX.Y.Z -m "vX.Y.Z"    # asks for approval (§4.4); push on explicit request (§4.5)
```

## After publish
- **Read it back from the registry**: the exact version exists and the dist-tag (`latest`, `next`, the channel
  name) points where it should. A pre-release must not move `latest`.
- **Install it from nothing.** In an empty temp directory, install the published version the way a user does and
  run its smallest smoke (the CLI's `--version`, an import, the first command).
- A check that cannot run here (no registry access, a store review pending) is reported as **partially verified**,
  with what is missing. It is a coverage gap, not a pass.

## DoD
- Correct SemVer bump; complete CHANGELOG; tag + rollback plan ready.
- After publish: the version and dist-tag read back, an install from an empty directory ran, or "partially
  verified" with the gap named.
