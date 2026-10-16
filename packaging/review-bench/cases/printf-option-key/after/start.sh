#!/usr/bin/env bash
# Setup wizard: asks who the install is for, shows a summary and asks for confirmation; then installs the WHOLE
# kit (./.claude + ./CLAUDE.md); finally deletes claude-starter/ and itself.
# Every install is identical — there is no frontend/backend/mobile split. Measured before it was removed: the
# widest profile pruning saved ~400 tokens of listing, while the split cost a per-profile e2e matrix, a second
# prune path in adopt.sh, and shipped a set the plugin channel never matched. Since 3.0 the backend pattern does
# not vary either: the stack is decided per project by the backend-architecture skill and recorded in CLAUDE.md.
# start.sh + claude-starter/ must be in the SAME directory. At the project root:  bash start.sh [flags]
set -euo pipefail
HERE="$(CDPATH= cd "$(dirname "$0")" && pwd)"

# --version (or -v) is answered first, before the source-checkout and payload checks below: it reads only VERSION, so it
# must work wherever start.sh sits, including a directory those checks would refuse.
for a in "$@"; do
  if [ "$a" = "--version" ] || [ "$a" = "-v" ]; then
    if [ -f "$HERE/VERSION" ]; then head -1 "$HERE/VERSION" | tr -d '\r'; else echo unknown; fi
    exit 0
  fi
done

SRC="$HERE/claude-starter"

if [ ! -d "$SRC" ]; then
  echo "ERROR: 'claude-starter/' folder not found."
  echo "start.sh and claude-starter/ must be in the SAME directory (both come together when you unzip)."
  exit 1
fi

# Refuse to run inside a checkout of the kit's own source repository. This script ends by deleting
# claude-starter/ and itself, which is correct when the kit has been unpacked into a project and is being
# consumed — and destroys the source when someone invokes it by absolute path from somewhere else while
# developing the kit. That is not hypothetical: it removed 122 tracked files during this kit's own
# development, recovered only because they were committed.
#
# The kit's developer instructions already said "do not run start.sh in this repo". A rule that only holds
# while someone remembers it is the exact thing this kit exists to replace with a gate, so here is the gate.
# The three markers together appear in the source repo and in no install: an installed kit has .claude/ and
# CLAUDE.md, never packaging/ next to a claude-starter/ it has not yet consumed.
if [ -d "$HERE/packaging" ] && [ -d "$HERE/.git" ] && [ -f "$HERE/VERSION" ]; then
  if [ "${CSK_ALLOW_SOURCE_INSTALL:-0}" = 1 ]; then
    echo "WARNING: CSK_ALLOW_SOURCE_INSTALL=1 — installing from the kit's own source checkout."
    echo "  $SRC and this script will be deleted when the install finishes."
  else
    echo "ERROR: this is the kit's own source repository, not a project to install into."
    echo "  Running here would delete $SRC and this script at the end — that is what the installer does."
    echo "  To try the installer, copy the kit somewhere else first:"
    echo "      cp -R \"$HERE\" /tmp/kit-trial && cd /tmp/kit-trial && bash start.sh"
    echo "  Set CSK_ALLOW_SOURCE_INSTALL=1 if you really mean to consume this checkout."
    exit 1
  fi
fi

