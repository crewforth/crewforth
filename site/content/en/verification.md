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

In the plugin edition the same files are under `<plugin-root>/eval/lib/crew-map/`. The scanner reads a project's modules, the external resources it touches, the endpoints it provides and calls, and the gaps between them, for Node and TypeScript, Python, Go, .NET and Java or Kotlin (Maven, Gradle). It runs no code of the project and needs Node 18 or later; without one it exits 3 and scans nothing, which is not a pass.

Every module, line and finding cites the `file:line` it was read from. The same tree gives the same bytes, so the map can be committed and `--check` kept in CI. Configuration values are read only to name their kind: a host is kept, credentials are cut off. What the scanner could not read is listed as not measured, with the reason, instead of being read in part. Studio's **Map** view draws the file and scans nothing itself.

`/crew-map` runs the scan, then has the model describe it: each module gets at most two sentences on what it is for, and the project a short overview, each citing `file:line` lines the scan itself read for it. `crew-map.sh --validate` refuses a description that cites anything else or nothing, runs past two sentences, or comes with a scanner field changed by hand. A scan again keeps a description whose lines it still cites and drops one whose lines moved, and says how many; `--check` leaves descriptions out of the comparison. The command never commits.

It looks for ten kinds of gap. Five are proven by the lines they cite: a dependency cycle between modules, one dependency declared at different versions, an import with no declared dependency, a configuration key read but defined in no configuration file, and an endpoint called but provided nowhere in the repository. The other five are concluded from absence in the repository (a module nothing uses, a dependency nothing imports, an endpoint nobody calls, a setting nothing reads, an external resource no module owns), and a caller outside the repository can make any of them wrong. Those are hidden by default and counted, until their false-positive rate has been measured.

## Findings and the refuter

A finding, from the crew map or from a review, is a JSON entry that cites the lines it rests on. The findings core holds every one of them to those lines: the file exists inside the project, the lines exist, and they are still the lines that were read.

```bash
bash .claude/eval/lib/findings/findings.sh validate FILE              # every citation checked
bash .claude/eval/lib/findings/findings.sh write --verified NAME FILE # and every finding verified, then written
```

With `--verified`, a `medium` finding needs one verifier and a `high` or `critical` one needs three, each a separate `crew-refuter` agent on its own lens. A refuter gets the finding and the cited lines, not the reasoning that produced them, and tries to prove it wrong. Its verdict counts only if it is a line of `.claude/state/crew-refuter.tsv`, which `refuter-ledger.sh` writes from the agent's own task and answer when it stops. A document cannot name a verifier that did not run, and only a confirmed finding keeps its severity. What no check proves is that the cited lines support the claim: that stays a judgement.
