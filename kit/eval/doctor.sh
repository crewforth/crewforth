#!/usr/bin/env bash
# Install doctor — verify a LIVE kit install in a CONSUMER repo is actually active. This is the counterpart to
# smoke-test.sh: smoke-test checks Crewforth's SOURCE (dev-side, in this repo); doctor checks a real install on a
# user's machine — the things that silently make the gates inert: a hook left non-executable, core.hooksPath not
# set (so the commit trace/secret scan never runs), settings.json missing (so the tool-level gates never fire).
# Zero-dep, bash-only, Git-Bash safe. Run from the project root (or pass the path):  bash .claude/eval/doctor.sh
set -uo pipefail
# The 2.x names of the variables a user can set still work (one helper: eval/lib/crew-env.sh).
_crew_d="${BASH_SOURCE%/*}"; [ "$_crew_d" = "${BASH_SOURCE}" ] && _crew_d=.
[ -f "$_crew_d/lib/crew-env.sh" ] && . "$_crew_d/lib/crew-env.sh"; unset _crew_d
ROOT="${1:-.}"
cd "$ROOT" 2>/dev/null || { echo "doctor: cannot enter '$ROOT'"; exit 2; }

# Nothing here needs input, and everything here spawns subprocesses that INHERIT this script's stdin. A hook
# reads its payload with `cat`, so one invocation without a pipe would sit waiting for a terminal that is never
# going to type — which is exactly what a "ran 120s and produced nothing" report looks like. Detaching stdin once
# makes that class of hang impossible instead of relying on every call site remembering to redirect.
exec </dev/null

FAIL=0
# Every reporter takes a FORMAT and its arguments, and the format is the key of the message table below: a value
# (a path, a count, a setting's name) goes in as an argument, so the sentence around it can be translated whole.
ok(){  _mt "$@"; echo "  ✅ $_M"; }
# bad MESSAGE FIX [arguments for MESSAGE]. The fix is a key of its own and takes no arguments; a fix that ends in
# something untranslatable (a command, a list of names) puts it in BAD_TAIL, which is printed after it once.
bad(){ local _m="$1" _x="$2"; shift 2; _mt "$_m" "$@"; echo "  ❌ $_M"; _mt "fix: "; local _f="$_M"; _mt "$_x"
       echo "     ↳ $_f$_M${BAD_TAIL:-}"; BAD_TAIL=""; FAIL=$((FAIL+1)); }
warn(){ _mt "$@"; echo "  ⚠️  $_M"; }
# `skip` lives up here with the other reporters, not down in the readiness block where it used to be
# defined: the health checks call it too, and a helper defined after its first caller is a silent
# no-op — the line never prints and the run shows `skip: command not found` on stderr, where nobody
# looks. Found by RUNNING doctor against a fixture install; grepping for the call sites said wired.
skip(){ _mt "$@"; echo "  ·  $_M"; }

