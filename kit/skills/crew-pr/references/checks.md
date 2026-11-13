# Reading a pull request's state

`/crew-pr status` reads one call: `gh pr view <n> --json state,isDraft,mergeStateStatus,reviewDecision,statusCheckRollup,headRefOid`.
Where `gh pr view` cannot reach the GraphQL API, the REST call `gh api repos/{owner}/{repo}/pulls/<n>` carries the
same merge state, in lower case, as `mergeable_state`; its checks come from
`gh api repos/{owner}/{repo}/commits/<sha>/check-runs` and `…/commits/<sha>/status`.

## The merge state

| `mergeStateStatus` | What it means | What to do |
|---|---|---|
| `UNKNOWN` | GitHub has not computed it yet (it does so lazily after a push) | read it again once, a few seconds later; still unknown → report "unknown", not clean |
| `CLEAN` | mergeable, required checks passed | it may be merged, if the user asked |
| `HAS_HOOKS` | mergeable, and the repository has pre-receive hooks | treat as clean, and say the hooks run at merge time |
| `UNSTABLE` | mergeable, but a check that is not required failed | name the failing check; the user decides whether it matters |
| `BEHIND` | the base moved and the branch must be brought up to date | sync the branch (merge or rebase as the repository does; a rebase of a pushed branch needs a force push, §4.5) |
| `DIRTY` | merge conflict | sync and resolve the conflict; never resolve it by dropping the other side's change |
| `BLOCKED` | a requirement is not met | read `reviewDecision` and the required checks, and report which one |
| `DRAFT` | the PR is a draft | report it; marking it ready is the user's call |

`reviewDecision`: `APPROVED`, `CHANGES_REQUESTED` (open the threads), `REVIEW_REQUIRED` (nobody has approved yet),
or empty (the repository requires no review).

## The checks
- **An empty rollup means "no checks reported yet"**, not "no checks". Right after a push the workflows have not
  registered; say that, and read it again only in wait mode.
- Each check has a state (pending, success, failure, cancelled, skipped, neutral, timed out). Report failing and
  pending ones by name, with the commit they ran on. A check that ran on an older commit says nothing about the
  head.
- **Evidence belongs to the final tree.** "CI passed" names the head commit it passed on. After a new push, every
  earlier result is history.
- Read a failure before acting on it: `gh run view <run-id> --log-failed`, or the check's details link. The cause
  is in the log, not in the check's name.
- **Wait mode** only: `gh pr checks <n> --watch`, then one snapshot. Never a hand-written polling loop, and never
  a wait the user did not ask for.
