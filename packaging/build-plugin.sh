#!/usr/bin/env bash
# Generate the Claude Code plugin edition from the payload — the "lite" channel.
# It ships the agents, skills, commands, AND the tool-level gate hooks (auto-discovered via hooks/hooks.json,
# invoked through ${CLAUDE_PLUGIN_ROOT}). What it does NOT ship: the git-hook gates (pre-commit / commit-msg
# trace/secret/bloat scan) — those are wired by core.hooksPath, which only the full install (start.sh / adopt.sh)
# can set. So a plugin user gets the Claude Code gates (commit/push approval, destructive-op & write guards,
# context measurement, session rehydration) but the commit-time trace scan still needs the full install.
# Single source of truth stays kit/; this regenerates plugin/ from it.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/kit"
OUT="$ROOT/plugin"

rm -rf "$OUT"
mkdir -p "$OUT/.claude-plugin" "$OUT/hooks"
cp -R "$SRC/agents"   "$OUT/agents"
cp -R "$SRC/skills"   "$OUT/skills"
# No commands/: since 3.0 the slash commands are skills (metadata kind: command) and ship with skills/.
# The kit's one JSON reader. A skill script reaches it at scripts/../../../eval/lib in BOTH editions
# (automode-policy/scripts/apply.sh merges the user's settings with it), so it ships at the same relative spot
# here. Only lib/ — the rest of eval/ is install-only tooling the plugin does not carry.
mkdir -p "$OUT/eval"
cp -R "$SRC/eval/lib" "$OUT/eval/lib"

# The panel. Measured, not assumed, before this line was written:
#   - a plugin's whole directory is copied to the user's machine on install; no manifest field opts a
#     directory in, and `claude plugin validate --strict` accepts an extra top-level one.
#   - the panel runs from here unchanged: palette.js's single `<panel>/../agents` rule resolves to
#     plugin/agents, --selftest passes 4/4, and the HTTP probe passes 9/9 against a plugin-shaped root.
#   - a plugin cannot reference anything outside its own root, so this has to be a copy, not a symlink.
# The command resolves it through ${CLAUDE_PLUGIN_ROOT}, which IS substituted in a command body.
cp -R "$SRC/studio"   "$OUT/studio"
# The recursive copy carries the permission-gate hook but not its exec bit. permissions.js invokes it as
# `bash <path>`, so the bit is not load-bearing — set anyway, so the two editions are not subtly different.
chmod +x "$OUT/studio/ensure-node.sh" "$OUT/studio/server/hooks/"*.sh 2>/dev/null || true

# The Claude Code hooks that work standalone (self-locate via $0, read stdin).
# skill-trust.sh is left out: it decides kit-owned vs project-owned from .claude/kit-manifest.txt, which only a
# start.sh/adopt.sh install writes. Shipped here it could only ever exit silently — an idle component.
# session-update-check.sh IS shipped: it reads the plugin's own .claude-plugin/plugin.json and compares it against
# the marketplace repo's copy, so a plugin user hears about a release on the channel that delivers it.
# board.sh is not itself a hook: it is the engine board-sync.sh and commit-msg both call by path. It ships in the
# same directory because both of those callers resolve it as "$HERE/board.sh", and a plugin edition without it
# would carry the board's session-start awareness and none of its claim gate — the exact one-channel-is-weaker
# asymmetry the git hooks below were added to close.
for h in guard-bash.sh guard-write.sh context-usage.sh session-guard.sh session-rehydrate.sh session-stats.sh \
         guard-commit-scan.sh route-hint.sh session-update-check.sh board.sh board-sync.sh guard-powershell.sh prompt-approval.sh guard-schedule.sh guard-agent-model.sh; do
  cp "$SRC/hooks/$h" "$OUT/hooks/$h"
  chmod +x "$OUT/hooks/$h"
done

# The git hooks and their pattern files now DO ship — not to be wired through core.hooksPath (a plugin cannot
# set that), but because guard-commit-scan.sh runs them from PreToolUse. Without them the plugin edition had
# the commit APPROVAL gate and none of the commit CONTENT gates: a credential or an authorship trailer could
# land, and of three distribution channels one was quietly weaker than the rest.
for h in pre-commit commit-msg; do
  cp "$SRC/hooks/$h" "$OUT/hooks/$h"
  chmod +x "$OUT/hooks/$h"
done
cp "$SRC/hooks/trace-blocklist.txt" "$SRC/hooks/secret-blocklist.txt" "$SRC/hooks/floor-blocklist.txt" "$OUT/hooks/"
# The one gate that is not a bash script: what the hook with no "shell" loads when Claude Code finds no Git Bash and
# runs it through PowerShell. Read with Get-Content and run with Invoke-Expression — never executed as a file.
cp "$SRC/hooks/no-bash-guard.ps1" "$OUT/hooks/"

