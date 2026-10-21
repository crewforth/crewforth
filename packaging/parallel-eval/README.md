# Parallel production eval

Is the same work faster, cheaper or cleaner when a planner splits it into parts that owners do at the same time in
separate worktrees, merged in order, than when one owner does all of it? This measures it.

| | |
|---|---|
| `node packaging/parallel-eval/run.mjs --dry-run` | prepare one project (the seed, Crewforth installed), call no model |
| `node packaging/parallel-eval/run.mjs --all --runs 3 --cap 50 --out DIR` | every task × both arms × N runs (**spends tokens**) |

Each run starts from a task's seed (`tasks/<name>/seed`, tests on `node --test`, no dependencies) with Crewforth
installed by `start.sh`. **single**: one `claude -p` session gets the whole task. **parallel**: a planning session
(crew-planner) splits it into 2 or 3 parts with disjoint files, each part runs in its own git worktree at the same
time, the parts are merged in order, and a conflict goes to one more session. Then, in both arms, the project's tests
run and one review session (crew-review-agent) lists findings. Main threads run on Sonnet in both arms. The cap is
checked before every session and passed to it (`--max-budget-usd`); runs are interleaved so time of day falls on both
arms alike. Results go to `DIR/results.jsonl`, one line a run.

## Measured, 2026-10-15

Claude Code 2.1.299, two tasks, three runs per arm, $14.60 in all (the review sessions included).

| task | arm | wall time (median, range) | cost of the work (median, range) | merge conflicts | tests | findings medium+ · low |
|---|---|---|---|---|---|---|
| inventory-api | single | **44 s** (44–69) | **$0.31** (0.30–0.45) | 0 | 3/3 | 3 · 14 |
| inventory-api | parallel | 150 s (138–223) | $1.27 (1.25–1.76) | 1 | 3/3 | 5 · 10 |
| notes-cli | single | **49 s** (47–49) | **$0.31** (0.30–0.33) | 0 | 3/3 | 3 · 11 |
| notes-cli | parallel | 138 s (125–181) | $1.25 (1.17–1.46) | 0 | 3/3 | 4 · 12 |

On these tasks parallel production gained nothing: about three times the wall time and four times the cost, tests
passing in both arms, slightly more medium findings, one merge conflict. The planning session and each part
building its own context are what the parallel arm pays for. So the acceptance audit it would have needed (R4) does
not go in.

**What this does not measure:** large work with genuinely independent parts. Both tasks take a single owner under a
minute, where the overhead of splitting dominates; whether parallel owners pay off on work an order of magnitude
larger is not measured here.
