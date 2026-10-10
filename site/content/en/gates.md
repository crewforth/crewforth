# Gates

A rule that matters becomes a gate. Enforcement sits at the tool level — a hook, a permission, a test case — so the model is not asked to remember it.

| Component | Count | What it is |
|:--|:--:|:--|
| **Agents** | {{AGENT_COUNT}} | Thin triggers — *who* owns a domain and *when* they fire |
| **Skills** | {{SKILL_COUNT}} | The method, written once, applied by whoever needs it |
| **Commands** | {{COMMAND_COUNT}} | `/crew-brainstorm` · `/crew-plan` · `/crew-review` · `/crew-ship` · `/crew-handoff` · `/crew-update` · `/crew-doctor` · `/crew-gates` · `/crew-skill` · `/crew-studio` |
| **Hooks** | 17 | The gates, plus session measurement and routing |
| **Discipline** | 1 | Principles, workflow, Definition of Done, prohibitions — imported by your `CLAUDE.md` |

## All 17 hooks

| Hook | Role |
|:--|:--|
| `prompt-approval.sh` | In `auto` and `dontAsk`, records the command you type, `/crew-approve commit` (or `push`, `commit+push`), as the approval, tied to what is staged, to `HEAD` and to the session |
| `guard-schedule.sh` | Refuses a tool call that schedules a prompt (`CronCreate`, `ScheduleWakeup`, `RemoteTrigger`, an MCP tool named for a trigger, a schedule or a cron) when that prompt is an approval: an approval is what you type, never what a session schedules for itself |
| `guard-agent-model.sh` | Reads the task card a `crew-*` agent is called with (files, kind of change, verify command) and refuses a call whose model does not fit: no card or no model; critical work (a migration, security, architecture or unknown-cause change, or a file on a critical path) below `opus`; test-writing, audits and reviews below `sonnet`; work with no verify command on `haiku`; a card whose verify failed, on the same or a lower model; critical work with a verify command in the background. It never rewrites the call. `fable` needs `CREW_ALLOW_FABLE=1`; `CREW_MODEL_ROUTING=off` turns it off |
| `agent-outcome.sh` | When a crew agent stops, runs its card's verify command: red once, the agent is kept running to fix it; red again, the session is told to repeat the task one model up. Writes one line per call to `.claude/state/model-outcomes.tsv`, raises a class's floor when its first try fails too often, and lists the project's critical paths. Not a gate: it cannot undo what an agent wrote. The verify command runs only when you allowed it by name (a `verify` line in `.claude/crew-model-rules`, a `Bash(...)` rule in `permissions.allow`) or, in `auto` and `bypassPermissions`, when it is a known test or build runner with no options. Known limits: a test runner runs code the agent wrote (test files, `package.json` scripts, `conftest.py`, a `Makefile`), so the list limits the command and not what the tests do; a failed card stays failed until the card changes; the shell rule for the routing files goes by their names; the list of critical paths is written at the first session, not at install; managed policy is read from the managed settings file only, not from macOS MDM, the Windows registry or the server. A raised floor is lowered by `/crew-loosen <agent> <change> <risk>`, a command only you can send: one model, once for each raise. The shell rule that keeps a session from writing that record can be passed by a name built from pieces, an interpreter or a parent-folder move; such a write can add a lowering, not only remove one |
| `route-hint.sh` | Names the owning agent alongside every prompt, so specialists run without you asking |
| `guard-bash.sh` | Tool-level command gate: commit/push approval, review-before-commit, destructive ops, remote-code-exec, hook tampering |
| `guard-write.sh` | The same protection on the Write/Edit side — a gate you can silently delete is not a gate. It normalises the target path before matching it, so a gate file cannot be reached under a different spelling. |
| `guard-commit-scan.sh` | Runs the real trace and secret scanners from `PreToolUse`, so the commit gate works where `core.hooksPath` cannot be set |
| `guard-powershell.sh` | Sends Crewforth's own scripts back to the Bash tool when the model tries them in PowerShell, where `bash` can be WSL's and the script fails |
| `context-usage.sh` | Reads the real token count from the transcript and injects it every turn |
| `session-guard.sh` | Warns once at {{FILL_WARN}}% context fill and once at {{FILL_ALERT}}% — never blocks a turn |
| `session-rehydrate.sh` | Re-surfaces the handover after `/compact` or `/clear`, and tells a session which language the project was installed in |
| `skill-trust.sh` | Names any skill or agent Crewforth never shipped and you never accepted |
| `session-stats.sh` | Reports what the session actually did — failing tool loops, repeated prompts, interrupts. `reflect` and `handoff` read it, so a retrospective rests on the record rather than on recollection |
| `session-update-check.sh` | Asks once, when a session opens, whether to update when a newer version is published — each edition compared against the channel that will deliver it. The lookup runs detached and at most daily, so an offline or proxied machine costs the session opening nothing; `CREW_NO_UPDATE_CHECK=1` turns it off |

The other two hooks serve an experimental feature and do nothing until a repository switches it on.

Two git hooks — `pre-commit` and `commit-msg` — run the trace, secret, repo-bloat and private-path scans. The last one exists because a path that only lives on your machine reaches a shared repo by being pasted, not by being typed: it blocks your own `$HOME` automatically, and the internal project, client and host names only you can recognise come from a gitignored `.private-terms.txt` (`.private-allowlist.txt` is the escape). Every gate matches in the C locale, so a system locale such as Turkish, where `i` and `I` are not a pair, does not change what is caught; and a scan that cannot run stops the commit instead of passing it. The plugin edition ships all of these except `skill-trust.sh`, which decides what Crewforth owns from the `kit-manifest.txt` an installer writes and the plugin never creates.

## Rule → gate

Left is the rule; right is the thing that refuses to let it slide.