# ---- CSK-I18N ------------------------------------------------------------------------------------------
# The installer speaks the user's language; the artefacts it writes do not.
#
# THE ENGLISH STRING IS THE KEY. `m 'Cancelled — nothing changed.'` looks that text up and prints the
# translation, or the text itself when there is none. Three things fall out of that and they are why it is
# written this way rather than with invented keys like `msg.cancelled`:
#   * A missing translation cannot produce a blank line or a bare key — the fallback IS English, structurally.
#   * The English text stays in the source, so a grep for it (the suite has two) keeps matching.
#   * The call site says what it prints. `m msg.cancelled` does not.
# The cost is that editing an English string silently drops its translation and the line reverts to English.
# That is a regression, not a break, and it is catchable: every pattern in the table below must match a
# string that occurs in this file.
#
# RULES FOR THE TABLE, each one paid for:
#   * No colour and no escape codes inside a message. Colour lives in the helpers (h1/sub/add/...), which
#     take an already-translated string. A translator copying an ANSI sequence is a translator breaking it.
#   * Interpolated values go through %s, never concatenation — Turkish word order and suffixes differ.
#   * A literal percent must be written %% because the message IS the printf format. "%100 yerel" would
#     otherwise eat an argument.
#
# NOT TRANSLATED, deliberately: the source-repo refusal above and --version. Both answer before the flags
# are parsed, and language selection cannot run ahead of them without putting a locale lookup in front of a
# gate whose whole job is to refuse. A gate that parses a locale before it can say no is a worse gate.
# The inherited CSK_LANG is captured before the working variable is cleared — otherwise this very line
# would destroy the environment setting it is meant to read.
CSK_LANG_ENV="${CSK_LANG:-}"
CSK_LANG=""
# `_mt` puts the result in _M with printf -v, so a call site pays no subshell: `$(m …)` is a FORK, and on Git
# Bash a fork is ~50 ms. Measured on Windows: the $(m …) form added 22 forks and ~1 s to one install; adopt.sh's
# printf -v twin removed them. `m` stays as a thin wrapper for the rare nested case that needs a value inline.
m() { _mt "$@"; printf '%s' "$_M"; }
_mt() {   # $1 = English text (the key); further args fill %s; result in _M
  # An empty key must still ASSIGN: bash 3.2's `printf -v _M ""` leaves _M holding the previous translation.
  [ -n "${1:-}" ] || { _M=""; return 0; }
  local s="$1"; shift
  if [ "$CSK_LANG" = tr ]; then
    case "$s" in
      "Agentic Working Kit · setup wizard") s='Agentic Working Kit · kurulum' ;;
      "stack-agnostic") s='her yığınla çalışır' ;;
      "[1/2] Who is this install for?") s='[1/2] Kurulumu kim kullanacak?' ;;
      "Decides whether your teammates get the kit's configuration — and what goes into .gitignore.") s="Kit ayarlarının ekiple paylaşılıp paylaşılmayacağını ve .gitignore'a nelerin ekleneceğini belirler." ;;
      "Just me") s='Yalnızca ben' ;;
      "private") s='kişisel' ;;
      "The whole team") s='Tüm ekip' ;;
      "shared") s='paylaşımlı' ;;
      ".claude/ and CLAUDE.md stay out of git — nothing appears in your teammates' checkouts") s=".claude/ ve CLAUDE.md git'e girmez — ekip arkadaşlarınız hiçbir şey görmez" ;;
      ".claude/ and CLAUDE.md are committable — everyone gets the same agents, skills and gates") s=".claude/ ve CLAUDE.md commit'lenebilir — herkes aynı ajanlarla, skill'lerle ve kapılarla çalışır" ;;
      "internal working documents (docs/) stay private in BOTH answers") s='iç çalışma belgeleri (docs/) HER İKİ seçenekte de dışarıda kalır' ;;
      "[2/2] Summary · see what will be installed before you confirm") s='[2/2] Özet · onaylamadan önce neyin kurulacağına bakın' ;;
      "Security gates armed on every install:") s='Her kurulumda devreye giren güvenlik kapıları:' ;;
      "commit/push approval gate — even in auto/bypass mode (guard-bash)") s='commit ve push için onay şartı — auto/bypass modunda bile (guard-bash)' ;;
      "trace scan — a git hook blocks AI traces / vendor names") s="iz taraması — AI izlerini ve sağlayıcı adlarını bir git hook'u yakalar" ;;
      "real context measurement + handoff at 75%% (Stop hook)") s="bağlam doluluğu gerçekten ölçülür, %%75'te devir önerilir (Stop hook)" ;;
      "destructive command guard (rm -rf / force-push, etc.)") s='yıkıcı komut koruması (rm -rf, force-push vb.)' ;;
      "Install with these settings?") s='Bu ayarlarla kurayım mı?' ;;
      "Cancelled — nothing changed.") s='İptal edildi, hiçbir şey değişmedi.' ;;
      "Choice") s='Seçiminiz' ;;
      "empty=1") s='boş=1' ;;
      "(default)") s='(varsayılan)' ;;
      "Scope") s='Kapsam' ;;
      "Included") s='Kurulacaklar' ;;
      "Backend pattern") s='Mimari' ;;
      "stack-agnostic — the stack comes from CLAUDE.md ## Stack or the repo (backend-architecture)") s="yığından bağımsız — yığın CLAUDE.md ## Stack bölümünden ya da depodan okunur (backend-architecture)" ;;
      "The --dotnet flag is ignored: the .NET-specific path was removed in 3.0; installing the stack-agnostic kit.") s="Bayrak yok sayıldı (--dotnet): .NET'e özel kurulum yolu 3.0'da kaldırıldı; yığından bağımsız kit kuruluyor." ;;
      "Will write") s='Yazılacaklar' ;;
      "Install visibility:") s='Kurulum türü:' ;;
      "full kit") s='tam kit' ;;
      "no effect:") s='etkisi yok:' ;;
      "Installing:") s='Kuruluyor:' ;;
      "Tip:  open Claude Code and run /doctor-csk — it checks the install is wired (hooks executable, core.hooksPath set, discipline imported) and scores the project's readiness. CLAUDE.md loads the discipline every session.") s="İpucu:  Claude Code'u açıp /doctor-csk çalıştırın — kurulumun eksiksiz bağlandığını denetler (hook'lar çalıştırılabilir mi, core.hooksPath ayarlı mı, disiplin import edilmiş mi) ve projenin ne kadar hazır olduğunu puanlar. Disiplin, CLAUDE.md sayesinde her oturumda yüklenir." ;;
      "%s agents, %s skills installed.") s="%s ajan ve %s skill kuruldu." ;;
      ".claude/DISCIPLINE.md written — kit-owned; an update overwrites it, so keep your own rules out of it.") s='.claude/DISCIPLINE.md yazıldı. Bu dosya kite ait ve her güncellemede yeniden yazılır; kendi kurallarınızı buraya eklemeyin.' ;;
      "./CLAUDE.md created — EDIT the project section.") s='./CLAUDE.md oluşturuldu — proje bölümünü sizin DOLDURMANIZ gerekiyor.' ;;
      "trace scan: core.hooksPath -> .claude/hooks (§4.1/§4.2 commit gate active)") s='iz taraması: core.hooksPath -> .claude/hooks (§4.1/§4.2 commit kapısı açık)' ;;
      "Done. ./.claude + ./CLAUDE.md ready (full kit); claude-starter/ deleted.") s='Tamamlandı. ./.claude ve ./CLAUDE.md hazır (tam kit); claude-starter/ silindi.' ;;
      "Next: 1) fill in the CLAUDE.md project section  2) open Claude Code at the repo root") s="Sıradaki adımlar: 1) CLAUDE.md'deki proje bölümünü doldurun  2) Claude Code'u deponun kökünde açın" ;;
      "Note: if Claude Code is ALREADY running here, restart it — CLAUDE.md and the discipline load at session start.") s='Not: Claude Code bu klasörde ZATEN açıksa yeniden başlatın — CLAUDE.md ve disiplin oturum açılırken yüklenir.' ;;
      "Panel: /studio-csk opens the Studio panel from this project (or: node .claude/studio/server/index.js --open).") s='Panel: /studio-csk komutu Studio panelini bu projeden açar (alternatif: node .claude/studio/server/index.js --open).' ;;
      "— backend + web + mobile (RN/Expo), every agent and skill") s="— backend, web ve mobil (RN/Expo); tüm ajanlar ve skill'ler" ;;
      "%s agents · %s skills will be installed") s='%s ajan · %s skill' ;;
      "(shared: .claude/ and CLAUDE.md stay committable)") s="(paylaşımlı: .claude/ ve CLAUDE.md commit'lenebilir kalır)" ;;
      "(default — pass --shared to commit .claude/ and CLAUDE.md)") s="(varsayılan — .claude/ ve CLAUDE.md'yi commit'lemek için --shared verin)" ;;
      "no") s='hayır' ;;
      "yes") s='evet' ;;
      "[yes/no]") s='[evet/hayır]' ;;
      "the kit always installs in full (all agents · all skills).") s="kit her zaman eksiksiz kurulur (tüm ajanlar · tüm skill'ler)." ;;
      "2 steps: who it is for -> summary & confirm.") s='2 adım: kim kullanacak -> özet ve onay.' ;;
      "AGENT_TEMPLATE.md missing from the payload — /skill-csk will have nothing to read.") s='AGENT_TEMPLATE.md pakette yok — /skill-csk okuyacak bir şablon bulamayacak.' ;;
      "./CLAUDE.md kept as-is (already imports the discipline) — the refresh landed in DISCIPLINE.md.") s="./CLAUDE.md'ye dokunulmadı (disiplini zaten import ediyor); güncelleme DISCIPLINE.md'ye yazıldı." ;;
      "! ./CLAUDE.md carries the discipline INLINE (pre-1.1 layout) — left untouched.") s='! ./CLAUDE.md disiplini dosyanın İÇİNDE taşıyor (1.1 öncesi düzen) — dokunulmadı.' ;;
      "Discipline updates will NOT reach it. To migrate: delete everything above your") s='Disiplin güncellemeleri bu dosyaya ULAŞMAZ. Geçiş için şu başlığın üstündeki her şeyi silin:' ;;
      "%s heading and leave this single line in its place:") s='%s — sildiğiniz yere de yalnızca şu satırı koyun:' ;;
      "./CLAUDE.md existed — prepended the discipline @import; your content is untouched.") s='./CLAUDE.md zaten vardı — en başa disiplinin @import satırı eklendi, içeriğinize dokunulmadı.' ;;
      "%s eol pin(s) so shared hooks stay LF") s="%s eol kuralı eklendi; paylaşılan hook'lar LF olarak kalır" ;;
      "NOTE: no git repository at this level; after %s run:  %s") s='NOT: bu klasörde git deposu yok. %s yaptıktan sonra şunu çalıştırın:  %s' ;;
      "Panel: needs Node 18+, which is not on this machine — but that is no longer a dead end.") s='Panel: Node 18+ gerekiyor ve bu makinede yok — ama bunun da bir çözümü var.' ;;
      "The kit fetches one for the panel: %s  (asks first;") s='Kit, panel için Node indirebilir: %s  (önce sorar;' ;;
      "verified against the published checksum, into %s, nothing else touched).") s='yayımlanan checksum ile doğrular, yalnızca %s içine kurar, başka hiçbir şeye dokunmaz).' ;;
      "Every gate still holds meanwhile; the panel is the only part that needs node.") s="Bu arada tüm kapılar çalışmaya devam eder; Node'a yalnızca panel ihtiyaç duyar." ;;
      "ERROR: the %s sentinel line is missing from %s — refusing to guess the discipline/project split.") s='HATA: %s işaret satırı %s içinde bulunamadı — disiplinin nerede bitip proje bölümünün nerede başladığı tahmin edilmeyecek.' ;;
      "Unknown parameter: %s") s='Bilinmeyen parametre: %s' ;;
      ".gitignore") ;;   # identifier, printed as is
      # No row: the line prints in English. CSK_I18N_MISS (set by e2e case 18) collects every such key, so a
      # missing translation is caught by NAME rather than guessed from which English words it happens to contain.
      *) [ -n "${CSK_I18N_MISS:-}" ] && printf '%s\n' "$s" >> "$CSK_I18N_MISS" ;;
    esac
  fi
  # shellcheck disable=SC2059
  printf -v _M "$s" "$@"
}
# ---- /CSK-I18N -----------------------------------------------------------------------------------------