# ---- CREW-I18N ------------------------------------------------------------------------------------------
# The doctor speaks the language the project was installed in: CREW_LANG when it is set, otherwise the `lang=` that
# start.sh / adopt.sh recorded in .claude/kit.conf, otherwise the locale. Same contract as the installers: the
# English string is the key, a missing translation prints English, and names are never translated — commands,
# paths, file names, settings keys and hook events are identifiers, only the prose around them is.
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
export CREW_LANG   # preflight.sh, which the doctor runs below, reads it and speaks the same language
_mt() {
  # An empty key must still ASSIGN: bash 3.2's `printf -v _M ""` leaves _M holding the previous translation.
  [ -n "${1:-}" ] || { _M=""; return 0; }
  local s="$1"; shift
  if [ "$CREW_LANG" = tr ]; then
    case "$s" in
      '== Crewforth — install doctor ==') s='== Crewforth — kurulum denetimi ==' ;;
      'fix: ') s='çözüm: ' ;;
      "no .claude/ in '%s' — is Crewforth installed here?") s="'%s' içinde .claude/ yok — Crewforth burada kurulu mu?" ;;
      'VERSION present (%s)') s='VERSION var (%s)' ;;
      'VERSION missing') s='VERSION yok' ;;
      "no install trace: VERSION is here but .claude/kit-manifest.txt is not — the last update did not finish, or .claude/ was copied; run: npx crewforth update --here (information only — nothing was changed)") s="kurulum izi yok: VERSION var ama .claude/kit-manifest.txt yok — son güncelleme bitmemiş ya da .claude/ kopyalanmış; çalıştırın: npx crewforth update --here (yalnız bilgi — hiçbir şey değiştirilmedi)" ;;
      'no install trace: components the install manifest lists are not here (%s) — the last update did not finish, or .claude/ was copied; run: npx crewforth update --here (information only — nothing was changed; if you removed a component on purpose, ignore this line)') s='kurulum izi yok: kurulum manifestinin listelediği bileşenler burada yok (%s) — son güncelleme bitmemiş ya da .claude/ kopyalanmış; çalıştırın: npx crewforth update --here (yalnız bilgi — hiçbir şey değiştirilmedi; bir bileşeni bilerek sildiyseniz bu satırı yok sayın)' ;;
      'install trace: the components on disk match the install manifest') s='kurulum izi: diskteki bileşenler kurulum manifestiyle uyuşuyor' ;;
      'reinstall or update Crewforth (npx crewforth update)') s="Crewforth'u yeniden kurun ya da güncelleyin (npx crewforth update)" ;;
      'Crewforth v%s installed, v%s published — update with /crew-update') s='Crewforth v%s kurulu, v%s yayında — /crew-update ile güncelleyin' ;;
      'required git hooks present (pre-commit, commit-msg)') s="gerekli git hook'ları yerinde (pre-commit, commit-msg)" ;;
      'MISSING git hook(s):%s — the commit trace/secret scan is absent') s="EKSİK git hook'u:%s — commit iz ve gizli bilgi taraması yok" ;;
      'reinstall or update Crewforth') s="Crewforth'u yeniden kurun ya da güncelleyin" ;;
      'all hooks are executable') s="tüm hook'lar çalıştırılabilir" ;;
      'not executable:%s') s='çalıştırılabilir değil:%s' ;;
      'guard-bash.sh did NOT block a force-push — the §4.5 gate is neutered/disarmed') s="guard-bash.sh force-push'u ENGELLEMEDİ — §4.5 kapısı etkisiz" ;;
      'restore guard-bash.sh from Crewforth (npx crewforth update)') s="guard-bash.sh'yi Crewforth'tan geri yükleyin (npx crewforth update)" ;;
      'guard-bash.sh blocks a force-push (gate live, not neutered)') s="guard-bash.sh force-push'u engelliyor (kapı canlı, etkisiz değil)" ;;
      'guard-bash.sh enforces the §4.6 review gate (gate live, not neutered)') s='guard-bash.sh §4.6 review kapısını uyguluyor (kapı canlı, etkisiz değil)' ;;
      'guard-bash.sh did NOT enforce §4.6 — a commit can land with no review of its diff') s="guard-bash.sh §4.6'yı UYGULAMADI — diff'i review edilmemiş bir commit geçebilir" ;;
      'restore guard-bash.sh from Crewforth (and check crew-review-agent still writes .claude/review-pass.json)') s="guard-bash.sh'yi Crewforth'tan geri yükleyin (ve crew-review-agent'ın .claude/review-pass.json'u hâlâ yazdığını kontrol edin)" ;;
      'core.hooksPath -> %s (commit-time gates active)') s='core.hooksPath -> %s (commit anındaki kapılar devrede)' ;;
      'core.hooksPath is unset — commit trace/secret/bloat gates are INACTIVE') s='core.hooksPath ayarlı değil — commit iz, gizli bilgi ve şişkinlik kapıları DEVRE DIŞI' ;;
      "core.hooksPath -> %s (not Crewforth's hooks)") s="core.hooksPath -> %s (Crewforth'un hook'ları değil)" ;;
      "core.hooksPath -> %s (Crewforth's hooks run first, then the project's own — commit-time gates active)") s="core.hooksPath -> %s (önce Crewforth'un hook'ları, sonra projenin kendi hook'ları çalışır — commit anındaki kapılar devrede)" ;;
      "core.hooksPath -> %s, but the shim there does not run Crewforth's hook:%s") s="core.hooksPath -> %s, ama oradaki shim Crewforth'un hook'unu çalıştırmıyor:%s" ;;
      'update Crewforth (npx crewforth update), which writes the shim again') s="Crewforth'u güncelleyin (npx crewforth update); güncelleme shim'i yeniden yazar" ;;
      "update Crewforth (npx crewforth update): this project has hooks of its own, and the update runs Crewforth's before them instead of replacing them") s="Crewforth'u güncelleyin (npx crewforth update): bu projenin kendi hook'ları var; güncelleme Crewforth'unkileri onların yerine koymaz, önlerinde çalıştırır" ;;
      "update Crewforth (npx crewforth update): it keeps that chain and runs Crewforth's hooks before it (.claude/git-shim)") s="Crewforth'u güncelleyin (npx crewforth update): o zinciri korur ve Crewforth'un hook'larını önünde çalıştırır (.claude/git-shim)" ;;
      "trace-blocklist.txt: the placeholder %s is active as it shipped — §4.2 looks for those characters and for no template name; write the template's name in its place, or put the # back") s="trace-blocklist.txt: %s yer tutucusu gönderildiği hâliyle etkin — §4.2 o karakterleri arıyor, bir şablon adını değil; yerine şablonun adını yazın ya da başına # koyun" ;;
      "§4.2 names no vendor template: .claude/hooks/trace-blocklist.txt holds only its placeholder, so that rule looks for nothing — if this project came from a template, write its name there") s="§4.2 hiçbir üçüncü taraf şablon adı içermiyor: .claude/hooks/trace-blocklist.txt'te yalnız yer tutucu var, yani o kural hiçbir şey aramıyor — proje bir şablondan geldiyse adını oraya yazın" ;;
      '§4.2 names %s vendor template pattern(s) in trace-blocklist.txt') s="§4.2, trace-blocklist.txt'te %s üçüncü taraf şablon deseni içeriyor" ;;
      'not a git repo — commit gates need: git init && git config core.hooksPath .claude/hooks') s='git deposu değil — commit kapıları için: git init && git config core.hooksPath .claude/hooks' ;;
      "Crewforth's JSON reader is missing (%s) — settings.json cannot be checked") s="Crewforth'un JSON okuyucusu yok (%s) — settings.json denetlenemiyor" ;;
      'update Crewforth') s="Crewforth'u güncelleyin" ;;
      'settings.json is valid JSON') s='settings.json geçerli JSON' ;;
      'settings.json wires PreToolUse / UserPromptSubmit / Stop (non-empty)') s='settings.json PreToolUse / UserPromptSubmit / Stop olaylarını bağlıyor (boş değil)' ;;
      "settings.json hook events empty or missing:%s — those gates won't fire") s="settings.json'da boş ya da eksik hook olayları:%s — bu kapılar çalışmaz" ;;
      'restore settings.json from Crewforth (npx crewforth update)') s="settings.json'u Crewforth'tan geri yükleyin (npx crewforth update)" ;;
      'SessionStart not wired — session rehydration after /compact or /clear is inactive (update Crewforth)') s="SessionStart bağlı değil — /compact ya da /clear sonrasında oturum toparlanmıyor (Crewforth'u güncelleyin)" ;;
      'SessionStart wired (session rehydration active)') s='SessionStart bağlı (oturum toparlama devrede)' ;;
      'settings.json is invalid JSON') s='settings.json geçersiz JSON' ;;
      'approval by your own message is wired (auto / dontAsk: approve: commit)') s='kendi mesajınızla onay bağlı (auto / dontAsk: onay: commit)' ;;
      "settings.json wires prompt-approval.sh but the script is missing — in auto and dontAsk the message 'approve: commit' records nothing; switch mode with Shift+Tab or commit in your own terminal (update Crewforth)") s="settings.json prompt-approval.sh'i bağlıyor ama betik yok — auto ve dontAsk modunda 'onay: commit' mesajı hiçbir şey kaydetmez; Shift+Tab ile mod değiştirin ya da kendi terminalinizden commit edin (Crewforth'u güncelleyin)" ;;
      "prompt-approval.sh is not wired on UserPromptSubmit — in auto and dontAsk the message 'approve: commit' records nothing; switch mode with Shift+Tab or commit in your own terminal (update Crewforth)") s="prompt-approval.sh UserPromptSubmit'e bağlı değil — auto ve dontAsk modunda 'onay: commit' mesajı hiçbir şey kaydetmez; Shift+Tab ile mod değiştirin ya da kendi terminalinizden commit edin (Crewforth'u güncelleyin)" ;;
      "worktree %s carries Crewforth %s, this one %s — a session there runs that version's gates and approval path (update Crewforth there)") s="%s worktree'sinde Crewforth %s var, burada %s — orada açılan oturum o sürümün kapılarını ve onay yolunu koşar (Crewforth'u orada güncelleyin)" ;;
      "fix the syntax by hand — restoring Crewforth's file would drop any hooks you added") s="sözdizimini elle düzeltin — Crewforth'un dosyasını geri yüklemek eklediğiniz hook'ları siler" ;;
      'settings.json wires hooks through the %s placeholder — on Windows its separators are stripped before bash runs, so NO hook launches and every gate is silently absent') s="settings.json hook'ları %s yer tutucusuyla bağlıyor — Windows'ta ayırıcılar bash çalışmadan silinir, bu yüzden HİÇBİR hook başlamaz ve bütün kapılar sessizce yok olur" ;;
      'update Crewforth (npx crewforth adopt) — hook commands become:') s="Crewforth'u güncelleyin (npx crewforth adopt) — hook komutları şu olur:" ;;
      'hook wiring carries no path placeholder (nothing for Windows to mangle)') s="hook bağlantısında yol yer tutucusu yok (Windows'un bozacağı bir şey yok)" ;;
      'settings.json missing — the tool-level gates (commit approval, guards, context) are INACTIVE') s='settings.json yok — araç düzeyindeki kapılar (commit onayı, korumalar, bağlam) DEVRE DIŞI' ;;
      'reinstall Crewforth') s="Crewforth'u yeniden kurun" ;;
      "Claude Code's default") s="Claude Code'un varsayılanı" ;;
      ' (estimated: only 1M and 200k windows were measured)') s=' (tahmini: yalnız 1M ve 200k pencereler ölçüldü)' ;;
      'skill listing: %s skill(s) use when_to_use or a folded description — a shape the count was not measured on') s='skill listesi: %s skill when_to_use ya da katlanmış açıklama kullanıyor — sayımın ölçülmediği bir biçim' ;;
      'skill listing %s chars for %s skills fits the %s-char budget (fraction %s from %s, %s-token window%s)') s="skill listesi %s karakter, %s skill; %s karakterlik bütçeye sığıyor (kesir %s, kaynak %s; %s token'lık pencere%s)" ;;
      'skill listing %s chars for %s skills EXCEEDS the %s-char budget (fraction %s from %s, %s-token window%s)') s="skill listesi %s karakter, %s skill; %s karakterlik bütçeyi AŞIYOR (kesir %s, kaynak %s; %s token'lık pencere%s)" ;;
      '  — Claude Code drops the descriptions of the least-used skills, and those are less likely to be picked on their own.') s="  — Claude Code en az kullanılan skill'lerin açıklamalarını düşürür; o skill'lerin kendiliğinden seçilmesi zorlaşır." ;;
      '  Fixes: raise %s in settings, or set rarely-used skills to %s in %s.') s="  Çözüm: ayarlarda %s değerini yükseltin ya da nadir kullanılan skill'leri %s olarak %s içine yazın." ;;
      '  Which skills? bash .claude/eval/utilization.sh (Bash tool, not PowerShell) — it reports the ones nothing in this project reached.') s="  Hangileri? bash .claude/eval/utilization.sh (PowerShell değil, Bash aracıyla) — bu projede hiçbir şeyin ulaşmadığı skill'leri listeler." ;;
      "on a 200,000-token model the whole listing would be ~%s chars (Crewforth %s + your personal skills %s + Claude Code's own ~%s, measured) against %s at fraction %s — the least-used skills there lose their descriptions.") s="200 000 token'lık bir modelde listenin tamamı ~%s karakter olur (Crewforth %s + kişisel skill'leriniz %s + Claude Code'un kendi ~%s, ölçüldü); bütçe ise %s karakter (kesir %s). Orada en az kullanılan skill'ler açıklamalarını kaybeder." ;;
      '  If you use such a model, one line in %s/settings.json fixes it: %s') s='  Böyle bir model kullanıyorsanız %s/settings.json dosyasına tek satır yeter: %s' ;;
      '  What it costs: the listing is sent every turn. At 0.04 it stays whole — ~%s chars, about %s tokens,') s="  Bedeli: liste her turda gönderilir. 0.04'te bütün kalır — ~%s karakter, yaklaşık %s token," ;;
      '  %s%% of a 200k window — instead of at most %s chars. (4 characters per token is how Claude Code sizes') s='  200k pencerede %%%s yer tutar — en fazla %s karakter yerine. (Claude Code bu bütçeyi 200k pencerede token başına' ;;
      '  this budget on a 200k window: 0.01 of 200,000 tokens is 8,000 characters.)') s="  4 karakter sayarak hesaplar: 200 000 token'ın 0.01'i 8 000 karakterdir.)" ;;
      "delegation check could not read:%s — not valid JSON (or Crewforth's reader is missing).") s="delegasyon denetimi okuyamadı:%s — geçerli JSON değil (ya da Crewforth'un okuyucusu yok)." ;;
      '  open it and check that Agent/Task is not under permissions.deny. If it is, no subagent can ever run.') s="  dosyayı açıp Agent/Task'ın permissions.deny altında olmadığını kontrol edin. Oradaysa hiçbir alt ajan çalışamaz." ;;
      'the Agent tool is DENIED in:%s — no subagent can ever run, so every agent on disk is dead weight') s='Agent aracı şurada REDDEDİLMİŞ:%s — hiçbir alt ajan çalışamaz, diskteki her ajan ölü yük' ;;
      'remove the Agent/Task entry from permissions.deny, or accept that this project runs main-thread-only') s='Agent/Task girdisini permissions.deny içinden çıkarın ya da bu projenin yalnız ana oturumda çalışacağını kabul edin' ;;
      'delegation is enabled (the Agent tool is not denied)') s='delegasyon açık (Agent aracı reddedilmemiş)' ;;
      'CLAUDE.md (or a doc it references) names auto-delegated agent(s) that no installed agent matches — delegation to them silently fails') s='CLAUDE.md (ya da başvurduğu bir belge) kurulu hiçbir ajanla eşleşmeyen, otomatik devredilen ajan(lar) anıyor — onlara devretmek sessizce başarısız olur' ;;
      'rename each bare reference to its `crew-` id:') s='her çıplak anmayı `crew-` kimliğiyle değiştirin:' ;;
      'CLAUDE.md (or a referenced doc) names pull-only agent(s) by their old bare id — invoked explicitly, so delegation still works; rename for consistency:%s') s='CLAUDE.md (ya da başvurduğu bir belge) yalnız açıkça çağrılan ajan(lar)ı eski çıplak kimliğiyle anıyor — açıkça çağrıldıkları için devretme yine çalışır; tutarlılık için yeniden adlandırın:%s' ;;
      'agent references resolve to installed agents (CLAUDE.md + referenced docs)') s='ajan anmaları kurulu ajanlara çözülüyor (CLAUDE.md ve başvurduğu belgeler)' ;;
      'CLAUDE.md missing — .claude/DISCIPLINE.md is never loaded (routing / DoD / session rules absent)') s='CLAUDE.md yok — .claude/DISCIPLINE.md hiç yüklenmiyor (yönlendirme / DoD / oturum kuralları yok)' ;;
      'create CLAUDE.md with this as its own line: @.claude/DISCIPLINE.md') s="CLAUDE.md'yi oluşturun ve şunu ayrı bir satır olarak yazın: @.claude/DISCIPLINE.md" ;;
      'CLAUDE.md imports .claude/DISCIPLINE.md (the discipline reaches the model)') s="CLAUDE.md .claude/DISCIPLINE.md'yi içe aktarıyor (disiplin modele ulaşıyor)" ;;
      "CLAUDE.md carries the discipline INLINE (pre-1.1 layout) — it loads, but Crewforth updates never reach it; migrate to the '@.claude/DISCIPLINE.md' import line") s="CLAUDE.md disiplini SATIR İÇİNDE taşıyor (1.1 öncesi düzen) — yükleniyor ama Crewforth güncellemeleri ona ulaşmıyor; '@.claude/DISCIPLINE.md' içe aktarma satırına geçin" ;;
      'CLAUDE.md does not import .claude/DISCIPLINE.md — the discipline is on disk but never loaded') s="CLAUDE.md .claude/DISCIPLINE.md'yi içe aktarmıyor — disiplin diskte duruyor ama hiç yüklenmiyor" ;;
      'add this as its own line at the top of CLAUDE.md: @.claude/DISCIPLINE.md') s="CLAUDE.md'nin en üstüne şunu ayrı bir satır olarak ekleyin: @.claude/DISCIPLINE.md" ;;
      ' · panel needs Node 18+ — .claude/studio/ensure-node.sh --plan fetches one') s=' · panel Node 18+ ister — .claude/studio/ensure-node.sh --plan bir tane indirir' ;;
      '%s is set — its 3.0 name is CREW_%s (the old name works until 4.0)') s="%s ayarlı — 3.0'daki adı CREW_%s (eski ad 4.0'a kadar çalışır)" ;;
      '%s is set but no longer read — set CREW_%s instead') s='%s ayarlı ama artık okunmuyor — yerine CREW_%s ayarlayın' ;;
      'DOCTOR: healthy ✅%s') s='DOCTOR: sağlıklı ✅%s' ;;
      'DOCTOR: %s issue(s) ❌ — apply the fixes above%s') s='DOCTOR: %s sorun ❌ — yukarıdaki çözümleri uygulayın%s' ;;
      'shell gates watch both Bash and PowerShell') s="kabuk kapıları hem Bash'i hem PowerShell'i izliyor" ;;
      'shell gates watch only Bash — PowerShell commands bypass every §4.5 rule') s="kabuk kapıları yalnız Bash'i izliyor — PowerShell komutları her §4.5 kuralını atlıyor" ;;
      'shell gates watch only PowerShell — Bash commands bypass every §4.5 rule') s="kabuk kapıları yalnız PowerShell'i izliyor — Bash komutları her §4.5 kuralını atlıyor" ;;
      'guard-bash.sh is not wired in PreToolUse — every shell command bypasses §4.4/§4.5') s="guard-bash.sh PreToolUse'a bağlı değil — her kabuk komutu §4.4/§4.5'i atlıyor" ;;
      'update Crewforth (npx crewforth update), which rewires it') s="Crewforth'u güncelleyin (npx crewforth update); bağlantıyı yeniden kurar" ;;
      'update Crewforth (npx crewforth update), or set the PreToolUse matcher to') s="Crewforth'u güncelleyin (npx crewforth update) ya da PreToolUse matcher'ını şuna ayarlayın:" ;;
      'auto-mode classifier config: built-ins intact, Crewforth rules present (config, not a gate)') s='auto-mode sınıflandırıcı ayarı: yerleşik kurallar sağlam, Crewforth kuralları var (ayar, kapı değil)' ;;
      'auto-mode classifier BUILT-INS DROPPED — an autoMode array lacks %s') s='auto-mode sınıflandırıcının YERLEŞİK KURALLARI DÜŞMÜŞ — bir autoMode dizisinde %s yok' ;;
      'restore it in ~/.claude/settings.json; see .claude/skills/automode-policy/SKILL.md') s='~/.claude/settings.json içinde geri koyun; bkz. .claude/skills/automode-policy/SKILL.md' ;;
      'auto-mode classifier config: Crewforth rules absent (measured not to enforce — see the skill)') s="auto-mode sınıflandırıcı ayarı: Crewforth kuralları yok (uygulanmadıkları ölçüldü — skill'e bakın)" ;;
      'auto-mode classifier config: not checked (no claude CLI, or auto mode unavailable here)') s='auto-mode sınıflandırıcı ayarı: denetlenmedi (claude CLI yok ya da burada auto mode kullanılamıyor)' ;;
      'auto-mode policy check skipped (install predates the automode-policy skill; run the updater)') s="auto-mode politika denetimi atlandı (kurulum automode-policy skill'inden eski; güncelleyiciyi çalıştırın)" ;;
      'gate activity: no gate has fired in this project yet — %s rules wired, recording on') s='kapı etkinliği: bu projede henüz hiçbir kapı tetiklenmedi — %s kural bağlı, kayıt açık' ;;
      'gate activity: %s decision(s) recorded (see /crew-gates)') s='kapı etkinliği: %s karar kaydedildi (bkz. /crew-gates)' ;;
      'gate activity recorded (see /crew-gates)') s='kapı etkinliği kaydediliyor (bkz. /crew-gates)' ;;
      'gate activity NOT MEASURED — nowhere to record (see /crew-gates)') s='kapı etkinliği ÖLÇÜLMEDİ — kaydedilecek yer yok (bkz. /crew-gates)' ;;
      'gate activity unreadable (see /crew-gates)') s='kapı etkinliği okunamadı (bkz. /crew-gates)' ;;
      'Readiness (advisory — does not affect the verdict above):') s='Hazırlık (tavsiye niteliğinde — yukarıdaki kararı etkilemez):' ;;
      'CLAUDE.md project section is still the template (placeholders left in)') s='CLAUDE.md proje bölümü hâlâ şablon (yer tutucular duruyor)' ;;
      'fill in Project / Stack / Project skills — agents read the stack from there') s='Project / Stack / Project skills bölümlerini doldurun — ajanlar yığını oradan okur' ;;
      'CLAUDE.md project section is filled in') s='CLAUDE.md proje bölümü doldurulmuş' ;;
      "%s project-specific skill(s) alongside Crewforth's") s="Crewforth'unkilerin yanında %s projeye özel skill" ;;
      "no project-specific skill — only Crewforth's generic ones are installed") s="projeye özel skill yok — yalnız Crewforth'un genel skill'leri kurulu" ;;
      "put the domain 'how's in .claude/skills/ (format: .claude/AGENT_TEMPLATE.md)") s="alanınıza özgü 'nasıl'ları .claude/skills/ altına koyun (biçim: .claude/AGENT_TEMPLATE.md)" ;;
      'project-skill signal skipped (no .claude/kit-manifest.txt — install predates it; run the updater)') s="proje skill'i sinyali atlandı (.claude/kit-manifest.txt yok — kurulum ondan eski; güncelleyiciyi çalıştırın)" ;;
      'devcontainer present (agentic execution is sandboxed)') s='devcontainer var (ajan komutları yalıtılmış ortamda çalışır)' ;;
      'no .devcontainer/devcontainer.json — agent commands run directly against your machine') s='.devcontainer/devcontainer.json yok — ajan komutları doğrudan makinenizde çalışır' ;;
      'add a devcontainer, or keep approval-mode gates on for anything destructive (§4.5)') s='bir devcontainer ekleyin ya da yıkıcı her şey için onay kapılarını açık tutun (§4.5)' ;;
      'MCP servers configured (project tools/data reach the model)') s='MCP sunucuları ayarlı (projenin araçları ve verisi modele ulaşır)' ;;
      'no MCP server configured — the model has no project-specific tool access') s='MCP sunucusu ayarlı değil — modelin projeye özel araç erişimi yok' ;;
      'add .mcp.json when a tool/data source would help (the mcp-builder skill covers writing one)') s="bir araç ya da veri kaynağı işe yarayacaksa .mcp.json ekleyin (nasıl yazılacağını mcp-builder skill'i anlatır)" ;;
      'CLAUDE.md is current (%s commit(s) of drift since it was last touched)') s="CLAUDE.md güncel (son dokunulduğundan beri %s commit'lik kayma)" ;;
      'CLAUDE.md is stale — %s commits changed the project since it was last touched (limit %s)') s='CLAUDE.md bayat — son dokunulduğundan beri %s commit projeyi değiştirdi (sınır %s)' ;;
      're-read it against the code and update Stack / Project skills (the claude-md-improver flow)') s='kodla karşılaştırarak yeniden okuyun ve Stack / Project skills bölümlerini güncelleyin (claude-md-improver akışı)' ;;
      'freshness signal skipped (cannot read CLAUDE.md mtime on this platform)') s="güncellik sinyali atlandı (bu platformda CLAUDE.md'nin değişme zamanı okunamıyor)" ;;
      '  → readiness %s/%s') s='  → hazırlık %s/%s' ;;
      'npx crewforth adopt') ;;   # identifier, printed as is
      'chmod +x .claude/hooks/*.sh .claude/hooks/pre-commit .claude/hooks/commit-msg') ;;   # identifier, printed as is
      'git config core.hooksPath .claude/hooks') ;;   # identifier, printed as is
      # No row: the line prints in English. CREW_I18N_MISS collects every such key, so smoke catches a missing
      # translation by NAME.
      *) [ -n "${CREW_I18N_MISS:-}" ] && printf '%s\n' "$s" >> "$CREW_I18N_MISS" ;;
    esac
  fi
  # shellcheck disable=SC2059
  printf -v _M "$s" "$@"
}
# ---- /CREW-I18N -----------------------------------------------------------------------------------------
_mt "== Crewforth — install doctor =="; echo "$_M"

