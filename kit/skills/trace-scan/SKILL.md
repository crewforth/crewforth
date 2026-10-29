---
name: trace-scan
description: |
  Trace scan (§4.1/§4.2): before a commit, scans the staged changes and the message for AI traces (co-author
  trailers, footers, robot emoji, tool names) and vendor template names. The git hooks apply it automatically.
---

# Trace Scan (trace-scan)

<!-- routing-eval reads the next line; why it sits in the body: AGENT_TEMPLATE.md -->
Trigger phrases: "scan traces", "trace scan", "AI trace", "check vendor name", "pre-commit audit"

Purpose: to bind §4.1/§4.2 to a *gate* rather than to *memory*. If the rule lives only in text,
a trace leaks sooner or later; this skill + the hooks stop the leak at commit time.

## When
- Before every commit (automatic: `pre-commit` + `commit-msg` hooks).
- Before crew-commit-agent proposes a message (manual verification).

## How
Pattern list: `./.claude/hooks/trace-blocklist.txt` (grep -iE, one pattern per line); in the plugin edition
`${CLAUDE_PLUGIN_ROOT}/hooks/trace-blocklist.txt`.
- **Defaults are high-hit:** co-author trailers, auto-generation footers, robot emoji, and AI-assistant/tool
  brand names. Standalone words that occur too often (model/assistant) are DELIBERATELY excluded. See trace-blocklist.txt for the exact list.
- **Vendor name is project-specific:** ADD the name of the third-party template in use to the list (§4.2).

Manual scan (a quick look without the hook):
```bash
git diff --cached --unified=0 | grep -E '^\+' | grep -Ev '^\+\+\+' \
  | grep -iEf .claude/hooks/trace-blocklist.txt    # full install; plugin edition: "${CLAUDE_PLUGIN_ROOT}/hooks/trace-blocklist.txt"
```

## Hook setup (full install only — a plugin cannot set `core.hooksPath`)
`start.sh` sets `core.hooksPath` to the absolute path of `.claude/hooks` (if there is a git repo). The hooks live
under `.claude` → they are in gitignore and stay local (§4.3), so a relative path would leave a linked worktree with
no hook at all. To do it later for a repo, from its root:
```bash
git config core.hooksPath "$(git rev-parse --show-toplevel)/.claude/hooks"
chmod +x .claude/hooks/pre-commit .claude/hooks/commit-msg
```

## Rules
- If there is a finding, the commit STOPS; the phrase is removed and the real rationale is written in the project's commit language (CLAUDE.md).
- Skipping with `--no-verify` only on an EXPLICIT request (§4.5); the hook is not skipped silently.
- On a false positive, narrow/remove the pattern — the list is set up by the project owner.