usage() {
  # A heredoc cannot go through m() line by line without breaking its layout, so the Turkish help is its own
  # block. Flags and commands are identical in both; only the prose differs.
  if [ "${CSK_LANG:-}" = tr ]; then
    cat <<'USAGE_TR'
Kullanım: bash start.sh [SEÇENEKLER]
Seçenek vermezseniz kurulum sihirbazı her şeyi adım adım sorar.

Backend her zaman yığından bağımsızdır: yığın projeye göre backend-architecture skill'iyle seçilir ve
CLAUDE.md'deki ## Stack bölümüne yazılır.
  --dotnet   3.0'da kaldırıldı; kabul edilir, uyarı basar ve yığından bağımsız kiti kurar
  --generic  kabul edilir, etkisi yok (artık tek kurulum biçimi bu)

Kit her zaman eksiksiz kurulur: tüm ajanlar ve skill'ler — backend, web ve mobil (RN/Expo).
  --backend | --frontend | --mobile | --fullstack   hâlâ kabul edilir ama etkisi yok (eski komutlar bozulmasın diye)
  --private | --shared   kurulum yalnızca sizin mi, yoksa ekiple paylaşılıp commit'lenecek mi? (varsayılan: private)
  --lang tr|en   kurulum dili (verilmezse sihirbaz sorar)
  --yes, -y      tüm sorulara evet de (gözetimsiz kurulum)
  --version, -v  kit sürümünü yazdırıp çık
USAGE_TR
    return
  fi
  cat <<'USAGE'
Usage: bash start.sh [OPTIONS]
If no flag is given, the script asks interactively (wizard).
The backend is always stack-agnostic: the stack is chosen per project by the backend-architecture skill and
recorded in the ## Stack section of CLAUDE.md.
  --dotnet   removed in 3.0; accepted, prints a warning and installs the stack-agnostic kit
  --generic  accepted, no effect (this is the only install shape now)

Every install ships the whole kit: all agents, all skills — backend, web and mobile (RN/Expo) together.
  --backend | --frontend | --mobile | --fullstack   accepted, no effect (kept so older commands still run)
  --private | --shared   is the install yours alone, or committed for the team? (default: private)
  --lang tr|en   installer language (asked interactively when not given)
  --yes, -y     answer every question with yes (unattended install)
  --version, -v  print the kit version and exit
USAGE
}