# 0) Is Crewforth even here?
[ -d .claude ] || { bad "no .claude/ in '%s' — is Crewforth installed here?" "npx crewforth adopt" "$PWD"; exit 1; }

# 1) VERSION (marks a full install; also what /crew-update compares)
if [ -f .claude/VERSION ]; then ok "VERSION present (%s)" "$(head -1 .claude/VERSION | tr -cd '0-9A-Za-z.-')"
else bad "VERSION missing" "reinstall or update Crewforth (npx crewforth update)"; fi

# 1b) Is that version the current one? Read-only, from the cache session-update-check.sh maintains — doctor makes
#     no network call of its own, so this stays honest offline (no cache -> nothing said) and instant everywhere.
#     The session notice fires once per release; this is the surface that still answers when it was missed.
if [ -f .claude/VERSION ] && [ -f .claude/.state/update-check ]; then
  read -r DLATEST _ < .claude/.state/update-check 2>/dev/null || DLATEST=""
  DLATEST="$(printf '%s' "${DLATEST:-}" | tr -cd '0-9A-Za-z.-')"
  DCUR="$(head -1 .claude/VERSION 2>/dev/null | tr -cd '0-9A-Za-z.-')"
  if [ -n "$DLATEST" ] && awk -v a="$DLATEST" -v b="$DCUR" 'BEGIN{split(a,x,".");split(b,y,".");
       for(i=1;i<=3;i++){if(x[i]+0>y[i]+0)exit 0; if(x[i]+0<y[i]+0)exit 1} exit 1}'; then
    warn "Crewforth v%s installed, v%s published — update with /crew-update" "$DCUR" "$DLATEST"
  fi
