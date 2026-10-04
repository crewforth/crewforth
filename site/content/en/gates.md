# Gates

A rule that matters becomes a gate. Enforcement sits at the tool level — a hook, a permission, a test case — so the model is not asked to remember it.

| Component | Count | What it is |
|:--|:--:|:--|
| **Agents** | {{AGENT_COUNT}} | Thin triggers — *who* owns a domain and *when* they fire |
| **Skills** | {{SKILL_COUNT}} | The method, written once, applied by whoever needs it |
| **Commands** | {{COMMAND_COUNT}} | `/crew-brainstorm` · `/crew-plan` · `/crew-review` · `/crew-ship` · `/crew-handoff` · `/crew-update` · `/crew-doctor` · `/crew-gates` · `/crew-skill` · `/crew-studio` |
| **Hooks** | 14 | The gates, plus session measurement and routing |
| **Discipline** | 1 | Principles, workflow, Definition of Done, prohibitions — imported by your `CLAUDE.md` |

## All 14 hooks

| Hook | Role |
|:--|:--|
| `prompt-approval.sh` | In `auto` and `dontAsk`, records your own message `approve: commit` (or `push`, `commit+push`) as the approval, tied to what is staged, to `HEAD` and to the session |
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
| Commit and push need your approval, in every permission mode; staging and creating a branch are free | `guard-bash.sh` raises a prompt only you can answer. In `auto` and `dontAsk`, where a prompt is answered by software, it accepts one thing: a message from you that is only `approve: commit`, `approve: push` or `approve: commit+push` (`onay:` works too). `prompt-approval.sh` records it with the tree of what is staged, `HEAD`, the branch, the address its remote pushes to and the session; the call has to be that one `git commit -m …` or `git push <remote> <branch>` and nothing else, the record lasts 30 minutes and your next message ends it. Fails closed under `plan` and `bypassPermissions` |
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
