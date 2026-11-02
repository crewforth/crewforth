---
name: dependency-audit
description: |
  Dependency risk assessment, read-only: known CVEs, deprecated packages, licence compliance, maintenance
  status, lockfile integrity, and a justification for every new dependency. Acting on it is dependency-upgrade.
---

# Dependency Audit

<!-- routing-eval reads the next line; why it sits in the body: AGENT_TEMPLATE.md -->
Trigger phrases: "dependency audit", "npm audit", "package security", "CVE", "license", "deprecated package", "still maintained", "no longer maintained", "unmaintained", "third party library", "supply chain", "add a dependency", "add a new dependency", "add the package", "install the package", "lockfile", "lock file", "package-lock", "yarn add", "pnpm add", "pip install", "uv add", "cargo add", "paket ekle", "paketi ekle", "paketini ekle", "bagimlilik ekle", "kutuphane ekle"

**The real trigger is an event in the diff, not a word in the request: a lockfile is staged.** Nobody asks for an
audit while adding a feature, so the phrases above only catch the request that names the package; the commit gate
(§4.7) catches the rest, and refuses the commit until the record below exists.

**This skill only reports.** It changes no manifest and no lockfile — bringing dependencies current is
[[dependency-upgrade]], which classifies each move by risk and verifies the build. Keeping the two apart keeps
this one safe to run any time, on any branch, including one you are only inspecting.

## Audit axes
1. **Known vulnerabilities (CVE):** audit appropriate to the ecosystem
   ```bash
   npm audit --production           # Node
   dotnet list package --vulnerable # .NET  (cannot be combined with --deprecated/--outdated)
   pip-audit                        # Python
   ```
2. **License compliance:** flag licenses incompatible with the project such as copyleft/GPL (a risk in commercial closed source).
3. **Maintenance status:** abandoned / long-unmaintained / single-maintainer packages, and packages the registry
   itself marks **deprecated** — `dotnet list package --deprecated`, `npm view <pkg> deprecated`. A deprecated
   package is not a version problem: no bump fixes it, it needs a replacement.
4. **Transitive dependencies:** also scan vulnerabilities in indirect dependencies.
5. **Lockfile integrity:** lockfile committed and consistent with the manifest; versions pinned.
6. **Justification for new dependencies:** is it actually needed? Don't add a heavy package for a single small function (supply-chain surface).
7. **Install-time execution:** does any dependency run code during installation — `preinstall`/`install`/
   `postinstall` scripts — and `prepare`, which runs only for a git, link or folder dependency and never for a
   registry tarball — a build hook, or a setup step that fetches at install time? This is the mechanism the recent
   registry compromises actually used: the malicious version does not have to be imported, only installed, so a
   CVE feed and a code review both miss it. Ask two things: which packages declare such a script, and whether
   the project can install without them at all (`npm ci --ignore-scripts`; for Python the control is refusing source
   distributions, `pip install --only-binary=:all:`, optionally with `--require-hashes` — a wheel has no install
   hook, an sdist does; or a vendored, pre-built artefact). A package that cannot install without running code is not disqualified —
   it is a package whose publisher you are trusting with arbitrary execution on every machine and every runner,
   which is a decision, not a default.
8. **Publisher concentration — read it from the registry, not from the repository.** "Many contributors" on a
   forge says who can open a pull request; it does not say who can publish. The number that matters is who holds
   the publish right on the registry (`npm owner ls <pkg>` · for PyPI the package JSON's `ownership.roles`,
   NOT the self-reported `info.maintainer` field · the equivalent ACL for the ecosystem in use) — and whether the
   PUBLISH PATH itself is challenged, which is not the same as "the account has 2FA": npm's `auth-only` 2FA mode
   does not gate `npm publish`, and a granular token with bypass-2FA publishes with no second factor, while on
   PyPI 2FA has been mandatory for every account since 2024 so the real question there is Trusted Publisher
   versus a long-lived API token. A widely-used
   package whose registry ACL is one unprotected account is a single compromised credential away from every
   build that installs it, whatever the contributor graph looks like.

## Output
Severity-sorted list: `package · version · issue (CVE/license/maintenance) · upgrade path`.

## The audit record (§4.7)
A commit that stages a lockfile is refused until this skill records its verdict for THAT lockfile diff. Audit what
the staged lockfile changed (axes 1, 3, 4, 7 at least), `git add` the lockfile in its own call (a command that stages
and commits at once is refused), then run (Bash tool, not PowerShell):

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/dependency-audit/scripts/record.sh" <clean|accepted|unverified> "<what the audit found>"
```

- `clean` — the audit ran and nothing is open.
- `accepted` — findings remain and **the user** accepted them by name in this session; the note lists them.
  Never accept for the user.
- `unverified` — the audit could not run (no network, no tool); the note says which and why. The gate lets it
  through, so that a machine with no network can still commit; the report to the user then says the dependencies
  were **not audited**, never that they are clean.

The record hashes the staged lockfile diff alone: staging more code keeps it valid, a lockfile change needs a new
audit. It lives in the git directory, so it is never committed.

## DoD
- 0 known HIGH/CRITICAL vulnerabilities; licenses compliant; lockfile consistent; every new package justified.
- **Every axis resolves to one of three states, and the third is a real answer:** *assessed-clean*,
  *assessed-flagged*, or *not assessable here — and why*. An axis that was skipped because the tool is missing,
  the registry was unreachable, or the ecosystem has no equivalent is reported as unassessed, never folded into
  the clean count. A report that cannot tell "nothing found" from "nobody looked" is the failure this skill
  exists to prevent, and the sibling `security-scan` already holds the same rule.