fi

# 1c) Install trace. An update leaves VERSION, the install manifest and the components on disk agreeing; when they do
#     not, the last update did not finish or .claude/ came from somewhere else (a copy from another project), and the
#     update's own steps — the legacy sweep, the pattern skill's trust — never ran here. Information only: nothing is
#     changed, the fix is the update. Measured case: a project whose trust record was missing after a 3.0 update.
if [ -f .claude/VERSION ]; then
  if [ ! -f .claude/kit-manifest.txt ]; then
    warn "no install trace: VERSION is here but .claude/kit-manifest.txt is not — the last update did not finish, or .claude/ was copied; run: npx crewforth update --here (information only — nothing was changed)"
  else
    DTMISS=""
    while IFS= read -r e || [ -n "$e" ]; do
      e="${e%$'\r'}"; case "$e" in ''|'#'*) continue ;; esac
      [ -e ".claude/$e" ] || DTMISS="$DTMISS $e"
    done < .claude/kit-manifest.txt
    # Only "listed but absent" is a signal. A crew-* component on disk that the manifest does not list may be the user's
    # own (review: a user's skills/crew-mine read as a broken install), so it is not reported.
    # A component the user deleted on purpose looks exactly like one an interrupted update never wrote: nothing on disk
    # tells the two apart, and recording deletions would be a new file to keep in step. So the line says it instead.
    if [ -n "$DTMISS" ]; then
      warn "no install trace: components the install manifest lists are not here (%s) — the last update did not finish, or .claude/ was copied; run: npx crewforth update --here (information only — nothing was changed; if you removed a component on purpose, ignore this line)" "${DTMISS# }"
    else
      ok "install trace: the components on disk match the install manifest"
    fi
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
              || bad "MISSING git hook(s):%s — the commit trace/secret scan is absent" "reinstall or update Crewforth" "$GONE"
[ -z "$NX" ] && ok "all hooks are executable" \
             || bad "not executable:%s" "chmod +x .claude/hooks/*.sh .claude/hooks/pre-commit .claude/hooks/commit-msg" "$NX"

# 2b) Behaviour probe — a hook that is present + executable can still be NEUTERED (its body replaced with `exit 0`).
#     Drive guard-bash with a command it MUST block; if it does not exit 2, the §4.5 gate is disarmed.
if [ -x .claude/hooks/guard-bash.sh ]; then
  # CREW_GATE_LOG=/dev/null: this probe drives the real gate, so without it every `/crew-doctor` writes a
  # synthetic "git push --force blocked" line into the evidence log — and the gate report would then be
  # counting the diagnostics instead of what the model reached for. A measurement tool that contaminates the
  # thing it measures is worse than none.
  if printf '%s' '{"tool_name":"Bash","permission_mode":"auto","tool_input":{"command":"git push --force"}}' | CREW_GATE_LOG=/dev/null bash .claude/hooks/guard-bash.sh >/dev/null 2>&1; then
    bad "guard-bash.sh did NOT block a force-push — the §4.5 gate is neutered/disarmed" "restore guard-bash.sh from Crewforth (npx crewforth update)"
  else ok "guard-bash.sh blocks a force-push (gate live, not neutered)"; fi

  # 2c) The §4.6 review gate, probed the same way — and probed on the ONE case whose verdict cannot depend on
  #     this project's state. "git commit" alone is no probe: with a matching review-pass.json it legitimately
  #     passes §4.6, and under a mode that cannot prompt §4.4 blocks it anyway, so exit 2 would prove nothing
  #     about §4.6. A commit pointed at another worktree is refused by §4.6 whatever else is true here, and the
  #     verdict is read from the MESSAGE rather than the exit code for the same reason. Mode `default` so that a
  #     disarmed gate answers "ask" and exits 0 instead of colliding with §4.4's fail-closed branch. Nothing
  #     runs: this is a PreToolUse payload, not a command.
  PROBE46="$(printf '%s' '{"tool_name":"Bash","permission_mode":"default","tool_input":{"command":"git -C /nonexistent-crew-probe commit -m probe"}}' \
             | CREW_GATE_LOG=/dev/null bash .claude/hooks/guard-bash.sh 2>&1 >/dev/null)"
  case "$PROBE46" in
    *"4.6"*) ok "guard-bash.sh enforces the §4.6 review gate (gate live, not neutered)" ;;
    *)       bad "guard-bash.sh did NOT enforce §4.6 — a commit can land with no review of its diff" \
                 "restore guard-bash.sh from Crewforth (and check crew-review-agent still writes .claude/review-pass.json)" ;;
  esac
