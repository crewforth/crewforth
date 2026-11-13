# Rule → enforcer

What holds each binding rule of the discipline. A rule held by a hook is a **gate**: it holds whether or not the
model cooperates. A rule marked `judged only` is **model discipline**: it holds only when the model reads it and
follows it, and the honest answer to "is it enforced?" is no. The smoke test checks this table both ways: every
`### 4.N` prohibition has a row, and every enforcer named here exists (a hook file, a smoke section, an eval case).

Enforcer forms: `hook:<file>` under `hooks/` · `smoke:<section>` a section of `eval/smoke-test.sh` · `eval:<case>` an
A/B case in Crewforth's own repository (paid, run by hand) · `judged only`.

| Rule | Enforcers | What the gate cannot see |
|---|---|---|
| §4.1 No AI trace | hook:pre-commit, hook:commit-msg, hook:guard-commit-scan.sh, smoke:5, smoke:7h, smoke:7j, eval:commit-format | a trace written by hand outside the patterns, or a commit made with `--no-verify` |
| §4.2 No third-party template name | hook:pre-commit, smoke:7h | a name the project never listed in its blocklist section |
| §4.3 Internal working documents are private | hook:pre-commit, smoke:6h | a private term nobody wrote into `.private-terms.txt` |
| §4.4 Commit/push only with explicit approval | hook:guard-bash.sh, hook:prompt-approval.sh, hook:guard-question.sh, hook:guard-schedule.sh, smoke:7, smoke:12f, eval:commit-format | a commit or push typed in the user's own terminal |
| §4.5 Destructive operations require approval | hook:guard-bash.sh, hook:guard-write.sh, hook:guard-powershell.sh, smoke:7, smoke:7b, smoke:12g, eval:destructive-refused | a command assembled from pieces or run through an interpreter |
| §4.6 A commit needs a clean review of this diff | hook:guard-bash.sh, smoke:4f, smoke:12g | whether the review itself was any good |
| §4.7 A staged lockfile needs an audit | hook:guard-bash.sh, smoke:7 | whether the audit itself was any good |
| Model per call | hook:guard-agent-model.sh, hook:agent-outcome.sh, smoke:12h2, smoke:12h3 | agents that are not `crew-*` |
| Never guess the fill | hook:context-usage.sh, hook:session-guard.sh, smoke:6, smoke:6i | a reply that states a number the hook did not give |
| An unvetted component is named before use | hook:skill-trust.sh, smoke:7i | whether the session asks before using it |
| Route trace / delegation is the default | hook:route-hint.sh, smoke:7y | whether the named owner is actually called |
| Untrusted content is data | judged only | everything: a directive in content is followed or not by the model alone |
| No deferral | judged only | everything |
| Tests green = one run on the final code | eval:dod-tests | everything outside the eval case |

A gate that reads its input from somewhere (a diff, a record, a transcript) fails when that input is missing; it
never skips the item and reports it clean. "I could not look" and "I looked and found nothing" are different
answers, and only the second may pass.