# The commands the model is told to run name the file install's path, `bash .claude/<path>.sh`. A plugin install has
# no .claude/, so in this edition every one of them exited 127 (measured from an empty project: 12 lines in 8 files).
# Claude Code substitutes ${CLAUDE_PLUGIN_ROOT} in a plugin's skill and agent bodies (plugins reference, "Where each
# variable resolves"), so the copy here names its own root — quoted, because the root can hold a space.
# ONE RULE: every `.sh` this edition ships is rewritten, wherever it lives (hooks, skills/<name>/scripts, studio, and
# any place a later version adds). Not a folder list. The name is matched literally (its dots escaped) and must end
# there, so `board.sh` does not half-rewrite `board.sh.orig` or pull `board-sh` onto board.sh. A line marked
# `# full install` is the file-install spelling beside its plugin twin, and is left as written. `.claude/eval/*.sh`
# never matches: the plugin ships no eval scripts, and the text there says so. kit/ keeps the file-install form: a
# literal ${CLAUDE_PLUGIN_ROOT} would expand to nothing there and give `bash /hooks/x.sh`.
_RW="$(mktemp)"; trap 'rm -f "$_RW"' EXIT
while IFS= read -r f; do r="${f#"$OUT"/}"; re="$(printf '%s' "$r" | sed 's/[.[\*^$]/\\&/g')"
  printf '/# full install/!s#bash \\.claude/%s([^A-Za-z0-9_./-]|$)#bash "${CLAUDE_PLUGIN_ROOT}/%s"\\1#g\n' "$re" "$r"
done < <(cd "$OUT" && find . -name '*.sh' -type f | sed 's#^\./##' | LC_ALL=C sort | sed "s#^#$OUT/#") > "$_RW"
while IFS= read -r f; do
  grep -qE 'bash \.claude/' "$f" || continue
  sed -E -f "$_RW" "$f" > "$f.rw" && mv "$f.rw" "$f"
done < <(find "$OUT/agents" "$OUT/skills" -name '*.md' -type f)
# Asserted: no shipped script is still named by the file-install path (outside a `# full install` line), every
# rewritten path is a file this edition ships, and no rewrite stopped inside a name (`"…/board.sh".orig`).
_left="$(grep -rhE 'bash \.claude/' "$OUT/agents" "$OUT/skills" --include='*.md' | grep -v '# full install' \
  | grep -oE 'bash \.claude/[A-Za-z0-9_./-]+\.sh([^A-Za-z0-9_./-]|$)' | sed -E 's/[^A-Za-z0-9_./-]$//' | sort -u \
  | while IFS= read -r c; do [ -f "$OUT/${c#bash .claude/}" ] && printf ' %s' "$c"; done)" || true
[ -z "$_left" ] || { echo "build-plugin.sh: still named by the file-install path:$_left" >&2; exit 1; }
_miss="$(grep -rhoE '"\$\{CLAUDE_PLUGIN_ROOT\}/[A-Za-z0-9_./-]+"[A-Za-z0-9_.-]?' "$OUT/agents" "$OUT/skills" --include='*.md' | sort -u \
  | while IFS= read -r c; do case "$c" in (*\"[A-Za-z0-9_.-]) printf ' half-rewritten:%s' "$c"; continue ;; esac
      c="${c#\"\$\{CLAUDE_PLUGIN_ROOT\}/}"; c="${c%\"}"; [ -f "$OUT/$c" ] || printf ' %s' "$c"; done)" || true
[ -z "$_miss" ] || { echo "build-plugin.sh: a rewritten path names a file this edition does not ship:$_miss" >&2; exit 1; }