fi

# 2c) §4.2's list. trace-blocklist.txt ships the vendor section with a placeholder, `# <vendor-template-name>`,
#     commented out: until a name stands there §4.2 looks for nothing, and nothing said so (a field note: it stays
#     unfilled). Two states are told apart. The placeholder made ACTIVE as it shipped (the # removed, the text left)
#     is a mistake: the rule then looks for those characters. No active line at all is the ordinary state of a
#     project that came from no template, so it is said once, as information, and is not counted.
_tb=.claude/hooks/trace-blocklist.txt
if [ -f "$_tb" ]; then
  _tbn=0; _tbp=""; _tbon=0
  while IFS= read -r _l || [ -n "$_l" ]; do
    _l="${_l%$'\r'}"
    case "$_l" in
      '# --- '*4.2*) _tbon=1; continue ;;
      '# --- '*)     _tbon=0; continue ;;
    esac
    [ "$_tbon" = 1 ] || continue
    case "$_l" in ''|'#'*) continue ;; esac
    _tbn=$((_tbn+1))
    case "$_l" in '<'*'>') _tbp="$_l" ;; esac
  done < "$_tb"
  if [ -n "$_tbp" ]; then
    warn "trace-blocklist.txt: the placeholder %s is active as it shipped — §4.2 looks for those characters and for no template name; write the template's name in its place, or put the # back" "$_tbp"
  elif [ "$_tbn" = 0 ]; then
    skip "§4.2 names no vendor template: .claude/hooks/trace-blocklist.txt holds only its placeholder, so that rule looks for nothing — if this project came from a template, write its name there"
  else
    ok "§4.2 names %s vendor template pattern(s) in trace-blocklist.txt" "$_tbn"
  fi
fi

# 3) core.hooksPath — without it the §4.1/§4.2 commit trace + secret/bloat scan never runs on a commit.
#    .claude/git-shim is Crewforth's too: it is where the updater points git when the project has a hook chain of
#    its own (husky, .git/hooks), and each shim there runs Crewforth's hook and then the project's. Doctor did not
#    know it: on such a project it answered ❌ "not Crewforth's hooks" and advised `git config core.hooksPath
#    .claude/hooks`, the one command that disconnects the project's own hooks. The advice for a project with a chain
#    of its own is the updater, which keeps the chain.
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  HP="$(git config --get core.hooksPath 2>/dev/null || true)"
  # A hook chain of the project's own that an unset or foreign core.hooksPath would be running today.
  _own=0; { [ -d .husky ] || [ -x .git/hooks/pre-commit ] || [ -x .git/hooks/commit-msg ]; } && _own=1
  case "$HP" in
    */.claude/hooks|.claude/hooks) ok "core.hooksPath -> %s (commit-time gates active)" "$HP" ;;
    */.claude/git-shim|.claude/git-shim)
      _shb=""
      for h in pre-commit commit-msg; do
        { [ -x "$HP/$h" ] && grep -q '\.claude/hooks/' "$HP/$h" 2>/dev/null; } || _shb="$_shb $h"
      done
      if [ -z "$_shb" ]; then ok "core.hooksPath -> %s (Crewforth's hooks run first, then the project's own — commit-time gates active)" "$HP"
      else bad "core.hooksPath -> %s, but the shim there does not run Crewforth's hook:%s" "update Crewforth (npx crewforth update), which writes the shim again" "$HP" "$_shb"; fi ;;
    "") if [ "$_own" = 1 ]; then
          bad "core.hooksPath is unset — commit trace/secret/bloat gates are INACTIVE" "update Crewforth (npx crewforth update): this project has hooks of its own, and the update runs Crewforth's before them instead of replacing them"
        else
          bad "core.hooksPath is unset — commit trace/secret/bloat gates are INACTIVE" "git config core.hooksPath .claude/hooks"
        fi ;;
    *)  bad "core.hooksPath -> %s (not Crewforth's hooks)" "update Crewforth (npx crewforth update): it keeps that chain and runs Crewforth's hooks before it (.claude/git-shim)" "$HP" ;;
  esac
else
  warn "not a git repo — commit gates need: git init && git config core.hooksPath .claude/hooks"
fi

# 4) settings.json wires the tool-level gates, and each event maps to a NON-EMPTY hook array (an empty [] wires
#    nothing). PreToolUse/UserPromptSubmit/Stop are required; SessionStart (rehydration) is a warn if absent.
S=.claude/settings.json
if [ -f "$S" ]; then
  # ONE READER on every machine: Crewforth's own awk JSON reader, the same file adopt.sh merges with. There were two
  # branches here — jq where jq ran, a name-and-bracket shape check where it did not — and the second could not
  # tell valid JSON from invalid at all, so a stock Windows box got a weaker doctor than a Mac. Now both get the
  # parse: validity, then each event's array length.
  SJ=.claude/eval/lib/settings-json.awk
  if [ ! -f "$SJ" ]; then
    bad "Crewforth's JSON reader is missing (%s) — settings.json cannot be checked" "update Crewforth" "$SJ"
  elif awk -v op=validate -f "$SJ" "$S" 2>/dev/null; then
    ok "settings.json is valid JSON"
    EMPTY=""
    for ev in PreToolUse UserPromptSubmit Stop; do
      n="$(awk -v op=len -v path="hooks.$ev" -f "$SJ" "$S" 2>/dev/null)"
      case "$n" in ''|0) EMPTY="$EMPTY $ev" ;; esac
    done
    [ -z "$EMPTY" ] && ok "settings.json wires PreToolUse / UserPromptSubmit / Stop (non-empty)" \
                    || bad "settings.json hook events empty or missing:%s — those gates won't fire" "restore settings.json from Crewforth (npx crewforth update)" "$EMPTY"
    sn="$(awk -v op=len -v path=hooks.SessionStart -f "$SJ" "$S" 2>/dev/null)"
    case "$sn" in ''|0) warn "SessionStart not wired — session rehydration after /compact or /clear is inactive (update Crewforth)" ;; *) ok "SessionStart wired (session rehydration active)" ;; esac
    # In auto and dontAsk the only approval is the user's own message, and ONE hook records it. Where it is not wired
    # the gate stays closed and a message 'approve: commit' records nothing (field report: a worktree on an older
    # Crewforth). A warning, not a failure: commit and push still cannot happen without the user.
    case "$(awk -v op=get -v path=hooks.UserPromptSubmit -f "$SJ" "$S" 2>/dev/null)" in
      *prompt-approval.sh*) if [ -f .claude/hooks/prompt-approval.sh ]; then ok "approval by your own message is wired (auto / dontAsk: approve: commit)"
                            else warn "settings.json wires prompt-approval.sh but the script is missing — in auto and dontAsk the message 'approve: commit' records nothing; switch mode with Shift+Tab or commit in your own terminal (update Crewforth)"; fi ;;
      *) warn "prompt-approval.sh is not wired on UserPromptSubmit — in auto and dontAsk the message 'approve: commit' records nothing; switch mode with Shift+Tab or commit in your own terminal (update Crewforth)" ;;
    esac
  else bad "settings.json is invalid JSON" "fix the syntax by hand — restoring Crewforth's file would drop any hooks you added"; fi
  # `${CLAUDE_PROJECT_DIR}` inside a hook command is the shape that breaks on Windows, and it breaks invisibly.
  # Claude Code substitutes that placeholder into the command STRING before any shell sees it; on Windows the
  # value is `C:\Repos\app` and the separators are gone by the time bash reads it. The reported path was
  # `C:ReposApp/.claude/hooks/...` — every hook failed to launch and every gate was absent, while settings.json
  # looked perfectly correct on inspection. Crewforth now uses a RELATIVE path (hooks run in the project
  # directory), with a `cd` off the bare `$CLAUDE_PROJECT_DIR` as a belt for a session started in a subdirectory.
  # Bare `$VAR` is not the placeholder syntax, so Claude Code leaves it for the shell to expand.
  #
  # Reported on every platform, not only Windows: a repo is shared across machines, and the wiring is wrong on
  # all of them the moment one teammate is on Windows.
  if grep -q '\${CLAUDE_PROJECT_DIR' "$S" 2>/dev/null; then
    BAD_TAIL=' cd "$CLAUDE_PROJECT_DIR" 2>/dev/null; bash .claude/hooks/<name>.sh'
    bad "settings.json wires hooks through the %s placeholder — on Windows its separators are stripped before bash runs, so NO hook launches and every gate is silently absent" \
        "update Crewforth (npx crewforth adopt) — hook commands become:" '${CLAUDE_PROJECT_DIR}'
  else
    ok "hook wiring carries no path placeholder (nothing for Windows to mangle)"
  fi
else
  bad "settings.json missing — the tool-level gates (commit approval, guards, context) are INACTIVE" "reinstall Crewforth"
