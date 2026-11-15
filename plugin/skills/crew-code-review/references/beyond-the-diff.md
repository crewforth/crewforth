# Beyond the diff

Loaded from `SKILL.md` §3 (the risks) and §7 (what a change must not quietly do). The diff shows the lines; these are
the places a change reaches that the lines do not show.

## Who else the change reaches
- **Dependents.** The callers, the other packages of the repository, a public API, a file or wire format. A change
  to any of them is a version question too: a public surface that changed shape is a major bump, not a patch.
- **The user who updates.** Their stored data, their config, a flag they set: what do they meet on the first run
  after this change, and does it say so?
- **The other platforms.** Windows paths and line endings, a case-insensitive file system, another shell, another
  locale. A change tested on one platform is a claim about that one.
- **The load it assumes.** For code on a hot path: how many items, how often, how large. Say the number the code
  was written for; a loop that is fine for ten rows is a finding at ten thousand.

## What the change must not leave behind
- **A mock or a stub in production code**: a hard-coded return, a fake client, a `TODO: real impl` behind a live
  path. The feature looks done and is not; it is a finding whatever the tests say.
- **A recorded decision undone.** Read the accepted ADRs (`docs/adr/` or the project's own scheme) that the diff
  touches. A change that goes against one is a finding, closed by changing the code or by a new ADR that
  supersedes the old one in the same change.
