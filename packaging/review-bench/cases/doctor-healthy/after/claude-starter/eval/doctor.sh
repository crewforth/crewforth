#!/usr/bin/env bash
# Install doctor — verify a LIVE kit install in a CONSUMER repo is actually active. This is the counterpart to
# smoke-test.sh: smoke-test checks the kit's SOURCE (dev-side, in this repo); doctor checks a real install on a
# user's machine — the things that silently make the gates inert: a hook left non-executable, core.hooksPath not
# set (so the commit trace/secret scan never runs), settings.json missing (so the tool-level gates never fire).
# Zero-dep, bash-only, Git-Bash safe. Run from the project root (or pass the path):  bash .claude/eval/doctor.sh
set -uo pipefail
ROOT="${1:-.}"
cd "$ROOT" 2>/dev/null || { echo "doctor: cannot enter '$ROOT'"; exit 2; }

# Nothing here needs input, and everything here spawns subprocesses that INHERIT this script's stdin. A hook
# reads its payload with `cat`, so one invocation without a pipe would sit waiting for a terminal that is never
# going to type — which is exactly what a "ran 120s and produced nothing" report looks like. Detaching stdin once
# makes that class of hang impossible instead of relying on every call site remembering to redirect.
exec </dev/null

FAIL=0
ok(){  echo "  ✅ $1"; }
bad(){ echo "  ❌ $1"; echo "     ↳ fix: $2"; FAIL=$((FAIL+1)); }
warn(){ echo "  ⚠️  $1"; }
# `skip` lives up here with the other reporters, not down in the readiness block where it used to be
# defined: the health checks call it too, and a helper defined after its first caller is a silent
# no-op — the line never prints and the run shows `skip: command not found` on stderr, where nobody
# looks. Found by RUNNING doctor against a fixture install; grepping for the call sites said wired.
skip(){ echo "  ·  $1"; }

echo "== Claude Starter Kit — install doctor =="

# 0) Is the kit even here?
[ -d .claude ] || { echo "  ❌ no .claude/ in '$PWD' — is the kit installed here?"; echo "     ↳ fix: npx @byerlikaya/claude-starter-kit adopt"; exit 1; }

# 1) VERSION (marks a full install; also what /update-csk compares)
if [ -f .claude/VERSION ]; then ok "VERSION present ($(head -1 .claude/VERSION | tr -cd '0-9A-Za-z.-'))"
else bad "VERSION missing" "reinstall or update the kit (npx @byerlikaya/claude-starter-kit update)"; fi

# 1b) Is that version the current one? Read-only, from the cache session-update-check.sh maintains — doctor makes
#     no network call of its own, so this stays honest offline (no cache -> nothing said) and instant everywhere.
#     The session notice fires once per release; this is the surface that still answers when it was missed.
if [ -f .claude/VERSION ] && [ -f .claude/.state/update-check ]; then
  read -r DLATEST _ < .claude/.state/update-check 2>/dev/null || DLATEST=""
  DLATEST="$(printf '%s' "${DLATEST:-}" | tr -cd '0-9A-Za-z.-')"
  DCUR="$(head -1 .claude/VERSION 2>/dev/null | tr -cd '0-9A-Za-z.-')"
  if [ -n "$DLATEST" ] && awk -v a="$DLATEST" -v b="$DCUR" 'BEGIN{split(a,x,".");split(b,y,".");
       for(i=1;i<=3;i++){if(x[i]+0>y[i]+0)exit 0; if(x[i]+0<y[i]+0)exit 1} exit 1}'; then
    warn "kit v$DCUR installed, v$DLATEST published — update with /update-csk"
  fi
fi