# Read one answer without hanging an unattended run — and be honest about which hang this closes.
#
# Four stdin shapes, measured (bare `read`, perl alarm as the clock, each shape calibrated first):
#   a terminal with a human ....... blocks until they type        <- correct, must not change
#   a terminal with NOBODY ........ blocks forever                <- the Claude Code pty case
#   a pipe carrying data .......... returns at once
#   a pipe at EOF (</dev/null) .... returns at once, answer ""
#   a pipe open and empty ......... blocks forever                <- closed by the timeout below
#
# The timeout applies ONLY when stdin is not a terminal. On a terminal a human may take as long as they
# like, and cutting them off would be a worse bug than the one being fixed.
#
# WHAT THIS DOES NOT FIX, stated plainly because the opposite was nearly written here: a pty IS a terminal,
# so `[ -t 0 ]` is TRUE for it and this takes the blocking branch. Measured under expect: `[ -t 0 ]` says
# yes and the read blocks with no input. An unattended run under a pty — which is what Claude Code creates —
# is therefore still answered by --yes and by nothing else. That is not a gap in the timeout; stdin carries
# no signal that distinguishes "a terminal nobody is watching" from "a terminal with a slow typist".
#
# 10 seconds rather than 5: the cost of being too short is a declined install, which is visible and
# recoverable, but a producer that legitimately takes a moment to write the answer should still win. The
# value is an integer because bash 3.2 rejects a fractional -t ("invalid timeout specification", measured).
csk_read() {   # $1 = name of the variable to set
  local __v="$1" __a=""
  if [ -t 0 ]; then read -r __a || __a=""
  else read -t 10 -r __a || __a=""
  fi
  eval "$__v=\$__a"
}
ask_yes() {  # $1 = question; returns 0 if the user says 'yes'
  local a
  # --yes ALWAYS wins, and it is answered BEFORE stdin is touched at all. Claude Code runs the installer
  # under a pty, so stdin IS a terminal there and a bare `read` blocks forever on input nobody will type:
  # testing the terminal first would ignore a --yes that was passed precisely to avoid that. adopt.sh:50
  # carries the same rule for the same reason, and this script was the one place that never learned it.
  if [ "${ASSUME_YES:-0}" = 1 ]; then _mt 'yes'; printf '%s %s %s(--yes)%s\n' "$1" "$_M" "$D" "$R"; return 0; fi
  # Deliberately NOT adopt.sh's `[ -t 0 ]` shape. adopt.sh declines outright when stdin is not a terminal;
  # here `printf 'yes\n' | bash start.sh` is the documented CI form (see the note at the confirm prompt) and
  # that shape would silently turn every piped install into a cancellation. A pipe reaching EOF already
  # answers "" => no, so the unattended case stays safe without special-casing it.
  _mt '[yes/no]'; printf '%s %s: ' "$1" "$_M"
  csk_read a
  case "$a" in [yY]|[yY][eE][sS]|[eE]|[eE][vV][eE][tT]) return 0 ;; *) return 1 ;; esac
}
# Append entries to .gitignore. Three callers had three copies of the same two bugs (start.sh's four-entry
# loop, and adopt.sh's review-pass.json line), so it lives here and adopt.sh carries the twin.
#   * A file whose last line has NO trailing newline concatenates the first appended entry onto it —
#     `node_modules` + `.claude/` becomes `node_modules.claude/`, ignoring neither. `touch` does not help:
#     it changes the timestamp, not the last byte. So read the last byte and add the newline ourselves.
#   * `grep -qxF` is an exact-literal test, so a repo that already ignores `.claude` (no trailing slash)
#     gets a second, redundant line. Ask git the real question instead — `git check-ignore` answers about
#     the PATH, whatever spelling the existing rule uses. It is only asked inside a repo; outside one we
#     fall back to the literal test, which is all that is knowable there.
gi_add() {   # $@ = entries to ensure in ./.gitignore; prints nothing, sets GI_WROTE to what it added
  local e
  GI_WROTE=""
  [ -e .gitignore ] || : > .gitignore
  for e in "$@"; do
    if git rev-parse --git-dir >/dev/null 2>&1; then
      git check-ignore -q "$e" 2>/dev/null && continue
    else
      grep -qxF "$e" .gitignore 2>/dev/null && continue
    fi
    # last byte is not a newline (and the file is not empty) -> close the line first
    if [ -s .gitignore ] && [ "$(tail -c 1 .gitignore | od -An -tx1 | tr -d ' \n')" != "0a" ]; then
      printf '\n' >> .gitignore
    fi
    printf '%s\n' "$e" >> .gitignore
    GI_WROTE="$GI_WROTE $e"
  done
  GI_WROTE="${GI_WROTE# }"
}
# Append eol pins to .gitattributes. ONLY in shared mode, and only for what cannot defend itself.
#
# MEASURED, not inferred — the ROADMAP called this an inference. A bare repo, a project that TRACKS .claude/,
# and a second clone with core.autocrlf=true (a git setting, so the mechanism reproduces anywhere):
#   the committed blob                     0 CR
#   the working tree after that checkout   1345 CR in guard-bash.sh · 575 in pre-commit · 49 in commit-msg
# Reproduced on a REAL Windows machine, both installers, all three autocrlf settings, with the pin and without
# it — the numbers above are that run's, not the simulation's.
# WHO THE VICTIM IS, corrected after a real Windows measurement, because the obvious answer is wrong.
# A CRLF hook does NOT die on Git Bash: the 1345-CR copy from an unpinned clone was run against a destructive
# payload through the real invocation and answered exactly like the LF copy — rc=2, same GUARD line. The kit's
# own .gitattributes already records this ("Git Bash happens to tolerate that … but WSL does not"). The death
# shapes below are real but were measured on macOS bash, and macOS never receives CRLF from autocrlf=true in
# the first place, since that is a Windows default:
#   ./hook          -> env: bash\r: No such file or directory
#   bash hook       -> syntax error: unexpected end of file
#   case … in\r     -> syntax error near unexpected token `newline`
#   f(){\r          -> syntax error near unexpected token `{`
# So what the pin protects is a NON-MSYS bash reading that same Windows working tree — WSL is the documented
# case, and it is UNMEASURED by either of us: `wsl.exe` resolves on the Windows desk with no distro installed,
# which is the Store-python3 shape and not evidence. What IS measured is that the pin removes a difference
# nobody should have to reason about: with it the working tree matches the blob on every autocrlf setting.
#
# AND IT PROTECTS AGAINST EXACTLY ONE SETTING. Unpinned, `core.autocrlf=input` and `=false` already come back
# with 0 CR; only `true` corrupts. That one is the Git for Windows default and it arrives from the SYSTEM
# config, not the global one — so the person the pin is for is the person who changed nothing.
#
# WHY ONLY THE SCRIPTS. The data files the hooks read line by line (blocklists, profiles.conf) already strip a
# trailing CR themselves — the kit's own .gitattributes says so, and calls that strip "the real defence" for
# exactly this case, a user's project where nothing pins anything. A shell script cannot do that: it cannot
# strip its own carriage returns before bash parses it. So the pins below are the scripts plus, belt and
# braces, the data types that are cheap to include; they are deliberately NOT a blanket `.claude/**`, which
# would apply text conversion to any binary a skill might carry.
#
# WHY ONLY SHARED MODE. In the private install .claude/ is gitignored, so git never checks it out and there is
# nothing to convert. Writing repo-wide attributes for someone who did not share their config would be editing
# a file they own to fix a problem they do not have.
#
# The two lessons gi_add carries apply here too — a missing trailing newline concatenates the first entry onto
# the last line, and the real question is not "is this text in the file" but "does git already answer lf for
# this path". `git check-attr` is the equivalent of gi_add's `git check-ignore`: it answers about the PATH,
# whatever pattern spelling an existing rule uses, so a project that already pins `* text eol=lf` gets nothing.
GA_LINES='.claude/**/*.sh text eol=lf
.claude/hooks/pre-commit text eol=lf
.claude/hooks/commit-msg text eol=lf
.claude/**/*.txt text eol=lf
.claude/**/*.conf text eol=lf'
ga_add() {   # no args; prints nothing, sets GA_WROTE to the number of lines added
  local line
  GA_WROTE=0
  if git rev-parse --git-dir >/dev/null 2>&1; then
    case "$(git check-attr eol -- .claude/hooks/guard-bash.sh 2>/dev/null)" in
      *": lf") return 0 ;;
    esac
  fi
  [ -e .gitattributes ] || : > .gitattributes
  printf '%s\n' "$GA_LINES" | while IFS= read -r line; do
    [ -n "$line" ] || continue
    if grep -qxF "$line" .gitattributes 2>/dev/null; then continue; fi
    if [ -s .gitattributes ] && [ "$(tail -c 1 .gitattributes | od -An -tx1 | tr -d ' \n')" != "0a" ]; then
      printf '\n' >> .gitattributes
    fi
    printf '%s\n' "$line" >> .gitattributes
  done
  # The loop above runs in a subshell (it is the right-hand side of a pipe), so it cannot report back through a
  # variable — the same trap this kit spent a night on. Count the result from the FILE instead.
  GA_WROTE="$(printf '%s\n' "$GA_LINES" | while IFS= read -r line; do
      [ -n "$line" ] && grep -qxF "$line" .gitattributes 2>/dev/null && echo x
    done | wc -l | tr -d ' ')"
}
# --- CLAUDE.md split (shared contract with adopt.sh) ---
# The payload CLAUDE.md carries the kit discipline, then a one-line sentinel, then the project template.
# The discipline half is installed as .claude/DISCIPLINE.md (kit-owned, overwritten on every update) and
# the project half becomes ./CLAUDE.md (yours, written once). A single @import line joins them.
IMPORT_LINE='@.claude/DISCIPLINE.md'
# The sentinel is matched ANCHORED to the start of the line, so prose that merely mentions the token
# (in this comment, in the docs, in the discipline text itself) can never be mistaken for the split point.
# Abort loudly if it is gone: a silent miss would ship the ENTIRE template as "discipline" — exactly how the
# old '<PROJE ADI>' marker failed once the payload was translated to English.
kit_require_sentinel() { grep -qE '^<!-- KIT:DISCIPLINE-END' "$1" || { printf '%s\n' "$(m 'ERROR: the %s sentinel line is missing from %s — refusing to guess the discipline/project split.' "'<!-- KIT:DISCIPLINE-END'" "$1")"; exit 1; }; }
kit_discipline_of()    { awk '/^<!-- KIT:DISCIPLINE-END/{exit} {print}' "$1"; }
kit_project_of()       { awk 'f{print} /^<!-- KIT:DISCIPLINE-END/{f=1}' "$1"; }
# Anchored: the import must BE the line, not merely be mentioned in prose (the discipline text names the path).
kit_has_import()       { grep -qE '^[[:space:]]*@\.claude/DISCIPLINE\.md[[:space:]]*$' "$1" 2>/dev/null; }
# A pre-1.1 install pasted the whole discipline inline into CLAUDE.md; adding the @import would load it twice.
# Both markers are required: a project that happens to write its own "Four working principles" heading is NOT a
# legacy kit install, and treating it as one would leave it without the discipline forever.
kit_claude_md_is_legacy() {
  grep -q '^## Four working principles' "$1" 2>/dev/null && grep -qE '^### 4\.[45] ' "$1" 2>/dev/null
}
# --- Flag parsing (silent/CI mode) ---
# The profile flags are ACCEPTED and ignored rather than rejected: they appear in older READMEs, CI steps and
# copy-pasted commands, and erroring out there breaks a pipeline over a flag whose absence changes nothing.
# A one-line notice is printed after the colour helpers load, so the user learns the flag no longer selects
# anything instead of quietly getting a different set than the one they typed.
# Language is resolved BEFORE any other flag, because every message below it goes through m(). Four
# sources, first answer wins: --lang, then CSK_LANG, then the locale variables, then English.
#
# English is the default rather than the locale's language on purpose: that is what this installer printed
# before it could speak anything else, and a default that changes under people is not a default. The locale
# branch only ever ADDS Turkish for someone whose environment already says Turkish.
#
# Measured, and recorded here rather than treated as a defect: on stock Windows LANG, LC_ALL and
# LC_MESSAGES are ALL empty (Git Bash defaults only LC_CTYPE). So auto-detect never fires there, and a
# Turkish-speaking Windows user lands on English unless they pass --lang tr or export CSK_LANG.
#
# AN INTERACTIVE INSTALL ASKS. Detection alone was not enough: on macOS the system language can be Turkish
# while the shell exports LANG=C.UTF-8 (measured on a Turkish desk), so the locale said English and the user
# never saw a choice. So when a human is at the terminal and nothing named a language (no --lang, no
# CSK_LANG), the first thing printed is a two-line menu, and the locale only decides which entry is the
# default. It is skipped under --yes and whenever stdin is not a terminal — for the same reason the
# visibility question is: every piped caller feeds a fixed answer sequence, and one more read would shift it.
_lang_flag=""; _lang_take=0; _lang_yes=0
for a in "$@"; do
  # `--lang` with no value must not swallow the next flag: `--lang --yes` is --yes with no language given.
  if [ "$_lang_take" = 1 ]; then _lang_take=0; case "$a" in -*) ;; *) _lang_flag="$a"; continue ;; esac; fi
  case "$a" in
    --lang=*) _lang_flag="${a#--lang=}" ;;
    --lang)   _lang_take=1 ;;
    --yes|-y) _lang_yes=1 ;;
    -h|--help|-v|--version) _lang_yes=1 ;;   # help and version answer at once, not after a language menu
  esac
