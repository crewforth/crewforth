#!/usr/bin/env bash
# payload-check.sh KIT_DIR — is this payload whole enough to install? start.sh and adopt.sh run it before their first
# write, so a broken download (a truncated archive, a copy that lost a folder, a hook settings.json names but the
# payload does not carry) stops with "nothing installed" instead of leaving a half install whose gates are missing.
# Read-only and quick: file tests and one read of settings.json, no node, no network. Prints one problem per line
# (paths relative to KIT_DIR) and exits 1 when there is any, 0 when there is none, 2 on bad usage.
# CREW_PAYLOAD_UNCHECKED=1 skips it (the installers say so); it exists for a payload someone trimmed on purpose.
set -uo pipefail
K="${1:-}"
[ -n "$K" ] && [ -d "$K" ] || { echo "usage: payload-check.sh KIT_DIR" >&2; exit 2; }
P=""
# The files every install copies and every gate depends on.
for f in CLAUDE.md settings.json hooks/pre-commit hooks/commit-msg hooks/guard-bash.sh hooks/guard-write.sh \
         eval/doctor.sh eval/lib/settings-json.awk; do
  [ -s "$K/$f" ] || P="$P"$'\n'"missing or empty: $f"
done
for d in agents skills hooks eval; do [ -d "$K/$d" ] || P="$P"$'\n'"missing folder: $d/"; done
# Every hook settings.json wires is in the payload: a missing one is a gate that fails on every tool call.
if [ -f "$K/settings.json" ]; then
  while IFS= read -r h; do
    [ -s "$K/hooks/$h" ] || P="$P"$'\n'"settings.json names hooks/$h, which the payload does not carry"
  done < <(grep -o '\.claude/hooks/[A-Za-z0-9._-]*' "$K/settings.json" | sed 's|^\.claude/hooks/||' | LC_ALL=C sort -u)
fi
# A skill folder without its SKILL.md and an empty agent file load as nothing, silently.
for s in "$K"/skills/*/; do [ -d "$s" ] || continue; [ -s "${s}SKILL.md" ] || P="$P"$'\n'"skills/$(basename "$s")/SKILL.md is missing or empty"; done
for a in "$K"/agents/*.md; do [ -e "$a" ] || continue; [ -s "$a" ] || P="$P"$'\n'"agents/$(basename "$a") is empty"; done
[ -z "$P" ] && exit 0
printf '%s\n' "${P#$'\n'}"
exit 1
