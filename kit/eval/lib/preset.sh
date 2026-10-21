#!/usr/bin/env bash
# preset.sh — an organisation's settings for Crewforth in one file, applied to a project.
#
#   bash preset.sh --apply <name|file.json>    from the project root; a name is one of eval/lib/presets/
#   bash preset.sh --check <name|file.json>    is it a valid preset? Nothing is written (the installers ask first)
#   bash preset.sh --show                      the preset in force here, or "none"
#   bash preset.sh --list                      the presets that ship
#
# A preset is plain JSON (see presets/default.json for every key):
#   critical.add / critical.remove   paths made critical, or not (globs, as `+ glob` / `- glob`)
#   floors                           [agent, change, risk, model]: a model a class of work runs on at least
#   verify                           commands the gate may run as a verify command
#   lang                             en | tr, the language of what Crewforth says (only when the project has none)
#
# Where it goes: .claude/crew-model-rules, the file every reader of these rules already reads (the model gate,
# agent-outcome's scan, doctor, Studio), as one marked block at the top. The project's own lines stay below it, so
# the rule is the file's own: for a critical path the last line that matches wins, so a project's `- glob` undoes a
# preset's `+ glob`; a floor only ever raises, so a preset's floor is a minimum a project can raise and not lower.
# Applying again replaces the block and nothing else; the same preset twice gives the same bytes.
#
# rc 0 = applied (or shown) · 1 = the preset is not valid, or names nothing; nothing was written · 2 = usage
# Every JSON read is Crewforth's own reader (settings-json.awk): no jq, no python.
set -u
_here="${BASH_SOURCE%[/\\]*}"; [ "$_here" = "${BASH_SOURCE}" ] && _here=.
SJ="$_here/settings-json.awk"; DIR="$_here/presets"
RULES=.claude/crew-model-rules; CONF=.claude/kit.conf
BEGIN_MARK='# ---- preset:'; END_MARK='# ---- end of preset (lines below are this project'"'"'s own and win over it, see preset.sh) ----'

die(){ echo "preset: $*" >&2; exit 1; }
jget(){ awk -v op=get -v path="$1" -f "$SJ" "$2" 2>/dev/null; }
jstrings(){ awk -v op=strings -v path="$1" -f "$SJ" "$2" 2>/dev/null; }
jlen(){ local n; n="$(awk -v op=len -v path="$1" -f "$SJ" "$2" 2>/dev/null)"; printf '%s' "${n:-0}"; }

case "${1:-}" in
  --list) for f in "$DIR"/*.json; do [ -f "$f" ] || continue; n="${f##*/}"; printf '%s\n' "${n%.json}"; done; exit 0 ;;
  --show)
    [ -f "$RULES" ] || { echo none; exit 0; }
    while IFS= read -r l || [ -n "$l" ]; do case "$l" in "$BEGIN_MARK "*) l="${l#"$BEGIN_MARK "}"; echo "${l%% *}"; exit 0 ;; esac; done < "$RULES"
    echo none; exit 0 ;;
  --apply|--check) [ -n "${2:-}" ] || { echo "usage: preset.sh --apply|--check <name|file.json> | --show | --list" >&2; exit 2; } ;;
  *) echo "usage: preset.sh --apply|--check <name|file.json> | --show | --list" >&2; exit 2 ;;
esac
MODE="$1"
[ "$MODE" = --check ] || [ -d .claude ] || die "no .claude/ here: run it from the root of a project Crewforth is installed in"

