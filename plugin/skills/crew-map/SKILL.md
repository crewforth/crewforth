---
name: crew-map
description: Map the project — modules, what they touch, the gaps between them — and describe each module from the lines the scan cites.
disable-model-invocation: true
metadata:
  kind: command
---
# /crew-map

Write `.crewforth/crew-map.json`, then describe it. The scanner draws the map from the files; you add only what
it cannot: a sentence or two on what each module is for, and a short overview. Every description points at lines
the scan itself read, and a gate holds it to that. **Never commit.** Show the diff and stop.

1. **Resolve the scanner.** Both editions carry it, in different places:

   ```
   PLUGIN_MAP=${CLAUDE_PLUGIN_ROOT}/eval/lib/crew-map/crew-map.sh
   ```

   Claude Code replaces `${CLAUDE_PLUGIN_ROOT}` in this text before you read it, and only in the plugin. If the
   line above names a real path, that is the scanner; if it still shows `${CLAUDE_PLUGIN_ROOT}`, this is a full
   install and the scanner is `.claude/eval/lib/crew-map/crew-map.sh`. Below, `MAP` is whichever it is.

2. **Scan:** `bash MAP` at the project root (Bash tool, not PowerShell). It writes the map and keeps the
   descriptions of an earlier run that still cite only lines this scan cites; it says how many it kept and dropped.
   rc 3 is no usable Node: say so and stop, it is not a pass.

3. **Describe.** Read `.crewforth/crew-map.json`, and as much of the cited source as you need. Then edit that
   file, changing ONLY these fields:
   - each `module` node's `narrative`: `{ "text": "…", "cites": ["file:line", …], "layer": "…", "domain": "…" }`.
     What the module is for, in at most two sentences. Every cite is a `file:line` the scan read for THAT node: its
     `evidence`, its `entryPoint`, or its `about` (the first prose line of its README); cite at least one. `layer` is where it sits, one of `ui` (what a person uses: an app, a site),
     `api` (serves requests to others), `service` (runs work: a worker, a job), `data` (holds or shapes data),
     `infra` (deploys and runs the rest), `tool` (a script or CLI for the team), `library` (code other modules
     import); `domain` is the part of the business it serves, a short phrase ("payments", "mail import"). Both
     are optional and rest on the same cites: leave one out rather than guess. Leave a node `null` when its
     evidence does not tell you what it is for: an honest gap beats a guess.
   - the document's `overview`: the same shape, at most 2000 characters, for someone new to the project: the entry
     points, where data goes, the risky places. Its cites may be any node's evidence.
   - the document's `tour`: `[{ "node": "<id>", "text": "…", "cites": ["file:line"] }, …]`, one to eight stops a
     newcomer reads in order, usually the entry point first and the riskiest place last. Each stop names a node of
     the map, says in at most two sentences why to look there, and cites lines from that node's own evidence.
   Describe what the cited lines show. A connection, a purpose or a risk the scan did not find is not added here:
   say it to the user instead.

4. **Validate:** `bash MAP --validate` (Bash tool, not PowerShell). It refuses a description that cites a line
   the scan did not read, cites nothing, or runs past two sentences; a layer not on the list or a domain written
   as a sentence; a tour stop at no node, citing another node's lines, or at a node twice; and a map whose
   scanner fields were changed.
   Fix what it names, in the descriptions only, until it holds.

5. **Hand over:** the scan's summary line, how many modules you described (and gave a layer) and how many you
   left `null` and why, the tour's stops,
   then `git diff --stat .crewforth/crew-map.json`. Studio's **Map** view (`/crew-studio`) draws the result.
   Committing it is the user's call.
