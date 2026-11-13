---
name: crew-gates
description: Gate report — what the tool-level gates actually did, and which rules nothing has tripped.
argument-hint: "[--log <path>]"
disable-model-invocation: true
metadata:
  kind: command
---

Run the report with the Bash tool, not PowerShell, and read it back to the user. The report is a file-install tool:
a plugin install carries no `eval/` commands (only `eval/lib`), by design — there, say so plainly and stop.

```bash
bash .claude/eval/gate-report.sh $ARGUMENTS
```

Then interpret it in two sentences, in the user's language:

- **Exit 3 (no log).** Say plainly that gate activity is *not measured* — not that the gates never fired. Offer
  the one-line opt-in the report prints. Do not present the rule count as if it were evidence of anything.
- **Exit 0.** Lead with the verdict split (how often the gates asked vs blocked). Then the notable rules: a rule
  firing repeatedly is worth a conversation ("something keeps reaching for this"), and the not-observed list is
  a prompt to check whether a rule *can* still match, not a delete list. `smoke-test` is what proves a rule can
  fire; this only shows what tripped it.

Never infer that a gate works because it appears in the report, or that it is broken because it does not.

Which rule each gate holds, which rules no gate holds (`judged only`), and what each gate cannot see:
`references/enforcers.md`. A gate that infers its input must fail when the input is missing, not skip the item.
