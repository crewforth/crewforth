#!/usr/bin/env bash
# Can Claude Code find Git Bash on this Windows machine? The ONE copy of this check: doctor.sh runs it for a full
# install, and /crew-doctor runs it on a plugin install, where doctor.sh does not ship (eval/lib ships in both).
#
#   bash eval/lib/git-bash.sh   nothing off Windows; on Windows one line (and a fix line), in doctor's format
#   exit 0  found, or not Windows · 1  NOT FOUND, a failure · 3  a warning · 4  not checked (no cygpath)
#
# WHY: Claude Code runs every hook through the bash it finds, and without one it runs them through PowerShell, where
# a Crewforth hook exits 0 and no gate runs — measured in the field (a `git push --force` went through). The lookup
# is Claude Code's own, read from its 2.1.284 binary, in its order: CLAUDE_CODE_GIT_BASH_PATH (a bash/sh binary that
# exists) · C:\Program Files\Git\bin\bash.exe · C:\Program Files (x86)\Git\bin\bash.exe ·
# <git.exe on PATH>\..\..\bin\bash.exe. The bash running THIS script proves nothing: it can come from anywhere on
# PATH. The last step depends on the PATH Claude Code starts with, which is not this shell's (Git Bash puts its own
# git first), so a bash found only there is a warning.
set -u
RC=0

# Language: CREW_LANG, else the install's kit.conf, else the locale — the doctor's rule, so both editions agree.
case "${CREW_LANG:-}" in tr|en) ;; *)
  CREW_LANG=""
  if [ -f .claude/kit.conf ]; then
    while IFS= read -r _l || [ -n "$_l" ]; do case "$_l" in lang=*) CREW_LANG="${_l#lang=}"; CREW_LANG="${CREW_LANG%$'\r'}" ;; esac; done < .claude/kit.conf
  fi
  case "$CREW_LANG" in tr|en) ;; *)
    _loc="${LC_ALL:-}"; [ -n "$_loc" ] || _loc="${LC_MESSAGES:-}"; [ -n "$_loc" ] || _loc="${LANG:-}"
    case "$_loc" in tr*|TR*) CREW_LANG=tr ;; *) CREW_LANG=en ;; esac ;;
  esac ;;
esac
# The English string is the key; a missing translation prints English and lands in CREW_I18N_MISS (smoke reads it).
_mt(){ local s="$1"; shift
  if [ "$CREW_LANG" = tr ]; then
    case "$s" in
      'fix: ') s='çözüm: ' ;;
      'Git Bash lookup not checked (no cygpath in this shell)') s='Git Bash araması denetlenmedi (bu kabukta cygpath yok)' ;;
      "CLAUDE_CODE_GIT_BASH_PATH (%s) is Git Bash's launcher, not bash — Claude Code ignores it; point it to %s") s="CLAUDE_CODE_GIT_BASH_PATH (%s) Git Bash'in başlatıcısı, bash değil — Claude Code onu yok sayıyor; %s yolunu gösterecek şekilde ayarlayın" ;;
      'CLAUDE_CODE_GIT_BASH_PATH (%s) is not a bash that exists — Claude Code ignores it') s='CLAUDE_CODE_GIT_BASH_PATH (%s) var olan bir bash değil — Claude Code onu yok sayıyor' ;;
      'Claude Code finds Git Bash (%s) — hooks run under bash') s="Claude Code Git Bash'i buluyor (%s) — hook'lar bash altında koşuyor" ;;
      'Claude Code finds Git Bash only through git on PATH (%s) — started without it on PATH, its hooks run under PowerShell and the gates do not run; set CLAUDE_CODE_GIT_BASH_PATH to that path') s="Claude Code Git Bash'i yalnız PATH'teki git üzerinden buluyor (%s) — PATH'te o yokken başlarsa hook'lar PowerShell altında koşar ve kapılar çalışmaz; CLAUDE_CODE_GIT_BASH_PATH'i bu yola ayarlayın" ;;
      'Git Bash is installed for this user only (%s), where Claude Code does not look — its hooks may run under PowerShell and the gates may not run') s="Git Bash yalnız bu kullanıcı için kurulu (%s) ve Claude Code oraya bakmıyor — hook'lar PowerShell altında koşabilir ve kapılar çalışmayabilir" ;;
      'set CLAUDE_CODE_GIT_BASH_PATH to') s="CLAUDE_CODE_GIT_BASH_PATH'i şuna ayarlayın:" ;;
      "Claude Code cannot find Git Bash — its hooks run under PowerShell and Crewforth's gates do not run") s="Claude Code Git Bash'i bulamıyor — hook'lar PowerShell altında koşuyor ve Crewforth'un kapıları çalışmıyor" ;;
      'install Git for Windows in its default folder, or set CLAUDE_CODE_GIT_BASH_PATH to') s="Git for Windows'u varsayılan klasörüne kurun ya da CLAUDE_CODE_GIT_BASH_PATH'i şuna ayarlayın:" ;;
      'then close the terminal and Claude Code and open them again — an open terminal keeps the old value') s="sonra terminali ve Claude Code'u kapatıp yeniden açın — açık bir terminal eski değeri taşır" ;;
      *) [ -n "${CREW_I18N_MISS:-}" ] && printf '%s\n' "$s" >> "$CREW_I18N_MISS" ;;
    esac
  fi
  printf -v _M "$s" "$@"; }