| Rule | Enforced by |
|:--|:--|
| Commit and push need your approval, in every permission mode; staging and creating a branch are free | `guard-bash.sh` raises a prompt only you can answer. In `auto` and `dontAsk`, where a prompt is answered by software, it accepts one thing: a message from you that is only the command `/crew-approve commit`, `/crew-approve push` or `/crew-approve commit+push`. Claude cannot run that command for you. `prompt-approval.sh` records it with the tree of what is staged, `HEAD`, the branch, the address its remote pushes to and the session; the call has to be that one `git commit -m …` or `git push <remote> <branch>` and nothing else, the record lasts 30 minutes and your next message ends it. When the refusal says the approval path is closed, the recording hook is not wired in that session (a worktree on an older Crewforth, for one): press Shift+Tab or commit in your own terminal, and `doctor.sh` names it. Fails closed under `plan` and `bypassPermissions` |
| A commit needs a clean review **of the diff it is actually about** | `guard-bash.sh` compares git's object id of the staged diff, and the `HEAD` it was reviewed against, with what `crew-review-agent` recorded when it cleared the change. A review of another diff — or of this one on another base — does not count, and there is no size exemption |
| Destructive ops: `reset --hard`, `checkout -- .`, force push, `rm -rf`, `clean -f`, `--no-verify`, amend | `guard-bash.sh`, blocked at the tool level. A `git commit` is read the way the shell and git read it, so `-n`, an abbreviated `--no-verif` or `--amen`, a flag behind a redirection or inside mis-paired quotes, and a commit run from another directory or under `GIT_DIR` / `GIT_INDEX_FILE` are refused as what they are. A git call whose subcommand the shell fills in (`git com${z}mit`, `git "$c"`), or git started through `System.Diagnostics.Process` in PowerShell, is refused: the gate must be able to read which git command it is. In PowerShell, arguments handed to `Start-Process git` or to a command held in a variable are judged as the git command they make. A wholly quoted argument of a command that does not run it (a commit or tag message, a `gh pr`, `issue` or `release` title or body, a `claude -p` prompt run where the call stands and with no option that changes its settings, a grep pattern, an `echo` that goes nowhere) is not read as a command. A command that names a gate file (a hook, `settings.json`, the rulebook, a git hook) passes when it reads the file, runs a hook script or stages it with git; any other command that names one is refused, whatever it is called. A command continued on the next line (a backslash, or a backtick in PowerShell) is read joined, as the shell runs it. A command that holds a commit and is larger than 32 KB is refused unread: write the message to a file and use `git commit -F <file>`. Any Bash or PowerShell call larger than 256 KB is refused unread too: a hook that runs out of time stops nothing, so the long content goes in a file |
| Remote code execution and permission nukes: `curl…\|bash`, world-writable `chmod`, `dd of=` | `guard-bash.sh`, hard-blocked in every mode |
| Disarming a gate — redirecting `core.hooksPath` (with `git config`, by writing `.git/config` or your own `~/.gitconfig`, through an included file or a `GIT_CONFIG_` variable), editing or deleting a hook, or rewriting the discipline the gates enforce | `guard-bash.sh` (shell) + `guard-write.sh` (file edits). Both match the **resolved** path, so `..` segments, doubled slashes, Windows separators and a symlinked parent all reach the same verdict as the plain spelling |
| No API key, token or private key reaches a commit | `pre-commit` secret scan; every pattern carries its own test case |
| No machine-private path or internal name reaches a commit | `pre-commit` private-path scan: your own `$HOME` automatically, plus a gitignored `.private-terms.txt` |
| No credential is *read* into the context — `~/.ssh/id_rsa`, `~/.aws/credentials`, `*.pem`, kubeconfig | `settings.json` read-deny + `guard-bash.sh` |
| No AI-authorship trace or vendor template name in a commit | `pre-commit` + `commit-msg` git hooks |
| No build artifact, vendored tree or oversized blob gets staged | `pre-commit` repo-bloat scan |
| No commit quietly lowers the quality bar: a checker switched off where it fired, a test skipped or deleted, assertions taken out of a test that stays, a stub or an empty `catch` where the work should be | `pre-commit` floor guard, across the supported stacks. Generated files and documentation are exempt; a genuine exception is a line in `.floor-allowlist.txt`, in the same commit, where review sees it |
| An unvetted skill or agent appearing in `.claude/` is named, with a scanner verdict | `skill-trust.sh` at session start |
| Always-on context stays lean | `smoke-test.sh` byte budget per component |
| A running session never follows stale rules after an update | `context-usage.sh` version comparison |

Every rule carries cases for **both** halves: that it blocks what it must, and that it does not block its neighbours — `chmod 755`, `rm -rf build`, `git checkout -- src/app.js`. A gate nobody proved is not a gate, and a gate that fires on routine work gets worked around.

The gates stop accidents, not determined attempts. On a command line there is always a way around a pattern; if you need a real boundary, run Claude Code in a devcontainer or a VM. `/crew-doctor` tells you whether you have one.

## Watching a gate fire

The Bash guard appends a line to `.claude/gate-log.tsv` for each block, approval prompt and `CLAUDE_GIT_OK` pre-authorisation (`BLOCK` / `ASK` / `ALLOW`), and the gate-file write guard one for each block, with the section and the rule; the command is recorded only with `CREW_GATE_LOG_CMD=1`. It is on by default when the project's `.claude/` directory exists and the file is git-ignored or the project is not a repo; `CREW_GATE_LOG=<path>` sends it elsewhere and `/dev/null` turns it off. The commit scan refuses without writing a line. It is write-only and written after the verdict, so it cannot change one. Useful when you need to know whether a gate stopped something or the model simply never went there — those two leave identical traces.