# ---- which file ----
P="$2"
case "$P" in *.json|*/*) ;; *) P="$DIR/$P.json" ;; esac
[ -f "$P" ] || die "no preset at $P (the ones that ship: $(bash "$0" --list 2>/dev/null | tr '\n' ' '))"
awk -v op=validate -f "$SJ" "$P" 2>/dev/null || die "$P is not a JSON object"
NAME="$(jget name "$P")"; NAME="${NAME#\"}"; NAME="${NAME%\"}"
case "$NAME" in ''|*[!a-z0-9-]*) die "$P: name must be lower case letters, digits and -" ;; esac

# ---- what it says, checked before anything is written ----
LINES=()
for k in add remove; do
  sign='+'; [ "$k" = remove ] && sign='-'
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    case "$g" in *[[:space:]\#]*) die "$P: critical.$k holds '$g', which has a space or a #" ;; esac
    LINES+=("$sign $g")
  done < <(jstrings "critical.$k" "$P")
done
nf="$(jlen floors "$P")"; i=0
while [ "$i" -lt "$nf" ]; do
  f=(); while IFS= read -r w; do f+=("$w"); done < <(jstrings "floors.$i" "$P")
  [ "${#f[@]}" = 4 ] || die "$P: floors[$i] is not [agent, change, risk, model]"
  case "${f[3]}" in haiku|sonnet|opus) ;; *) die "$P: floors[$i] names the model '${f[3]}', not haiku, sonnet or opus" ;; esac
  for w in "${f[@]}"; do case "$w" in ''|*[[:space:]\#]*) die "$P: floors[$i] has an empty word, a space or a #" ;; esac; done
  LINES+=("floor ${f[0]} ${f[1]} ${f[2]} ${f[3]}"); i=$((i+1))
done
while IFS= read -r c; do
  [ -n "$c" ] || continue
  case "$c" in *[\;\&\|\<\>\`\$\#]*) die "$P: verify '$c' has a shell operator or a #; the gate runs a verify command as one command" ;; esac
  LINES+=("verify $c")
done < <(jstrings verify "$P")
LANGV="$(jget lang "$P")"; LANGV="${LANGV#\"}"; LANGV="${LANGV%\"}"
case "$LANGV" in ''|null|en|tr) ;; *) die "$P: lang is '$LANGV', not en or tr" ;; esac
for k in $(awk -v op=keys -f "$SJ" "$P" 2>/dev/null); do
  case "$k" in about|name|critical|floors|verify|lang) ;; *) die "$P: unknown key '$k' (about, name, critical, floors, verify, lang)" ;; esac
done

[ "$MODE" = --check ] && { echo "preset: $NAME is valid — ${#LINES[@]} line(s)"; exit 0; }

# ---- the block, at the top of the rules file; the project's own lines kept below it ----
OWN=""
if [ -f "$RULES" ]; then
  skip=0
  while IFS= read -r l || [ -n "$l" ]; do
    case "$l" in "$BEGIN_MARK "*) skip=1; continue ;; "$END_MARK") skip=0; continue ;; esac
    [ "$skip" = 1 ] || OWN+="$l"$'\n'
  done < "$RULES"
fi
T="$RULES.preset.$$"
{
  printf '%s %s (written by preset.sh; apply again to change it, edit your own lines below) ----\n' "$BEGIN_MARK" "$NAME"
  for l in ${LINES[@]+"${LINES[@]}"}; do printf '%s\n' "$l"; done
  printf '%s\n' "$END_MARK"
  printf '%s' "$OWN"
} > "$T" && mv -f "$T" "$RULES" || { rm -f "$T"; die "could not write $RULES"; }

# ---- kit.conf: the preset's language, only where the project has none. Which preset is in force is said once, by
# the block's own first line (--show reads it): kit.conf is rewritten by every update, the rules file is not.
if [ -f "$CONF" ] && case "$LANGV" in en|tr) true ;; *) false ;; esac; then
  hadlang=0; while IFS= read -r l || [ -n "$l" ]; do case "$l" in lang=*) hadlang=1 ;; esac; done < "$CONF"
  [ "$hadlang" = 0 ] && printf 'lang=%s\n' "$LANGV" >> "$CONF"
fi
echo "preset: $NAME applied — ${#LINES[@]} line(s) in $RULES; your own lines below the block were kept"
exit 0