ok(){   _mt "$@"; echo "  ✅ $_M"; }
warn(){ _mt "$@"; echo "  ⚠️  $_M"; [ "$RC" = 0 ] && RC=3; ADVISED=1; }
skip(){ _mt "$@"; echo "  ·  $_M"; RC=4; }
# bad MESSAGE FIX [arguments for MESSAGE]: the fix takes none; what follows it goes in BAD_TAIL, printed once.
bad(){ local _m="$1" _x="$2"; shift 2; _mt "$_m" "$@"; echo "  ❌ $_M"; _mt "fix: "; local _f="$_M"; _mt "$_x"
       echo "     ↳ $_f$_M${BAD_TAIL:-}"; BAD_TAIL=""; RC=1; ADVISED=1; }
# Every warning and failure here ends in "set CLAUDE_CODE_GIT_BASH_PATH" (or install Git). A process keeps the
# environment it started with, so a Claude Code restarted INSIDE the terminal that was open when the variable was
# changed still has the old value: in the field the fix was right and the proof came two rounds late. Said once,
# after whatever was advised.
ADVISED=0
reopen(){ [ "$ADVISED" = 1 ] || return 0
  _mt 'then close the terminal and Claude Code and open them again — an open terminal keeps the old value'; echo "     ↳ $_M"; }

