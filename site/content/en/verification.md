# Verification

```bash
bash .claude/eval/smoke-test.sh      # structure, frontmatter, gate integrity
bash .claude/eval/routing-eval.sh    # does an example prompt reach the right agent or skill
bash .claude/eval/doctor.sh          # is this install healthy, and is the project ready
bash .claude/eval/preflight.sh       # which tools this machine has, and what degrades without them
```

`preflight.sh` also runs inside `start.sh`, `adopt.sh` and `doctor.sh`. Crewforth needs neither `jq` nor `python`: every JSON read and write, every hook and every installer step is one bash/awk path, so macOS, Linux and a stock Windows Git Bash run the same code and get the same result. Where a tool is still optional Crewforth degrades rather than breaks — no `sha256sum` falls back to `cksum` — which is the right design and also the reason a gap never announces itself. Preflight names the gap and what it costs. It reports; it never installs anything on your machine and never blocks a run.

## Does it actually change anything?

The same prompt is run in a Crewforth project and a bare one, and graded on what each left on disk. The rule a result must meet is written down before the run. Every measurement is published with its reasoning in [`evals/README.md`](../../../evals/README.md), including the ones where that rule did not hold.

## The crew map

```bash
bash .claude/eval/lib/crew-map/crew-map.sh            # scan, write .crewforth/crew-map.json
bash .claude/eval/lib/crew-map/crew-map.sh --stdout   # scan, print the map, write nothing
bash .claude/eval/lib/crew-map/crew-map.sh --check    # 0 when the file is what a scan writes now, 1 when not
```

In the plugin edition the same files are under `<plugin-root>/eval/lib/crew-map/`. The scanner reads a project's modules, the external resources it touches, the endpoints it provides and calls, and the gaps between them, for Node and TypeScript, Python, Go, .NET, Java or Kotlin (Maven, Gradle) and Dart (a Flutter app is one module, its `android/` and `ios/` folders its platforms). For each module it also says what it is built with (Hono, Cloudflare Workers, Flutter, Riverpod: a package its manifest declares or a file at its root, from `rules/tech.json`) and what is inside it (its folders and how many source files each holds, tests apart). A module served at a host its own deployment file names (wrangler routes, `fly.toml`) is called by any module that writes that host, quoted or as a URL's host, and that call is drawn module to module rather than as an external API. Source in a language no reader here knows, such as Swift, is listed as not measured. It runs no code of the project and needs Node 18 or later; without one it exits 3 and scans nothing, which is not a pass.

Every module, line and finding cites the `file:line` it was read from. The same tree gives the same bytes, so the map can be committed and `--check` kept in CI. Configuration values are read only to name their kind: a host is kept, credentials are cut off. What the scanner could not read is listed as not measured, with the reason, instead of being read in part. Studio's **Map** view draws the file and scans nothing itself.

`/crew-map` runs the scan, then has the model describe it: each module gets at most two sentences on what it is for, its layer (`ui`, `api`, `service`, `data`, `infra`, `tool` or `library`) and the part of the business it serves, the project a short overview, and a tour of up to eight stops a newcomer reads in order, each citing `file:line` lines the scan itself read for it (a module's evidence, its entry point, and the first line of prose in its own README). `crew-map.sh --validate` refuses a description that cites anything else or nothing, runs past two sentences, names a layer not on the list or writes the domain as a sentence, a tour stop at no node, citing another node's lines or at a node twice, and a map with a scanner field changed by hand. A scan again keeps a description whose lines it still cites and drops one whose lines moved, and says how many; `--check` leaves descriptions out of the comparison. The command never commits.

It looks for ten kinds of gap. Five are proven by the lines they cite: a dependency cycle between modules, one dependency declared at different versions, an import with no declared dependency, a configuration key read but defined in no configuration file, and an endpoint called but provided nowhere in the repository. The other five are concluded from absence in the repository (a module nothing uses, a dependency nothing imports, an endpoint nobody calls, a setting nothing reads, an external resource no module owns), and a caller outside the repository can make any of them wrong. Those are hidden by default and counted, until their false-positive rate has been measured.

## Findings and the refuter

A finding, from the crew map or from a review, is a JSON entry that cites the lines it rests on. The findings core holds every one of them to those lines: the file exists inside the project, the lines exist, and they are still the lines that were read.

```bash
bash .claude/eval/lib/findings/findings.sh validate FILE              # every citation checked
bash .claude/eval/lib/findings/findings.sh write --verified NAME FILE # and every finding verified, then written
```

With `--verified`, a `medium` finding needs one verifier and a `high` or `critical` one needs three, each a separate `crew-refuter` agent on its own lens. A refuter gets the finding and the cited lines, not the reasoning that produced them, and tries to prove it wrong. Its verdict counts only if it is a line of `.claude/state/crew-refuter.tsv`, which `refuter-ledger.sh` writes from the agent's own task and answer when it stops. A document cannot name a verifier that did not run, and only a confirmed finding keeps its severity. What no check proves is that the cited lines support the claim: that stays a judgement.

## The review pre-pass

Before the review agent reads a change, a deterministic pass reads the lines it adds and writes what it finds as findings, in the same shape:

```bash
bash .claude/eval/lib/review-prepass/prepass.sh                  # the staged change → .crewforth/review-prepass.json
bash .claude/eval/lib/review-prepass/prepass.sh --base origin/main  # a branch against its base
bash .claude/eval/lib/review-prepass/prepass.sh --stdout         # print it, write nothing
```

It checks, by file: a pattern of the pre-commit gate's secret list (cited by its hash, never quoted; `.secret-allowlist.txt` applies), a console call or debugger left in JavaScript or TypeScript, a breakpoint in Python, `print(` in Dart (not in tests, not in a command-line script), a TODO, FIXME, XXX or HACK opening a comment added in code (not in tests; the word in a string or a pattern is not a marker), shellcheck's findings on a shell file's added lines, a lock file that changed while its manifest did not, and one file gaining more than 500 lines. A file edited again after it was staged, a binary file, and shell files on a machine without shellcheck are listed as not measured; nothing is installed, and without Node it exits 3, which is not a pass.

The review agent starts from that file and writes its own findings beside it, to `.crewforth/review.json`; a `critical` or `high` one goes through `crew-refuter` first and the document is written with `--verified`. Running the pass and reading it is the review skill's discipline: no hook runs it.

## How right the review is

`review-bench` runs the review on labelled cases and counts: how many defects it found (recall), how many of its findings were about a defect (precision), and every false alarm by name.

```bash
bash .claude/eval/review-bench.sh --cases DIR                    # the pre-pass only: no model, no cost
bash .claude/eval/review-bench.sh --cases DIR --arm agent --max-cost 5   # the review agent; spends tokens
```

A case is a directory: what the change claims to do, the files before and after, and where the defect is. Crewforth's own set is 27 cases: 16 defects taken from its history by undoing a fix (the fix's own explanatory comments are left out, so the defect has to be found in the code), 6 changes that nothing later had to fix, and 5 written cases a pattern can see; 8 are held out. The pre-pass's floor on them is a CI gate: every pattern case found, no false alarm.

Measured on 2026-10-16, Sonnet, one review pass, isolated from the user's own settings: **18 of 20 defects found** (held out: 4 of 5) and **34 of 49 findings were about the defect**; $1.62 for the 27 cases. The matcher matches by place, so it counted 20 of 20: two matched findings commented on the right lines without naming the defect, and were counted as misses by hand. Most false alarms were "no test covers this" on a clean change. The record, with every false alarm, is `packaging/review-bench/results/2026-10-16-sonnet.json` in the repository.