fi
# 4b) Another worktree of this repository on another Crewforth. A session that moves there runs THAT version's hooks
#     against this one's expectations: its gates, its approval path (3.0 has none for auto mode). `.claude/` is
#     tracked in some projects, so a worktree cut from an older branch carries the older kit.
if [ -f .claude/VERSION ] && git rev-parse --git-dir >/dev/null 2>&1; then
  _wv0="$(head -1 .claude/VERSION 2>/dev/null | tr -cd '0-9A-Za-z.-')"; _wt0="$(git rev-parse --show-toplevel 2>/dev/null)"
  while IFS= read -r _wl; do
    case "$_wl" in "worktree "*) _wp="${_wl#worktree }" ;; *) continue ;; esac
    [ "$_wp" != "$_wt0" ] && [ -f "$_wp/.claude/VERSION" ] || continue
    _wv="$(head -1 "$_wp/.claude/VERSION" 2>/dev/null | tr -cd '0-9A-Za-z.-')"
    [ "$_wv" = "$_wv0" ] || warn "worktree %s carries Crewforth %s, this one %s — a session there runs that version's gates and approval path (update Crewforth there)" "$_wp" "${_wv:-?}" "$_wv0"
  done <<EOF_WT
$(git worktree list --porcelain 2>/dev/null)
EOF_WT
fi

# 4a) Skill listing budget. Claude Code puts a listing of every model-invocable skill's name and description into
#     context each turn and caps it at skillListingBudgetFraction of the context window (default 0.01); over the
#     cap it drops the descriptions of the least-used skills, which stops them matching requests. The count is
#     eval/lib/skill-listing.awk — the method smoke-test.sh gates with, measured against Claude Code's own counter
#     (see that file). The budget is the fraction as Claude Code resolves it (settings.local.json, then
#     settings.json, then the user's settings, then 0.01) times the window's characters, and those were MEASURED
#     from the "Skill listing over budget: … > B budget" debug warning: a 1,000,000-token window gives 3 characters
#     per token of budget (0.001 -> 3000, 0.005 -> 15000), a 200,000-token window 4 (0.001 -> 800, 0.01 -> 8000).
#     Another window is not measured; it is estimated at 3 and said to be an estimate. Reported, never enforced.
if [ -d .claude/skills ]; then
  SLA=.claude/eval/lib/skill-listing.awk
  SKF=""; for f in .claude/skills/*/SKILL.md; do [ -e "$f" ] && SKF=1 && break; done
  if [ -n "$SKF" ] && [ -f "$SLA" ]; then
    read -r LISTING NLISTED UNMEAS <<EOF_SLA
$(LC_ALL=C awk -f "$SLA" .claude/skills/*/SKILL.md)
EOF_SLA
    FRAC=""; _mt "Claude Code's default"; FROM="$_M"
    for sf in .claude/settings.local.json .claude/settings.json "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"; do
      [ -f "$sf" ] || continue
      v="$(awk -v op=get -v path=skillListingBudgetFraction -f "${SJ:-.claude/eval/lib/settings-json.awk}" "$sf" 2>/dev/null)" || v=""
      case "$v" in ''|*[!0-9.]*) ;; *) FRAC="$v"; FROM="$sf"; break ;; esac
    done
    [ -n "$FRAC" ] || FRAC=0.01
    CW="${CONTEXT_WINDOW:-1000000}"
    case "$CW" in 1000000) CPT=3; EST="" ;; 200000) CPT=4; EST="" ;; *) CPT=3; _mt " (estimated: only 1M and 200k windows were measured)"; EST="$_M" ;; esac
    BUDGET=$(awk -v f="$FRAC" -v w="$CW" -v c="$CPT" 'BEGIN { printf "%d", f * w * c }')
    B200=$(awk -v f="$FRAC" 'BEGIN { printf "%d", f * 200000 * 4 }')
    [ "${UNMEAS:-0}" = 0 ] || warn "skill listing: %s skill(s) use when_to_use or a folded description — a shape the count was not measured on" "$UNMEAS"
    if [ "$LISTING" -le "$BUDGET" ]; then
      ok "skill listing %s chars for %s skills fits the %s-char budget (fraction %s from %s, %s-token window%s)" "$LISTING" "$NLISTED" "$BUDGET" "$FRAC" "$FROM" "$CW" "$EST"
    else
      warn "skill listing %s chars for %s skills EXCEEDS the %s-char budget (fraction %s from %s, %s-token window%s)" "$LISTING" "$NLISTED" "$BUDGET" "$FRAC" "$FROM" "$CW" "$EST"
      warn "  — Claude Code drops the descriptions of the least-used skills, and those are less likely to be picked on their own."
      warn "  Fixes: raise %s in settings, or set rarely-used skills to %s in %s." '"skillListingBudgetFraction"' '"name-only"' '"skillOverrides"'
      warn "  Which skills? bash .claude/eval/utilization.sh (Bash tool, not PowerShell) — it reports the ones nothing in this project reached."
    fi
    # The whole listing, not only Crewforth's share: the user's personal skills and Claude Code's own bundled skills
    # sit in the same budget. The bundled ones were measured once (14 skills, 5898 chars, Claude Code v2.1.282, an
    # isolated config) — another version may differ, so the figure is labelled as measured, not read. Skills from
    # other plugins are not counted: the doctor cannot see them.
    PERS=0; PD="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills"
    for f in "$PD"/*/SKILL.md; do [ -e "$f" ] && { PERS=$(LC_ALL=C awk -f "$SLA" "$PD"/*/SKILL.md | cut -d' ' -f1); break; }; done
    BUILTIN=5898; TOTAL=$((LISTING + BUILTIN + 1)); [ "$PERS" -gt 0 ] && TOTAL=$((TOTAL + PERS + 1))   # one joining character per group
    if [ "$TOTAL" -gt "$B200" ]; then
      warn "on a 200,000-token model the whole listing would be ~%s chars (Crewforth %s + your personal skills %s + Claude Code's own ~%s, measured) against %s at fraction %s — the least-used skills there lose their descriptions." "$TOTAL" "$LISTING" "$PERS" "$BUILTIN" "$B200" "$FRAC"
      warn "  If you use such a model, one line in %s/settings.json fixes it: %s" "${CLAUDE_CONFIG_DIR:-~/.claude}" '"skillListingBudgetFraction": 0.04'
      TK=$((TOTAL / 4)); PCT=$(awk -v t="$TK" 'BEGIN { printf "%.1f", t / 2000 }'); [ "$CREW_LANG" = tr ] && PCT="${PCT/./,}"
      warn "  What it costs: the listing is sent every turn. At 0.04 it stays whole — ~%s chars, about %s tokens," "$TOTAL" "$TK"
      warn "  %s%% of a 200k window — instead of at most %s chars. (4 characters per token is how Claude Code sizes" "$PCT" "$B200"
      warn "  this budget on a 200k window: 0.01 of 200,000 tokens is 8,000 characters.)"
    fi
  fi
fi

# 4b) Is delegation itself switched off? The documented way to stop Claude using ANY subagent is to deny the `Agent`
#     tool in permissions.deny. A project that does that keeps twelve agents on disk that can never run, and the only
#     symptom is that every task quietly happens on the main thread — which reads as "Crewforth does nothing" rather
#     than as a setting. Checked at every scope the CLI merges, because one line in ~/.claude/settings.json disables
#     delegation for every project on the machine. Denying it may be deliberate; this names it, it does not judge.
DENYSRC=""
for f in .claude/settings.json .claude/settings.local.json "$HOME/.claude/settings.json"; do
  [ -f "$f" ] || continue
  # A deny entry for the delegation tool, in any of its spellings, with or without an argument pattern. Read
  # with Crewforth's JSON reader, so "is Agent/Task in permissions.deny" is answered from the parse on every OS.
  # It used to need python3: on Windows — a Store stub, or nothing — the check degraded to "both words appear in
  # the file", a prompt instead of a verdict. An unreadable file is still NOT a silent pass (NOPY below).
  if [ ! -f "${SJ:-.claude/eval/lib/settings-json.awk}" ] || ! awk -v op=validate -f "${SJ:-.claude/eval/lib/settings-json.awk}" "$f" 2>/dev/null; then
    NOPY=1; MAYBEDENY="${MAYBEDENY:-} $f"; continue
  fi
  awk -v op=strings -v path=permissions.deny -f "${SJ:-.claude/eval/lib/settings-json.awk}" "$f" 2>/dev/null \
    | grep -qE '^(Agent|Task)([^A-Za-z0-9_]|$)' && DENYSRC="$DENYSRC $f"
done
if [ "${NOPY:-0}" = 1 ]; then
  warn "delegation check could not read:%s — not valid JSON (or Crewforth's reader is missing)." "$MAYBEDENY"
  warn "  open it and check that Agent/Task is not under permissions.deny. If it is, no subagent can ever run."