done
_loc="${LC_ALL:-}"; [ -n "$_loc" ] || _loc="${LC_MESSAGES:-}"; [ -n "$_loc" ] || _loc="${LANG:-}"
case "$_loc" in tr*|TR*) _lang_detected=tr ;; *) _lang_detected=en ;; esac
if [ -n "$_lang_flag" ]; then
  CSK_LANG="$_lang_flag"
elif [ -n "${CSK_LANG_ENV:-}" ]; then
  CSK_LANG="$CSK_LANG_ENV"
elif [ -t 0 ] && [ "$_lang_yes" = 0 ]; then
  if [ "$_lang_detected" = tr ]; then _lang_def=2; else _lang_def=1; fi
  printf '\n  Language / Dil\n    1) English\n    2) Türkçe\n  -> [1-2, empty/boş=%s]: ' "$_lang_def"
  csk_read _lang_ans
  case "${_lang_ans:-$_lang_def}" in
    2|tr|TR|t|T|[tT]ürkçe|[tT]urkce|[tT]urkish) CSK_LANG=tr ;;
    *) CSK_LANG=en ;;
  esac
else
  CSK_LANG="$_lang_detected"
fi
# Anything that is not a language we actually carry falls back to English rather than printing keys.
case "$CSK_LANG" in tr|en) ;; *) CSK_LANG=en ;; esac
# Exported because eval/preflight.sh runs as a child and resolves its own language from the environment: a
# choice made by --lang or the menu above stayed in this shell, and the preflight block printed English.
export CSK_LANG

STACK="generic"; DOTNET_FLAG=0; LEGACY_FLAGS=""; ASSUME_YES=0; VISIBILITY=""
for a in "$@"; do
  case "$a" in
    --lang) ;;                       # value consumed in the language pass above
    --lang=*) ;;
    tr|en) ;;                        # the value of a separated --lang
    --backend|--frontend|--mobile|--fullstack) LEGACY_FLAGS="$LEGACY_FLAGS $a" ;;
    --dotnet) DOTNET_FLAG=1 ;;       # removed in 3.0 — warned below, never an error (old scripts keep running)
    --generic) ;;                    # the only shape now; accepted silently
    --yes|-y) ASSUME_YES=1 ;;
    --private) VISIBILITY="private" ;;
    --shared)  VISIBILITY="shared" ;;
    -h|--help) usage; exit 0 ;;
    *) printf '%s\n' "$(m 'Unknown parameter: %s' "$a")"; echo; usage; exit 1 ;;
  esac
done

# ===================== COLOR / STYLE HELPERS =====================
# Color is emitted ONLY on an interactive TTY + TERM!=dumb + NO_COLOR empty.
# Otherwise all codes are '' => raw \033 does NOT leak in CI/pipe/dumb (NO_COLOR is respected).
if [ -t 1 ] && [ "${TERM:-dumb}" != "dumb" ] && [ -z "${NO_COLOR:-}" ]; then
  R=$'\033[0m'; B=$'\033[1m'; D=$'\033[2m'
  CY=$'\033[36m'; GR=$'\033[32m'; YE=$'\033[33m'; MG=$'\033[35m'
else
  R=''; B=''; D=''; CY=''; GR=''; YE=''; MG=''