case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*)
  if ! command -v cygpath >/dev/null 2>&1; then
    skip "Git Bash lookup not checked (no cygpath in this shell)"
  else
    # Exists the way Claude Code's existsSync means it: MSYS answers `[ -f …/bash ]` true when only bash.exe is
    # there, so a name without .exe must also appear in its folder's listing (case-insensitively, as Windows does).
    _gbx(){ local u d f n; u="$(cygpath -u "$1" 2>/dev/null)" || return 1; [ -n "$u" ] && [ -f "$u" ] || return 1
      case "$u" in *.[Ee][Xx][Ee]) return 0 ;; esac
      d="${u%/*}"; n="$(printf '%s' "${u##*/}" | tr '[:upper:]' '[:lower:]')"
      for f in "$d"/*; do [ "$(printf '%s' "${f##*/}" | tr '[:upper:]' '[:lower:]')" = "$n" ] && return 0; done; return 1; }
    _gbf=""; _gbv="${CLAUDE_CODE_GIT_BASH_PATH:-}"
    if [ -n "$_gbv" ]; then
      _gbn="${_gbv##*[\\/]}"; _gbn="$(printf '%s' "$_gbn" | tr '[:upper:]' '[:lower:]')"
      case "$_gbn" in bash.exe|sh.exe|bash|sh) _gbx "$_gbv" && _gbf="$_gbv" ;; esac
      # The field case (RC-2, c1): the variable named git-bash.exe, Git Bash's LAUNCHER (a window, not a shell), and
      # Claude Code refused it. Its bash sits in bin\ next to it; that path is checked here before it is suggested.
      _gbq=""
      if [ -z "$_gbf" ] && [ "$_gbn" = git-bash.exe ]; then
        _gbq="${_gbv%[\\/]*}"'\bin\bash.exe'; _gbx "$_gbq" || _gbq=""
      fi
      if [ -n "$_gbq" ]; then
        warn "CLAUDE_CODE_GIT_BASH_PATH (%s) is Git Bash's launcher, not bash — Claude Code ignores it; point it to %s" "$_gbv" "$_gbq"
      elif [ -z "$_gbf" ]; then
        warn "CLAUDE_CODE_GIT_BASH_PATH (%s) is not a bash that exists — Claude Code ignores it" "$_gbv"
      fi
    fi
    if [ -z "$_gbf" ]; then
      for _gbc in 'C:\Program Files\Git\bin\bash.exe' 'C:\Program Files (x86)\Git\bin\bash.exe'; do
        _gbx "$_gbc" && { _gbf="$_gbc"; break; }
      done
    fi
    if [ -n "$_gbf" ]; then ok "Claude Code finds Git Bash (%s) — hooks run under bash" "$_gbf"
    else
      # A per-user Git for Windows install lives in %LOCALAPPDATA%\Programs\Git — none of Claude Code's fixed folders.
      # Checked FIRST and counted: such an install usually puts its cmd folder on PATH, so Claude Code's last step
      # may find it, but that hangs on the PATH Claude Code starts with, and the field's per-user install ran its hooks
      # under PowerShell. The path in the advice is the one that exists here, never a guess.
      _gbu=""
      if [ -n "${LOCALAPPDATA:-}" ] && _gbl="$(cygpath -u "$LOCALAPPDATA" 2>/dev/null)" && [ -n "$_gbl" ]; then
        _gbu="$(cygpath -w "$_gbl/Programs/Git/bin/bash.exe" 2>/dev/null)" || _gbu=""
        [ -n "$_gbu" ] && _gbx "$_gbu" || _gbu=""
      fi
      _gbp=""
      [ -n "$_gbu" ] || while IFS= read -r _gbg; do
        [ -n "$_gbg" ] || continue
        _gbw="$(cygpath -w "$_gbg" 2>/dev/null)" || continue
        _gbw="${_gbw%\\*}"; _gbw="${_gbw%\\*}"'\bin\bash.exe'
        _gbx "$_gbw" && { _gbp="$_gbw"; break; }
      done <<GBEOF
$(type -ap git 2>/dev/null)
GBEOF
      if [ -n "$_gbu" ]; then
        BAD_TAIL=" \"$_gbu\""
        bad "Git Bash is installed for this user only (%s), where Claude Code does not look — its hooks may run under PowerShell and the gates may not run" \
            "set CLAUDE_CODE_GIT_BASH_PATH to" "$_gbu"
      elif [ -n "$_gbp" ]; then
        warn "Claude Code finds Git Bash only through git on PATH (%s) — started without it on PATH, its hooks run under PowerShell and the gates do not run; set CLAUDE_CODE_GIT_BASH_PATH to that path" "$_gbp"
      else
        BAD_TAIL=' <Git>\bin\bash.exe'   # a backslash in the key would be a printf escape
        bad "Claude Code cannot find Git Bash — its hooks run under PowerShell and Crewforth's gates do not run" \
            "install Git for Windows in its default folder, or set CLAUDE_CODE_GIT_BASH_PATH to"
      fi
    fi
    reopen
  fi ;;
esac
exit "$RC"