fi
# `A && B && ok … || bad …` cannot express three outcomes. With no usable python3 the && chain is false, so the
# || arm fired and reported `the Agent tool is DENIED in:` — an empty list, a failure that had not been found,
# and a verdict of ❌ on a healthy install. It stayed invisible while `command -v python3` was the test, because
# on Windows the Store stub answered yes and NOPY was never set. Three states, three branches.
if [ -n "$DENYSRC" ]; then
  bad "the Agent tool is DENIED in:%s — no subagent can ever run, so every agent on disk is dead weight" \
      "remove the Agent/Task entry from permissions.deny, or accept that this project runs main-thread-only" "$DENYSRC"
elif [ "${NOPY:-0}" != 1 ]; then
  ok "delegation is enabled (the Agent tool is not denied)"
fi

# 5) Agent-name references resolve to an installed agent — checked across CLAUDE.md AND every local doc it points to
#    (its @imports and docs/*.md references). A brownfield takeover renames the project's agents to `crew-` ids, but
#    CLAUDE.md — or an orchestration doc it delegates to, e.g. "detail: docs/AGENTS.md" — may still name the OLD bare
#    agent. That name matches no installed agent, so delegation to it silently fails. Following CLAUDE.md's reference
#    chain catches the pointed-to docs too, while unreferenced prose (design/audit docs, code comments) is ignored —
#    so it stays complete without the false positives a blanket repo scan would raise.
if [ -f CLAUDE.md ] && ls .claude/agents/*.md >/dev/null 2>&1; then
  # Two pull-only agents are invoked explicitly (a commit needs approval; session health is emitted by a hook),
  # NOT auto-delegated — so a bare reference to them does not break delegation; it is only a naming inconsistency.
  PULL_AGENTS=" crew-commit-agent crew-session-manager "
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
  CREW_AGENT_BASES="$(awk '
    FNR==1 { files[++nf]=FILENAME }
    !got[FILENAME] && /^name:[[:space:]]*/ {
      n=$0; sub(/^name:[[:space:]]*/,"",n); gsub(/[^a-zA-Z0-9-]/,"",n)       # same charset tr -cd kept
      if (n != "") { nm[FILENAME]=n; got[FILENAME]=1 }
    }
    END {
      for (i=1;i<=nf;i++) {
        f=files[i]; n=(f in nm) ? nm[f] : ""
        if (n=="") { n=f; sub(/\.md$/,"",n); sub(/.*\//,"",n) }              # fallback: the file name
        if (n ~ /^crew-/) { b=n; sub(/^crew-/,"",b); print b "\t" n; print b "-csk\t" n }   # the 2.x name is stale too
      }
    }' .claude/agents/*.md)"
  export CREW_AGENT_BASES
  STALE=""; STALE_PULL=""
  while IFS="$(printf '\t')" read -r base name f lines; do
    [ -n "$base" ] || continue
    entry="
     ↳ \"$base\" → \"$name\"   ($f line(s): $lines)"
    case "$PULL_AGENTS" in *" $name "*) STALE_PULL="$STALE_PULL$entry" ;; *) STALE="$STALE$entry" ;; esac
  done <<EOF
$(awk '
  BEGIN {
    n = split(ENVIRON["CREW_AGENT_BASES"], rows, "\n"); k=0
    for (i=1;i<=n;i++) { if (rows[i]=="") continue; split(rows[i], a, "\t"); k++; base[k]=a[1]; full[k]=a[2] }
    nb=k
  }
  FNR==1 { order[++nf]=FILENAME }
  {
    # bare `base` NOT touching a `-` on either side (so not crew-base, nor base-local) and not glued into a longer word — the identical
    # boundary the grep used. Agent ids are [a-z-] only, so nothing here needs regex escaping.
    for (i=1;i<=nb;i++)
      if ($0 ~ ("(^|[^a-zA-Z0-9_-]|@agent-)" base[i] "([^a-zA-Z0-9_-]|$)"))
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
    BAD_TAIL="$STALE"
    bad "CLAUDE.md (or a doc it references) names auto-delegated agent(s) that no installed agent matches — delegation to them silently fails" \
        'rename each bare reference to its `crew-` id:'
  fi
  [ -n "$STALE_PULL" ] && warn "CLAUDE.md (or a referenced doc) names pull-only agent(s) by their old bare id — invoked explicitly, so delegation still works; rename for consistency:%s" "$STALE_PULL"
  [ -z "$STALE$STALE_PULL" ] && ok "agent references resolve to installed agents (CLAUDE.md + referenced docs)"
fi

# 6) Does the discipline actually REACH the model? `.claude/DISCIPLINE.md` sitting on disk is inert unless
#    `./CLAUDE.md` pulls it in — Claude Code reads CLAUDE.md, not Crewforth's own files. This is the one failure
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
    warn "CLAUDE.md carries the discipline INLINE (pre-1.1 layout) — it loads, but Crewforth updates never reach it; migrate to the '@.claude/DISCIPLINE.md' import line"
  else
    bad "CLAUDE.md does not import .claude/DISCIPLINE.md — the discipline is on disk but never loaded" \
        "add this as its own line at the top of CLAUDE.md: @.claude/DISCIPLINE.md"
  fi
fi

# 8b) The shell matcher. Claude Code's hooks reference is explicit: inspect shell commands with
#     `Bash|PowerShell`, because wherever the PowerShell tool is enabled it IS the shell — and it is on by
#     default for claude.ai and Console accounts on Windows. An install from before 2.5.0 watches only `Bash`,
#     so every PowerShell command walks past the §4.5 rules with nothing firing. Nothing about the session
#     looks wrong, which is why this is a check and not a release note.
#     The matcher read is the one of the PreToolUse entry that runs guard-bash.sh, through the one JSON reader.
#     Any matcher naming PowerShell used to pass — and 3.0.1 wires guard-powershell.sh on a PowerShell-only entry, so
#     an install whose guard-bash watched only Bash read as healthy (measured). A line-by-line read also answered
#     wrong on another key order or on one-line JSON. Placed BEFORE the verdict, so a failure here counts in it.
#     An entry with no matcher applies to every tool.
SJ8="${SJ:-.claude/eval/lib/settings-json.awk}"
if [ -f .claude/settings.json ] && [ -f "$SJ8" ] && awk -v op=validate -f "$SJ8" .claude/settings.json 2>/dev/null; then
  _n8="$(awk -v op=len -v path=hooks.PreToolUse -f "$SJ8" .claude/settings.json 2>/dev/null)" || _n8=0
  _gbm="none"; _i8=0
  while [ "$_i8" -lt "${_n8:-0}" ] 2>/dev/null; do
    case "$(awk -v op=get -v path="hooks.PreToolUse.$_i8.hooks" -f "$SJ8" .claude/settings.json 2>/dev/null)" in
      *guard-bash.sh*) _gbm="$(awk -v op=get -v path="hooks.PreToolUse.$_i8.matcher" -f "$SJ8" .claude/settings.json 2>/dev/null)" || _gbm='"*"'
                       _gbm="${_gbm#\"}"; _gbm="${_gbm%\"}"; break ;;
    esac
    _i8=$((_i8+1))
  done
  case "|$_gbm|" in
    "|none|") BAD_TAIL=''
              bad "guard-bash.sh is not wired in PreToolUse — every shell command bypasses §4.4/§4.5" \
                  "update Crewforth (npx crewforth update), which rewires it" ;;
    "|*|"|"||"|*"|PowerShell|"*) case "|$_gbm|" in *"|Bash|"*|"|*|"|"||") ok "shell gates watch both Bash and PowerShell" ;;
                                   *) BAD_TAIL=' "Bash|PowerShell"'
                                      bad "shell gates watch only PowerShell — Bash commands bypass every §4.5 rule" \
                                          "update Crewforth (npx crewforth update), or set the PreToolUse matcher to" ;; esac ;;
    *"|Bash|"*) BAD_TAIL=' "Bash|PowerShell"'
                bad "shell gates watch only Bash — PowerShell commands bypass every §4.5 rule" \
                    "update Crewforth (npx crewforth update), or set the PreToolUse matcher to" ;;
    *) BAD_TAIL=''
       bad "guard-bash.sh is not wired in PreToolUse — every shell command bypasses §4.4/§4.5" \
           "update Crewforth (npx crewforth update), which rewires it" ;;
  esac
fi
# 8c) Windows: can Claude Code find Git Bash? Without one it runs every hook through PowerShell and no gate runs.
#     The check lives in ONE script, eval/lib/git-bash.sh, which the plugin edition's /crew-doctor runs as well. It
#     prints nothing off Windows, and its exit 1 (not found) counts in this verdict.
_gbs="$(dirname "$0")/lib/git-bash.sh"
if [ -f "$_gbs" ]; then bash "$_gbs"; [ "$?" = 1 ] && FAIL=$((FAIL+1)); fi
echo "---"
# The verdict is the line people read, and some read only it. The preflight block
# below reports a missing node, but it prints AFTER this — so on a machine that
# cannot start the panel the last word a reader takes away was "healthy". The
# verdict is not wrong (every gate is wired and holds without node) so it keeps
# its tick, and carries what it costs beside it.
# Resolved here rather than beside the preflight report below, because the verdict
# needs to ask it a question and the verdict prints first.
PREFLIGHT=".claude/eval/preflight.sh"
[ -f "$PREFLIGHT" ] || PREFLIGHT="$(dirname "$0")/preflight.sh"
PANEL_NOTE=""
if [ -d .claude/studio ] && ! bash "$PREFLIGHT" --has node 2>/dev/null; then
  _mt " · panel needs Node 18+ — .claude/studio/ensure-node.sh --plan fetches one"; PANEL_NOTE="$_M"