# hooks/hooks.json — auto-discovered by Claude Code when the plugin is enabled (no plugin.json field needed).
# Same structure as settings.json's "hooks", but paths resolve through ${CLAUDE_PLUGIN_ROOT} (the plugin's install
# dir) instead of ${CLAUDE_PROJECT_DIR}/.claude. Quoted heredoc: ${CLAUDE_PLUGIN_ROOT} stays literal for Claude Code.
cat > "$OUT/hooks/hooks.json" <<'HOOKS'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash|PowerShell|Write|Edit|NotebookEdit",
        "hooks": [
          { "type": "command", "command": "echo --% >/dev/null;: ' | out-null\n<#'\nexit 0\n#> try { Invoke-Expression (Get-Content -Raw -LiteralPath (Join-Path $env:CLAUDE_PLUGIN_ROOT 'hooks/no-bash-guard.ps1') -ErrorAction Stop) } catch { [Console]::Error.WriteLine(\"GUARD: Crewforth's gate for a machine without Git Bash could not be loaded, so this tool call is stopped: $_\"); exit 2 }", "timeout": 600 }
        ]
      },
      {
        "matcher": "Bash|PowerShell",
        "hooks": [
          { "type": "command", "shell": "bash", "command": "bash \"$CLAUDE_PLUGIN_ROOT/hooks/guard-bash.sh\"", "timeout": 600 },
          { "type": "command", "shell": "bash", "command": "bash \"$CLAUDE_PLUGIN_ROOT/hooks/guard-commit-scan.sh\"", "timeout": 600 }
        ]
      },
      {
        "matcher": "PowerShell",
        "hooks": [
          { "type": "command", "shell": "bash", "command": "bash \"$CLAUDE_PLUGIN_ROOT/hooks/guard-powershell.sh\"", "timeout": 600 }
        ]
      },
      {
        "matcher": "Write|Edit|NotebookEdit",
        "hooks": [
          { "type": "command", "shell": "bash", "command": "bash \"$CLAUDE_PLUGIN_ROOT/hooks/guard-write.sh\"", "timeout": 600 }
        ]
      },
      {
        "matcher": "CronCreate|ScheduleWakeup|RemoteTrigger|mcp__.*([Tt]rigger|[Ss]chedul|[Cc]ron|[Ll]ater).*",
        "hooks": [
          { "type": "command", "shell": "bash", "command": "bash \"$CLAUDE_PLUGIN_ROOT/hooks/guard-schedule.sh\"", "timeout": 600 }
        ]
      },
      {
        "matcher": "Agent|Task",
        "hooks": [
          { "type": "command", "shell": "bash", "command": "bash \"$CLAUDE_PLUGIN_ROOT/hooks/guard-agent-model.sh\"", "timeout": 600 }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          { "type": "command", "shell": "bash", "command": "bash \"$CLAUDE_PLUGIN_ROOT/hooks/prompt-approval.sh\"", "timeout": 60 },
          { "type": "command", "shell": "bash", "command": "bash \"$CLAUDE_PLUGIN_ROOT/hooks/context-usage.sh\"", "timeout": 60 },
          { "type": "command", "shell": "bash", "command": "bash \"$CLAUDE_PLUGIN_ROOT/hooks/route-hint.sh\"", "timeout": 60 }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          { "type": "command", "shell": "bash", "command": "bash \"$CLAUDE_PLUGIN_ROOT/hooks/session-guard.sh\"", "timeout": 60 }
        ]
      }
    ],
    "SessionStart": [
      {
        "matcher": "startup|resume|clear|compact|fork",
        "hooks": [
          { "type": "command", "shell": "bash", "command": "bash \"$CLAUDE_PLUGIN_ROOT/hooks/session-rehydrate.sh\"", "timeout": 60 }
        ]
      },
      {
        "matcher": "startup|resume|clear|compact|fork",
        "hooks": [
          { "type": "command", "shell": "bash", "command": "bash \"$CLAUDE_PLUGIN_ROOT/hooks/board-sync.sh\"", "timeout": 60 }
        ]
      },
      {
        "matcher": "startup",
        "hooks": [
          { "type": "command", "shell": "bash", "command": "bash \"$CLAUDE_PLUGIN_ROOT/hooks/session-update-check.sh\"", "timeout": 60 }
        ]
      }
    ]
  }
}
HOOKS

VERSION="$(cat "$ROOT/VERSION")"
cat > "$OUT/.claude-plugin/plugin.json" <<JSON
{
  "\$schema": "https://json.schemastore.org/claude-code-plugin-manifest.json",
  "name": "crewforth",
  "displayName": "Crewforth",
  "description": "Crewforth — disciplined agents, skills, commands, and tool-level gate hooks (commit/push approval, destructive-op & write guards, context-fill measurement, session rehydration) for Claude Code. The git-commit trace/secret/bloat scan needs the full install (start.sh / adopt.sh).",
  "version": "${VERSION}",
  "author": { "name": "Barış Yerlikaya" },
  "homepage": "https://github.com/Crewforth/crewforth",
  "repository": "https://github.com/Crewforth/crewforth",
  "license": "MIT",
  "keywords": ["claude-code", "agents", "subagents", "skills", "slash-commands", "workflow", "hooks"]
}
JSON

# Asserted, not printed. The counts below are a summary a reader skims; this is the one component whose
# absence would be invisible — the plugin would install cleanly and /crew-studio would send the user to a
# path that is not there.
[ -f "$OUT/studio/server/index.js" ] || { echo "build-plugin.sh: the panel did not land in $OUT/studio" >&2; exit 1; }

NCMD="$(grep -l '^  kind: command' "$OUT"/skills/*/SKILL.md 2>/dev/null | wc -l | tr -d ' ')"
echo "plugin/ generated (v${VERSION}): $(ls "$OUT/agents"/*.md | wc -l | tr -d ' ') agents, $(( $(ls -d "$OUT/skills"/*/ | wc -l | tr -d ' ') - NCMD )) skills, $NCMD commands (as skills), $(ls "$OUT/hooks"/*.sh | wc -l | tr -d ' ') hooks, studio ($(find "$OUT/studio" -type f | wc -l | tr -d ' ') files)"