fi
# printf's %-Ns pads by BYTES, so a Turkish label (İ, ç, ı are two bytes each) came out short and knocked
# its column out of line. Pad by characters instead: drop the UTF-8 continuation bytes under the C locale
# and count what is left. Builtins only — no fork per row.
padr() {   # $1 = text, $2 = width; sets PADDED
  local LC_ALL=C n
  n="${1//[$'\200'-$'\277']/}"; n=$(( $2 - ${#n} ))
  PADDED="$1"
  while [ "$n" -gt 0 ]; do PADDED="$PADDED "; n=$((n-1)); done
}
# The helpers below take the ENGLISH key and translate it themselves, so no call site needs a $(m …) fork.
h1()   { _mt "$@"; printf '\n%s%s%s%s\n' "$B" "$CY" "$_M" "$R"; }         # section heading
sub()  { _mt "$@"; printf '%s%s%s\n' "$D" "$_M" "$R"; }                   # dim description
opt()  { # $1=no $2=label $3=is_default $4=right-badge
  local mark='' lbl; [ "${3:-0}" = 1 ] && { _mt '(default)'; mark=" ${GR}${B}${_M}${R}"; }
  _mt "${4:-}"; local badge="$_M"; _mt "$2"; lbl="$_M"
  padr "$lbl" 24
  printf '  %s%s%s)%s %s%s%s %s%s%s%s\n' "$B" "$YE" "$1" "$R" "$B" "$PADDED" "$R" "$MG" "$badge" "$R" "$mark"
}
add()  { _mt "$@"; printf '     %s+%s %s\n'      "$GR" "$R" "$_M"; }            # INSTALLED
skip() { _mt "$@"; printf '     %s-%s %s%s%s\n'  "$YE" "$R" "$D" "$_M" "$R"; }  # NOT INSTALLED (tradeoff)
gate() { _mt "$@"; printf '     %s>%s %s\n'      "$CY" "$R" "$_M"; }            # gate to be armed
row()  { _mt "$1"; padr "$_M" 15; printf '  %s%s%s %s\n' "$B" "$PADDED" "$R" "$2"; }   # summary row; $1 = key
rule() { printf '  %s------------------------------------------------%s\n' "$D" "$R"; }

h1  'Agentic Working Kit · setup wizard'
sub '2 steps: who it is for -> summary & confirm.'
if [ -n "$LEGACY_FLAGS" ]; then
  _mt 'no effect:'; _a="$_M"; _mt 'the kit always installs in full (all agents · all skills).'
  printf '\n  %s!%s%s %s%s %s\n' "$YE" "$R" "$B$LEGACY_FLAGS" "$_a" "$R" "$_M"
fi

# --dotnet used to pick a .NET-only install (a pattern skill, a backend agent variant, and a base project
# cloned from the network). 3.0 removed that path: every install is the same stack-agnostic kit, and the
# backend-architecture skill decides the stack per project. The flag stays ACCEPTED so an old script or README
# command keeps working — but it says what it no longer does, rather than silently meaning something else.
if [ "$DOTNET_FLAG" = 1 ]; then
  # The key must not START with '-': _mt ends in `printf -v _M "$s"`, and a format beginning with '--' is read
  # as an option (measured: "printf: --: invalid option", rc=2, nothing installed). The Turkish row too.
  _mt 'The --dotnet flag is ignored: the .NET-specific path was removed in 3.0; installing the stack-agnostic kit.'
  printf '\n  %s!%s %s\n' "$YE" "$R" "$_M"
fi

# ===================== STEP 1 · WHO IS THIS INSTALL FOR =====================
# ONE question about intent, not four about paths. Until now the installer wrote four .gitignore entries
# unconditionally and the summary never mentioned .gitignore at all — so "confirm the install" silently
# edited a TRACKED file, which is a change nobody agreed to. The answer decides two of the four entries;
# the summary below lists the exact lines either way.
#
# Two entries are NOT part of the question, and both are guarantees rather than preferences:
#   * .private-terms.txt is the list of strings that must never be published (internal project names,
#     client names, hosts). Publishing the list defeats its purpose, so it is ignored in both answers.
#   * docs/ holds internal working documents — PLAN.md, SESSION_STATE.md, THREAT_MODEL.md,
#     SECURITY_FINDINGS.md, DISCOVERY.md, EVAL.md. §4.3 promises they stay private and README.md says so
#     too; a team that shares its kit config has not asked to publish its threat model.
#
# ASKED ONLY WHEN SOMEONE IS THERE TO ANSWER. A new prompt consumes a line of stdin, and every existing
# non-interactive caller feeds a FIXED sequence — `printf 'yes\n' | bash start.sh --generic` is the form in
# this repo's own e2e and in user scripts. Adding a read shifts that sequence by one: the visibility question
# ate the 'yes', the confirm prompt hit EOF, and the install silently CANCELLED. Measured: e2e went from
# green to rc=127 because the installed tree never existed. So a non-interactive run keeps today's behaviour
# (private) without reading anything, and --private/--shared are how a script chooses instead.
if [ -z "$VISIBILITY" ] && { [ ! -t 0 ] || [ "$ASSUME_YES" = 1 ]; }; then
  VISIBILITY="private"
  _mt 'Install visibility:'; _a="$_M"; _mt 'private'; _b="$_M"; _mt '(default — pass --shared to commit .claude/ and CLAUDE.md)'
  printf '  %s%s%s %s %s%s%s\n' "$B" "$_a" "$R" "$_b" "$D" "$_M" "$R"
fi
if [ -z "$VISIBILITY" ]; then
  h1  '[1/2] Who is this install for?'
  sub "Decides whether your teammates get the kit's configuration — and what goes into .gitignore."
  echo
  opt 1 'Just me' 1 'private'
  add  ".claude/ and CLAUDE.md stay out of git — nothing appears in your teammates' checkouts"
  echo
  opt 2 'The whole team' 0 'shared'
  add  '.claude/ and CLAUDE.md are committable — everyone gets the same agents, skills and gates'
  skip 'internal working documents (docs/) stay private in BOTH answers'
  echo
  _mt 'Choice'; _a="$_M"; _mt 'empty=1'
  printf '  %s->%s %s %s[1-2, %s]%s: ' "$CY" "$R" "$_a" "$D" "$_M" "$R"
  csk_read s                        # empty => default (private = today's behaviour)
  case "$s" in 2) VISIBILITY="shared" ;; *) VISIBILITY="private" ;; esac
fi
# The exact lines this install will append, resolved once so the summary and the writer cannot disagree.
if [ "$VISIBILITY" = "shared" ]; then
  GI_PLAN='docs/ .private-terms.txt'
else
  GI_PLAN='docs/ .claude/ CLAUDE.md .private-terms.txt'
fi

# ===================== STEP 2 · SUMMARY + CONFIRM =====================
# Count the agents/skills to install LIVE FROM SOURCE (not a hardcoded constant; self-corrects if the payload changes).
count_installed() {   # $1=glob  -> count to install
  local n=0
  for p in $1; do
    [ -e "$p" ] && n=$((n+1))
  done
  printf '%s' "$n"
}
N_AG="$(count_installed "$SRC/agents/*.md")"
N_SK="$(count_installed "$SRC/skills/*/")"

h1 '[2/2] Summary · see what will be installed before you confirm'
echo
_mt 'full kit'; _a="$_M"; _mt '— backend + web + mobile (RN/Expo), every agent and skill'
row 'Scope' "${B}${_a}${D} ${_M}${R}"
_mt '%s agents · %s skills will be installed' "${MG}${B}${N_AG}${R}" "${MG}${B}${N_SK}${R}"
row 'Included'  "$_M"
_mt 'stack-agnostic — the stack comes from CLAUDE.md ## Stack or the repo (backend-architecture)'
row 'Backend pattern' "$_M"
echo
_mt 'Security gates armed on every install:'; printf '  %s%s%s\n' "$B" "$_M" "$R"
gate 'commit/push approval gate — even in auto/bypass mode (guard-bash)'
gate 'trace scan — a git hook blocks AI traces / vendor names'
gate 'real context measurement + handoff at 75%% (Stop hook)'
gate 'destructive command guard (rm -rf / force-push, etc.)'
echo
row 'Will write' "${D}./.claude (agents·skills·commands·hooks·eval·studio·settings.json) + ./CLAUDE.md${R}"
# .gitignore is a TRACKED file in most repos, so appending to it is a change to the project — it belongs in
# the summary, named line by line, not discovered afterwards in `git diff`. Entries this repo already
# ignores are dropped at write time, so what is listed here is the upper bound, not a promise of four lines.
if [ "$VISIBILITY" = "shared" ]; then
  _mt '(shared: .claude/ and CLAUDE.md stay committable)'
  row ".gitignore" "${D}$(printf '%s · ' $GI_PLAN | sed 's/ · $//')  ${YE}${_M}${R}"
else
  _mt 'private'; _a="$_M"
  row ".gitignore" "${D}$(printf '%s · ' $GI_PLAN | sed 's/ · $//')  ${GR}(${_a})${R}"
fi
# What this machine is missing, BEFORE the confirm prompt — not after, when it becomes a symptom pointing
# somewhere else. Report-only and never blocking: the kit degrades rather than breaks, and that is exactly why
# a gap is otherwise invisible. See claude-starter/eval/preflight.sh for the reasoning per tool.
[ -f "$SRC/eval/preflight.sh" ] && bash "$SRC/eval/preflight.sh"
rule
echo
# ask_yes reads from stdin => in CI `printf 'yes\n' | bash start.sh` works; 'no' on EOF (no accidental install).
_mt 'Install with these settings?'
if ! ask_yes "  $_M"; then
  _mt 'Cancelled — nothing changed.'; printf '  %s%s%s\n' "$YE" "$_M" "$R"
  exit 0
fi
echo

# --- Kit installation (./.claude + ./CLAUDE.md) — everything, no prune ---
{ _mt 'Installing:'; echo "== ${_M} ./.claude + ./CLAUDE.md =="; }
mkdir -p .claude/agents .claude/skills .claude/commands .claude/hooks .claude/eval .claude/studio
cp -R "$SRC/agents/."   .claude/agents/
cp -R "$SRC/skills/."   .claude/skills/
cp -R "$SRC/commands/." .claude/commands/
VENDOR_ARMED=0; grep -qxE $'DevArchitecture\r?' .claude/hooks/trace-blocklist.txt 2>/dev/null && VENDOR_ARMED=1   # before the copy resets it; \r? = a CRLF copy still counts
cp -R "$SRC/hooks/."    .claude/hooks/ 2>/dev/null || true
cp -R "$SRC/eval/."     .claude/eval/ 2>/dev/null || true
# The Studio panel — launched by /studio-csk from this project's root. One `cp -R`
# plus one `rm`, not a selective walk: on Git Bash a per-file copy of 25 files is 25
# process spawns at 62-135 ms each. test/ is dropped because its assertions read the
# The panel's own suite is NOT here to delete: it lives in packaging/studio-test/,
# outside the payload, because claude-starter/ ships whole and 104 KB of test code
# would travel through all four channels only to be removed on arrival.
cp -R "$SRC/studio/."   .claude/studio/ 2>/dev/null || true
{ _mt "%s agents, %s skills installed." "$(ls .claude/agents/*.md 2>/dev/null | wc -l | tr -d ' ')" "$(ls -d .claude/skills/*/ 2>/dev/null | wc -l | tr -d ' ')"; echo "  ${_M}"; }
[ -f "$SRC/settings.json" ] && cp "$SRC/settings.json" .claude/settings.json
[ -f "$HERE/VERSION" ] && cp "$HERE/VERSION" .claude/VERSION   # make the kit version trackable in the installed project
# Glob form so every shipped hook/eval is made executable — including ones added later (guard-write.sh,
# session-rehydrate.sh, …). An explicit list silently missed new hooks and left them non-executable.
# studio's gate hook is invoked as `bash <path>` today, so the bit is not load-bearing
# yet; set it anyway, because a future direct exec would fail silently.
chmod +x .claude/hooks/*.sh .claude/hooks/pre-commit .claude/hooks/commit-msg .claude/eval/*.sh .claude/studio/server/hooks/*.sh 2>/dev/null || true

# §4.2: a vendor line that was armed before this run stays armed (the copy above resets it to a comment); nothing
# else arms it. Rationale, and the measured failure of "arm it whenever the pattern skill exists", in adopt.sh.
# The `#test:` line comes with it: smoke-test fails any active pattern that has no case.
if [ "$VENDOR_ARMED" = 1 ] && [ -f .claude/hooks/trace-blocklist.txt ] \
   && grep -qx '# DevArchitecture' .claude/hooks/trace-blocklist.txt; then
  awk '/^# DevArchitecture$/ { print "DevArchitecture"; print "#test: ported the handler from DevArchitecture"; next } { print }' \
    .claude/hooks/trace-blocklist.txt > .claude/hooks/trace-blocklist.txt.kit-tmp \
    && mv .claude/hooks/trace-blocklist.txt.kit-tmp .claude/hooks/trace-blocklist.txt
fi
# `|| true` here used to swallow a missing payload file entirely: the install reported success and
# /skill-csk opened with `Read .claude/AGENT_TEMPLATE.md` against nothing. A best-effort copy is right —
# a missing doc must not abort an otherwise good install — but it has to be AUDIBLE, or the gap is
# invisible until someone runs the command. adopt.sh copies the same file for the same reason.
cp "$SRC/AGENT_TEMPLATE.md" .claude/ 2>/dev/null || { _mt 'AGENT_TEMPLATE.md missing from the payload — /skill-csk will have nothing to read.'; printf '  %s!%s %s\n' "$YE" "$R" "$_M"; }
cp "$SRC/README.md"         .claude/ 2>/dev/null || true

# Install manifest — the names the KIT ships. It is the only way to tell kit-owned from project-owned later:
# the readiness check reads it to find the project's own skills, and the trust gate reads it to spot a skill
# the kit never shipped. Generated from the PAYLOAD, not from disk: a brownfield adopt preserves a pre-existing
# project file under a kit name, and reading disk would then brand that project file "kit-owned". Erring this
# way under-reports project ownership and can never raise a false alarm on a kit file — the safe direction for
# a gate. Rewritten on every install/update, so a component the kit drops stops counting as kit-owned.
# studio/ is deliberately NOT listed. Both consumers walk components: skill-trust.sh iterates skills/*/ and
# agents/*.md, and the doctor readiness check separates kit skills from the project's. A studio/ line would be
# read by nobody, and adopt.sh's stale sweep only considers commands/, agents/ and skills/ entries anyway.
{ for d in "$SRC"/skills/*/;     do [ -d "$d" ] && echo "skills/$(basename "$d")"; done
  for f in "$SRC"/agents/*.md;   do [ -e "$f" ] && echo "agents/$(basename "$f")"; done
  for f in "$SRC"/commands/*.md; do [ -e "$f" ] && echo "commands/$(basename "$f")"; done
} > .claude/kit-manifest.txt 2>/dev/null || true

# stack= is always 'generic' since 3.0. The key is KEPT because an older updater reads it, and a file without it
# would send that updater down its stack-detection branch. No 'profile=' key — adopt.sh treats a leftover one
# from a pre-2.0 install as a migration signal, not as a shape.
{ echo "# Written by start.sh. stack= is always generic since 3.0; the key is kept for older updaters."
  echo "stack=$STACK"
  echo "installer=start.sh"
  echo "version=$( [ -f "$HERE/VERSION" ] && head -1 "$HERE/VERSION" || echo unknown )"
} > .claude/kit.conf

# Discipline (kit-owned, refreshed on every update) vs project section (yours, written once), joined by @import.
kit_require_sentinel "$SRC/CLAUDE.md"
kit_discipline_of "$SRC/CLAUDE.md" > .claude/DISCIPLINE.md
{ _mt '.claude/DISCIPLINE.md written — kit-owned; an update overwrites it, so keep your own rules out of it.'; echo "  ${_M}"; }
if [ ! -f ./CLAUDE.md ]; then
  { printf '<!-- kit discipline · on conflict the project rules BELOW win -->\n%s\n' "$IMPORT_LINE"
    kit_project_of "$SRC/CLAUDE.md"; } > ./CLAUDE.md
  { _mt './CLAUDE.md created — EDIT the project section.'; echo "  ${_M}"; }
elif kit_has_import ./CLAUDE.md; then
  { _mt './CLAUDE.md kept as-is (already imports the discipline) — the refresh landed in DISCIPLINE.md.'; echo "  ${_M}"; }
elif kit_claude_md_is_legacy ./CLAUDE.md; then
  { _mt '! ./CLAUDE.md carries the discipline INLINE (pre-1.1 layout) — left untouched.'; echo "  ${_M}"; }
  { _mt 'Discipline updates will NOT reach it. To migrate: delete everything above your'; echo "    ${_M}"; }
  { _mt '%s heading and leave this single line in its place:' "'# CLAUDE.md — <project>'"; echo "    ${_M}"; }
  echo "        $IMPORT_LINE"
else
  { printf '<!-- kit discipline · on conflict the project rules BELOW win -->\n%s\n\n' "$IMPORT_LINE"; cat ./CLAUDE.md; } > ./CLAUDE.md.kit-tmp \
    && mv ./CLAUDE.md.kit-tmp ./CLAUDE.md
  { _mt './CLAUDE.md existed — prepended the discipline @import; your content is untouched.'; echo "  ${_M}"; }
fi
# The entries were decided in step 2 and printed in the summary; gi_add drops the ones this repo already
# ignores and fixes a missing trailing newline before appending. Word-split on purpose: GI_PLAN is a
# space-separated list this script built, not user input.
# shellcheck disable=SC2086
gi_add $GI_PLAN
[ -n "$GI_WROTE" ] && printf '  %s+%s .gitignore: %s\n' "$GR" "$R" "$GI_WROTE"
# Pinned only when git will actually CHECK .claude/ OUT — and that question goes to git, not to the mode
# variable, for the same reason gi_add asks `git check-ignore` instead of grepping the file: the variable is
# what we intended, the answer is what is true. They agree in the normal case (a private install has just
# added `.claude/` to .gitignore) and they differ in the ones that matter — a repo that already ignored
# `.claude/` before this install, or a shared install inside a repo whose parent rules ignore it anyway.
# Where git will never check the directory out there is no conversion to prevent, and writing repo-wide
# attributes for that project would be editing a file its owner did not need touched.
if ! git check-ignore -q .claude 2>/dev/null; then
  ga_add
  [ "${GA_WROTE:-0}" != 0 ] && { _mt '%s eol pin(s) so shared hooks stay LF' "$GA_WROTE"; printf '  %s+%s .gitattributes: %s\n' "$GR" "$R" "$_M"; }
fi
# `[ -d .git ]` is a proxy for the answer, and it lies exactly where it matters: in a worktree or a submodule
# `.git` is a FILE, so the commit gate was never armed there and the installer said nothing was wrong. adopt.sh
# already names this (red-team hole #6) and start.sh was never taught it. Measured: in a worktree the installer
# printed "no git repository", core.hooksPath stayed empty, and a commit carrying a forbidden expression landed;
# arming by hand and retrying, the trace scanner rejected it. start.sh deletes itself afterwards, so there is no
# second chance from the installer.
#
# Anchored on the TOPLEVEL, not merely on being inside a work tree: a relative core.hooksPath resolves against
# the work-tree root, so arming from a subdirectory stores the value and runs no hook at all — a gate reported
# active over a dead path. `pwd -P` because git answers with the physical path, and the arming call itself is
# the probe, so a git that resolves and fails falls into the NOTE instead of a false "active".
# Asked as `--show-prefix`, not by comparing two spellings of the same path. Comparing them is what the line
# above this one used to do, and on Windows the two sides NEVER match: git answers `C:/repo/app` while
# `pwd -P` answers `/c/repo/app`, so the arming call was never reached — in a worktree AND in an ordinary
# repository. Measured on a Windows 11 desktop against this commit: `core.hooksPath` came back EMPTY in both,
# the installer exited 0, and it printed "no git repository at this level" standing inside one. That is the
# §4.1/§4.2 commit gate silently absent on every Windows install, reported as a successful one.
# `--show-prefix` is the question itself: empty at the work-tree root, `sub/dir/` below it, non-zero exit
# outside a repo — and it carries no path spelling to disagree about. Verified here at a normal root, a
# worktree root, a subdirectory and a non-repo.
if PFX="$(git rev-parse --show-prefix 2>/dev/null)" && [ -z "$PFX" ] && git config core.hooksPath .claude/hooks 2>/dev/null; then
  { _mt 'trace scan: core.hooksPath -> .claude/hooks (§4.1/§4.2 commit gate active)'; echo "  ${_M}"; }
else
  { _mt 'NOTE: no git repository at this level; after %s run:  %s' "'git init'" 'git config core.hooksPath .claude/hooks'; echo "  ${_M}"; }
fi
rm -rf "$SRC"
echo
{ _mt 'Done. ./.claude + ./CLAUDE.md ready (full kit); claude-starter/ deleted.'; echo "== ${_M} =="; }
{ _mt 'Next: 1) fill in the CLAUDE.md project section  2) open Claude Code at the repo root'; echo "${_M}"; }
{ _mt 'Note: if Claude Code is ALREADY running here, restart it — CLAUDE.md and the discipline load at session start.'; echo "${_M}"; }
{ _mt "Tip:  open Claude Code and run /doctor-csk — it checks the install is wired (hooks executable, core.hooksPath set, discipline imported) and scores the project's readiness. CLAUDE.md loads the discipline every session."; echo "${_M}"; }
# Say what is true of THIS machine, not what is true in general. The line used to
# print identically with or without node, so on a machine that cannot start the
# panel it read as a footnote rather than as the reason nothing will happen. The
# question goes to preflight so the version floor stays defined in one place, and
# it is asked of the INSTALLED copy: $SRC is deleted at line 397, a few lines
# above this, so asking there answered "no node" on every machine.
if bash .claude/eval/preflight.sh --has node 2>/dev/null; then
  { _mt 'Panel: /studio-csk opens the Studio panel from this project (or: node .claude/studio/server/index.js --open).'; echo "${_M}"; }
else
  { _mt 'Panel: needs Node 18+, which is not on this machine — but that is no longer a dead end.'; echo "${_M}"; }
  { _mt 'The kit fetches one for the panel: %s  (asks first;' 'bash .claude/studio/ensure-node.sh --plan'; echo "       ${_M}"; }
  { _mt 'verified against the published checksum, into %s, nothing else touched).' '~/.claude/studio-runtime'; echo "       ${_M}"; }
  { _mt 'Every gate still holds meanwhile; the panel is the only part that needs node.'; echo "       ${_M}"; }
fi
rm -f -- "$0"