# 2) Hooks present + executable. The .sh set is a glob (extras ok); pre-commit + commit-msg are REQUIRED — they
#    ARE the §4.1/§4.2 trace/secret gate, so a MISSING one is a failure, not a silent skip.
NX=""; GONE=""
for h in .claude/hooks/*.sh; do [ -e "$h" ] || continue; [ -x "$h" ] || NX="$NX $(basename "$h")"; done
for h in .claude/hooks/pre-commit .claude/hooks/commit-msg; do
  if [ ! -e "$h" ]; then GONE="$GONE $(basename "$h")"; elif [ ! -x "$h" ]; then NX="$NX $(basename "$h")"; fi
done
[ -z "$GONE" ] && ok "required git hooks present (pre-commit, commit-msg)" \
              || bad "MISSING git hook(s):$GONE — the commit trace/secret scan is absent" "reinstall or update the kit"
[ -z "$NX" ] && ok "all hooks are executable" \
             || bad "not executable:$NX" "chmod +x .claude/hooks/*.sh .claude/hooks/pre-commit .claude/hooks/commit-msg"

# 2b) Behaviour probe — a hook that is present + executable can still be NEUTERED (its body replaced with `exit 0`).
#     Drive guard-bash with a command it MUST block; if it does not exit 2, the §4.5 gate is disarmed.
if [ -x .claude/hooks/guard-bash.sh ]; then
  # CSK_GATE_LOG=/dev/null: this probe drives the real gate, so without it every `/doctor-csk` writes a
  # synthetic "git push --force blocked" line into the evidence log — and the gate report would then be
  # counting the diagnostics instead of what the model reached for. A measurement tool that contaminates the
  # thing it measures is worse than none.
  if printf '%s' '{"tool_name":"Bash","permission_mode":"auto","tool_input":{"command":"git push --force"}}' | CSK_GATE_LOG=/dev/null bash .claude/hooks/guard-bash.sh >/dev/null 2>&1; then
    bad "guard-bash.sh did NOT block a force-push — the §4.5 gate is neutered/disarmed" "restore guard-bash.sh from the kit"
  else ok "guard-bash.sh blocks a force-push (gate live, not neutered)"; fi
fi

# 3) core.hooksPath — without it the §4.1/§4.2 commit trace + secret/bloat scan never runs
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  HP="$(git config --get core.hooksPath 2>/dev/null || true)"
  case "$HP" in
    */.claude/hooks|.claude/hooks) ok "core.hooksPath -> $HP (commit-time gates active)" ;;
    "") bad "core.hooksPath is unset — commit trace/secret/bloat gates are INACTIVE" "git config core.hooksPath .claude/hooks" ;;
    *)  bad "core.hooksPath -> $HP (not the kit's hooks)" "git config core.hooksPath .claude/hooks" ;;
  esac
else
  warn "not a git repo — commit gates need: git init && git config core.hooksPath .claude/hooks"
fi

