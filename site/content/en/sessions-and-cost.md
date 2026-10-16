# Sessions and cost

How full a session is gets **measured, not estimated** — the real token count, read every turn, the same figure `/context` reports. One warning at **{{FILL_WARN}}%**, one more at **{{FILL_ALERT}}%**, and neither interrupts your turn.

The standing cost is published, not hidden. The discipline plus every agent and skill description load into each session: **{{ALWAYS_ON_BYTES}} bytes**, measured by `smoke-test.sh`. A real `claude -p` turn in which 21,804 bytes of the same material cost 9,198 tokens gives the ratio; at that ratio this is about **{{ALWAYS_ON_TOKENS}} tokens**. The byte figure is what the suite gates. Each skill you add is a permanent **~100-token** tax on every session, so a byte budget per component is enforced as a gate. Raising it takes an explicit edit to the test.

**Why not install fewer components?** Because it buys almost nothing. Every agent and skill description together is {{DESC_BYTES}} bytes, about **{{DESC_TOKENS}} tokens** at the same ratio; leaving out the four UI skills and the frontend agent saves {{UI_BYTES}} of those bytes — roughly **{{UI_TOKENS}} tokens**. That is worth controlling per component, which the byte budget does, rather than per project.

## Which model does the work

Most of what a session costs is the model that runs each piece of work, so that is chosen per task and not per session. A `crew-*` agent is called with a card (the files, the kind of change, the command that proves it), and the card decides: `haiku` where a command checks the work, `sonnet` for ordinary work and for anything nothing can verify, `opus` for critical work (a migration, security, architecture, an unknown-cause bug, or a file under auth, payments, migrations and the like). When the agent stops, its verify command runs; work that fails it twice is repeated once, one model up. A model that was too small therefore costs one more run, and the expensive model is kept for the work that needs it.

What that came to is recorded, one line per call, in `.claude/state/model-outcomes.tsv`, and stays in your project. Studio reads it (see the Studio page): the **Models** view shows, for each kind of task, the model, how often the first try passed, how often it was repeated one model up, and an estimated cost at API list price. A class whose first try fails too often is held one model up from then on; `/crew-loosen` lowers it again when you decide to.

The card's model is also the default. A call that asks for more runs on the card's model, unless the card adds a line `above: <why>`; one that asks for less is refused. Agents outside the crew have no card, so only the expensive end is held: a call asking for `opus` or `fable` without `above:` runs on `sonnet`, and so does a general-purpose call (or a project agent with no model of its own) that names no model, which would otherwise take the session's. A session on `haiku`, and an agent whose definition names its own model, are left alone. Those agents are not in the record.

## The advisor

Claude Code's advisor tool lets the model consult a second, usually stronger model mid-task. Crewforth never turns it on; `/crew-doctor` says whether it is on, on what, and from which settings file.

Its cost is its own. Each call reads the whole conversation at the advisor model's rates, uncached: in one measured session a two-sentence answer on Sonnet cost $0.06 and the single advisor call behind it $0.15. The API keeps those tokens out of the response's top-level usage. Claude Code counts them in `/usage`, and Studio's session cost adds them and shows an **Advisor** line, with the number of calls and what they cost; a session with no call has no line.

It does not follow the card. An advisor that ranks below the model it would advise is not attached at all, so with a Sonnet advisor an agent on Opus (critical work) gets no advice. The advisor is not in `model-outcomes.tsv`.

Turn it off with `/advisor off`, or for good with `CLAUDE_CODE_DISABLE_ADVISOR_TOOL=1`. It needs the Anthropic API; on Amazon Bedrock, Google Cloud's Agent Platform or Microsoft Foundry it is not available.

## The status line

One line under the prompt says what Crewforth's hooks know about this session:

```
🛡 BLOCK §4.2 · ✓ commit approved 24m · ⚙ 2 crew agents · 🔋 34% · ~$1.20
```

The gate's last word in this session, an approval you gave for a commit or a push that still holds, the crew agents started in this session and still running, the context fill Claude Code measured, and what Claude Code puts the session's cost at. Each part shows only when there is something to say, and nothing from before the session: the gate log carries no time, so a line from last week would otherwise read as now.

The installers set it only where no status line is set, in the project or in your own settings, because the project's setting would win over yours. With one of your own, they leave it and `/crew-doctor` says how to turn Crewforth's on. The plugin edition cannot set a status line.