fi
# A 2.x variable name still works until 4.0 (lib/crew-env.sh reads it); name its 3.0 spelling so the user can switch.
for _v in $(compgen -e); do
  case "$_v" in CSK_CORRECT_STACK) ;; CSK_*)
    case "${_crew_legacy:-}" in
      *" ${_v#CSK_} "*) warn "%s is set — its 3.0 name is CREW_%s (the old name works until 4.0)" "$_v" "${_v#CSK_}" ;;
      *)                warn "%s is set but no longer read — set CREW_%s instead" "$_v" "${_v#CSK_}" ;;
    esac ;;
  esac
done
if [ "$FAIL" -eq 0 ]; then _mt "DOCTOR: healthy ✅%s" "$PANEL_NOTE"; echo "$_M"
  # Healthy verdict: the star line, once per kit version — the marker is shared with the installers, so the
  # doctor run that /crew-update makes right after an update stays quiet. Text/URL/silence: lib/star.sh.
  [ -f "$(dirname "$0")/lib/star.sh" ] && bash "$(dirname "$0")/lib/star.sh" --once .
else _mt "DOCTOR: %s issue(s) ❌ — apply the fixes above%s" "$FAIL" "$PANEL_NOTE"; echo "$_M"; fi

# 9) The auto-mode classifier. Since 2026-08-14 auto mode is the default permission mode on Pro/Max/Team, so a
#     classifier answers permission prompts the user used to answer. Two things can be wrong and neither shows
#     up in a session. Only ONE of them is a real gate finding: a custom autoMode block that dropped the
#     built-ins by omitting "$defaults" — 66 soft blocks gone, silently. Whether Crewforth's own rules are present
#     is reported but NOT treated as a failure: they were measured on 2026-08-24 not to enforce (see the skill).
if [ -x .claude/skills/automode-policy/scripts/check.sh ] || [ -f .claude/skills/automode-policy/scripts/check.sh ]; then
  AMOUT="$(bash .claude/skills/automode-policy/scripts/check.sh 2>&1)"; AMRC=$?
  case "$AMRC" in
    0) ok "auto-mode classifier config: built-ins intact, Crewforth rules present (config, not a gate)" ;;
    2) bad "auto-mode classifier BUILT-INS DROPPED — an autoMode array lacks %s" \
           "restore it in ~/.claude/settings.json; see .claude/skills/automode-policy/SKILL.md" '"$defaults"' ;;
    3) skip "auto-mode classifier config: Crewforth rules absent (measured not to enforce — see the skill)" ;;
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
#     Read through --json and worded here, so the line speaks the doctor's language (gate-report itself is English
#     and prints its own sentence; quoting it here used to leave half of that sentence dangling on this line).
if [ -f .claude/eval/gate-report.sh ]; then
  GOUT="$(bash .claude/eval/gate-report.sh --json 2>/dev/null)"; GRC=$?
  case "$GRC" in
    0) GRU="${GOUT#*\"rules\":}"; GRU="${GRU%%[,\}]*}"; GDE="${GOUT#*\"decisions\":}"; GDE="${GDE%%[,\}]*}"
       case "$GRU$GDE" in
         *[!0-9]*|'') ok "gate activity recorded (see /crew-gates)" ;;
         *) if [ "$GDE" = 0 ]; then ok "gate activity: no gate has fired in this project yet — %s rules wired, recording on" "$GRU"
            else ok "gate activity: %s decision(s) recorded (see /crew-gates)" "$GDE"; fi ;;
       esac ;;
    3) skip "gate activity NOT MEASURED — nowhere to record (see /crew-gates)" ;;
    *) skip "gate activity unreadable (see /crew-gates)" ;;
  esac
fi
# --- Agentic readiness (ADVISORY) -------------------------------------------------------------------------
# Everything above answers "are Crewforth's gates live?". This answers a different question the gates cannot see:
# "is this PROJECT set up so an agent can actually work well in it?" A flawless install still starves its
# agents when the CLAUDE.md project section is left as the template, there is no sandbox to run in, and no
# project-specific skill carries the domain. These are project maturity, not install health, so they NEVER
# change the exit code — doctor's verdict stays a statement about the install.
echo
# The toolchain the install actually landed on. It runs here as well as in the installers because the machine
# changes after install day — a wiped PATH, a new laptop, a corporate image that removed jq — and Crewforth's
# fallbacks mean none of that announces itself. Advisory: it never changes the verdict above.
# doctor has already cd'd into the project, so the installed copy is the one to run; fall back to the copy
# sitting beside this script for the case where doctor is run straight out of the Crewforth source.
[ -f "$PREFLIGHT" ] && bash "$PREFLIGHT"

_mt "Readiness (advisory — does not affect the verdict above):"; echo "$_M"
RDY=0; RTOT=0
rdy(){ RTOT=$((RTOT+1)); RDY=$((RDY+1)); _mt "$@"; echo "  ✅ $_M"; }
gap(){ local _m="$1" _x="$2"; shift 2; RTOT=$((RTOT+1)); _mt "$_m" "$@"; echo "  ➖ $_M"; _mt "$_x"; echo "     ↳ $_M"; }

# R1) Is the CLAUDE.md project section filled in, or still the shipped template? An unfilled section means every
#     agent works stack-blind — it is the single most common way a correct install still underperforms.
if [ -f CLAUDE.md ]; then
  if grep -qE '<PROJECT NAME>|<One sentence:|<Fill in per the project' CLAUDE.md; then
    gap "CLAUDE.md project section is still the template (placeholders left in)" \
        "fill in Project / Stack / Project skills — agents read the stack from there"
  else rdy "CLAUDE.md project section is filled in"; fi
fi

# R2) A project-specific skill — Crewforth ships the generic 'how's; the domain ones (payment-contract,
#     notification-rules, a backend-pattern skill) are the project's to add. Needs the install manifest to tell
#     kit-shipped from project-owned; without it (pre-1.8 install) the signal is unknowable, so it is skipped
#     rather than guessed — a wrong "you have no project skills" is worse than no line at all.
MAN=.claude/kit-manifest.txt
if [ -f "$MAN" ]; then
  OWN=0
  # The CR strip is the whole reason this reads through `tr` rather than grepping the file directly, and it is
  # not defensive: MEASURED on a CRLF manifest with one project skill installed, this counted TWO. `grep -qxF`
  # wants a whole-line match, `skills/handoff\r` is not `skills/handoff`, so every KIT skill read as
  # project-owned. A Windows checkout with core.autocrlf produces exactly that manifest. `skill-trust.sh`
  # already strips it for the same reason and the same file — this was the copy that did not, which is why the
  # two answers disagreed on the same install.
  MANTXT="$(tr -d '\r' < "$MAN")"
  # A whole-line match by shell pattern, the way skill-trust.sh reads the same file: a `basename` and a `grep`
  # per skill was 82 spawns for the shipped set — the bulk of doctor's cost on Git Bash.
  NL='
'
  for d in .claude/skills/*/; do
    [ -d "$d" ] || continue
    s="${d%/}"; s="${s##*/}"
    case "$NL$MANTXT$NL" in *"${NL}skills/$s$NL"*) ;; *) OWN=$((OWN+1)) ;; esac
  done
  [ "$OWN" -gt 0 ] && rdy "%s project-specific skill(s) alongside Crewforth's" "$OWN" \
                   || gap "no project-specific skill — only Crewforth's generic ones are installed" \
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
#     mcpServers block in Crewforth's settings counts.
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
  MAXC="${CREW_FRESHNESS_MAX:-40}"
  if [ -n "$MT" ]; then
    CH="$(git rev-list --count HEAD --since="@$MT" -- . ':(exclude).claude' 2>/dev/null | tr -cd '0-9')"
    CH="${CH:-0}"
    [ "$CH" -le "$MAXC" ] && rdy "CLAUDE.md is current (%s commit(s) of drift since it was last touched)" "$CH" \
                          || gap "CLAUDE.md is stale — %s commits changed the project since it was last touched (limit %s)" \
                                 "re-read it against the code and update Stack / Project skills (the claude-md-improver flow)" "$CH" "$MAXC"
  else skip "freshness signal skipped (cannot read CLAUDE.md mtime on this platform)"; fi
fi

[ "$RTOT" -gt 0 ] && { _mt "  → readiness %s/%s" "$RDY" "$RTOT"; echo "$_M"; }
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