# 4) settings.json wires the tool-level gates, and each event maps to a NON-EMPTY hook array (an empty [] wires
#    nothing). PreToolUse/UserPromptSubmit/Stop are required; SessionStart (rehydration) is a warn if absent.
S=.claude/settings.json
if [ -f "$S" ]; then
  # Probed by RUNNING, like §4b does for python3 two sections down. On `command -v` alone a jq that resolves
  # and fails takes this branch forever: the documented grep fallback below becomes unreachable, `jq empty`
  # failing is blamed on the USER's file, and doctor prescribes overwriting it — which would destroy any
  # hooks the project added. Measured with a stub jq on a healthy install: "settings.json is invalid JSON",
  # rc=1, and the three checks after it simply absent.
  if command -v jq >/dev/null 2>&1 && printf '{}' | jq -e . >/dev/null 2>&1; then
    if jq empty "$S" 2>/dev/null; then
      ok "settings.json is valid JSON"
      EMPTY=""
      for ev in PreToolUse UserPromptSubmit Stop; do
        n="$(jq -r --arg e "$ev" '(.hooks[$e] // []) | length' "$S" 2>/dev/null)"
        case "$n" in ''|0) EMPTY="$EMPTY $ev" ;; esac
      done
      [ -z "$EMPTY" ] && ok "settings.json wires PreToolUse / UserPromptSubmit / Stop (non-empty)" \
                      || bad "settings.json hook events empty or missing:$EMPTY — those gates won't fire" "restore settings.json from the kit"
      sn="$(jq -r '(.hooks.SessionStart // []) | length' "$S" 2>/dev/null)"
      case "$sn" in ''|0) warn "SessionStart not wired — session rehydration after /compact or /clear is inactive (update the kit)" ;; *) ok "SessionStart wired (session rehydration active)" ;; esac
    else bad "settings.json is invalid JSON" "restore settings.json from the kit"; fi
  else
    # no jq: the NAME is not the wiring. `"PreToolUse": []` carries the name and wires nothing, and this branch
    # passed it — so on a stock Windows box, the one platform with no jq, doctor reported `healthy` over a
    # settings.json whose §4.4/§4.5 tool gate was empty. That is the M2 finding from the 1.4.0 audit, fixed for
    # the jq path and never for this one; measured here against a hand-built fixture, and it is what
    # smoke-test's M2a case caught the first time it was able to run without jq.
    # Emptiness needs no parser: after the event's `[`, the first non-space character is `]` exactly when the
    # array is empty. Pure parameter expansion, so it costs no process on the hook-heavy platform.
    json_event_nonempty(){   # $1 = file, $2 = event -> 0 when that event's array holds at least one entry
      local all s c
      all="$(cat "$1" 2>/dev/null)"
      s="${all#*\"$2\"}"
      [ "$s" != "$all" ] || return 1
      case "$s" in *"["*) ;; *) return 1 ;; esac
      s="${s#*"["}"
      while [ -n "$s" ]; do
        c="${s%"${s#?}"}"; s="${s#?}"
        case "$c" in [[:space:]]) continue ;; esac
        [ "$c" = "]" ] && return 1
        return 0
      done
      return 1
    }
    MISS=""; EMPTYNJ=""
    for ev in PreToolUse UserPromptSubmit Stop; do
      if grep -q "\"$ev\"" "$S"; then
        json_event_nonempty "$S" "$ev" || EMPTYNJ="$EMPTYNJ $ev"
      else MISS="$MISS $ev"; fi
    done
    { [ -z "$MISS" ] && [ -z "$EMPTYNJ" ] && grep -q 'hooks/' "$S"; } \
      && ok "settings.json wires the required hook events, each non-empty (no jq: shape check)" \
      || bad "settings.json hook events missing:$MISS empty:$EMPTYNJ — those gates won't fire" "restore settings.json from the kit"
    grep -q '"SessionStart"' "$S" || warn "SessionStart not wired — session rehydration inactive (update the kit)"
  fi
  # `${CLAUDE_PROJECT_DIR}` inside a hook command is the shape that breaks on Windows, and it breaks invisibly.
  # Claude Code substitutes that placeholder into the command STRING before any shell sees it; on Windows the
  # value is `C:\Repos\app` and the separators are gone by the time bash reads it. The reported path was
  # `C:ReposApp/.claude/hooks/...` — every hook failed to launch and every gate was absent, while settings.json
  # looked perfectly correct on inspection. The kit now uses a RELATIVE path (hooks run in the project
  # directory), with a `cd` off the bare `$CLAUDE_PROJECT_DIR` as a belt for a session started in a subdirectory.
  # Bare `$VAR` is not the placeholder syntax, so Claude Code leaves it for the shell to expand.
  #
  # Reported on every platform, not only Windows: a repo is shared across machines, and the wiring is wrong on
  # all of them the moment one teammate is on Windows.
  if grep -q '\${CLAUDE_PROJECT_DIR' "$S" 2>/dev/null; then
    bad "settings.json wires hooks through the \${CLAUDE_PROJECT_DIR} placeholder — on Windows its separators are stripped before bash runs, so NO hook launches and every gate is silently absent" \
        "update the kit (npx @byerlikaya/claude-starter-kit adopt) — hook commands become: cd \"\$CLAUDE_PROJECT_DIR\" 2>/dev/null; bash .claude/hooks/<name>.sh"
  else
    ok "hook wiring carries no path placeholder (nothing for Windows to mangle)"
  fi
else
  bad "settings.json missing — the tool-level gates (commit approval, guards, context) are INACTIVE" "reinstall the kit"
fi

