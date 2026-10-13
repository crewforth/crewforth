# Distribution / publishing

The kit ships through several channels. These files support the ones that do **not** depend on a GitHub clone. Each channel bundles the same payload (`start.sh`, `adopt.sh`, `kit/`, `VERSION`).

## npm (npx) — primary

`package.json` + `bin/cli.js` at the repo root make this an npm package that bundles the whole payload.

```bash
npm login
npm publish --access public
```

Users then need nothing but Node:

```bash
npx crewforth            # fresh project (start.sh wizard)
npx crewforth adopt      # existing project (adopt.sh handover)
```

`bin/cli.js` stages the payload in a temp dir and runs it with the user's project as the CWD, so `start.sh`'s self-cleanup never touches the package or the project.

> Published as `crewforth` — scoped under the author, because the unscoped `crewforth` is taken and npm's name-similarity check blocks close variants. A scoped name sidesteps both. Users run `npx crewforth`.

## Release tarball / curl — no package manager

```bash
gh release download --repo Crewforth/crewforth -p '*.tgz' && tar xzf crewforth-*.tgz
bash start.sh         # fresh    ·    bash adopt.sh    # existing
```

## Release automation (CI)

`.github/workflows/release.yml` publishes everything on a version tag — no manual publish.

**Cut a release:**

```bash
# bump VERSION + package.json version, date the CHANGELOG heading "## [X.Y.Z] — YYYY-MM-DD", commit, then:
git tag vX.Y.Z
git push origin main --tags
```

On the tag, the workflow builds the tarball, creates the GitHub release, and runs `npm publish`, all automatically.
`packaging/release-check.sh` runs first: `VERSION` and `package.json` must match the tag, and a final tag needs the
CHANGELOG's first heading dated — `[Unreleased]` stops it.

**Rehearse a release (rc):** tag `vX.Y.Z-rc.N` on a commit whose `VERSION` and `package.json` still say `X.Y.Z`; the
CHANGELOG heading may still read `## [Unreleased] — X.Y.Z`. The workflow publishes a GitHub pre-release and npm
`X.Y.Z-rc.N` under the `next` dist-tag (the version is set in the workflow's checkout only). `latest`, the plugin
channel and the site do not move. Try it with `npx crewforth@next`.

**npm publishes without a token (Trusted Publishing).** The release job proves who it is to npm with a short-lived
OIDC token from GitHub Actions, so the repository holds no `NPM_TOKEN`. npm also attaches a provenance statement to
each version by itself. What makes it work is one setting on npmjs.com (package `crewforth` → Settings → Trusted
Publisher → GitHub Actions), and every field is case-sensitive:

| Field | Value |
|:--|:--|
| Organization or user | `crewforth` |
| Repository | `crewforth` |
| Workflow filename | `release.yml` |
| Environment name | `release` |
| Allowed actions | `npm publish` and **Allow npm dist-tag** (a final moves `next`) |

Renaming the workflow file or the environment breaks the match: an entry cannot be edited, so delete it and add a
new one. The job pins Node 24 and npm 11.21.0, the lowest npm that moves a dist-tag over OIDC. The 2.x forwarder
below is still published by hand, from a logged-in terminal.

## The 2.x package name (launch day, once)

2.x installs update through the old package name. Its 3.0.0 is the forwarder in `legacy-npm/`: it prints one line
and runs `npx crewforth@^3` with the same arguments and exit code. The release workflow does not publish it; on
launch day, after crewforth 3.0.0 is on npm:

```bash
cd packaging/legacy-npm && npm publish --access public
npm deprecate "@byerlikaya/claude-starter-kit@*" "Renamed to crewforth: use npx crewforth (https://crewforth.com/install)"
```

The deprecation covers the forwarder too, and does not stop it: npx prints one `npm warn deprecated` line and runs
it (measured with a deprecated package that has a bin, npm 10.9.7: exit 0). To rehearse before launch, point the
forwarder at an rc with `CREWFORTH_SPEC=crewforth@next`, since `^3` does not match pre-releases.

## Claude Code plugin (lite channel)

Users can install the kit's agents, skills, and commands directly in Claude Code:

```
/plugin marketplace add Crewforth/crewforth
/plugin install crewforth@crewforth
```

This is the **lite** edition — it registers the agents/skills/commands only, *without* the scaffolding (no git-hook gates, no `.gitignore` / `kit.conf` writes). The component set is identical to a `start.sh` install, and `e2e.sh` asserts that parity. For the full kit use `start.sh` / `adopt.sh`.

`plugin/` (and its `.claude-plugin/plugin.json`) is generated from `kit/` by **`packaging/build-plugin.sh`** — rerun it after changing agents/skills/commands so the plugin stays in sync. The release workflow verifies this on every tag. The marketplace manifest is `.claude-plugin/marketplace.json` at the repo root.