# 4a) Skill listing budget. Claude Code loads a listing of every skill's name + description into context each
#     session; the budget is 1% of the context window, and over it descriptions get truncated or dropped
#     "which can strip the keywords Claude needs to match your request" (skills docs). The failure is invisible:
#     the skills are all still installed and still listed BY NAME, they just stop matching. Reported, never
#     enforced — a project is free to ship many skills, it just needs to know the trade and the two documented
#     ways out (raise skillListingBudgetFraction, or set low-priority skills to "name-only" in skillOverrides).
if [ -d .claude/skills ]; then
  LISTING=$(for f in .claude/skills/*/SKILL.md; do
      [ -e "$f" ] || continue
      awk '/^---$/{c++; next} c==1' "$f" | awk '/^(name|description):/,0'
    done | wc -c | tr -d ' ')
  CW="${CONTEXT_WINDOW:-1000000}"; BUDGET=$((CW/100))
  if [ "$LISTING" -le "$BUDGET" ]; then
    ok "skill listing fits the budget (${LISTING} <= ${BUDGET} chars at 1% of a ${CW}-token window)"
  else
    warn "skill listing ${LISTING} chars EXCEEDS the ~${BUDGET} budget for a ${CW}-token window — Claude Code will"
    warn "  truncate or drop descriptions, and a skill whose description is gone stops matching requests."
    warn "  Fixes: raise \"skillListingBudgetFraction\" in settings, or set rarely-used skills to \"name-only\""
    warn "  in \"skillOverrides\". Re-check with a smaller CONTEXT_WINDOW=200000 to see your real model's budget."
    warn "  Which skills? bash .claude/eval/utilization.sh — it reports the ones nothing in this project reached."
  fi
fi

# 4b) Is delegation itself switched off? The documented way to stop Claude using ANY subagent is to deny the `Agent`
#     tool in permissions.deny. A project that does that keeps twelve agents on disk that can never run, and the only
#     symptom is that every task quietly happens on the main thread — which reads as "the kit does nothing" rather
#     than as a setting. Checked at every scope the CLI merges, because one line in ~/.claude/settings.json disables
#     delegation for every project on the machine. Denying it may be deliberate; this names it, it does not judge.
DENYSRC=""
for f in .claude/settings.json .claude/settings.local.json "$HOME/.claude/settings.json"; do
  [ -f "$f" ] || continue
  # A deny entry for the delegation tool, in any of its spellings, with or without an argument pattern.
  # `python3` is guarded: on Windows it is often a Microsoft Store execution alias that BLOCKS instead of
  # failing, so calling it unconditionally can hang the whole doctor run on the machines least able to debug it.
  # Absent python3 does NOT silently skip the check — a skipped check that reports nothing is indistinguishable
  # from a check that passed, which is the failure this whole file exists to prevent.
  # Not "is python3 on PATH" — "can python3 parse JSON". Windows puts a Microsoft Store redirector stub of
  # that name on PATH by default; it passes `command -v`, exits 49 and prints nothing. NOPY then stayed 0, the
  # parse below failed silently, DENYSRC stayed empty, and this reported `ok delegation is enabled` on a
  # machine where nothing had been read. That is the false green this file's own comments are about, and on
  # Windows it was the default outcome. The probe passes arguments: an argless stub run opens the Store.
  #
  # With no usable interpreter this check used to say nothing at all — on Windows, which is every stock
  # Windows machine, and "check by hand" is advice nobody acts on. A grep cannot tell a deny list from an
  # allow list, so it cannot produce the ❌; what it CAN do is notice that both spellings are in the same
  # file and say so as a warning. Coarse on purpose: it is allowed to be wrong in the direction of asking a
  # human to look, never in the direction of a verdict it did not earn.
  if ! printf '{}' | python3 -c 'import sys,json;json.load(sys.stdin)' >/dev/null 2>&1; then
    NOPY=1
    grep -qE '"(Agent|Task)(\([^"]*\))?"' "$f" 2>/dev/null && grep -q '"deny"' "$f" 2>/dev/null \
      && MAYBEDENY="${MAYBEDENY:-} $f"
    continue
  fi
  grep -qE '"(Agent|Task)(\([^"]*\))?"' "$f" 2>/dev/null \
    && grep -q '"deny"' "$f" 2>/dev/null \
    && python3 - "$f" <<'PY' 2>/dev/null && DENYSRC="$DENYSRC $f"
import json,sys,re
try: d=json.load(open(sys.argv[1]))
except Exception: sys.exit(1)
deny=(d.get('permissions') or {}).get('deny') or []
sys.exit(0 if any(re.match(r'^(Agent|Task)\b', str(x)) for x in deny) else 1)
PY
done
if [ "${NOPY:-0}" = 1 ]; then
  if [ -n "${MAYBEDENY:-}" ]; then
    warn "delegation MAY be denied in:${MAYBEDENY} — both \"deny\" and \"Agent\"/\"Task\" appear in that file."
    warn "  No JSON parser here to tell whether they are in the same block, so this is a prompt, not a verdict:"
    warn "  open it and check that Agent/Task is not under permissions.deny. If it is, no subagent can ever run."
  else
    warn "delegation check could not run precisely — no working python3 (a Microsoft Store stub counts as none)."
    warn "  Nothing suspicious found by name; install python3 or jq for a real answer."
  fi
fi
# `A && B && ok … || bad …` cannot express three outcomes. With no usable python3 the && chain is false, so the
# || arm fired and reported `the Agent tool is DENIED in:` — an empty list, a failure that had not been found,
# and a verdict of ❌ on a healthy install. It stayed invisible while `command -v python3` was the test, because
# on Windows the Store stub answered yes and NOPY was never set. Three states, three branches.
if [ -n "$DENYSRC" ]; then
  bad "the Agent tool is DENIED in:$DENYSRC — no subagent can ever run, so every agent on disk is dead weight" \
      "remove the Agent/Task entry from permissions.deny, or accept that this project runs main-thread-only"
elif [ "${NOPY:-0}" != 1 ]; then
  ok "delegation is enabled (the Agent tool is not denied)"
fi

# 5) Agent-name references resolve to an installed agent — checked across CLAUDE.md AND every local doc it points to
#    (its @imports and docs/*.md references). A brownfield takeover renames the project's agents to `-csk` ids, but
#    CLAUDE.md — or an orchestration doc it delegates to, e.g. "detail: docs/AGENTS.md" — may still name the OLD bare
#    agent. That name matches no installed agent, so delegation to it silently fails. Following CLAUDE.md's reference
#    chain catches the pointed-to docs too, while unreferenced prose (design/audit docs, code comments) is ignored —
#    so it stays complete without the false positives a blanket repo scan would raise.
if [ -f CLAUDE.md ] && ls .claude/agents/*.md >/dev/null 2>&1; then
  # Two pull-only agents are invoked explicitly (a commit needs approval; session health is emitted by a hook),
  # NOT auto-delegated — so a bare reference to them does not break delegation; it is only a naming inconsistency.
  PULL_AGENTS=" commit-agent-csk session-manager-csk "
  # Scan set = CLAUDE.md + the local .md files it references (one level: its @imports and any `docs/…md` path).
  SCAN="CLAUDE.md"
  for r in $(grep -oE '@?[A-Za-z0-9_./-]+\.md' CLAUDE.md 2>/dev/null | sed 's/^@//' | sort -u); do
    [ -f "$r" ] && [ "$r" != "CLAUDE.md" ] && SCAN="$SCAN $r"
  done
  # TWO awk passes, not a nested shell loop. This check used to run `sed|head|tr` per agent and then a
  # `grep|cut|tr|sed` for every (agent × scanned file) pair — 12 agents against a handful of docs is already
  # ~250 process spawns. On Linux/macOS that is invisible; on Windows, where Git Bash pays 62-135 ms per spawn
  # instead of ~1.7ms, doctor stopped dead right here and looked hung to the user who ran it. Same disease the
  # route-hint hook had, same cure: let awk do the looping. Two spawns, whatever the component count.
  CSK_AGENT_BASES="$(awk '
    FNR==1 { files[++nf]=FILENAME }
    !got[FILENAME] && /^name:[[:space:]]*/ {
      n=$0; sub(/^name:[[:space:]]*/,"",n); gsub(/[^a-zA-Z0-9-]/,"",n)       # same charset tr -cd kept
      if (n != "") { nm[FILENAME]=n; got[FILENAME]=1 }
    }
    END {
      for (i=1;i<=nf;i++) {
        f=files[i]; n=(f in nm) ? nm[f] : ""
        if (n=="") { n=f; sub(/\.md$/,"",n); sub(/.*\//,"",n) }              # fallback: the file name
        if (n ~ /-csk$/) { b=n; sub(/-csk$/,"",b); print b "\t" n }
      }
    }' .claude/agents/*.md)"
  export CSK_AGENT_BASES
  STALE=""; STALE_PULL=""
  while IFS="$(printf '\t')" read -r base name f lines; do
    [ -n "$base" ] || continue
    entry="
     ↳ \"$base\" → \"$name\"   ($f line(s): $lines)"
    case "$PULL_AGENTS" in *" $name "*) STALE_PULL="$STALE_PULL$entry" ;; *) STALE="$STALE$entry" ;; esac
  done <<EOF
$(awk '
  BEGIN {
    n = split(ENVIRON["CSK_AGENT_BASES"], rows, "\n"); k=0
    for (i=1;i<=n;i++) { if (rows[i]=="") continue; split(rows[i], a, "\t"); k++; base[k]=a[1]; full[k]=a[2] }
    nb=k
  }
  FNR==1 { order[++nf]=FILENAME }
  {
    # bare `base` NOT followed by `-` (so not base-csk) and not glued into a longer word — the identical
    # boundary the grep used. Agent ids are [a-z-] only, so nothing here needs regex escaping.
    for (i=1;i<=nb;i++)
      if ($0 ~ ("(^|[^a-zA-Z-])" base[i] "([^a-zA-Z-]|$)"))
        hit[i, FILENAME] = (hit[i, FILENAME]=="" ? FNR : hit[i, FILENAME] "," FNR)
  }
  # Emitted in agent order, then scanned-file order, so the report reads the same as it always did rather
  # than in awk hash order.
  END {
    for (i=1;i<=nb;i++)
      for (j=1;j<=nf;j++)
        if ((i, order[j]) in hit) print base[i] "\t" full[i] "\t" order[j] "\t" hit[i, order[j]]
  }' $SCAN)
EOF
  if [ -n "$STALE" ]; then
    bad "CLAUDE.md (or a doc it references) names auto-delegated agent(s) that no installed agent matches — delegation to them silently fails" \
        "rename each bare reference to its \`-csk\` id:$STALE"
  fi
  [ -n "$STALE_PULL" ] && warn "CLAUDE.md (or a referenced doc) names pull-only agent(s) by their old bare id — invoked explicitly, so delegation still works; rename for consistency:$STALE_PULL"
  [ -z "$STALE$STALE_PULL" ] && ok "agent references resolve to installed agents (CLAUDE.md + referenced docs)"
fi

# 6) Does the discipline actually REACH the model? `.claude/DISCIPLINE.md` sitting on disk is inert unless
#    `./CLAUDE.md` pulls it in — Claude Code reads CLAUDE.md, not the kit's own files. This is the one failure
#    every check above is blind to: the hooks fire, the gates are live, and yet §1–§3 (routing, DoD, session
#    management) never enter the context, so the model works without any of the discipline it is measured on.
#    Two shapes load it: the `@import` line, or the pre-1.1 layout that pasted the discipline inline (stale,
#    but loaded). Neither present -> absent, and that is a failure, not a style note.
if [ -f .claude/DISCIPLINE.md ]; then
  if [ ! -f CLAUDE.md ]; then
    bad "CLAUDE.md missing — .claude/DISCIPLINE.md is never loaded (routing / DoD / session rules absent)" \
        "create CLAUDE.md with this as its own line: @.claude/DISCIPLINE.md"
  elif grep -qE '^[[:space:]]*@\.claude/DISCIPLINE\.md[[:space:]]*$' CLAUDE.md; then
    ok "CLAUDE.md imports .claude/DISCIPLINE.md (the discipline reaches the model)"
  elif grep -q '^## Four working principles' CLAUDE.md && grep -qE '^### 4\.[45] ' CLAUDE.md; then
    warn "CLAUDE.md carries the discipline INLINE (pre-1.1 layout) — it loads, but kit updates never reach it; migrate to the '@.claude/DISCIPLINE.md' import line"
  else
    bad "CLAUDE.md does not import .claude/DISCIPLINE.md — the discipline is on disk but never loaded" \
        "add this as its own line at the top of CLAUDE.md: @.claude/DISCIPLINE.md"
  fi
fi

echo "---"
if [ "$FAIL" -eq 0 ]; then echo "DOCTOR: healthy ✅"
else echo "DOCTOR: $FAIL issue(s) ❌ — apply the fixes above"; fi

# 8b) The shell matcher. Claude Code's hooks reference is explicit: inspect shell commands with
#     `Bash|PowerShell`, because wherever the PowerShell tool is enabled it IS the shell — and it is on by
#     default for claude.ai and Console accounts on Windows. An install from before 2.5.0 watches only `Bash`,
#     so every PowerShell command walks past the §4.5 rules with nothing firing. Nothing about the session
#     looks wrong, which is why this is a check and not a release note.
if [ -f .claude/settings.json ]; then
  if grep -q '"matcher"[[:space:]]*:[[:space:]]*"[^"]*PowerShell' .claude/settings.json; then
    ok "shell gates watch both Bash and PowerShell"
  elif grep -q '"matcher"[[:space:]]*:[[:space:]]*"Bash"' .claude/settings.json; then
    bad "shell gates watch only Bash — PowerShell commands bypass every §4.5 rule" \
        "update the kit (npx @byerlikaya/claude-starter-kit update), or set the PreToolUse matcher to \"Bash|PowerShell\""
  fi
fi
# 9) The auto-mode classifier. Since 2026-08-14 auto mode is the default permission mode on Pro/Max/Team, so a
#     classifier answers permission prompts the user used to answer. Two things can be wrong and neither shows
#     up in a session. Only ONE of them is a real gate finding: a custom autoMode block that dropped the
#     built-ins by omitting "$defaults" — 66 soft blocks gone, silently. Whether the kit's own rules are present
#     is reported but NOT treated as a failure: they were measured on 2026-08-24 not to enforce (see the skill).
if [ -x .claude/skills/automode-policy/scripts/check.sh ] || [ -f .claude/skills/automode-policy/scripts/check.sh ]; then
  AMOUT="$(bash .claude/skills/automode-policy/scripts/check.sh 2>&1)"; AMRC=$?
  case "$AMRC" in
    0) ok "auto-mode classifier config: built-ins intact, kit rules present (config, not a gate)" ;;
    2) bad "auto-mode classifier BUILT-INS DROPPED — an autoMode array lacks \"\$defaults\"" \
           "restore it in ~/.claude/settings.json; see .claude/skills/automode-policy/SKILL.md" ;;
    3) skip "auto-mode classifier config: kit rules absent (measured not to enforce — see the skill)" ;;
    # Same vocabulary as the other three branches on purpose. It used to read "auto-mode policy check
    # skipped", and the suite's assertion — written on a machine that HAS the claude CLI — never saw this
    # branch. CI has no CLI, so every run took it and the case failed on a wording difference, not a defect.
    *) skip "auto-mode classifier config: not checked (no claude CLI, or auto mode unavailable here)" ;;
  esac
  [ "$AMRC" = 2 ] && printf '%s\n' "$AMOUT" | grep 'auto-mode config' 
else
  warn "auto-mode policy check skipped (install predates the automode-policy skill; run the updater)"
fi
# 10) Gate activity. The suite proves the gates CAN fire; this reports whether anything actually tripped them.
#     Recording is on by default (rule names only, never the command), so "no log" here means no gate has
#     fired yet — a measured zero, not a gap. Never a failure either way.
if [ -f .claude/eval/gate-report.sh ]; then
  GOUT="$(bash .claude/eval/gate-report.sh 2>/dev/null)"; GRC=$?
  case "$GRC" in
    0) GL="$(printf '%s' "$GOUT" | grep -E 'decision\(s\)|no gate has fired' | head -1 | sed 's/^ *//')"
       [ -n "$GL" ] && ok "gate activity: $GL" || ok "gate activity recorded (see /gates-csk)" ;;
    3) skip "gate activity NOT MEASURED — nowhere to record (see /gates-csk)" ;;
    *) skip "gate activity unreadable (see /gates-csk)" ;;
  esac
fi
# --- Agentic readiness (ADVISORY) -------------------------------------------------------------------------
# Everything above answers "are the kit's gates live?". This answers a different question the gates cannot see:
# "is this PROJECT set up so an agent can actually work well in it?" A flawless install still starves its
# agents when the CLAUDE.md project section is left as the template, there is no sandbox to run in, and no
# project-specific skill carries the domain. These are project maturity, not install health, so they NEVER
# change the exit code — doctor's verdict stays a statement about the install.
echo
# The toolchain the install actually landed on. It runs here as well as in the installers because the machine
# changes after install day — a wiped PATH, a new laptop, a corporate image that removed jq — and the kit's
# fallbacks mean none of that announces itself. Advisory: it never changes the verdict above.
# doctor has already cd'd into the project, so the installed copy is the one to run; fall back to the copy
# sitting beside this script for the case where doctor is run straight out of the kit source.
PREFLIGHT=".claude/eval/preflight.sh"
[ -f "$PREFLIGHT" ] || PREFLIGHT="$(dirname "$0")/preflight.sh"
[ -f "$PREFLIGHT" ] && bash "$PREFLIGHT"

echo "Readiness (advisory — does not affect the verdict above):"
RDY=0; RTOT=0
rdy(){ RTOT=$((RTOT+1)); RDY=$((RDY+1)); echo "  ✅ $1"; }
gap(){ RTOT=$((RTOT+1)); echo "  ➖ $1"; echo "     ↳ $2"; }

# R1) Is the CLAUDE.md project section filled in, or still the shipped template? An unfilled section means every
#     agent works stack-blind — it is the single most common way a correct install still underperforms.
if [ -f CLAUDE.md ]; then
  if grep -qE '<PROJECT NAME>|<One sentence:|<Fill in per the project' CLAUDE.md; then
    gap "CLAUDE.md project section is still the template (placeholders left in)" \
        "fill in Project / Stack / Project skills — agents read the stack from there"
  else rdy "CLAUDE.md project section is filled in"; fi
fi

# R2) A project-specific skill — the kit ships the generic 'how's; the domain ones (payment-contract,
#     notification-rules, a backend-pattern skill) are the project's to add. Needs the install manifest to tell
#     kit-shipped from project-owned; without it (pre-1.8 install) the signal is unknowable, so it is skipped
#     rather than guessed — a wrong "you have no project skills" is worse than no line at all.
MAN=.claude/kit-manifest.txt
if [ -f "$MAN" ]; then
  OWN=0
  for d in .claude/skills/*/; do
    [ -d "$d" ] || continue
    grep -qxF "skills/$(basename "$d")" "$MAN" || OWN=$((OWN+1))
  done
  [ "$OWN" -gt 0 ] && rdy "$OWN project-specific skill(s) alongside the kit's" \
                   || gap "no project-specific skill — only the kit's generic ones are installed" \
                          "put the domain 'how's in .claude/skills/ (format: .claude/AGENT_TEMPLATE.md)"
else
  skip "project-skill signal skipped (no .claude/kit-manifest.txt — install predates it; run the updater)"
fi

# R3) A sandbox to run in. Agentic work executes commands; a devcontainer is what makes that bounded rather
#     than trusting every command against the host.
if [ -f .devcontainer/devcontainer.json ]; then rdy "devcontainer present (agentic execution is sandboxed)"
else gap "no .devcontainer/devcontainer.json — agent commands run directly against your machine" \
         "add a devcontainer, or keep approval-mode gates on for anything destructive (§4.5)"; fi

# R4) MCP servers — the project's own tools/data reaching the model. Either the project-level .mcp.json or an
#     mcpServers block in the kit's settings counts.
if [ -f .mcp.json ] || grep -q '"mcpServers"' .claude/settings.json 2>/dev/null; then
  rdy "MCP servers configured (project tools/data reach the model)"
else gap "no MCP server configured — the model has no project-specific tool access" \
         "add .mcp.json when a tool/data source would help (the mcp-builder skill covers writing one)"; fi

# R5) Context freshness. CLAUDE.md is read once per session and is the only project-wide instruction the model
#     gets; if the code moved a long way since it was last touched, it is describing a project that no longer
#     exists. Counted as commits (not days) that changed something OUTSIDE .claude since CLAUDE.md's mtime —
#     mtime, not git history, because a default install gitignores CLAUDE.md and it has no history to read.
if git rev-parse --is-inside-work-tree >/dev/null 2>&1 && [ -f CLAUDE.md ]; then
  MT="$(stat -c %Y CLAUDE.md 2>/dev/null || stat -f %m CLAUDE.md 2>/dev/null)"
  MT="$(printf '%s' "${MT:-}" | tr -cd '0-9')"
  MAXC="${CSK_FRESHNESS_MAX:-40}"
  if [ -n "$MT" ]; then
    CH="$(git rev-list --count HEAD --since="@$MT" -- . ':(exclude).claude' 2>/dev/null | tr -cd '0-9')"
    CH="${CH:-0}"
    [ "$CH" -le "$MAXC" ] && rdy "CLAUDE.md is current ($CH commit(s) of drift since it was last touched)" \
                          || gap "CLAUDE.md is stale — $CH commits changed the project since it was last touched (limit $MAXC)" \
                                 "re-read it against the code and update Stack / Project skills (the claude-md-improver flow)"
  else skip "freshness signal skipped (cannot read CLAUDE.md mtime on this platform)"; fi
fi

[ "$RTOT" -gt 0 ] && echo "  → readiness $RDY/$RTOT"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
