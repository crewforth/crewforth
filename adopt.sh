#!/usr/bin/env bash
# kit adopt — hands the kit OVER (handover) to an EXISTING project, brownfield-safe.
# Later becomes the `kit adopt` subcommand. Handover philosophy: don't break the project · don't lose decisions made ·
# don't leave the kit passive (100% hybrid). Kit agents are namespaced with crew- -> no clash with project agents.
#
# >>> STAGE 1: detection + smart suggestion only. CHANGES NOTHING (read-only). <<<
# Later stages: open git branch -> mutation (settings merge · DISCIPLINE.md · coexist) -> install proof
# -> HANDOVER.md / ADR. The SUGGESTION produced here for each decision is applied in the next stage via review/override.
#
# Usage: at the target project root (same directory as kit/):  bash adopt.sh
set -uo pipefail
# The 2.x names of the variables a user can set still work (one helper: eval/lib/crew-env.sh).
_crew_d="${BASH_SOURCE%/*}"; [ "$_crew_d" = "${BASH_SOURCE}" ] && _crew_d=.
[ -f "$_crew_d/kit/eval/lib/crew-env.sh" ] && . "$_crew_d/kit/eval/lib/crew-env.sh"; unset _crew_d
HERE="$(CDPATH= cd "$(dirname "$0")" && pwd)"

# --version (or -v) is answered first, before the payload check below: it reads only VERSION, so it works
# wherever adopt.sh sits. `npx … adopt --version` and `update --version` reach it through bin/cli.js.
for _a in "$@"; do
  if [ "$_a" = "--version" ] || [ "$_a" = "-v" ]; then
    if [ -f "$HERE/VERSION" ]; then head -1 "$HERE/VERSION" | tr -d '\r'; else echo unknown; fi
    exit 0
  fi
done

SRC="$HERE/kit"
[ -d "$SRC" ] || { echo "ERROR: kit/ not found (must be in the same directory as adopt.sh)."; exit 1; }

# --- flags (B5 — where a refresh lands) ---  --here: the current branch · --new-branch: a fresh review branch.
# Left empty, Stage 2 picks a smart default (first adopt -> new; update + untracked .claude -> here; update +
# tracked -> ask). Unknown flags are ignored here (start.sh owns --backend/--frontend/… ; adopt auto-detects shape).
BRANCH_MODE=""; ASSUME_YES=0
_lang_flag=""; _lang_take=0
for _a in "$@"; do
  # `--lang` with no value must not swallow the next flag: `--lang --yes` is --yes with no language given.
  if [ "$_lang_take" = 1 ]; then _lang_take=0; case "$_a" in -*) ;; *) _lang_flag="$_a"; continue ;; esac; fi
  case "$_a" in
  --here)       BRANCH_MODE=here ;;
  --new-branch) BRANCH_MODE=new  ;;
  --yes|-y)     ASSUME_YES=1     ;;   # assume "yes" at every gate — for agent-driven / CI updates (no TTY to prompt)
  --lang=*)     _lang_flag="${_a#--lang=}" ;;
  --lang)       _lang_take=1 ;;
esac; done

# ---- CREW-I18N (the twin of start.sh's; see the long note there for why the English string is the key) ----
# Short version, because the reasoning belongs in one place: `m 'text'` prints the translation of that text
# or the text itself. A missing translation therefore cannot print a blank line or a bare key — the fallback
# IS English. Colour never enters a message (the helpers above add it), interpolation goes through %s, and a
# literal percent must be written %% because the message is the printf format.
#
# Language: --lang, then an inherited CREW_LANG, then — on an interactive run without --yes — a one-line menu,
# then LC_ALL/LC_MESSAGES/LANG, then English. An interactive run ASKS because detection alone never offered
# Turkish where it should have: measured, macOS can run with a Turkish system language while the shell exports
# LANG=C.UTF-8. The locale still picks the menu's default. A piped, CI or --yes run never sees the menu (a
# `read` there would block or eat the caller's input) and keeps plain detection. On stock Windows all three
# locale variables are empty (measured), so a non-interactive Windows run needs the flag — documented
# behaviour, not a defect. English stays the fallback because it is what this script printed before it could
# speak anything else.
_loc="${LC_ALL:-}"; [ -n "$_loc" ] || _loc="${LC_MESSAGES:-}"; [ -n "$_loc" ] || _loc="${LANG:-}"
case "$_loc" in tr*|TR*) _lang_det=tr; _lang_def=2 ;; *) _lang_det=en; _lang_def=1 ;; esac
_LANG_CHOSEN=1                                             # 0 = a locale guess: used, never written down
if [ -n "$_lang_flag" ]; then
  CREW_LANG="$_lang_flag"
elif [ -n "${CREW_LANG:-}" ]; then
  :
elif _lang_rec="$(sed -n 's/^lang=//p' .claude/kit.conf 2>/dev/null | head -1 | tr -d '\r')" && [ -n "$_lang_rec" ]; then
  CREW_LANG="$_lang_rec"   # an update keeps the language the install chose (the session-start prompt speaks it too)
elif [ -t 0 ] && [ "$ASSUME_YES" != 1 ]; then
  printf '\n  Language / Dil\n    1) English\n    2) Türkçe\n  -> [1-2, empty/boş=%s]: ' "$_lang_def"
  read -r _lang_ans || _lang_ans=""
  [ -n "$_lang_ans" ] || _lang_ans="$_lang_def"
  case "$_lang_ans" in 2|tr|TR|t|T) CREW_LANG=tr ;; *) CREW_LANG=en ;; esac
else
  CREW_LANG="$_lang_det"; _LANG_CHOSEN=0
fi
case "$CREW_LANG" in tr|en) ;; *) CREW_LANG=en ;; esac
# Exported: child scripts (eval/preflight.sh) resolve their own language from the environment, and an
# unexported choice from --lang or the menu made them print English.
export CREW_LANG
# _mt sets _M instead of printing, so a call site can translate WITHOUT a `$( )` subshell. Each subshell is a
# fork, and on Git Bash a fork costs 62-135 ms; wrapping ~100 lines in `$(m …)` would have added seconds to
# every update. The helpers below (say/h1m/subm/warnm/rowm/rowv/propm, ask_yes) all go through _mt.
m() { _mt "$@"; printf '%s' "$_M"; }
_mt() {   # $1 = English text (the key); further args fill %s; result in _M
  # An empty key must still ASSIGN: bash 3.2's `printf -v _M ""` leaves _M holding the previous translation.
  [ -n "${1:-}" ] || { _M=""; return 0; }
  local s="$1"; shift
  if [ "$CREW_LANG" = tr ]; then
    case "$s" in
      "crewforth adopt · Stage 1 — DETECTION (read-only; nothing changes)") s='crewforth adopt · Aşama 1 — TESPİT (salt okunur, hiçbir şey değişmez)' ;;
      "Reads the existing project, produces a smart suggestion for the 7 handover decisions. Approval + mutation in the next stage.") s='Projeyi okur ve devralma için 7 karara akıllı bir öneri çıkarır. Onay ve değişiklikler sonraki aşamada.' ;;
      "[1] Environment") s='[1] Ortam' ;;
      "no git — 'git init' required") s="git yok — önce 'git init' gerekli" ;;
      "worktree/submodule (.git file)") s='worktree/submodule (.git bir dosya)' ;;
      "normal repo") s='normal depo' ;;
      "git hook system") s='git hook sistemi' ;;
      "none") s='yok' ;;
      "Crewforth (already armed)") s='Crewforth (zaten devrede)' ;;
      "pre-commit framework") s='pre-commit çatısı' ;;
      "unknown") s='bilinmiyor' ;;
      "stack hint") s='yığın ipucu' ;;
      "[2] Existing agentic setup (accumulated work to inherit)") s='[2] Projedeki agentic kurulum (korunacak birikim)' ;;
      "present — %s project agents · %s project skills") s="var — %s proje ajanı · %s proje skill'i" ;;
      "present") s='var' ;;
      "already adopted%s — this run REFRESHES Crewforth files, project untouched") s='Crewforth zaten kurulu%s — bu çalıştırma yalnız Crewforth dosyalarını YENİLER, projeye dokunmaz' ;;
      "Crewforth status") s='Crewforth durumu' ;;
      "(no kit.conf — read back from the installed files)") s='(kit.conf yok — kurulu dosyalardan çıkarıldı)' ;;
      "inferred pattern") s='çıkarılan desen' ;;
      "recorded pattern") s='kayıtlı desen' ;;
      "3.0 rename: %s → %s") s='3.0 ad değişikliği: %s → %s' ;;
      "3.0 rename: both the old and the new name exist for:%s — nothing moved; keep one") s='3.0 ad değişikliği: eski ve yeni ad ikisi de var:%s — hiçbir şey taşınmadı; birini tutun' ;;
      "3.0 ref-sweep: old 2.x names → crew- names in %s") s='3.0 referans taraması: %s içindeki eski 2.x adları crew- adlarına çevrildi' ;;
      "3.0 ref-sweep: the 2.x template wording in %s now says Crewforth") s="3.0 referans taraması: %s içindeki 2.x şablon ifadeleri artık Crewforth diyor" ;;
      "3.0 commands are skills: %s → %s") s="3.0'da komutlar skill oldu: %s → %s" ;;
      "3.0 commands are skills: a skill of that name already exists for:%s — nothing moved; keep one") s="3.0'da komutlar skill oldu: bu adla bir skill zaten var:%s — hiçbir şey taşınmadı; birini tutun" ;;
      "3.0 commands are skills: an older copy of an already-moved command is left in place:%s — remove it") s="3.0'da komutlar skill oldu: taşınmış bir komutun eski kopyası yerinde bırakıldı:%s — silin" ;;
      "3.0 commands are skills: symlinked command file(s) left as they are:%s — the skill of that name now answers /name") s="3.0'da komutlar skill oldu: symlink olan komut dosyaları olduğu gibi bırakıldı:%s — /ad artık aynı adlı skill'e gider" ;;
      "3.0 commands are skills: .claude/commands is a symlink (shared?) — nothing was moved out of it; the skills of those names now answer /name") s="3.0'da komutlar skill oldu: .claude/commands bir symlink (paylaşılan?) — içinden hiçbir şey taşınmadı; /ad artık aynı adlı skill'lere gider" ;;
      "your own command(s) keep their name — the Crewforth skill of the same name was not installed:%s") s="kendi komutlarınız adını korur — aynı adlı Crewforth skill'i kurulmadı:%s" ;;
      "3.0 board: moved to the crew names in this clone:%s") s='3.0 pano: bu klonda crew adlarına taşındı:%s' ;;
      "3.0 board: the remote's 2.x board ref is not deleted — while it exists, 3.x writes both, so 2.x teammates still see your claims; ask the team to update, then delete the old ref") s="3.0 pano: uzaktaki 2.x pano ref'i silinmedi — o durdukça 3.x ikisine birden yazar, 2.x kullanan ekip arkadaşları sahiplenmelerinizi görmeye devam eder; ekipten de güncellemesini isteyin, sonra eski ref'i silin" ;;
      "3.0 auto-mode: the Crewforth rules in %s are renamed CSK … → Crewforth … (backup: %s)") s='3.0 auto-mode: %s içindeki Crewforth kuralları CSK … → Crewforth … olarak yeniden adlandırıldı (yedek: %s)' ;;
      "%s is set — its 3.0 name is %s (the old name works until 4.0)") s="%s ayarlı — 3.0'daki adı %s (eski ad 4.0'a kadar çalışır)" ;;
      "%s is set but no longer read — set %s instead") s='%s ayarlı ama artık okunmuyor — yerine %s ayarlayın' ;;
      "stack=%s %s") s='stack=%s %s' ;;
      "stack=%s · via %s") s='stack=%s · kuran: %s' ;;
      "stack=dotnet — 3.0 records generic; the pattern skill stays as a project skill") s="stack=dotnet — 3.0 generic kaydeder; desen skill'i proje skill'i olarak kalır" ;;
      '⚠️  cqrs-aop-module could not be recorded as trusted (skill-trust.sh exit %s: %s) — the next session will ask about it') s="⚠️  cqrs-aop-module güvenilir olarak kaydedilemedi (skill-trust.sh çıkış kodu %s: %s) — bir sonraki oturum onu soracak" ;;
      "cqrs-aop-module could not be checked against the copies Crewforth shipped (git or the shipped list is missing) — not vouched for; the next session will ask whether to trust it.") s="cqrs-aop-module, Crewforth'un gönderdiği kopyalarla karşılaştırılamadı (git ya da gönderilen liste yok) — güvenilir sayılmadı; bir sonraki oturum güvenip güvenmeyeceğinizi soracak." ;;
      "cqrs-aop-module is 2.x's .NET pattern, changed since Crewforth shipped it — not vouched for; the next session will ask whether to trust it.") s="cqrs-aop-module 2.x'in .NET deseni; Crewforth'un gönderdiği halinden değiştirilmiş — güvenilir sayılmadı; bir sonraki oturum güvenip güvenmeyeceğinizi soracak." ;;
      "cqrs-aop-module is now a project skill (Crewforth no longer ships it); backend-expert applies it as your project's pattern.") s="cqrs-aop-module artık bir proje skill'i (Crewforth onu artık taşımıyor); backend-expert onu projenizin deseni olarak uygular." ;;
      "cqrs-aop-module: you declined to trust it — the update keeps that answer and does not vouch for it.") s="cqrs-aop-module: ona güvenmemeyi seçtiniz — güncelleme bu cevabı koruyor ve onu güvenilir saymıyor." ;;
      "CSK_CORRECT_STACK has no effect since 3.0 — there is one backend shape; the stack lives in CLAUDE.md ## Stack.") s="CSK_CORRECT_STACK 3.0'dan beri etkisiz — tek bir backend biçimi var; yığın CLAUDE.md ## Stack bölümünde durur." ;;
      "§4.2: DevArchitecture stays armed in the trace blocklist (it was armed before this update)") s="§4.2: DevArchitecture iz engel listesinde devrede kalıyor (güncellemeden önce de devredeydi)" ;;
      "— profile pruning was removed in 2.0; this refresh completes the install") s="— profil budama 2.0'da kalktı; bu güncelleme eksikleri tamamlar" ;;
      "pre-2.0 profile") s='2.0 öncesi profil' ;;
      "YES — shared with the team") s='EVET — ekiple paylaşılıyor' ;;
      "no/untracked") s='hayır / izlenmiyor' ;;
      ".claude/CLAUDE.md in git") s=".claude/CLAUDE.md git'te mi" ;;
      "supply-chain scan flagged existing project skills/agents (advisory — review before trusting them):") s='tedarik zinciri taraması projedeki bazı skill/ajanları işaretledi (yalnız uyarı — güvenmeden önce inceleyin):' ;;
      "full report after install: %s  (Bash tool, not PowerShell; heuristic — a security skill can score low by design)") s="kurulumdan sonra tam rapor: %s  (PowerShell değil, Bash aracıyla; sezgisel — güvenlik skill'leri doğası gereği düşük puan alabilir)" ;;
      "supply-chain scan") s='tedarik zinciri taraması' ;;
      "existing project skills/agents look clean (no red flags)") s='projedeki skill/ajanlar temiz görünüyor (şüpheli bir şey yok)' ;;
      "[3] 7 handover decisions — SMART SUGGESTION") s='[3] Devralma için 7 karar — AKILLI ÖNERİ' ;;
      "format:  decision  ->  SUGGESTED  ->  rationale   (you can review and override all of them in the next stage)") s='biçim:  karar  ->  ÖNERİ  ->  gerekçe   (hepsini sonraki aşamada inceleyip değiştirebilirsiniz)' ;;
      "1 Role overlap") s='1 Rol çakışması' ;;
      "Crewforth takes over") s='Crewforth üstlenir' ;;
      "%s project agent(s) cover the SAME job as a Crewforth agent (%s) — routing is ambiguous; Crewforth wins, yours preserved") s='%s proje ajanı bir Crewforth ajanıyla AYNI işi yapıyor (%s) — hangisine gideceği belirsiz; Crewforth öne geçer, sizinkiler saklanır' ;;
      "1 Role clash") s='1 Rol çakışması' ;;
      "keep (coexist)") s='koru (yan yana)' ;;
      "%s project agents, none overlap a Crewforth role; thanks to the crew- prefix they live side by side") s='%s proje ajanı var, hiçbiri Crewforth rolleriyle çakışmıyor; crew- öneki sayesinde yan yana çalışırlar' ;;
      "no custom agents found in the project") s='projede özel ajan yok' ;;
      "2 Precedence") s='2 Öncelik' ;;
      "project wins (fixed)") s='proje önde (sabit)' ;;
      "on conflict the project's rules win; in DISCIPLINE.md §4 they can only tighten, never loosen (the one exception: the §4.1 trace allowlist you choose at adoption); Crewforth fills gaps (not overridable)") s="çakışmada projenin kuralı geçerli; DISCIPLINE.md §4'te proje yalnız sıkılaştırabilir, gevşetemez (tek istisna: kurulumda sizin seçtiğiniz §4.1 iz izin listesi); Crewforth boşlukları doldurur (değiştirilemez)" ;;
      "3 Trace gate") s='3 İz kapısı' ;;
      "loosen (.trace-allowlist)") s='gevşet (.trace-allowlist)' ;;
      "co-author/sign-off present in git log — may be a convention") s='git geçmişinde co-author/sign-off var — ekibin alışkanlığı olabilir' ;;
      "keep") s='koru' ;;
      "no co-author/sign-off convention seen") s='co-author/sign-off alışkanlığı görülmedi' ;;
      "4 Share/hide") s='4 Paylaş/gizle' ;;
      "share") s='paylaş' ;;
      ".claude/CLAUDE.md is tracked — keep sharing with the team") s=".claude/CLAUDE.md git'te izleniyor — ekiple paylaşmaya devam" ;;
      "untracked; Crewforth files are shared by default — pick hide to keep them local") s='izlenmiyor; Crewforth dosyaları varsayılan olarak paylaşılır — yerelde tutmak için hide seçin' ;;
      "hide") s='gizle' ;;
      ".claude is already gitignored in this repo — Crewforth stays local (pick share and un-ignore it to share)") s="bu depoda .claude zaten gitignore'da — Crewforth yerelde kalır (paylaşmak için share seçip ignore kuralını kaldırın)" ;;
      "#4 hide -> this repo already ignores .claude — nothing to add; Crewforth stays local") s="#4 hide -> bu depo .claude'u zaten yok sayıyor — eklenecek bir şey yok; Crewforth yerelde kalır" ;;
      "docs/ is gitignored here (a private install): %s and %s are written but not staged — they stay on this machine") s="docs/ burada gitignore'da (kişisel kurulum): %s ve %s yazıldı ama stage edilmedi — bu makinede kalır" ;;
      "5 Git hooks") s="5 Git hook'ları" ;;
      "install directly") s='doğrudan kur' ;;
      "no existing hook system") s='hook sistemi yok' ;;
      "SHIM (bridge)") s='SHIM (köprü)' ;;
      "existing %s present — let both run") s='%s zaten var — ikisi birlikte çalışsın' ;;
      "baseline+regression") s='taban + gerileme' ;;
      "existing code debt unknown; absolute 0/0/0/0 is risky") s='mevcut kod borcu bilinmiyor; mutlak 0/0/0/0 riskli' ;;
      "7 Off-repo: no local .claude/CLAUDE.md — decisions may live in chat/on the web; there is context I CANNOT SEE.") s='7 Depo dışı: yerelde .claude/CLAUDE.md yok — kararlar sohbette ya da webde kalmış olabilir; GÖREMEDİĞİM bir bağlam var.' ;;
      "  -> suggestion") s='  -> öneri' ;;
      "you transfer") s='siz aktarın' ;;
      "in the mutation stage 'paste if any' is asked; goes into HANDOVER.md") s="uygulama aşamasında 'varsa yapıştırın' diye sorulur; HANDOVER.md'ye yazılır" ;;
      "7 Off-repo") s='7 Depo dışı' ;;
      "local + ask") s='yerel + sor' ;;
      "some decisions are in files; still may be in-chat (asked during the stage)") s='kararların bir kısmı dosyalarda; sohbette kalanlar olabilir (aşama sırasında sorulur)' ;;
      "Review the decisions") s='Kararları gözden geçirin' ;;
      "[%s/%s] (current: %s, ENTER=keep): ") s='[%s/%s] (şu an: %s, ENTER=aynen kalsın): ' ;;
      'type "%s" or "%s" (or ENTER to keep "%s")') s='"%s" ya da "%s" yazın ("%s" kalsın diye yalnız ENTER)' ;;
      "Accept all smart suggestions?") s='Tüm akıllı öneriler kabul edilsin mi?' ;;
      "All smart suggestions accepted.") s='Tüm akıllı öneriler kabul edildi.' ;;
      "Reviewing each decision. ENTER keeps the current value. (#1 overlap and #2/#5 are handled separately below.)") s='Kararlar tek tek soruluyor. ENTER mevcut değeri korur. (#1 çakışma ve #2/#5 aşağıda ayrıca ele alınıyor.)' ;;
      "#3 Trace gate") s='#3 İz kapısı' ;;
      "#4 Share/hide") s='#4 Paylaş/gizle' ;;
      "#7 Off-repo") s='#7 Depo dışı' ;;
      "Final: #3=%s #4=%s #6=%s #7=%s  (#2 project-wins, #5 SHIM — fixed)") s='Sonuç: #3=%s #4=%s #6=%s #7=%s  (#2 proje önde, #5 SHIM — sabit)' ;;
      "(non-interactive: smart defaults accepted)") s='(etkileşimsiz çalışma: akıllı varsayılanlar kabul edildi)' ;;
      "Role overlap — project & Crewforth both cover: %s") s='Rol çakışması — proje ve Crewforth aynı işi yapıyor: %s' ;;
      "Two agents for one job = the router picks one, usually your older agent — so Crewforth's would sit idle.") s="Aynı iş için iki ajan olunca yönlendirici birini seçer, çoğu zaman sizin eski ajanınızı — Crewforth'unki boşta kalır." ;;
      "Crewforth's crew- agents win; each old agent's domain is imported to a draft skill (skills/<name>-local), original backed up") s="Crewforth'un crew- ajanları öne geçer; eski ajanın alan bilgisi taslak bir skill'e (skills/<name>-local) taşınır, orijinali yedeklenir" ;;
      "your agents win; Crewforth's overlapping crew- agents are not installed") s="sizin ajanlarınız öne geçer; Crewforth'un çakışan crew- ajanları kurulmaz" ;;
      "keep both (routing stays ambiguous; only documented in HANDOVER)") s="ikisi de kalır (yönlendirme belirsiz kalır; yalnız HANDOVER'a not düşülür)" ;;
      "owner") s='sahip' ;;
      "type takeover, keepmine or coexist") s='takeover, keepmine ya da coexist yazın' ;;
      "overlap -> %s") s='çakışma -> %s' ;;
      "Stage 2 — apply Crewforth (coexist)") s="Aşama 2 — Crewforth'u uygula (projeyle yan yana)" ;;
      "no git repo — cannot apply safely. First:  %s  (then run again).") s='git deposu yok — güvenle uygulanamaz. Önce şunu çalıştırın:  %s  (sonra tekrar deneyin).' ;;
      "Apply on a NEW review branch? (no = apply on the current branch '%s')") s="YENİ bir inceleme dalında mı uygulansın? (hayır = mevcut '%s' dalında)" ;;
      "the current branch '%s'") s="mevcut '%s' dalı" ;;
      "a new review branch (off '%s')") s="'%s' üzerinden açılan yeni bir inceleme dalı" ;;
      "Apply Crewforth onto %s now? (mutation; staged-not-committed, reversible with git)") s='Crewforth şimdi uygulansın mı? Hedef: %s (dosyalar değişir; stage edilir, commit edilmez, git ile geri alınabilir)' ;;
      "Stopped") s='Durduruldu' ;;
      "Stayed at Stage 1 — NOTHING CHANGED (read-only).") s="Aşama 1'de kalındı — HİÇBİR ŞEY DEĞİŞMEDİ (salt okunur)." ;;
      "applying on the current branch: %s  (no separate branch; staged, HEAD untouched until you commit)") s='mevcut dala uygulanıyor: %s  (ayrı dal yok; değişiklikler stage edilir, siz commit edene kadar HEAD yerinde kalır)' ;;
      "You are on your current branch %s with everything STAGED but NOT committed.") s='Mevcut %s dalındasınız; her şey STAGE edildi ama commit EDİLMEDİ.' ;;
      "accept:   %s") s='kabul:    %s' ;;
      "discard:  %s   (un-stages everything; nothing was committed)") s="vazgeç:   %s   (stage'i boşaltır; zaten hiçbir şey commit edilmedi)" ;;
      "HEAD is a prior adopt branch (%s) — the review diff will be vs it, not your main line. Consider %s first.") s="HEAD önceki bir adopt dalında (%s) — inceleme diff'i ana dalınıza değil bu dala göre çıkar. Önce %s çalıştırmayı düşünün." ;;
      "ERROR: could not open branch '%s'.") s="HATA: '%s' dalı açılamadı." ;;
      "handover branch: %s  (%s stays clean)") s='inceleme dalı: %s  (%s temiz kalır)' ;;
      "You are on branch %s with everything STAGED but NOT committed.") s='%s dalındasınız; her şey STAGE edildi ama commit EDİLMEDİ.' ;;
      "accept:   %s   then:  %s") s='kabul:    %s   ardından:  %s' ;;
      "discard:  %s") s='vazgeç:   %s' ;;
      ".NET pattern skill renamed: devarch-module -> cqrs-aop-module (content kept)") s=".NET desen skill'inin adı değişti: devarch-module -> cqrs-aop-module (içerik korundu)" ;;
      "⚠️  both devarch-module and cqrs-aop-module are present — nothing moved; remove the old one when ready") s='⚠️  devarch-module ve cqrs-aop-module ikisi birden var — hiçbir şey taşınmadı; hazır olduğunuzda eskisini silin' ;;
      "AGENT_TEMPLATE.md written (owned by Crewforth; refreshed on every update)") s="AGENT_TEMPLATE.md yazıldı (Crewforth'un dosyası; her güncellemede yenilenir)" ;;
      '%s is not a copy Crewforth shipped before this version — it is kept in %s/%s') s="%s, Crewforth'un bu sürümden önce gönderdiği bir kopya değil — %s/%s içinde saklandı" ;;
      '%s could not be checked against what Crewforth shipped (git or the shipped list is missing) — the old copy is kept in %s/%s') s="%s, Crewforth'un gönderdikleriyle karşılaştırılamadı (git ya da gönderilen liste yok) — eski kopya %s/%s içinde saklandı" ;;
      'README.md refreshed (describes this version of Crewforth)') s="README.md yenilendi (Crewforth'un bu sürümünü anlatıyor)" ;;
      '%s is not a copy Crewforth shipped before this version and could not be backed up — left as it is') s="%s, Crewforth'un bu sürümden önce gönderdiği bir kopya değil ve yedeklenemedi — olduğu gibi bırakıldı" ;;
      "pre-2.0 install (profile=%s): profile pruning was removed — completing the install") s='2.0 öncesi kurulum (profile=%s): profil budama kalktı — eksikler tamamlanıyor' ;;
      "pre-2.0 install (profile=%s): nothing was missing — the full set was already present") s='2.0 öncesi kurulum (profile=%s): eksik yok — tam set zaten kuruluydu' ;;
      "overlap: %s -> skill '%s' already present (kept); original re-backed up") s="çakışma: %s -> '%s' skill'i zaten var (korundu); orijinal yeniden yedeklendi" ;;
      "overlap: %s -> imported to skill '%s' (draft); Crewforth's %s owns routing") s="çakışma: %s -> '%s' skill'ine taşındı (taslak); yönlendirme artık Crewforth'un %s ajanında" ;;
      "ref-sweep: %s → %s in %s") s='ref-sweep: %s → %s (%s)' ;;
      "Reference sweep: rewrote taken-over agent names to their crew- id across CLAUDE.md + referenced docs") s='Referans taraması: devralınan ajan adları CLAUDE.md ve bağlı belgelerde crew- adlarına çevrildi' ;;
      "ref-sweep: no stale references in CLAUDE.md's chain") s='ref-sweep: CLAUDE.md ve bağlı belgelerde eski ad kalmamış' ;;
      "⚠️  installed by an older Crewforth version and no longer shipped:%s") s='⚠️  eski bir Crewforth sürümünden kalan, artık dağıtılmayan dosyalar:%s' ;;
      "The name is the invocation: a leftover COMMAND still lists in the / picker (/review twice), and a") s='Burada adın kendisi çağrıdır: artakalan bir KOMUT / menüsünde hâlâ görünür (/review iki kez), artakalan' ;;
      "leftover SKILL still matches prompts, so it competes with whatever replaced it.") s='bir SKILL de istemlerle eşleşmeye devam eder ve yerine gelenle yarışır.' ;;
      "Nothing is deleted for you — one of these may be a file you customised. To drop them all:") s='Hiçbiri sizin yerinize silinmez — aralarında özelleştirdiğiniz bir dosya olabilir. Hepsini kaldırmak için:' ;;
      'older Crewforth components could not be checked against what Crewforth shipped (git or the shipped list is missing) — left in place:%s') s="eski Crewforth bileşenleri Crewforth'un dağıttıklarıyla karşılaştırılamadı (git ya da dağıtım listesi yok) — yerinde bırakıldı:%s" ;;
      'moved aside — each one exactly as an older Crewforth shipped it, and no longer shipped:%s') s="kenara alındı — her biri eski bir Crewforth'un dağıttığıyla birebir aynı ve artık dağıtılmıyor:%s" ;;
      'to put them back: cp -R %s/. .claude/') s='geri koymak için: cp -R %s/. .claude/' ;;
      'left in place — installed by an older Crewforth, no longer shipped, and changed since (yours now?):%s') s="yerinde bırakıldı — eski bir Crewforth kurmuştu, artık dağıtılmıyor ve o günden beri değişmiş (artık sizin mi?):%s" ;;
      'Each still answers its name (a command lists in the / picker, a skill matches prompts). To drop them:') s='Her biri adıyla çağrılmaya devam eder (komut / menüsünde görünür, skill istemlerle eşleşir). Kaldırmak için:' ;;
      '%s (an unchanged copy Crewforth shipped) moved aside; your %s was not touched') s="%s (Crewforth'un dağıttığı, değişmemiş kopya) yedeğe taşındı; sizin %s dosyanıza dokunulmadı" ;;
      '%s (a second, unchanged copy Crewforth shipped) moved aside; %s already answers that command') s="%s (Crewforth'un dağıttığı ikinci, değişmemiş kopya) yedeğe taşındı; o komutu zaten %s karşılıyor" ;;
      'older Crewforth components in a symlinked (shared?) directory are left in place — moving them out would remove them from every project that uses it:%s') s='sembolik bağlantılı (paylaşılan?) bir dizindeki eski Crewforth bileşenleri yerinde bırakıldı — taşımak onları bu dizini kullanan her projeden kaldırırdı:%s' ;;
      '(an unchanged copy put back is moved aside again by the next update — to keep one, change it)') s='(geri konan değişmemiş bir kopya sonraki güncellemede yine kenara alınır — birini tutmak için onu değiştirin)' ;;
      "Coexist summary") s='Kurulum özeti' ;;
      "%s · %s skipped") s='%s · %s atlandı' ;;
      "+%s added") s='+%s eklendi' ;;
      "Crewforth agents (crew-)") s='Crewforth ajanları (crew-)' ;;
      "skills") s="skill'ler" ;;
      "commands") s='komutlar' ;;
      "hooks") s="hook'lar" ;;
      "%s (needs Node 18+)") s='%s (Node 18+ gerekir)' ;;
      "%s (%s imported to skills/<name>-local drafts; originals backed up in superseded/)") s='%s (%s tanesi skills/<name>-local taslaklarına taşındı; orijinaller superseded/ altında)' ;;
      "%s — the rest UNTOUCHED") s='%s — geri kalanına DOKUNULMADI' ;;
      "project agents") s='proje ajanları' ;;
      "overlap") s='çakışma' ;;
      "keepmine — your agents own: %s (Crewforth's crew- for these NOT installed)") s="keepmine — bu roller sizin ajanlarınızda: %s (Crewforth'un karşılık gelen crew- ajanları KURULMADI)" ;;
      "overlap: %s — BOTH kept; routing between your agent and Crewforth's crew- stays ambiguous") s="çakışma: %s — İKİSİ de kaldı; sizin ajanınızla Crewforth'un crew- ajanı arasında seçim belirsiz" ;;
      "conflicting files (the project's was PRESERVED, Crewforth's skipped):") s="çakışan dosyalar (projeninki KORUNDU, Crewforth'unki atlandı):" ;;
      "Stage 3 — activate the Crewforth discipline (without touching the project CLAUDE.md) + settings merge") s="Aşama 3 — Crewforth disiplinini etkinleştir (proje CLAUDE.md'sine dokunmadan) + ayarları birleştir" ;;
      "DISCIPLINE.md written (Crewforth discipline only; the project template stays out of it)") s='DISCIPLINE.md yazıldı (yalnız Crewforth disiplini; proje şablonu içinde yok)' ;;
      "CLAUDE.md: @import already present (idempotent)") s='CLAUDE.md: @import zaten var (tekrar eklenmedi)' ;;
      "CLAUDE.md carries the discipline INLINE (pre-1.1 layout) — discipline updates cannot reach it.") s='CLAUDE.md disiplini DOSYANIN İÇİNDE taşıyor (1.1 öncesi düzen) — disiplin güncellemeleri ona ulaşamaz.' ;;
      "the inline block is lines 1-%s; your project section starts at line %s") s='gömülü blok 1-%s. satırlar; proje bölümünüz %s. satırda başlıyor' ;;
      "  Replace that inline block with the single @import line? (a backup is written; this branch is reviewable)") s='  Bu gömülü blok tek bir @import satırıyla değiştirilsin mi? (yedek alınır; değişiklik bu dalda incelenebilir)' ;;
      "CLAUDE.md migrated -> @import + your project section (backup: %s)") s='CLAUDE.md taşındı -> @import + proje bölümünüz (yedek: %s)' ;;
      "Skipped. Discipline updates will NOT reach this project until you migrate.") s='Atlandı. Taşıyana kadar disiplin güncellemeleri bu projeye ULAŞMAZ.' ;;
      "Project heading not found — migrate by hand: delete everything above it, leave only:  %s") s='Proje başlığı bulunamadı — elle taşıyın: başlığın üstündeki her şeyi silin, yalnız şunu bırakın:  %s' ;;
      "CLAUDE.md: single-line @import prepended (project content untouched)") s='CLAUDE.md: başına tek satırlık @import eklendi (proje içeriğine dokunulmadı)' ;;
      "CLAUDE.md was missing -> @import + project template created") s='CLAUDE.md yoktu -> @import ve proje şablonuyla oluşturuldu' ;;
      "custom hooks and every other permission PRESERVED") s="özel hook'lar ve diğer tüm izinler KORUNDU" ;;
      "custom hooks/permissions PRESERVED") s="özel hook'lar ve izinler KORUNDU" ;;
      "settings.json: was missing in the project -> Crewforth's was installed") s="settings.json: projede yoktu -> Crewforth'unki kuruldu" ;;
      "settings.json: hook-aware MERGE (Crewforth hooks refreshed - %s)") s="settings.json: hook'ları gözeten BİRLEŞTİRME (Crewforth hook'ları yenilendi - %s)" ;;
      "settings.json: %s") s='settings.json: %s' ;;
      "merge failed -> project setting PRESERVED (not overwritten)") s='birleştirme başarısız -> proje ayarı KORUNDU (üzerine yazılmadı)' ;;
      "existing file is INVALID JSON -> merge ABORT (no silent overwrite). Fix it by hand first.") s='mevcut dosya GEÇERSİZ JSON -> birleştirme İPTAL (üzerine sessizce yazılmaz). Önce elle düzeltin.' ;;
      "settings.json: retired §4.4 ask rule(s) REMOVED (%s) — guard-bash.sh now asks for these itself; an ask rule would override its CLAUDE_GIT_OK allow. Re-add one only if your project wants that trade.") s='settings.json: emekliye ayrılan §4.4 ask kuralları KALDIRILDI (%s) — bunları artık guard-bash.sh kendisi soruyor; bir ask kuralı onun CLAUDE_GIT_OK iznini ezerdi. Bu bedeli bilerek istiyorsanız geri ekleyin.' ;;
      "Stage 4 — arm the git gates (SHIM via husky) + PROOF") s='Aşama 4 — git kapılarını devreye al (husky üzerinden SHIM) + KANIT' ;;
      "core.hooksPath -> .claude/hooks (no existing hook chain)") s='core.hooksPath -> .claude/hooks (başka hook zinciri yok)' ;;
      "SHIM installed -> core.hooksPath=.claude/git-shim (Crewforth + %s run together)") s='SHIM kuruldu -> core.hooksPath=.claude/git-shim (Crewforth ve %s birlikte çalışır)' ;;
      "worktree/submodule: core.hooksPath may also affect the main checkout (git design).") s="worktree/submodule: core.hooksPath ana checkout'u da etkileyebilir (git böyle tasarlanmış)." ;;
      "Stage 4b — PROOF") s='Aşama 4b — KANIT' ;;
      "~  PROOF-1: skipped — could not stage the probe file (nothing was measured)") s='~  KANIT-1: atlandı — deneme dosyası stage edilemedi (hiçbir şey ölçülmedi)' ;;
      "PROOF-1 FAILED: the trace scan LET THROUGH the AI trace") s='KANIT-1 BAŞARISIZ: iz taraması AI izini GEÇİRDİ' ;;
      "OK · PROOF-1: staged AI trace BLOCKED by the trace scan") s='OK · KANIT-1: stage edilen AI izini iz taraması ENGELLEDİ' ;;
      "~  PROOF-1: hook blocked (%s)") s='~  KANIT-1: hook engelledi (%s)' ;;
      "PROOF-2 FAILED: guard-bash LET THROUGH the keyless commit") s="KANIT-2 BAŞARISIZ: guard-bash anahtarsız commit'i GEÇİRDİ" ;;
      "OK · PROOF-2: guard-bash BLOCKED the keyless 'git commit' (holds in auto/bypass too)") s="OK · KANIT-2: guard-bash anahtarsız 'git commit'i ENGELLEDİ (auto/bypass modunda da geçerli)" ;;
      "OK · PROOF-3: %s Crewforth agents (crew-) installed + discoverable") s='OK · KANIT-3: %s Crewforth ajanı (crew-) kurulu ve bulunabiliyor' ;;
      "PROOF-3: no Crewforth agent") s='KANIT-3: Crewforth ajanı yok' ;;
      "OK · PROOF-4: DISCIPLINE.md loaded + @import-ed from CLAUDE.md") s="OK · KANIT-4: DISCIPLINE.md yerinde ve CLAUDE.md'den @import ediliyor" ;;
      "PROOF-4: discipline not linked") s='KANIT-4: disiplin bağlanmamış' ;;
      "%s line(s): %s") s='%s, satır: %s' ;;
      "PROOF-5: CLAUDE.md (or a doc it references) names auto-delegated agent(s) by an old bare id — rename each to its crew- id, else delegation to them silently fails:%s") s='KANIT-5: CLAUDE.md (ya da bağlı bir belge) otomatik devredilen ajanları eski, eksiz adıyla anıyor — her birini crew- adıyla değiştirin, yoksa onlara devretme sessizce başarısız olur:%s' ;;
      "PROOF-5: CLAUDE.md (or a referenced doc) names pull-only agent(s) by an old bare id (still work; rename for consistency):%s") s='KANIT-5: CLAUDE.md (ya da bağlı bir belge) elle çağrılan ajanları eski, eksiz adıyla anıyor (yine çalışır; tutarlılık için yeniden adlandırın):%s' ;;
      "PROOF: Crewforth 100%% ACTIVE — gates armed, agents + discipline loaded") s='KANIT: Crewforth %%100 ETKİN — kapılar devrede, ajanlar ve disiplin yüklü' ;;
      "PROOF: some gates could not be verified (see above)") s='KANIT: bazı kapılar doğrulanamadı (yukarıya bakın)' ;;
      "Stage B — apply the decisions") s='Aşama B — kararları uygula' ;;
      "#3 loosen -> .trace-allowlist.txt (co-author trailer exempt)") s='#3 loosen -> .trace-allowlist.txt (co-author satırı taramadan muaf)' ;;
      "#3 keep -> full trace scan") s='#3 keep -> tam iz taraması' ;;
      "#4 hide -> recorded; .claude stays TRACKED on the branch (rollback-safe). Post-merge steps in HANDOVER.") s="#4 hide -> kaydedildi; .claude bu dalda İZLENMEYE devam eder (geri almak güvenli). Merge sonrası adımlar HANDOVER'da." ;;
      "#4 share -> .claude/CLAUDE.md is tracked; nothing added to .gitignore, so it stays shared") s="#4 share -> .claude/CLAUDE.md izleniyor; .gitignore'a bir şey eklenmedi, paylaşılmaya devam eder" ;;
      "#4 share -> nothing added to .gitignore, but this repo ALREADY ignores .claude — the stage step skips it, so it is NOT shared") s="#4 share -> .gitignore'a bir şey eklenmedi, ama bu depo .claude'u ZATEN yok sayıyor — stage adımı onu atlar, yani PAYLAŞILMAZ" ;;
      "#4 share -> nothing added to .gitignore; the stage step below adds .claude — commit it to share it") s="#4 share -> .gitignore'a bir şey eklenmedi; aşağıdaki stage adımı .claude'u ekler — paylaşmak için commit edin" ;;
      "#7 off-repo decisions — paste them here") s='#7 depo dışındaki kararlar — buraya yapıştırın' ;;
      "Write the decisions made in chat/on the web but NOT in the repo. When done, an EMPTY line (Enter).") s='Sohbette ya da webde alınıp depoya YAZILMAMIŞ kararları girin. Bitirmek için BOŞ bir satır (Enter).' ;;
      "#7 -> %s lines will go into HANDOVER") s="#7 -> %s satır HANDOVER'a yazılacak" ;;
      "#7 -> empty") s='#7 -> boş' ;;
      "Stage 5 — HANDOVER.md + ADR (handover persists; decisions are not lost)") s='Aşama 5 — HANDOVER.md + ADR (devralma kayda geçer; kararlar kaybolmaz)' ;;
      "%s written") s='%s yazıldı' ;;
      "%s written (persistent handover decision)") s='%s yazıldı (devralmanın kalıcı karar kaydı)' ;;
      "%s already exists — untouched (never-overwrite)") s='%s zaten var — dokunulmadı (üzerine asla yazılmaz)' ;;
      "+ .gitattributes: eol pins so the shared hooks stay LF on a Windows checkout") s="+ .gitattributes: paylaşılan hook'lar Windows checkout'unda LF kalsın diye eol sabitlendi" ;;
      "Review in your editor — nothing committed yet") s='Editörünüzde inceleyin — henüz hiçbir şey commit edilmedi' ;;
      "staged") s='stage edilen' ;;
      "see it:   open the Source Control / Changes panel (every added + changed file is listed)  ·  or: %s") s='görmek için:  Source Control / Changes panelini açın (eklenen ve değişen her dosya orada)  ·  ya da: %s' ;;
      "panel:    %s opens it from this project (or: %s)") s='panel:    bu projede %s ile açılır (ya da: %s)' ;;
      "panel:    needs Node 18+, absent here — Crewforth can fetch one (Bash tool, not PowerShell): %s") s='panel:    Node 18+ gerekiyor ve bu makinede yok — Crewforth indirebilir (PowerShell değil, Bash aracıyla): %s' ;;
      "(it asks first, verifies the checksum, and touches nothing outside %s)") s='(önce sorar, sağlama toplamını doğrular ve %s dışında hiçbir şeye dokunmaz)' ;;
      "If Claude Code is running in this project, run /clear (or quit and relaunch it) — a new session loads the") s='Claude Code bu projede açıksa /clear çalıştırın (ya da kapatıp yeniden açın) — yeni oturum güncel' ;;
      "updated CLAUDE.md and discipline; a session opened before this run keeps the old rules until then.") s='CLAUDE.md ve disiplini yükler; bu çalıştırmadan önce açılmış oturum o zamana kadar eski kuralları uygular.' ;;
      "yes") s='evet' ;;
      "no") s='hayır' ;;
      "[yes/no]") s='[evet/hayır]' ;;
      "(non-interactive — pass --yes to apply)") s='(etkileşimsiz — uygulamak için --yes ekleyin)' ;;
      "ERROR: the %s sentinel line is missing from %s — refusing to guess the discipline/project split.") s='HATA: %s işaret satırı yok (dosya: %s) — disiplin ile proje bölümünün sınırı tahmin edilmeyecek.' ;;
      "studio (panel)") ;;   # identifier, printed as is
      "settings.json") ;;   # identifier, printed as is
      "eval") ;;   # identifier, printed as is
      "Node/JS") ;;   # identifier, printed as is
      "Go") ;;   # identifier, printed as is
      "Python") ;;   # identifier, printed as is
      ".NET") ;;   # identifier, printed as is
      "CLAUDE.md") ;;   # identifier, printed as is
      "6 Brownfield DoD") ;;   # identifier, printed as is
      ".claude/") ;;   # identifier, printed as is
      "git") ;;   # identifier, printed as is
      "husky (.husky/)") ;;   # identifier, printed as is
      "lefthook") ;;   # identifier, printed as is
      # No row: the line prints in English. CREW_I18N_MISS (set by e2e case 18) collects every such key, so a
      # missing translation is caught by NAME rather than guessed from which English words it happens to contain.
      *) [ -n "${CREW_I18N_MISS:-}" ] && printf '%s\n' "$s" >> "$CREW_I18N_MISS" ;;
    esac
  fi
  # shellcheck disable=SC2059
  # `--` ends option parsing: without it ANY format starting with '-' ("--dotnet …", "- x") is read as an option
  # and printf exits 2 — measured on bash 3.2 (macOS) and Git Bash 5.3; with it both assign normally.
  printf -v _M -- "$s" "$@"
}
# ---- /CREW-I18N -----------------------------------------------------------------------------------------

# --- color: only on an interactive TTY (same guard as start.sh) ---
if [ -t 1 ] && [ "${TERM:-dumb}" != "dumb" ] && [ -z "${NO_COLOR:-}" ]; then
  R=$'\033[0m'; B=$'\033[1m'; D=$'\033[2m'; CY=$'\033[36m'; GR=$'\033[32m'; YE=$'\033[33m'; MG=$'\033[35m'
else R=''; B=''; D=''; CY=''; GR=''; YE=''; MG=''; fi
h1()  { printf '\n%s%s%s%s\n' "$B" "$CY" "$1" "$R"; }
sub() { printf '%s%s%s\n' "$D" "$1" "$R"; }
# printf's %-Ns pads by BYTES, so a Turkish label (İ, ç, ı are two bytes each) came out short and knocked its
# column out of line. Pad by characters: drop UTF-8 continuation bytes under C and count the rest. No fork.
padr() {   # $1 = text, $2 = width; sets PADDED
  local LC_ALL=C n
  n="${1//[$'\200'-$'\277']/}"; n=$(( $2 - ${#n} ))
  PADDED="$1"
  while [ "$n" -gt 0 ]; do PADDED="$PADDED "; n=$((n-1)); done
}
row() { padr "$1" 20; printf '  %s%s%s %s\n' "$B" "$PADDED" "$R" "$2"; }
warn(){ printf '  %s!%s %s%s%s\n' "$YE" "$R" "$YE" "$1" "$R"; }
# smart suggestion line:  number+decision · SUGGESTED(green) · rationale(dim)
prop(){ local _p1; padr "$1" 18; _p1="$PADDED"; padr "$2" 24
        printf '  %s%s%s %s%s%s %s%s%s\n' "$B" "$_p1" "$R" "$GR" "$PADDED" "$R" "$D" "$3" "$R"; }
# Translating twins of the helpers above: the FIRST argument is the English key, the rest fill its %s.
# rowv translates only the label (value printed verbatim); rowm translates both; propm all three.
say()  { _mt "$@"; printf '  %s\n' "$_M"; }
h1m()  { _mt "$@"; h1 "$_M"; }
subm() { _mt "$@"; sub "$_M"; }
warnm(){ _mt "$@"; warn "$_M"; }
rowv() { local v="$2"; _mt "$1"; row "$_M" "$v"; }
rowm() { local l; _mt "$1"; l="$_M"; shift; _mt "$@"; row "$l" "$_M"; }
propm(){ local a b; _mt "$1"; a="$_M"; _mt "$2"; b="$_M"; shift 2; _mt "$@"; prop "$a" "$b" "$_M"; }
# --yes ALWAYS wins — check it BEFORE the TTY test. A `read` on a TTY blocks on human input, so if we tested
# `-t 0` first, an agent/CI run that DID pass --yes but happens to inherit a TTY (Claude Code on Windows runs
# under a pty) would hang at the prompt, ignoring --yes. Only when --yes is absent do we prompt (TTY) or decline
# cleanly (no TTY — a bare `read` would otherwise block forever on an open-but-empty stdin).
# $1 = the English prompt (translated here), further args fill its %s.
ask_yes(){ local a q w
  _mt "$@"; q="$_M"
  if [ "${ASSUME_YES:-0}" = 1 ]; then _mt 'yes'; printf '%s %s %s(--yes)%s\n' "$q" "$_M" "$D" "$R"; a=yes
  elif [ -t 0 ]; then _mt '[yes/no]'; printf '%s %s: ' "$q" "$_M"; read -r a || a=""
  else _mt 'no'; w="$_M"; _mt '(non-interactive — pass --yes to apply)'; printf '%s %s %s%s%s\n' "$q" "$w" "$D" "$_M" "$R"; a=no; fi
  case "$a" in
    [yY]|[yY][eE][sS]|[eE]|[eE][vV][eE][tT]) return 0;;
    [hH]|hayır|Hayır|hayir|Hayir) return 1;;   # explicit Turkish "no" (anything unrecognised is "no" too)
    *) return 1;;
  esac; }
# Twin of start.sh's gi_add — the same two defects were present in both scripts, and twice in this one.
#   * A .gitignore whose last line has NO trailing newline concatenates the first appended entry onto it:
#     `node_modules` + `docs/` becomes `node_modulesdocs/`, which ignores neither. Reproduced on the old
#     shape before this was written. `touch` does not help — it changes the timestamp, not the last byte.
#   * `grep -qxF` is an exact-literal test, so a repo that already ignores `.claude` (no trailing slash)
#     collected a second, redundant line. `git check-ignore` asks about the PATH rather than the spelling,
#     which is the technique this script already uses at the #4 share branch and never applied to its own
#     writes. Outside a repository there is nothing to ask, so the literal test stays as the fallback.
gi_add() {   # $@ = entries to ensure in ./.gitignore; sets GI_WROTE to what it actually added
  local e
  GI_WROTE=""
  [ -e .gitignore ] || : > .gitignore
  for e in "$@"; do
    if git rev-parse --git-dir >/dev/null 2>&1; then
      git check-ignore -q --no-index "$e" 2>/dev/null && continue   # --no-index: a dir holding tracked files (docs/HANDOVER.md) still counts as ignored
    else
      grep -qxF "$e" .gitignore 2>/dev/null && continue
    fi
    if [ -s .gitignore ] && [ "$(tail -c 1 .gitignore | od -An -tx1 | tr -d ' \n')" != "0a" ]; then
      printf '\n' >> .gitignore
    fi
    printf '%s\n' "$e" >> .gitignore
    GI_WROTE="$GI_WROTE $e"
  done
  GI_WROTE="${GI_WROTE# }"
}
# never-overwrite copy: does NOT overwrite an EXISTING target file (project file is preserved), skips+counts.
# Result globals: ret_add / ret_skip; conflicts are added to SKIP_LIST. Do NOT call in a subshell (globals are lost).
SKIP_LIST=""
# $4 = space-separated names to SKIP entirely, matched against the first path component of each source file
# ('crew-frontend-expert.md' for agents/, 'a11y' for skills/). We skip rather than copy-then-delete: a project
# may own a directory of the same name, and a refresh must never remove the project's own files.
# Per-FILE process spawns are what make this hurt on Windows: Git Bash pays 62-135 ms per process where Linux pays
# ~1.7ms, so `dirname`+`mkdir`+`cp` for each of ~100 payload files is minutes, not milliseconds. Measured on a
# user's machine: a refresh took 6m43s wall with 66s of it in the kernel — the fork signature, not file I/O.
#   - the refresh case (force=1, nothing excluded) is ONE `cp -R`, not one `cp` per file;
#   - the selective case keeps per-file decisions but drops `dirname` for parameter expansion, and only calls
#     `mkdir` when the directory actually changes (find walks a directory at a time, so that is nearly always).
copy_noclobber(){ local src="$1" dst="$2" force="${3:-0}" exclraw="${4:-}" excl=" ${4:-} " rel top f d lastd=""; ret_add=0; ret_skip=0; [ -d "$src" ] || return; mkdir -p "$dst"
  if [ "$force" = 1 ] && [ -z "$exclraw" ]; then
    ret_add="$(find "$src" -type f 2>/dev/null | wc -l | tr -d ' ')"
    cp -R "$src/." "$dst/" 2>/dev/null
    return
  fi
  while IFS= read -r f; do rel="${f#"$src"/}"; top="${rel%%/*}"
    case "$excl" in *" $top "*) continue ;; esac
    if [ -e "$dst/$rel" ] && [ "$force" != 1 ]; then ret_skip=$((ret_skip+1)); SKIP_LIST="$SKIP_LIST $dst/$rel"
    else
      case "$rel" in */*) d="$dst/${rel%/*}" ;; *) d="$dst" ;; esac
      [ "$d" = "$lastd" ] || { mkdir -p "$d"; lastd="$d"; }
      cp "$f" "$dst/$rel"; ret_add=$((ret_add+1))
    fi
  done < <(find "$src" -type f 2>/dev/null); }

# --- CLAUDE.md split (shared contract with start.sh; keep the two in lockstep) ---
IMPORT_LINE='@.claude/DISCIPLINE.md'
# Sentinel matched ANCHORED to line start, so prose that merely names the token is never mistaken for the split
# point. Abort loudly if it is gone: a silent miss ships the ENTIRE template as "discipline" — which is exactly
# what the previous '<PROJE ADI>' marker did once the payload was translated to English.
kit_require_sentinel() { grep -qE '^<!-- KIT:DISCIPLINE-END' "$1" || { _mt "ERROR: the %s sentinel line is missing from %s — refusing to guess the discipline/project split." "'<!-- KIT:DISCIPLINE-END'" "$1"; printf '%s\n' "$_M"; exit 1; }; }
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
# Where does the project section of a legacy CLAUDE.md begin? Line 1 is the discipline's own '# CLAUDE.md — Working
# rules' heading, so look from line 2 on. Fallback: the first '# ' heading after the §4.5 block (covers a renamed
# heading). Capture the output — `awk … && return` would return on awk's exit status even when it printed nothing.
kit_legacy_boundary() {
  local n
  n="$(awk 'NR>1 && /^# CLAUDE\.md/{print NR; exit}' "$1" 2>/dev/null)"
  [ -n "$n" ] || n="$(awk '/^### 4\.5 /{f=1;next} f && /^# /{print NR; exit}' "$1" 2>/dev/null)"
  printf '%s' "$n"
}
# A project installed before kit.conf existed carries its backend pattern only in what is on disk. Read it
# back, so the 3.0 migration below can tell a former .NET install (which keeps its pattern skill) from one that
# never had it.
kit_infer_shape() {
  # A pre-3.0 .NET install is marked by the .NET pattern skill being on disk; the generic stack pruned it.
  # BOTH NAMES. The skill was `devarch-module` from v1.0.0 until the rename to `cqrs-aop-module`, and this
  # function exists for exactly the installs that predate kit.conf — which are the installs that carry the OLD
  # name. Reading only the new one would miss every such project, and the migration notice with it.
  if [ -d .claude/skills/cqrs-aop-module ] || [ -d .claude/skills/devarch-module ]; then KIT_STACK=dotnet; else KIT_STACK=generic; fi
  KIT_INSTALLER="${KIT_INSTALLER:-pre-kit.conf}"
  INFERRED=1
}
# tr -d '\r' on both readers: a CRLF file (Windows checkout, or kit.conf reopened in Notepad) would otherwise
# glue '\r' to every value — 'generic\r' matches no branch, and the refresh would pick the wrong pattern.
kit_conf_get()         { [ -f .claude/kit.conf ] && sed -n "s/^$1=//p" .claude/kit.conf | head -1 | tr -d '\r'; }

# Turn a project agent into a DRAFT project skill (prints the SKILL.md to stdout). On takeover the kit's crew-
# agent owns routing (who/when); this carries the OLD agent's domain (its "how") into an active skill the kit
# agent can apply, so nothing is lost from the working setup. It keeps the agent's description (domain keywords)
# and body, guarantees a Trigger-phrases line for discovery, and marks it as a carried-over draft to refine.
kit_agent_to_skill() {   # $1 = agent .md file, $2 = base name
  local f="$1" b="$2" desc trig body
  desc="$(awk '/^---[ \t]*$/{c++; next} c==1 && /^description:/{sub(/^description:[ \t]*\|?[ \t]*/,""); if($0!="")print; exit}' "$f")"
  [ -n "$desc" ] || desc="Project-specific $b knowledge carried over when Crewforth took over the role."
  trig="$(awk '/[Tt]rigger phrases:/{sub(/.*[Tt]rigger phrases:[ \t]*/,""); print; exit}' "$f")"
  [ -n "$trig" ] || trig="\"$b\""
  body="$(awk 'c>=2{print} /^---[ \t]*$/{c++}' "$f")"
  printf '%s\n' '---' "name: ${b}-local"
  printf 'description: |\n  %s\n' "$desc"
  printf '  Carried over from the project'"'"'s own %s agent when crew-%s took over the role — trim to the domain worth keeping.\n' "$b" "$b"
  printf '  Trigger phrases: %s\n---\n\n' "$trig"
  printf '# %s — project knowledge (carried over on Crewforth adoption)\n\n' "$b"
  printf '> Draft generated from your original `%s` agent; Crewforth'"'"'s `crew-%s` applies this skill. Refine it to the domain "how" worth keeping.\n\n' "$b" "$b"
  printf '%s\n' "$body"
}

h1m 'crewforth adopt · Stage 1 — DETECTION (read-only; nothing changes)'
subm 'Reads the existing project, produces a smart suggestion for the 7 handover decisions. Approval + mutation in the next stage.'

# ========================= [1] ENVIRONMENT =========================
h1m '[1] Environment'
# git context — in a worktree/submodule .git is a FILE (do NOT use [ -d .git ]; red-team hole #6)
IS_GIT=0; GITTOP=""; GITKIND="no git — 'git init' required"
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  IS_GIT=1; GITTOP="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
  if [ -f "$GITTOP/.git" ]; then GITKIND="worktree/submodule (.git file)"; else GITKIND="normal repo"; fi
fi
rowm 'git' "$GITKIND"   # every GITKIND value is a literal with its own table row

# existing hook system (decision #5 — single-hooksPath clash with husky/lefthook)
HOOKSYS="none"; SHIM_CHAIN=""
CURHP="$(git config --get core.hooksPath 2>/dev/null || true)"
case "$CURHP" in
  "") : ;;
  .claude/hooks) HOOKSYS="Crewforth (already armed)"; CURHP="" ;;   # kit's OWN path — not a foreign chain (re-adopt must not shim itself)
  .claude/git-shim)
    # Crewforth's shim, from an earlier run: git is pointed at it, and IT holds the project's own chain. That chain
    # is read back from the shim, or the next lines would see "no chain" and point git straight at .claude/hooks:
    # measured, the second update of a project with core.hooksPath=myhooks left its own pre-commit never running
    # again, with nothing said. (A project with .husky was found again by its directory; one with any other
    # directory was not.)
    HOOKSYS="Crewforth (already armed)"; CURHP=""
    for _sf in .claude/git-shim/pre-commit .claude/git-shim/commit-msg; do
      [ -f "$_sf" ] || continue
      while IFS= read -r _sl || [ -n "$_sl" ]; do
        _sl="${_sl%$'\r'}"
        case "$_sl" in 'P="'*'/$H"') _sl="${_sl#P=\"}"; _sl="${_sl%/\$H\"}"; _sl="${_sl#\$ROOT/}"
          case "$_sl" in ''|.claude/hooks|.claude/git-shim) ;; *) SHIM_CHAIN="$_sl" ;; esac ;;
        esac
      done < "$_sf"
      [ -n "$SHIM_CHAIN" ] && break
    done
    [ -n "$SHIM_CHAIN" ] && HOOKSYS="core.hooksPath=$SHIM_CHAIN" ;;
  *) HOOKSYS="core.hooksPath=$CURHP" ;;
esac
[ -d .husky ] && HOOKSYS="husky (.husky/)"
{ [ -f lefthook.yml ] || [ -f .lefthook.yml ]; } && HOOKSYS="lefthook"
[ -f .pre-commit-config.yaml ] && HOOKSYS="pre-commit framework"
# A core.hooksPath value is DATA (a Windows one carries backslashes, which a printf format would expand: `\t`, `\n`),
# so it goes in as a plain value; only the fixed names are table keys.
case "$HOOKSYS" in core.hooksPath=*) rowv 'git hook system' "$HOOKSYS" ;; *) rowm 'git hook system' "$HOOKSYS" ;; esac

# stack hint (context only — it selects nothing since 3.0; the backend-architecture skill resolves the stack).
# Look PAST the root: a .NET solution commonly lives in ./backend, ./src, ./server, and a root-only
# `ls ./*.sln` reported "unknown" for exactly those layouts. Search a few levels deep, skipping build/vendor dirs.
STACK="unknown"
# PRUNE, don't filter. The old form walked bin/obj/node_modules in full and threw the results away afterwards —
# on a real .NET repo that is tens of thousands of directory entries, and on Windows every one of them is a
# Defender-scanned syscall. Pruning stops the descent instead of discarding its output.
PRUNE_DIRS=' ( -name bin -o -name obj -o -name node_modules -o -name .git -o -name .vs -o -name packages ) -prune -o '
# shellcheck disable=SC2086
DOTNET_HIT="$(find . -maxdepth 3 $PRUNE_DIRS \( -name '*.sln*' -o -name '*.csproj' \) -print 2>/dev/null | head -1)"
if [ -n "$DOTNET_HIT" ]; then STACK=".NET"
elif [ -f package.json ]; then STACK="Node/JS"
elif [ -f go.mod ]; then STACK="Go"
elif [ -f pyproject.toml ] || [ -f requirements.txt ]; then STACK="Python"; fi
_mt "$STACK"; rowv 'stack hint' "$_M"

# ================= [2] EXISTING AGENTIC SETUP =================
h1m '[2] Existing agentic setup (accumulated work to inherit)'
HAS_CLAUDE=0; [ -d .claude ] && HAS_CLAUDE=1
# count only the PROJECT's own agents/skills — exclude the kit's crew- agents and kit skills left by a prior adopt
# A 2.x install still has the kit's components under their old <x>-csk names (moved further down); they are the
# kit's, not the project's, so they are left out of both counts. The names come from the payload, like the move.
KIT_OLD=" "; for kf in "$SRC"/agents/crew-*.md "$SRC"/skills/crew-*/; do kf="${kf%/}"; kf="${kf##*/}"; kf="${kf%.md}"; KIT_OLD="$KIT_OLD${kf#crew-}-csk "; done
N_PAGENTS=0
if [ -d .claude/agents ]; then
  while IFS= read -r f; do f="${f##*/}"; f="${f%.md}"; case "$KIT_OLD" in *" $f "*) ;; *) N_PAGENTS=$((N_PAGENTS+1)) ;; esac
  done < <(find .claude/agents -name '*.md' ! -name 'crew-*.md' 2>/dev/null)
fi
N_PSKILLS=0
if [ -d .claude/skills ]; then
  # `basename $(dirname …)` per skill is two spawns × every installed skill, for a number printed once. Parameter
  # expansion does the same slicing with none.
  while IFS= read -r f; do d="${f%/SKILL.md}"; d="${d##*/}"
    [ -d "$SRC/skills/$d" ] || case "$KIT_OLD" in *" $d "*) ;; *) N_PSKILLS=$((N_PSKILLS+1)) ;; esac
  done < <(find .claude/skills -name 'SKILL.md' 2>/dev/null)
fi
# Same-domain agent overlap: a PROJECT agent whose base name matches a kit crew- agent (e.g. backend-expert vs
# crew-backend-expert). The two describe the same job, so the router has to pick between them — plain coexist
# leaves that ambiguous and the project's older agent tends to win, which defeats installing the kit. Collect
# the overlaps so the handover can RESOLVE them, not merely note them.
COLLIDE=""
if [ -d .claude/agents ]; then
  for kf in "$SRC"/agents/crew-*.md; do b="${kf##*/}"; b="${b%.md}"; b="${b#crew-}"; [ -f ".claude/agents/$b.md" ] && COLLIDE="$COLLIDE $b"; done
fi
COLLIDE="${COLLIDE# }"; N_COLLIDE=0; [ -n "$COLLIDE" ] && N_COLLIDE="$(printf '%s\n' $COLLIDE | wc -l | tr -d ' ')"
HAS_MD=0; [ -f CLAUDE.md ] && HAS_MD=1
HAS_SETTINGS=0; [ -f .claude/settings.json ] && HAS_SETTINGS=1
# already-adopted fingerprint: did a PRIOR adopt/kit install run here? -> REFRESH semantics, not a fresh handover
KIT_PRESENT=0; KIT_VER=""
{ [ -f .claude/DISCIPLINE.md ] || [ -d .claude/git-shim ] || ls .claude/agents/crew-*.md >/dev/null 2>&1 || [ -f .claude/VERSION ]; } && KIT_PRESENT=1
# A 2.x install, by the kit's OWN old names only: a project agent that merely ends in -csk (my-helper-csk.md) must
# not make a never-installed project look installed — that turns on the force-refresh and overwrites its files.
if [ "$KIT_PRESENT" = 0 ]; then for n in $KIT_OLD; do [ -f ".claude/agents/$n.md" ] && { KIT_PRESENT=1; break; }; done; fi
[ -f .claude/VERSION ] && KIT_VER="$(head -1 .claude/VERSION 2>/dev/null)"
# Backend pattern of the existing install. Since 3.0 there is ONE shape (generic) and this only answers a
# migration question: was this a pre-3.0 .NET install? If so its pattern skill stays, as the project's own.
# LEGACY_PROFILE is a pre-2.0 leftover of the same kind: it selects nothing, it only drives a notice.
LEGACY_PROFILE="$(kit_conf_get profile)"; KIT_STACK="$(kit_conf_get stack)"; KIT_INSTALLER="$(kit_conf_get installer)"
# No kit.conf means the project predates it (v1.0.x). Recover the pattern from the files themselves.
INFERRED=0
{ [ "$KIT_PRESENT" = 1 ] && [ -z "$KIT_STACK" ]; } && kit_infer_shape
# LEGACY_DOTNET: recorded dotnet, or no record at all while a pattern skill sits on disk. Either way the kit
# writes stack=generic from here on and leaves the skill where it is (see the 3.0 migration further down).
# Only for a project the KIT was on: a fresh adopt of a repo that ships its own pattern skill is not a migration,
# and telling it "the kit no longer ships" a skill it never got from the kit would be false.
LEGACY_DOTNET=0
if [ "$KIT_PRESENT" = 1 ] && [ "$KIT_STACK" = dotnet ]; then LEGACY_DOTNET=1; fi
if [ "$HAS_CLAUDE" = 1 ]; then rowm '.claude/' 'present — %s project agents · %s project skills' "$N_PAGENTS" "$N_PSKILLS"
else rowm '.claude/' 'none'; fi
if [ "$HAS_MD" = 1 ]; then _v=present; else _v=none; fi;       rowm 'CLAUDE.md' "$_v"
if [ "$HAS_SETTINGS" = 1 ]; then _v=present; else _v=none; fi; rowm 'settings.json' "$_v"
[ "$KIT_PRESENT" = 1 ] && { _mt 'already adopted%s — this run REFRESHES Crewforth files, project untouched' "${KIT_VER:+ (v$KIT_VER)}"
                            rowv 'Crewforth status' "${YE}$_M${R}"; }
if [ "$LEGACY_DOTNET" = 1 ]; then
  if [ "$INFERRED" = 1 ]; then _k='inferred pattern'; else _k='recorded pattern'; fi
  rowm "$_k" 'stack=dotnet — 3.0 records generic; the pattern skill stays as a project skill'
elif [ -n "$KIT_STACK" ]; then
  if [ "$INFERRED" = 1 ]; then
    _mt '(no kit.conf — read back from the installed files)'
    rowm 'inferred pattern' 'stack=%s %s' "$KIT_STACK" "${YE}$_M${R}"
  else
    rowm 'recorded pattern' 'stack=%s · via %s' "$KIT_STACK" "${KIT_INSTALLER:-?}"
  fi
fi
[ -n "$LEGACY_PROFILE" ] && { _mt '— profile pruning was removed in 2.0; this refresh completes the install'
                              rowv 'pre-2.0 profile' "${YE}profile=${LEGACY_PROFILE}${R} ${D}$_M${R}"; }

# tracked in git? (decision #4 — share/hide)
TRACKED=0
if [ "$IS_GIT" = 1 ]; then
  git ls-files --error-unmatch CLAUDE.md >/dev/null 2>&1 && TRACKED=1
  { [ "$HAS_CLAUDE" = 1 ] && [ -n "$(git ls-files .claude 2>/dev/null | head -1)" ]; } && TRACKED=1
fi
if [ "$TRACKED" = 1 ]; then _v='YES — shared with the team'; else _v='no/untracked'; fi
# Already ignored? Then "share" is not a real option without the user undoing their own rule, and recommending it
# ended with "#4 share -> … NOT shared" (RC-1 rehearsal). Asked of git, like the stage step below asks it.
# The question names a path INSIDE .claude: a fresh adopt has no .claude yet, and a `.claude/` rule only matches a
# directory git can see — asked about the bare name it answered "not ignored" (measured). An inner path's leading
# components are directories to git, so both `.claude/` and `.claude` rules answer.
IGN=0; [ "$IS_GIT" = 1 ] && [ "$TRACKED" != 1 ] && git check-ignore -q .claude/settings.json 2>/dev/null && IGN=1
rowm '.claude/CLAUDE.md in git' "$_v"

# Supply-chain scan (advisory, read-only): the project's OWN (non-crew) skills/agents may have been pulled from an
# untrusted source. Scan them for red flags (curl|bash, prompt-injection directives, credential exfil) before the
# kit starts coexisting with them. Heuristic; it NEVER blocks — it surfaces, the user judges.
if { [ "$N_PAGENTS" != 0 ] || [ "$N_PSKILLS" != 0 ]; } && [ -f "$SRC/eval/scan-skill.sh" ]; then
  SCANOUT="$(bash "$SRC/eval/scan-skill.sh" .claude 2>/dev/null)"
  if printf '%s' "$SCANOUT" | grep -qE 'DANGER|REVIEW'; then
    warnm 'supply-chain scan flagged existing project skills/agents (advisory — review before trusting them):'
    printf '%s\n' "$SCANOUT" | grep -E 'DANGER|REVIEW' | sed 's/^/    /'
    _mt 'full report after install: %s  (Bash tool, not PowerShell; heuristic — a security skill can score low by design)' 'bash .claude/eval/scan-skill.sh .claude'
    sub "    $_M"
  else
    rowm 'supply-chain scan' 'existing project skills/agents look clean (no red flags)'
  fi
fi

# co-author/sign-off convention (decision #3)
COAUTHOR=0
[ "$IS_GIT" = 1 ] && git log -80 --format='%b' 2>/dev/null | grep -qiE 'Co-Authored[-]By|Signed-off-by' && COAUTHOR=1  # [-] : not a contiguous literal in source (trace hook)

# off-repo hint (decision #7 — decisions may live in chat/on the web)
OFFREPO=0; { [ "$HAS_CLAUDE" = 0 ] && [ "$HAS_MD" = 0 ]; } && OFFREPO=1

# ===================== [3] SMART SUGGESTION ======================
h1m '[3] 7 handover decisions — SMART SUGGESTION'
subm 'format:  decision  ->  SUGGESTED  ->  rationale   (you can review and override all of them in the next stage)'
if [ "$N_COLLIDE" != 0 ]; then
  propm '1 Role overlap' 'Crewforth takes over' '%s project agent(s) cover the SAME job as a Crewforth agent (%s) — routing is ambiguous; Crewforth wins, yours preserved' "$N_COLLIDE" "$COLLIDE"
elif [ "$N_PAGENTS" != 0 ]; then
  propm '1 Role clash' 'keep (coexist)' '%s project agents, none overlap a Crewforth role; thanks to the crew- prefix they live side by side' "$N_PAGENTS"
else
  propm '1 Role clash' 'none' 'no custom agents found in the project'
fi
propm '2 Precedence' 'project wins (fixed)' "on conflict the project's rules win; in DISCIPLINE.md §4 they can only tighten, never loosen (the one exception: the §4.1 trace allowlist you choose at adoption); Crewforth fills gaps (not overridable)"
if [ "$COAUTHOR" = 1 ]; then
  propm '3 Trace gate' 'loosen (.trace-allowlist)' 'co-author/sign-off present in git log — may be a convention'
else
  propm '3 Trace gate' 'keep' 'no co-author/sign-off convention seen'
fi
if [ "$TRACKED" = 1 ]; then
  propm '4 Share/hide' 'share' '.claude/CLAUDE.md is tracked — keep sharing with the team'
elif [ "$IGN" = 1 ]; then
  propm '4 Share/hide' 'hide' '.claude is already gitignored in this repo — Crewforth stays local (pick share and un-ignore it to share)'
else
  propm '4 Share/hide' 'share' 'untracked; Crewforth files are shared by default — pick hide to keep them local'
fi
if [ "$HOOKSYS" = "none" ]; then
  propm '5 Git hooks' 'install directly' 'no existing hook system'
else
  case "$HOOKSYS" in core.hooksPath=*) _M="$HOOKSYS" ;; *) _mt "$HOOKSYS" ;; esac   # a path is data, a name is a key
  propm '5 Git hooks' 'SHIM (bridge)' 'existing %s present — let both run' "$_M"
fi
propm '6 Brownfield DoD' 'baseline+regression' 'existing code debt unknown; absolute 0/0/0/0 is risky'
if [ "$OFFREPO" = 1 ]; then
  warnm '7 Off-repo: no local .claude/CLAUDE.md — decisions may live in chat/on the web; there is context I CANNOT SEE.'
  propm '  -> suggestion' 'you transfer' "in the mutation stage 'paste if any' is asked; goes into HANDOVER.md"
else
  propm '7 Off-repo' 'local + ask' 'some decisions are in files; still may be in-chat (asked during the stage)'
fi

# ============ COMPILE DECISIONS + OVERRIDE (Stage B) ============
DEC1="$([ "$N_PAGENTS" != 0 ] && echo keep || echo none)"
DEC2="project"   # precedence is FIXED to project-wins (not overridable — reflected in the @import comment)
DEC3="$([ "$COAUTHOR" = 1 ] && echo loosen || echo keep)"
DEC4="$([ "$TRACKED" = 1 ] && echo share || { [ "$IGN" = 1 ] && echo hide || echo kit-default; })"
DEC6="baseline"
DEC7="$([ "$OFFREPO" = 1 ] && echo transfer || echo local)"
# normalize display defaults to a real, offered token
[ "$DEC1" = none ] && DEC1=keep
[ "$DEC4" = kit-default ] && DEC4=share
if [ -t 0 ]; then
  h1m 'Review the decisions'
  # ask_dec: echoes the chosen value to STDOUT; ALL prompts/errors go to STDERR so $(...) captures only the value.
  # $1 is the English label (translated here); the typed tokens $2/$3 stay English — they are what the user types.
  ask_dec(){ local label a="$2" b="$3" cur="$4" v fa fb; fa="${a:0:1}"; fb="${b:0:1}"; _mt "$1"; label="$_M"
    while :; do
      _mt '[%s/%s] (current: %s, ENTER=keep): ' "$a" "$b" "${B}$cur${R}"
      printf '  %s%s%s %s' "$B" "$label" "$R" "$_M" >&2
      read -r v || v=""
      case "$v" in
        "")         echo "$cur"; return ;;
        "$a"|"$fa") echo "$a";   return ;;
        "$b"|"$fb") echo "$b";   return ;;
        *) _mt 'type "%s" or "%s" (or ENTER to keep "%s")' "$a" "$b" "$cur"
           printf '     %s! %s%s\n' "$YE" "$_M" "$R" >&2 ;;
      esac
    done; }
  if ask_yes 'Accept all smart suggestions?'; then
    subm 'All smart suggestions accepted.'
  else
    subm 'Reviewing each decision. ENTER keeps the current value. (#1 overlap and #2/#5 are handled separately below.)'
    DEC3="$(ask_dec '#3 Trace gate'     loosen   keep     "$DEC3")"
    DEC4="$(ask_dec '#4 Share/hide'     share    hide     "$DEC4")"
    DEC6="$(ask_dec '#6 Brownfield DoD' baseline absolute "$DEC6")"
    DEC7="$(ask_dec '#7 Off-repo'       transfer skip     "$DEC7")"
  fi
  say 'Final: #3=%s #4=%s #6=%s #7=%s  (#2 project-wins, #5 SHIM — fixed)' "$DEC3" "$DEC4" "$DEC6" "$DEC7"
else
  subm '(non-interactive: smart defaults accepted)'
fi

# --- Backend stack: one shape since 3.0 ----------------------------------------------------------------------
# The fresh-adopt .NET question and the stale-generic correction are gone with the .NET install path: there is
# nothing left to choose here. The stack is resolved per project by the backend-architecture skill and recorded
# in CLAUDE.md ## Stack. CSK_CORRECT_STACK is read only to say it no longer does anything — an automation that
# still sets it deserves to hear that, not a silent no-op.
KIT_STACK=generic
[ "${CSK_CORRECT_STACK:-0}" = 1 ] && say 'CSK_CORRECT_STACK has no effect since 3.0 — there is one backend shape; the stack lives in CLAUDE.md ## Stack.'

# --- Role overlap (#1): resolve same-domain agent collisions ---------------------------------------------
# When a project agent and a kit crew- agent cover the same job, "coexist" leaves routing ambiguous. Offer to
# resolve it. takeover = kit wins (your agent preserved, moved out of the routing pool); keepmine = your agent
# wins (the kit's overlapping crew- is not installed); coexist = keep both (documented). Non-interactive -> takeover
# (you ran adopt to get the kit's agents). The chosen mode is APPLIED on the handover branch in Stage 2.
COLLIDE_MODE=coexist
if [ "$N_COLLIDE" != 0 ]; then
  h1m 'Role overlap — project & Crewforth both cover: %s' "$COLLIDE"
  subm "Two agents for one job = the router picks one, usually your older agent — so Crewforth's would sit idle."
  # the first word of each line is the token the user types, so it stays English and outside the message
  _mt "Crewforth's crew- agents win; each old agent's domain is imported to a draft skill (skills/<name>-local), original backed up"; sub "  takeover  $_M"
  _mt "your agents win; Crewforth's overlapping crew- agents are not installed";                                                 sub "  keepmine  $_M"
  _mt 'keep both (routing stays ambiguous; only documented in HANDOVER)';                                                     sub "  coexist   $_M"
  COLLIDE_MODE=takeover
  if [ -t 0 ] && [ "${ASSUME_YES:-0}" != 1 ]; then   # --yes keeps the documented non-interactive default (takeover)
    while :; do
      _mt 'owner'; printf '  %s%s%s [takeover/keepmine/coexist] (ENTER=takeover): ' "$B" "$_M" "$R"
      read -r _v || _v=""
      case "$_v" in ""|t|takeover) COLLIDE_MODE=takeover; break ;; k|keepmine) COLLIDE_MODE=keepmine; break ;; c|coexist) COLLIDE_MODE=coexist; break ;;
        *) _mt 'type takeover, keepmine or coexist'; printf '     %s! %s%s\n' "$YE" "$_M" "$R" >&2 ;; esac
    done
  fi
  say 'overlap -> %s' "$COLLIDE_MODE"
fi
# #1 display/HANDOVER value reflects what actually happens.
case "$COLLIDE_MODE" in
  takeover) DEC1=takeover ;; keepmine) DEC1=keepmine ;;
  *) DEC1="$([ "$N_PAGENTS" != 0 ] && echo keep || echo none)" ;;
esac

# A non-interactive REFRESH of an existing kit install is low-risk — it rewrites only kit-owned files and the change
# is staged/reversible — so it applies by default; this is what lets /crew-update self-heal without any flag. A first
# adopt (KIT_PRESENT=0, a larger brownfield change) still requires an explicit --yes when there is no TTY to ask.
if [ ! -t 0 ] && [ "$KIT_PRESENT" = 1 ]; then ASSUME_YES=1; fi

# ================= [STAGE 2] HANDOVER BRANCH + COEXIST =================
h1m 'Stage 2 — apply Crewforth (coexist)'
if [ "$IS_GIT" != 1 ]; then
  warnm 'no git repo — cannot apply safely. First:  %s  (then run again).' 'git init && git add -A && git commit -m init'
  exit 0
fi

# --- Branch decision (B5): where does this land? A flag wins; otherwise a smart default. ---
# A new branch isolates a big first change so the main line stays clean until you review. But on a routine UPDATE
# of a project whose .claude/ is gitignored, a forced new branch is empty and pointless — the refresh lands on disk
# with no tracked diff to review, so a branch is pure noise on top of your working branch.
# symbolic-ref, not `rev-parse --abbrev-ref HEAD || echo main`: on a repository with no commit yet rev-parse PRINTS
# "HEAD" and then fails, so the fallback was appended and the prompt named the branch "HEAD<newline>main" (RC-1).
# symbolic-ref names an unborn branch; a detached HEAD falls through to rev-parse and reads "HEAD" as before.
BASE="$(git symbolic-ref --short -q HEAD 2>/dev/null)" || BASE="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
[ -n "$BASE" ] || BASE=main
DEC_BR="$BRANCH_MODE"
if [ -z "$DEC_BR" ]; then
  if   [ "$KIT_PRESENT" != 1 ]; then DEC_BR=new     # first adopt: isolate the change, keep the main line clean
  elif [ "$TRACKED" != 1 ];     then DEC_BR=here    # update + untracked .claude: no tracked diff -> a branch is noise
  elif [ -t 0 ]; then                               # update + tracked: a real diff exists -> prefer new, but ask
    ask_yes "Apply on a NEW review branch? (no = apply on the current branch '%s')" "$BASE" && DEC_BR=new || DEC_BR=here
  else DEC_BR=new; fi                               # non-interactive + tracked: the safe default is a new branch
fi

if [ "$DEC_BR" = here ]; then _mt "the current branch '%s'" "$BASE"; else _mt "a new review branch (off '%s')" "$BASE"; fi
WHERE="$_M"
# Missing tools named before the mutation prompt, not after, while going ahead is still a choice. The settings
# merge is not among them: it is awk and runs the same everywhere. Report-only; never blocks.
[ -f "$SRC/eval/preflight.sh" ] && bash "$SRC/eval/preflight.sh"
if ! ask_yes 'Apply Crewforth onto %s now? (mutation; staged-not-committed, reversible with git)' "$WHERE"; then
  h1m 'Stopped'; subm 'Stayed at Stage 1 — NOTHING CHANGED (read-only).'; exit 0
fi

# BR_HANDOVER_LINE / GEN_WHERE / ADR_BR_STATUS go into HANDOVER.md and the ADR, so they stay English (artefacts).
# ONBRANCH/ACCEPT/DISCARD_LINE are only ever printed to the terminal, so they are translated here.
# A repository with no commit yet has no HEAD to reset to and no branch to delete, so the discard command differs:
# un-stage with `git rm --cached` (the files stay on disk, nothing was committed) and, on a new branch, point HEAD
# back at the original name. Measured on an unborn repository: both leave 0 staged files and HEAD on the base name.
UNBORN=0; git rev-parse --verify -q HEAD >/dev/null 2>&1 || UNBORN=1
if [ "$DEC_BR" = here ]; then
  BR="$BASE"                                          # $BR is referenced downstream; on 'here' it IS the current branch
  say 'applying on the current branch: %s  (no separate branch; staged, HEAD untouched until you commit)' "${B}$BASE${R}"
  BR_HANDOVER_LINE="Applied on the current branch: $BASE (the change set is STAGED-not-committed — review in 'git status' / your editor, then commit; HEAD untouched until you do)."
  GEN_WHERE="current branch $BASE"
  ADR_BR_STATUS="accepted (applied on current branch: $BASE — staged, not committed)"
  _mt 'You are on your current branch %s with everything STAGED but NOT committed.' "$BASE"; ONBRANCH_LINE="$_M"
  _mt 'accept:   %s' "git commit -m 'adopt Crewforth'"; ACCEPT_LINE="$_M"
  if [ "$UNBORN" = 1 ]; then _mt 'discard:  %s   (un-stages everything; nothing was committed)' 'git rm -r -q --cached .'
  else _mt 'discard:  %s   (un-stages everything; nothing was committed)' 'git reset --hard HEAD'; fi; DISCARD_LINE="$_M"
else
  case "$BASE" in kit-adopt-*) warnm 'HEAD is a prior adopt branch (%s) — the review diff will be vs it, not your main line. Consider %s first.' "$BASE" "'git checkout <main>'" ;; esac
  TS="$(date +%Y%m%d-%H%M%S)"; BR="kit-adopt-$TS"
  # Second-resolution timestamp: two adopts within one second would collide and the second checkout would fail.
  # Bump a counter until the name is free (also covers a re-run after a discarded attempt left the branch behind).
  n=2; while git rev-parse --verify -q "refs/heads/$BR" >/dev/null 2>&1; do BR="kit-adopt-$TS-$n"; n=$((n+1)); done
  git checkout -b "$BR" >/dev/null 2>&1 || { _mt "ERROR: could not open branch '%s'." "$BR"; printf '%s\n' "$_M"; exit 1; }
  say 'handover branch: %s  (%s stays clean)' "${B}$BR${R}" "$BASE"
  BR_HANDOVER_LINE="Handover branch: $BR  ($BASE untouched; the change set is STAGED-not-committed — review in your editor / 'git status', then commit)."
  GEN_WHERE="branch $BR"
  ADR_BR_STATUS="accepted (handover branch: $BR)"
  _mt 'You are on branch %s with everything STAGED but NOT committed.' "$BR"; ONBRANCH_LINE="$_M"
  # With no commit yet there is no $BASE to merge into (checkout fails: "pathspec did not match"); the first commit
  # simply becomes the base branch by renaming this one.
  if [ "$UNBORN" = 1 ]; then _mt 'accept:   %s   then:  %s' "git commit -m 'adopt Crewforth'" "git branch -m $BASE"
  else _mt 'accept:   %s   then:  %s' "git commit -m 'adopt Crewforth'" "git checkout $BASE && git merge $BR"; fi; ACCEPT_LINE="$_M"
  if [ "$UNBORN" = 1 ]; then _mt 'discard:  %s' "git rm -r -q --cached . && git symbolic-ref HEAD refs/heads/$BASE"
  else _mt 'discard:  %s' "git reset --hard $BASE && git checkout $BASE && git branch -D $BR"; fi; DISCARD_LINE="$_M"
fi

mkdir -p .claude
# Every adopt installs the full payload; the only thing that varies is the .NET pattern skill below.
EXCL_A=""; EXCL_S=""; EXCL_C=""
# Pre-2.0 migration: that install pruned by profile, so components are MISSING and this refresh restores them.
# The list is derived from a before/after disk diff rather than from a profile→pruned map, because the map
# (profiles.conf) no longer exists — and a diff also reports components added by the version bump itself,
# which is the honest thing to show: it names what actually appeared, not what a table predicts.
MIGRATE_MISSING=""
if [ -n "$LEGACY_PROFILE" ]; then
  for f in "$SRC"/agents/*.md;  do [ -e "$f" ] && [ ! -e ".claude/agents/$(basename "$f")" ] && MIGRATE_MISSING="$MIGRATE_MISSING agents/$(basename "$f")"; done
  for d in "$SRC"/skills/*/;    do [ -d "$d" ] && [ ! -d ".claude/skills/$(basename "$d")" ] && MIGRATE_MISSING="$MIGRATE_MISSING skills/$(basename "$d")"; done
fi
# THE 3.0 MIGRATION. The kit no longer ships cqrs-aop-module, and a project that had it keeps it: from now on it is
# the PROJECT's own pattern skill, which crew-backend-expert applies ahead of backend-architecture. Nothing here
# deletes it, the copy below cannot touch it (the payload no longer carries the name), and the stale sweep
# further down is told to leave it out, because that sweep's advice is an `rm -r` line.
#
# THE RENAME MIGRATION is kept inside it: devarch-module -> cqrs-aop-module. The kit renamed its own skill, so an
# install from before the rename carries the old name. Three measured reasons it is not left to the stale sweep:
#   1. that sweep REPORTS and never deletes, so until the user acts the project would carry two pattern skills
#      competing for every prompt;
#   2. kit-manifest.txt arrived in v1.8.0 and this skill shipped from v1.0.0, so an install not updated since
#      before 1.8.0 has no manifest and the sweep is BLIND to it;
#   3. kit_infer_shape reads the legacy stack from this directory's name.
# Nothing is deleted: the directory is renamed and its content travels with it, so a customised copy survives.
# If BOTH names are already present nothing is moved — the user decides which one is theirs.
# Only on a project the kit was installed on: a repo adopted for the first time may own a `devarch-module` skill of
# its own, and renaming that is not a migration of anything the kit shipped.
if [ "$KIT_PRESENT" = 1 ] && [ -d .claude/skills/devarch-module ]; then
  if [ ! -e .claude/skills/cqrs-aop-module ]; then
    mv .claude/skills/devarch-module .claude/skills/cqrs-aop-module 2>/dev/null \
      && say '.NET pattern skill renamed: devarch-module -> cqrs-aop-module (content kept)'
  else
    say '⚠️  both devarch-module and cqrs-aop-module are present — nothing moved; remove the old one when ready'
  fi
fi
# Whether the updater vouches for cqrs-aop-module is decided AFTER the manifest is written — see "THE PATTERN SKILL'S
# TRUST" below; the notice is printed there with the verdict.
# THE 3.0 NAME MIGRATION: <x>-csk -> crew-<x>, for the KIT'S OWN components only (agents, commands, the code-review
# skill), and only on a project the kit was installed on. Same principle as the devarch-module rename above: move,
# never delete. The names come from the payload, so a project file that merely ends in -csk (my-helper-csk.md) is
# never considered. If both names exist nothing moves — the user decides which one is theirs. The force-refresh just
# below then brings every moved file's content up to 3.0.
LEGACY_MOVED=0; LEGACY_BOTH=""
if [ "$KIT_PRESENT" = 1 ]; then
  for kf in "$SRC"/agents/crew-*.md "$SRC"/skills/crew-*/; do   # skills/ includes the commands since 3.0
    [ -e "$kf" ] || continue
    kf="${kf%/}"; kd="${kf%/*}"; kd="${kd##*/}"; kn="${kf##*/}"; kx=""
    case "$kn" in *.md) kn="${kn%.md}"; kx=".md" ;; esac
    old=".claude/$kd/${kn#crew-}-csk$kx"; new=".claude/$kd/$kn$kx"
    [ -e "$old" ] || continue
    if [ -e "$new" ]; then LEGACY_BOTH="$LEGACY_BOTH $old"
      # 2.x never shipped a crew- name, so that file is the user's: the force-refresh below must not replace it.
      case "$kd" in agents) EXCL_A="$EXCL_A $kn$kx" ;; skills) EXCL_S="$EXCL_S $kn" ;; commands) EXCL_C="$EXCL_C $kn$kx" ;; esac
    else mv "$old" "$new" 2>/dev/null && { LEGACY_MOVED=$((LEGACY_MOVED+1)); say '3.0 rename: %s → %s' "${old#.claude/}" "${new#.claude/}"; }
    fi
  done
fi
# THE 3.0 COMMANDS -> SKILLS MOVE. Claude Code merged custom commands into skills (`.claude/commands/` is "the
# older format"), and a skill and a command of the same name are the same `/name` — the skill wins. So the kit's
# own commands move to `.claude/skills/crew-<x>/SKILL.md`: `/crew-review` stays `/crew-review`. A 2.x `<x>-csk.md`
# goes straight there, with no stop at `commands/crew-<x>.md`. Which skills were commands is read from the payload
# (`metadata: kind: command`), so a command of the user's own in .claude/commands/ is never considered; and when a
# `.claude/skills/crew-<x>/` already exists nothing moves — the user is told and decides, and the refresh leaves
# that directory alone. Moved, never deleted; the force-refresh below then brings each moved file up to 3.0.
CMD_SKILLS="$(grep -l '^  kind: command' "$SRC"/skills/crew-*/SKILL.md 2>/dev/null)"   # one process for all of them
NCMD=0; CMD_BOTH=""; CMD_DUP=""; CMD_LINK=""; CMD_MINE=""
# A .claude/commands that is itself a symlink (a directory shared by several projects) is left alone whole: moving
# files OUT of it would empty it for every other project that points at it.
CMD_DIR_SHARED=0; [ -L .claude/commands ] && CMD_DIR_SHARED=1
for kf in $CMD_SKILLS; do
  NCMD=$((NCMD+1))
  kn="${kf%/SKILL.md}"; kn="${kn##*/}"; kb="${kn#crew-}"
  if [ "$KIT_PRESENT" != 1 ]; then
    # FRESH adopt: a commands/crew-<x>.md here is the PROJECT's own (the kit was never installed). The kit's skill
    # of that name would silently win over it, so the kit's copy is not installed and the user is told.
    [ -f ".claude/commands/$kn.md" ] && { EXCL_S="$EXCL_S $kn"; CMD_MINE="$CMD_MINE $kn"; }
    continue
  fi
  [ "$CMD_DIR_SHARED" = 1 ] && continue
  MOVED_NOW=0
  for old in ".claude/commands/$kn.md" ".claude/commands/$kb-csk.md"; do
    [ -f "$old" ] || [ -L "$old" ] || continue
    if [ -L "$old" ]; then CMD_LINK="$CMD_LINK ${old#.claude/}"; continue; fi   # a moved relative link would dangle
    if [ "$MOVED_NOW" = 1 ]; then CMD_DUP="$CMD_DUP ${old#.claude/}"; continue; fi   # the other kit copy of the same command
    if [ -e ".claude/skills/$kn" ]; then CMD_BOTH="$CMD_BOTH ${old#.claude/}"; EXCL_S="$EXCL_S $kn"
    else mkdir -p ".claude/skills/$kn" && mv "$old" ".claude/skills/$kn/SKILL.md" \
         && { MOVED_NOW=1; say '3.0 commands are skills: %s → %s' "${old#.claude/}" "skills/$kn/SKILL.md"; }
    fi
  done
done
[ -n "$CMD_LINK" ] && warnm '3.0 commands are skills: symlinked command file(s) left as they are:%s — the skill of that name now answers /name' "$CMD_LINK"
[ "$CMD_DIR_SHARED" = 1 ] && [ "$KIT_PRESENT" = 1 ] && warnm '3.0 commands are skills: .claude/commands is a symlink (shared?) — nothing was moved out of it; the skills of those names now answer /name'
[ -n "$CMD_MINE" ] && warnm 'your own command(s) keep their name — the Crewforth skill of the same name was not installed:%s' "$CMD_MINE"
[ "$CMD_DIR_SHARED" = 1 ] || rmdir .claude/commands 2>/dev/null || true   # only when nothing of the user's is left in it
# THE 3.0 BOARD NAMES, in THIS clone only: the board ref, its local settings, its caches, and a `csk-board` remote
# move to the crew names. The remote's 2.x ref is never deleted: while it exists board.sh writes both refs in one
# atomic push, so a 2.x teammate still sees every claim — and the user is told the team should update too.
if [ "$KIT_PRESENT" = 1 ] && _BGD="$(git rev-parse --git-common-dir 2>/dev/null)" && [ -n "$_BGD" ]; then
  _BMV=""; _BHEAD="$(git symbolic-ref -q HEAD 2>/dev/null || true)"
  for _bp in "refs/csk/board refs/crew/board" "refs/heads/csk-board refs/heads/crew-board"; do
    _bo="${_bp% *}"; _bn="${_bp#* }"
    _bs="$(git rev-parse -q --verify "$_bo" 2>/dev/null)" || continue
    [ "$_BHEAD" = "$_bo" ] && continue                                   # never delete the checked-out branch
    git rev-parse -q --verify "$_bn" >/dev/null 2>&1 && continue          # both: board.sh folds the old one in
    git update-ref "$_bn" "$_bs" && git update-ref -d "$_bo" "$_bs" && _BMV="$_BMV $_bn"
  done
  # A board remote made by `init --remote <url>` is ADDED under the crew name, never renamed: a global
  # csk.boardRemote=csk-board (outside this clone, not moved here) must keep finding its remote. And a remote that
  # is already called crew-board is someone else's — then the setting keeps pointing at csk-board.
  _BRM=0
  if _bu="$(git remote get-url csk-board 2>/dev/null)"; then
    if ! git remote get-url crew-board >/dev/null 2>&1; then git remote add crew-board "$_bu" 2>/dev/null && { _BRM=1; _BMV="$_BMV remote:crew-board"; }
    elif [ "$(git remote get-url crew-board 2>/dev/null)" = "$_bu" ]; then _BRM=1; fi
  fi
  for _bk in board boardRef boardRemote; do
    _bv="$(git config --local --get "csk.$_bk" 2>/dev/null)" || continue
    case "$_bv" in refs/csk/board) _bv=refs/crew/board ;; refs/heads/csk-board) _bv=refs/heads/crew-board ;; csk-board) [ "$_BRM" = 1 ] && _bv=crew-board ;; esac
    git config --local --get "crew.$_bk" >/dev/null 2>&1 || git config --local "crew.$_bk" "$_bv"
    git config --local --unset "csk.$_bk" 2>/dev/null; _BMV="$_BMV crew.$_bk"
  done
  for _bf in "$_BGD"/csk-board-*; do
    [ -e "$_bf" ] || continue
    _bt="$_BGD/crew-board-${_bf##*/csk-board-}"
    if [ -e "$_bt" ]; then rm -f "$_bf"; else mv "$_bf" "$_bt"; fi
  done
  if [ -n "$_BMV" ]; then
    say '3.0 board: moved to the crew names in this clone:%s' "$_BMV"
    warnm "3.0 board: the remote's 2.x board ref is not deleted — while it exists, 3.x writes both, so 2.x teammates still see your claims; ask the team to update, then delete the old ref"
  fi
fi
# THE 3.0 AUTO-MODE RULE NAMES: a policy applied by 2.x named its rules "CSK …" in the USER's settings. They become
# "Crewforth …" here, after a backup, and only those three rule names change — every other byte is left as it was.
_AMS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
if [ "$KIT_PRESENT" = 1 ] && [ -f "$_AMS" ] && grep -qE '"CSK (Uncommitted Work Destruction|Gate Tampering|Internal Docs Publication):' "$_AMS" 2>/dev/null; then
  _AMB="$_AMS.crew-bak-$(date +%Y%m%d-%H%M%S)"; _SB0=; sed -b q </dev/null >/dev/null 2>&1 && _SB0=-b
  if cp "$_AMS" "$_AMB" && sed $_SB0 -E 's/"CSK (Uncommitted Work Destruction|Gate Tampering|Internal Docs Publication):/"Crewforth \1:/g' "$_AMB" > "$_AMS.crew-new" \
     && [ -s "$_AMS.crew-new" ] && cat "$_AMS.crew-new" > "$_AMS"; then
    say '3.0 auto-mode: the Crewforth rules in %s are renamed CSK … → Crewforth … (backup: %s)' "$_AMS" "$_AMB"
  fi
  rm -f "$_AMS.crew-new"
fi
# THE LEGACY SWEEP. Components Crewforth shipped in 1.x-2.x and no longer ships (kit/legacy-blobs.tsv, generated from the
# release tags) stay on disk after an update, and for every kind the NAME IS THE INVOCATION: a leftover command lists
# in the / picker, a leftover skill competes for prompts, and the next session's trust gate asks about each skill as
# if the user had brought it in. One that is byte-for-byte a copy Crewforth shipped is MOVED ASIDE to
# .claude/.legacy-backup/<time>/ with a one-line restore; anything else — an edit, an extra file, a symlink — is the
# user's work and stays where it is, named. Nothing is deleted. The rule is "every file is a blob shipped for ITS path",
# not "all from one release": a field install carried vps-deploy with SKILL.md from 2.0-2.6 and references from 1.4.
# cqrs-aop-module / devarch-module are excluded: 3.0 keeps the pattern skill as the project's own (its trust is below).
# Runs after the rename and commands->skills moves, so what reaches it is what they left: a v1 -cck agent, a plain
# v1 command, a -csk copy next to its crew- name. Works without an install manifest — the list is the kit's, not the
# project's.
#
# _untouched_copies <component>...: prints each component (skills/<n>, agents/<n>.md, commands/<n>.md) that is an
# untouched shipped copy. rc 2 = cannot tell (no git, no list). Same hardening as the
# pattern skill's check, which uses it: a symlink or special file anywhere refuses the component (`find -type f` does
# not list one, so a link would be "checked" by checking nothing); zero files is not a match; CR is stripped only when
# every CR ends a line; paths reach awk as data, never through -v. Batched: one find, one git, one awk for all of
# them — per-file hashing was 5 processes a file, which is seconds on Git Bash.
_untouched_copies(){
  local lst="$SRC/legacy-blobs.tsv" NL=$'\n' TB=$'\t' CR=$'\r' c p bad fo f h hl cr crl rows="" i=0
  local live=() fl=() hs=()
  [ -f "$lst" ] && command -v git >/dev/null 2>&1 || return 2
  for c in "$@"; do [ -e ".claude/$c" ] || [ -L ".claude/$c" ] && live+=(".claude/$c"); done   # a link is kept, for find to refuse
  [ "${#live[@]}" -gt 0 ] || return 0
  # A newline, tab or CR in a name would split or bend a line below (git's line reader drops a trailing CR), so it
  # disqualifies its component like a symlink does.
  bad="$(find "${live[@]}" \( ! -type f ! -type d \) -o -name "*$NL*" -o -name "*$TB*" -o -name "*$CR*" 2>/dev/null)"
  for p in "${live[@]}"; do
    case "$NL$bad$NL" in *"$NL$p$NL"*|*"$NL$p/"*) continue ;; esac
    # find's status is read: a subdirectory it cannot enter hides files, and those would travel with the component.
    fo="$(find "$p" -type f 2>/dev/null)" || continue
    while IFS= read -r f; do [ -n "$f" ] && fl+=("$f"); done <<< "$fo"
  done
  [ "${#fl[@]}" -gt 0 ] || return 0
  while IFS= read -r h; do hs+=("$h"); done < <(printf '%s\n' "${fl[@]}" | git hash-object --no-filters --stdin-paths 2>/dev/null)
  # One file git cannot read stops the batch. Then each file is hashed on its own, and one that fails is simply not a
  # match — it refuses its own component, not every component.
  if [ "${#hs[@]}" != "${#fl[@]}" ]; then
    hs=(); for f in "${fl[@]}"; do h="$(git hash-object --no-filters -- "$f" 2>/dev/null)"; hs+=("${h:--}"); done
  fi
  # Only a file that holds a CR pays for the CR-stripped hash (none of the shipped blobs has one).
  local crf; crf="$NL$(grep -l $'\r' -- "${fl[@]}" 2>/dev/null)$NL"
  while [ "$i" -lt "${#fl[@]}" ]; do
    f="${fl[$i]}"; h="${hs[$i]}"; hl="$h"
    case "$crf" in *"$NL$f$NL"*)
      cr="$(tr -dc '\r' < "$f" 2>/dev/null | wc -c | tr -d ' ')"; crl="$(grep -c $'\r$' "$f" 2>/dev/null)"
      [ "$cr" = "${crl:-x}" ] && hl="$(tr -d '\r' < "$f" 2>/dev/null | git hash-object --no-filters --stdin 2>/dev/null)" ;;
    esac
    rows="$rows$f$TB$h$TB${hl:-$h}$NL"; i=$((i+1))
  done
  printf '%s' "$rows" | awk -F'\t' 'FNR == NR { if ($0 !~ /^#/) ok[$2 SUBSEP $3] = 1; next }
    { c = substr($1, 9); split(c, a, "/"); if (a[1] == "skills") c = a[1] "/" a[2]
      n[c]++; if (!((($1 SUBSEP $2) in ok) || (($1 SUBSEP $3) in ok))) bad[c] = 1 }
    END { for (c in n) if (!(c in bad)) print c }' "$lst" - | LC_ALL=C sort
}
LEG_MOVED=""; LEG_KEPT=""; LEG_BK=""; _LNL=$'\n'
if [ "$KIT_PRESENT" = 1 ] && [ -f "$SRC/legacy-blobs.tsv" ]; then
  _lon=""; _lsh=""
  for c in $(awk -F'\t' '!/^#/ && $1 != "skills/cqrs-aop-module" && $1 != "skills/devarch-module" && !s[$1]++ { print $1 }' "$SRC/legacy-blobs.tsv"); do
    [ -e ".claude/$c" ] || [ -L ".claude/$c" ] || continue
    # A symlinked .claude/ or .claude/<kind>/ is likely shared by several projects: moving a file OUT of it would take
    # it from every one of them (the same reason the commands->skills move leaves a linked commands/ alone).
    if [ -L .claude ] || [ -L ".claude/${c%%/*}" ]; then _lsh="$_lsh $c"; continue; fi
    # A 2.x command or skill beside a skills/crew-<x>/ of the user's that has no SKILL.md: the kit's skill is not
    # installed there, so this one is the only thing answering the name — it stays, and "keep one" below says why.
    case "$c" in commands/*-csk.md) _b="${c#commands/}"; _b="${_b%-csk.md}" ;; skills/*-csk) _b="${c#skills/}"; _b="${_b%-csk}" ;; *) _b="" ;; esac
    [ -n "$_b" ] && [ -d ".claude/skills/crew-$_b" ] && [ ! -f ".claude/skills/crew-$_b/SKILL.md" ] && continue
    _lon="$_lon $c"
  done
  [ -n "$_lsh" ] && warnm 'older Crewforth components in a symlinked (shared?) directory are left in place — moving them out would remove them from every project that uses it:%s' "$_lsh"
  if [ -n "$_lon" ]; then
    _lun="$(_untouched_copies $_lon)"; _lrc=$?
    if [ "$_lrc" = 2 ]; then
      LEG_KEPT="$_lon"
      warnm 'older Crewforth components could not be checked against what Crewforth shipped (git or the shipped list is missing) — left in place:%s' "$_lon"
    else
      LEG_BK=".claude/.legacy-backup/$(date +%Y%m%d-%H%M%S)"; _b="$LEG_BK"; i=2
      while [ -e "$_b" ]; do _b="$LEG_BK-$i"; i=$((i+1)); done; LEG_BK="$_b"
      for c in $_lon; do
        case "$_LNL$_lun$_LNL" in *"$_LNL$c$_LNL"*)
          if mkdir -p "$LEG_BK/${c%/*}" 2>/dev/null && mv ".claude/$c" "$LEG_BK/$c" 2>/dev/null; then
            LEG_MOVED="$LEG_MOVED $c"
            # A v1 -cck agent was counted as the project's own (KIT_OLD knows the 2.x names); moved aside, it is neither.
            case "$c" in agents/*) _la="${c#agents/}"; case "$KIT_OLD" in *" ${_la%.md} "*) ;; *) N_PAGENTS=$((N_PAGENTS-1)) ;; esac ;; esac
            continue
          fi ;;
        esac
        LEG_KEPT="$LEG_KEPT $c"
      done
      if [ -n "$LEG_MOVED" ]; then
        # A team that shares .claude/ should not commit the backup by accident; the restore reads the files, not git.
        [ -f .claude/.legacy-backup/.gitignore ] || printf '*\n' > .claude/.legacy-backup/.gitignore 2>/dev/null
        say 'moved aside — each one exactly as an older Crewforth shipped it, and no longer shipped:%s' "$LEG_MOVED"
        say 'to put them back: cp -R %s/. .claude/' "$LEG_BK"
        say '(an unchanged copy put back is moved aside again by the next update — to keep one, change it)'
      else rmdir "$LEG_BK" .claude/.legacy-backup 2>/dev/null || true
      fi
      if [ -n "$LEG_KEPT" ]; then
        warnm 'left in place — installed by an older Crewforth, no longer shipped, and changed since (yours now?):%s' "$LEG_KEPT"
        _mt 'Each still answers its name (a command lists in the / picker, a skill matches prompts). To drop them:'; printf '     %s\n' "$_M"
        printf '       rm -r'; for e in $LEG_KEPT; do printf ' .claude/%s' "$e"; done; echo
      fi
    fi
  fi
fi
[ -n "$LEG_MOVED" ] && [ "$CMD_DIR_SHARED" = 0 ] && { rmdir .claude/commands 2>/dev/null || true; }   # emptied by the sweep
# The "keep one" notices wait for the sweep: a -csk copy it moved aside is no longer one of two. When it moved one,
# the line names BOTH files, so the user reads from one line what went, why, and that their own file was not touched.
_lb=""; for o in $LEGACY_BOTH; do
  if [ -e "$o" ]; then _lb="$_lb $o"; continue; fi
  _lo="${o#.claude/}"; _lx=""; case "$_lo" in *.md) _lx=.md ;; esac; _ln="${_lo%/*}/crew-$(_b="${_lo##*/}"; _b="${_b%.md}"; printf '%s' "${_b%-csk}")$_lx"
  say '%s (an unchanged copy Crewforth shipped) moved aside; your %s was not touched' "$_lo" "$_ln"
done
[ -n "$_lb" ] && warnm '3.0 rename: both the old and the new name exist for:%s — nothing moved; keep one' "$_lb"
_lb=""; for o in $CMD_BOTH; do
  if [ -e ".claude/$o" ]; then _lb="$_lb $o"; continue; fi
  _b="${o##*/}"; _b="${_b%.md}"; say '%s (an unchanged copy Crewforth shipped) moved aside; your %s was not touched' "$o" "skills/crew-${_b%-csk}/"
done
[ -n "$_lb" ] && warnm '3.0 commands are skills: a skill of that name already exists for:%s — nothing moved; keep one' "$_lb"
_lb=""; for o in $CMD_DUP; do
  if [ -e ".claude/$o" ]; then _lb="$_lb $o"; continue; fi
  _b="${o##*/}"; _b="${_b%.md}"; _b="${_b#crew-}"; say '%s (a second, unchanged copy Crewforth shipped) moved aside; %s already answers that command' "$o" "skills/crew-${_b%-csk}/"
done
[ -n "$_lb" ]  && warnm '3.0 commands are skills: an older copy of an already-moved command is left in place:%s — remove it' "$_lb"
# #1 keepmine: your overlapping agents own those roles, so the kit's matching crew- agents are NOT installed.
[ "$COLLIDE_MODE" = keepmine ] && for b in $COLLIDE; do EXCL_A="$EXCL_A crew-$b.md"; done
# kit-owned trees: FORCE-refresh on a re-adopt (KIT_PRESENT) so kit updates land; never-overwrite on a fresh adopt
copy_noclobber "$SRC/agents"   .claude/agents   "$KIT_PRESENT" "$EXCL_A"; A_ADD=$ret_add; A_SKIP=$ret_skip
# The summary counts skills and commands the way the README does — one per skill, a `kind: command` skill as a
# command, an `experimental: true` one as neither. copy_noclobber counts FILES (a skill with references/ is several),
# which is how an update from 2.13.0 once reported "skills +75" for 39 skills. A skill counts as added when the
# copy put it there or refreshed it; one that was excluded, or that a fresh adopt found already present and left
# alone, counts as skipped. The "already present" answer is taken before the copy, with builtins only.
_pre=" "; for kd in .claude/skills/*/; do [ -d "$kd" ] && { kn="${kd%/}"; _pre="$_pre${kn##*/} "; }; done
copy_noclobber "$SRC/skills"   .claude/skills   "$KIT_PRESENT" "$EXCL_S"
S_ADD=0; S_SKIP=0; C_ADD=0; C_SKIP=0
for kd in "$SRC"/skills/*/; do
  [ -f "$kd/SKILL.md" ] || continue; kn="${kd%/}"; kn="${kn##*/}"; _k=0; _e=0; _d=0
  while IFS= read -r _l || [ -n "$_l" ]; do
    _l="${_l%$'\r'}"
    case "$_l" in ---) _d=$((_d+1)); [ "$_d" -ge 2 ] && break ;; "  kind: command") _k=1 ;; "  experimental: true") _e=1 ;; esac
  done < "$kd/SKILL.md"
  [ "$_e" = 1 ] && continue
  _got=1
  case " $EXCL_S " in *" $kn "*) _got=0 ;; esac
  [ "$_got" = 1 ] && [ "$KIT_PRESENT" != 1 ] && case "$_pre" in *" $kn "*) _got=0 ;; esac
  if [ "$_k" = 1 ]; then [ "$_got" = 1 ] && C_ADD=$((C_ADD+1)) || C_SKIP=$((C_SKIP+1))
  else                   [ "$_got" = 1 ] && S_ADD=$((S_ADD+1)) || S_SKIP=$((S_SKIP+1)); fi
done
# Read BEFORE the hooks tree is refreshed: whether §4.2's vendor line is armed right now (see the re-arm below).
# `\r?`: a blocklist that reached this checkout CRLF (autocrlf=true, a Windows editor) still counts as armed —
# a plain -x match read it as disarmed and the refresh switched §4.2 off without a word (measured in review).
VENDOR_ARMED=0; grep -qxE $'DevArchitecture\r?' .claude/hooks/trace-blocklist.txt 2>/dev/null && VENDOR_ARMED=1
copy_noclobber "$SRC/hooks"    .claude/hooks    "$KIT_PRESENT"; H_ADD=$ret_add; H_SKIP=$ret_skip
copy_noclobber "$SRC/eval"     .claude/eval     "$KIT_PRESENT"; E_ADD=$ret_add; E_SKIP=$ret_skip
# The Studio panel. This is the line that answers "I updated and `/crew-studio` says the panel
# is missing": with KIT_PRESENT=1 it is a force-refresh, so a project that already has the kit
# gets the panel on its next update.
# NOT passed the $4 exclusion argument even though `test` would match it correctly — a non-empty
# exclraw disables the force=1 fast path above and drops into the per-file loop, i.e. 25 process
# spawns on Git Bash instead of one `cp -R` plus one `rm`. That fast path exists because a
# per-file refresh was measured at 6m43s. On a FRESH adopt (KIT_PRESENT=0) copy_noclobber never
# overwrites, so a project that somehow owns .claude/studio keeps its own files.
copy_noclobber "$SRC/studio"   .claude/studio   "$KIT_PRESENT"; T_ADD=$ret_add; T_SKIP=$ret_skip
# test/ reads the REPO (root package.json, the payload beside it); from .claude/studio those
# resolve to a tree that has neither, so shipping it would be a gate red in every project. The
# installed diagnostic is `node .claude/studio/server/index.js --selftest`. The suite itself
# lives in packaging/studio-test/, outside the payload, so nothing has to be deleted here and
# the count is simply what landed.
chmod +x .claude/studio/server/hooks/*.sh 2>/dev/null || true
# THE FLAT FILES CREWFORTH OWNS — AGENT_TEMPLATE.md, README.md and (in stage 3) DISCIPLINE.md. Each states the kit's own
# contract, so it is rewritten on every run: `/crew-skill` opens with `Read .claude/AGENT_TEMPLATE.md`, the README
# describes this version, and a stale discipline is worse than none. Until 3.1 two of the three were rewritten with
# no look at what was there, so a copy the user had edited was lost without a word. One rule for the three now:
#   * the same as this version's (line endings aside): written, nothing said about the old one;
#   * a copy an earlier release shipped, untouched — its bytes, or its bytes with CR removed, are an id
#     kit/owned-blobs.tsv holds for that file: refreshed, nothing kept (it is in the release it came from);
#   * anything else is kept first in .claude/.legacy-backup/<time>/ and named, then refreshed: an edit of the user's,
#     or a copy from a release the list does not hold (it holds the final releases below this VERSION, so a patch
#     release made after this one, or a release candidate, is not in it). The line says what is known — "not a copy
#     Crewforth shipped before this version" — and not that somebody edited it. When git or the list is missing
#     nothing can be told, and the copy is kept the same way.
# A copy that cannot be backed up is left as it is.
_owned_bkdir(){  # -> LEG_BK: this run's backup directory (the legacy sweep's when it made one), created; 1 when it cannot be
  local b i=2
  if [ -z "$LEG_BK" ] || [ ! -d "$LEG_BK" ]; then
    LEG_BK=".claude/.legacy-backup/$(date +%Y%m%d-%H%M%S)"; b="$LEG_BK"
    while [ -e "$b" ]; do b="$LEG_BK-$i"; i=$((i+1)); done; LEG_BK="$b"
  fi
  mkdir -p "$LEG_BK" 2>/dev/null || return 1
  # A team that shares .claude/ should not commit the backup by accident.
  [ -f .claude/.legacy-backup/.gitignore ] || printf '*\n' > .claude/.legacy-backup/.gitignore 2>/dev/null
  return 0
}
_owned_shipped(){  # $1 = name -> 0 when .claude/<name> is a copy an earlier release shipped · 1 it is not · 2 cannot tell
  local f=".claude/$1" lst="$SRC/owned-blobs.tsv" h hl cr crl
  [ -f "$lst" ] && command -v git >/dev/null 2>&1 || return 2
  h="$(git hash-object --no-filters -- "$f" 2>/dev/null)" || return 2
  [ -n "$h" ] || return 2
  hl="$h"
  # CR is stripped only when every CR ends a line (a Windows editor, an autocrlf copy); no shipped copy holds one.
  # Whether there is a CR at all is asked with tr, not `grep -q`: Git for Windows' grep 3.0 answers "no" to
  # `grep -q $'\r'` on a CRLF file (measured there: rc 1 on a file where `grep -c` counts 107), and an untouched copy
  # checked out with core.autocrlf=true was then kept as if it had been edited.
  cr="$(tr -dc '\r' < "$f" 2>/dev/null | wc -c | tr -d ' ')"
  if [ "${cr:-0}" != 0 ]; then
    crl="$(grep -c $'\r$' "$f" 2>/dev/null)"
    [ "$cr" = "${crl:-x}" ] && hl="$(tr -d '\r' < "$f" 2>/dev/null | git hash-object --no-filters --stdin 2>/dev/null)"
  fi
  awk -F'\t' -v p="$f" -v a="$h" -v b="${hl:-$h}" '!/^#/ && $1 == p && ($2 == a || $2 == b) { f = 1 } END { exit !f }' "$lst"
}
_owned_refresh(){  # $1 = name under .claude/, $2 = a file holding this version's content -> 0 written · 1 left as it is
  local n="$1" new="$2" cur=".claude/$1" rc
  if [ -f "$cur" ] && ! cmp -s "$new" "$cur" && ! tr -d '\r' < "$cur" 2>/dev/null | cmp -s "$new" -; then
    _owned_shipped "$n"; rc=$?
    if [ "$rc" != 0 ]; then
      if _owned_bkdir && cp "$cur" "$LEG_BK/$n" 2>/dev/null; then
        if [ "$rc" = 2 ]; then say '%s could not be checked against what Crewforth shipped (git or the shipped list is missing) — the old copy is kept in %s/%s' "$n" "$LEG_BK" "$n"
        else say '%s is not a copy Crewforth shipped before this version — it is kept in %s/%s' "$n" "$LEG_BK" "$n"; fi
      else
        warnm '%s is not a copy Crewforth shipped before this version and could not be backed up — left as it is' "$n"
        return 1
      fi
    fi
  fi
  cp "$new" "$cur" 2>/dev/null
}
_owned_refresh AGENT_TEMPLATE.md "$SRC/AGENT_TEMPLATE.md" && say 'AGENT_TEMPLATE.md written (owned by Crewforth; refreshed on every update)'
if [ -f "$SRC/README.md" ]; then
  _owned_refresh README.md "$SRC/README.md" && say 'README.md refreshed (describes this version of Crewforth)'
fi
# Report the migration by what LANDED, not by what was missing: a component the payload lists can still be kept
# out (EXCL_S), and must not be announced as restored when it was.
if [ -n "$MIGRATE_MISSING" ]; then
  MIGRATED=""
  for c in $MIGRATE_MISSING; do [ -e ".claude/$c" ] && MIGRATED="$MIGRATED $c"; done
  if [ -n "$MIGRATED" ]; then
    warnm 'pre-2.0 install (profile=%s): profile pruning was removed — completing the install' "$LEGACY_PROFILE"
    for c in $MIGRATED; do echo "      ${GR}+${R} $c"; done
  else
    say 'pre-2.0 install (profile=%s): nothing was missing — the full set was already present' "$LEGACY_PROFILE"
  fi
fi
# #1 takeover: the kit's crew- owns the role, and the OLD agent's domain is IMPORTED into an active project skill
# (skills/<base>-local) that the kit agent applies — so nothing is lost from the working setup. The agent is then
# removed from the routing pool (Claude Code discovers .claude/agents/*.md, not subdirs) so routing is no longer
# ambiguous, and the raw original is kept under .claude/superseded/agents/ as a backup. The skill is a DRAFT to refine.
N_TAKEN=0
if [ "$COLLIDE_MODE" = takeover ] && [ -n "$COLLIDE" ]; then
  mkdir -p .claude/superseded/agents
  for b in $COLLIDE; do
    af=".claude/agents/$b.md"; [ -f "$af" ] || continue
    if [ -e ".claude/skills/$b-local/SKILL.md" ]; then       # idempotent: a prior takeover already imported it
      say "overlap: %s -> skill '%s' already present (kept); original re-backed up" "$b" "$b-local"
    else
      mkdir -p ".claude/skills/$b-local"
      kit_agent_to_skill "$af" "$b" > ".claude/skills/$b-local/SKILL.md"
      say "overlap: %s -> imported to skill '%s' (draft); Crewforth's %s owns routing" "$b" "$b-local" "crew-$b"
    fi
    cp "$af" ".claude/superseded/agents/$b.md"; rm -f "$af"
    N_TAKEN=$((N_TAKEN+1))
  done
fi
# Both reference sweeps below rewrite user files with sed. MSYS sed (Git Bash) drops the CR of every CRLF line it
# reads, so a CRLF CLAUDE.md came back LF-only in full — not just the rewritten line (measured on Windows: 36 CRs
# → 0; the 2.13 re-adopt kept all 36). GNU sed's -b reads the bytes as they are; BSD sed has no -b and keeps CRs
# anyway, so the flag is used only where it exists.
_SB=; sed -b q </dev/null >/dev/null 2>&1 && _SB=-b
# #1b takeover reference sweep — the rename above orphaned every project reference to the taken-over agents
# ($COLLIDE): "→ backend-expert" in CLAUDE.md, the "detail: docs/AGENTS.md" orchestration doc, etc. This is the ONE
# moment the kit knows the exact old→new map, so it COMPLETES the migration instead of leaving the user to chase
# dangling names. It rewrites each bare old name to its crew- id across CLAUDE.md's reference chain (its @imports +
# docs/…md paths), boundary-safe: `backend-expert` → `crew-backend-expert`, but `crew-backend-expert`/`-local` and
# `backend-expertise` are left intact (no double-suffix). Unreferenced design/audit docs and code comments are NOT
# touched (precise, no false positives). The edit lands on the adopt review branch — visible in the diff, revertible.
if [ "$N_TAKEN" -gt 0 ] && [ -f CLAUDE.md ]; then
  SWEEP="CLAUDE.md"
  for r in $(grep -oE '@?[A-Za-z0-9_./-]+\.md' CLAUDE.md 2>/dev/null | sed 's/^@//' | sort -u); do
    [ -f "$r" ] && [ "$r" != "CLAUDE.md" ] && SWEEP="$SWEEP $r"
  done
  SWEPT=0
  for b in $COLLIDE; do
    for f in $SWEEP; do
      i=0
      while grep -qE "(^|[^A-Za-z-])$b([^A-Za-z-]|$)" "$f" 2>/dev/null && [ "$i" -lt 5 ]; do
        sed $_SB -E "s/(^|[^A-Za-z-])$b([^A-Za-z-]|\$)/\1crew-$b\2/g" "$f" > "$f.kit-sweep" && mv "$f.kit-sweep" "$f"
        i=$((i+1)); SWEPT=$((SWEPT+1))
      done
      [ "$i" -gt 0 ] && say 'ref-sweep: %s → %s in %s' "$b" "crew-$b" "$f"
    done
  done
  [ "$SWEPT" -gt 0 ] && h1m 'Reference sweep: rewrote taken-over agent names to their crew- id across CLAUDE.md + referenced docs' \
                     || say "ref-sweep: no stale references in CLAUDE.md's chain"
fi
# The 3.0 names in CLAUDE.md's reference chain (itself, its @imports, the docs/*.md it names): each OLD kit name —
# backend-expert-csk, /review-csk, @agent-planner-csk — becomes its crew- form. Only kit names, from the payload;
# the boundary is the takeover sweep's (not glued to a longer name, `@agent-` allowed), so the rest of the file is
# left as it was. Runs only when a file mentions -csk at all.
if [ "$KIT_PRESENT" = 1 ] && [ -f CLAUDE.md ] && grep -q -e '-csk' CLAUDE.md $(grep -oE '@?[A-Za-z0-9_./-]+\.md' CLAUDE.md 2>/dev/null | sed 's/^@//' | sort -u) 2>/dev/null; then
  LSWEEP="CLAUDE.md"; PROJ_REAL="$(pwd -P)"
  for r in $(grep -oE '@?[A-Za-z0-9_./-]+\.md' CLAUDE.md 2>/dev/null | sed 's/^@//' | sort -u); do
    r="${r#./}"
    case "$r" in .claude/*) continue ;; esac   # kit-owned (DISCIPLINE.md is rewritten on every update anyway)
    # Inside the project only: an update does not edit files outside it — not by `..`, not by an absolute path, and
    # not through a symlinked directory (docs -> ../shared), which is why the directory is resolved, not the spelling.
    case "/$r/" in */../*) continue ;; esac
    case "$r" in /*) continue ;; esac
    [ -f "$r" ] && [ "$r" != "CLAUDE.md" ] || continue
    case "$r" in */*) rd="$(cd "${r%/*}" 2>/dev/null && pwd -P)" || continue
                      case "$rd/" in "$PROJ_REAL"/*) ;; *) continue ;; esac ;; esac
    LSWEEP="$LSWEEP $r"
  done
  set --
  for kf in "$SRC"/agents/crew-*.md "$SRC"/skills/crew-*/; do   # skills/ includes the commands since 3.0
    [ -e "$kf" ] || continue
    kn="${kf%/}"; kn="${kn##*/}"; kn="${kn%.md}"; kb="${kn#crew-}"
    set -- "$@" -e "s/(^|[^A-Za-z0-9_-]|@agent-)$kb-csk([^A-Za-z0-9_-]|\$)/\1$kn\2/g"
  done
  for f in $LSWEEP; do
    grep -q -e '-csk' "$f" 2>/dev/null || continue
    # A symlink is followed only to a target inside the project (CLAUDE.md → AGENTS.md is common); writing with
    # `cat >` rather than `mv` goes THROUGH the link and keeps the file's mode, instead of replacing it.
    if [ -L "$f" ]; then t="$(readlink "$f")"; case "$t" in /*|*..*) continue ;; esac; fi
    i=0; cp "$f" "$f.kit-before"
    while [ "$i" -lt 5 ]; do
      sed $_SB -E "$@" "$f" > "$f.kit-sweep" || { rm -f "$f.kit-sweep"; break; }   # a failed sed changes nothing
      cmp -s "$f" "$f.kit-sweep" && { rm -f "$f.kit-sweep"; break; }
      cat "$f.kit-sweep" > "$f"; rm -f "$f.kit-sweep"; i=$((i+1))
    done
    cmp -s "$f" "$f.kit-before" || say '3.0 ref-sweep: old 2.x names → crew- names in %s' "$f"
    rm -f "$f.kit-before"
  done
  set --
  # The 2.x template's own sentences say "kit" (the RC-1 rehearsal found three in an updated CLAUDE.md). Each is
  # matched as that template wrote it — the whole header line, and two sentences from their first word — so text the
  # user wrote is never touched; 3.0's template says Crewforth in exactly these places.
  if grep -qE '^<!-- kit discipline · on conflict the project rules BELOW win -->$|^kit-owned and identical in every project|^kit-owned: an update overwrites it' CLAUDE.md 2>/dev/null; then
    cp CLAUDE.md CLAUDE.md.kit-before
    if sed $_SB -E -e 's/^<!-- kit discipline · on conflict the project rules BELOW win -->$/<!-- Crewforth discipline · on conflict the project rules BELOW win -->/' \
         -e 's/^kit-owned (and identical in every project, so it cannot know either\.)/Crewforth-owned \1/' \
         -e 's/^kit-owned(: an update overwrites it, so put )/Crewforth-owned\1/' CLAUDE.md > CLAUDE.md.kit-sweep; then
      cat CLAUDE.md.kit-sweep > CLAUDE.md
    fi
    rm -f CLAUDE.md.kit-sweep
    cmp -s CLAUDE.md CLAUDE.md.kit-before || say '3.0 ref-sweep: the 2.x template wording in %s now says Crewforth' CLAUDE.md
    rm -f CLAUDE.md.kit-before
  fi
fi
# §4.2: an armed vendor line STAYS armed, and nothing else arms it. The blocklist ships `# DevArchitecture`
# commented; before 3.0 only `start.sh --dotnet` uncommented it, and the force-refresh above resets it to a
# comment — so a 2.13 --dotnet project would silently lose the protection on update. The rule is "keep what was
# there", NOT "arm it whenever the pattern skill exists": the updater never armed it before 3.0, so a DevArchitecture
# project installed through adopt.sh still carries the name in its own namespaces, and arming it there made every
# commit that touches that code fail (measured: rc=1, "forbidden expression … 'DevArchitecture'"). The `#test:`
# line travels with it: smoke-test fails any active pattern that has no case.
if [ "$VENDOR_ARMED" = 1 ] && [ -f .claude/hooks/trace-blocklist.txt ] \
   && grep -qx '# DevArchitecture' .claude/hooks/trace-blocklist.txt; then
  awk '/^# DevArchitecture$/ { print "DevArchitecture"; print "#test: ported the handler from DevArchitecture"; next } { print }' \
    .claude/hooks/trace-blocklist.txt > .claude/hooks/trace-blocklist.txt.kit-tmp \
    && mv .claude/hooks/trace-blocklist.txt.kit-tmp .claude/hooks/trace-blocklist.txt \
    && say '§4.2: DevArchitecture stays armed in the trace blocklist (it was armed before this update)'
fi
chmod +x .claude/hooks/*.sh .claude/hooks/pre-commit .claude/hooks/commit-msg 2>/dev/null || true
[ -f "$HERE/VERSION" ] && cp "$HERE/VERSION" .claude/VERSION 2>/dev/null || true   # first-class marker so a future adopt detects a REFRESH
# Stale kit files: names the kit USED to ship and no longer does. `copy_noclobber` only ever adds, so a component
# removed or renamed upstream lives on in the project forever — and that is not cosmetic, because for all three
# kinds the NAME IS THE INVOCATION. A command's filename is what the / picker lists: after 1.11.0 renamed the
# commands, an un-pruned `review.md` sits beside `crew-review.md` and both show up. A SKILL's directory name is
# what the router scores — `route-hint.sh` ranks `.claude/skills/*/SKILL.md` by the trigger phrases inside, so a
# renamed skill left on disk competes with its own replacement for every prompt. Measured on this machine: a
# 2.6.0 install upgraded in place kept `skills/vps-deploy` beside the new `skills/deploy`, both with live
# triggers, and the installer said nothing — it had counted the leftover as one of the PROJECT's own skills.
# That silence is the bug; skills were simply outside the scan below.
#
# They are REPORTED, never deleted: this installer deliberately preserves a pre-existing project file that
# happens to sit under a kit name, so a name in the old manifest is not proof the file is ours. Deleting on that
# assumption would destroy the user's own work; naming it costs them one command.
# .claude/studio is deliberately outside this sweep, and outside kit-manifest.txt with it. The sweep works
# on components whose NAME is the invocation — a leftover command lists in the / picker, a leftover skill
# competes for prompts — and the panel is neither: nothing routes to a file under studio/, so a stale copy
# is dead weight rather than a competing answer. The cost of accepting it is stated rather than hidden: if
# the panel is ever renamed or dropped, an old copy stays in every project until someone deletes it.
if [ -f .claude/kit-manifest.txt ]; then
  STALE=""
  while IFS= read -r entry; do
    case "$entry" in commands/*|agents/*|skills/*) ;; *) continue ;; esac
    [ -e "$SRC/${entry#*/}" ] && continue                       # still shipped under the same folder? keep
    [ -e "$SRC/$entry" ] && continue
    # The 3.0 migration keeps the former .NET pattern skill as the project's own; this sweep's advice is `rm -r`.
    [ "$entry" = skills/cqrs-aop-module ] && continue
    case " $LEG_KEPT " in *" $entry "*) continue ;; esac   # the legacy sweep above has already named it
    [ -e ".claude/$entry" ] && STALE="$STALE $entry"
  done < .claude/kit-manifest.txt
  if [ -n "$STALE" ]; then
    echo
    say '⚠️  installed by an older Crewforth version and no longer shipped:%s' "$STALE"
    _mt 'The name is the invocation: a leftover COMMAND still lists in the / picker (/review twice), and a'; printf '     %s\n' "$_M"
    _mt 'leftover SKILL still matches prompts, so it competes with whatever replaced it.';                   printf '     %s\n' "$_M"
    _mt 'Nothing is deleted for you — one of these may be a file you customised. To drop them all:';         printf '     %s\n' "$_M"
    printf '       rm -r'; for e in $STALE; do printf ' .claude/%s' "$e"; done; echo
  fi
fi

# Install manifest — the names the KIT ships (see start.sh for the full rationale). Generated from the PAYLOAD,
# never from disk: this installer deliberately PRESERVES a pre-existing project file under a kit name, and a
# disk-read manifest would brand that project file "kit-owned". Consumers: the doctor readiness check and the
# skill trust gate.
{ for d in "$SRC"/skills/*/;     do [ -d "$d" ] && echo "skills/$(basename "$d")"; done
  for f in "$SRC"/agents/*.md;   do [ -e "$f" ] && echo "agents/$(basename "$f")"; done
} > .claude/kit-manifest.txt 2>/dev/null || true

# THE PATTERN SKILL'S TRUST. 3.0 keeps cqrs-aop-module as the project's own; the updater vouches for it only when it is
# PROVABLY the copy Crewforth shipped — every file in it hashes (raw, or with CR removed) to a blob id listed for its
# path in legacy-blobs.tsv (cqrs-aop-module 2.12-2.13, and devarch-module 1.0.0-2.11.0 renamed in place), and nothing
# else is in the directory. An edited copy is the user's work, and a skill is executable instruction: it is named,
# not vouched for, and the next session asks. The old test was the recorded stack (`stack=dotnet`), which measured
# the wrong thing: a generic-recorded install carrying the skill got nothing and its first session flagged it
# (field report, reproduced in e2e). Asked only while the skill is still unvetted — the trust gate's own answer,
# read after the manifest exists — so an update does not repeat itself once it is settled.
# Returns 0 shipped · 1 not a shipped copy · 2 cannot tell (no git, no list). The check is the legacy sweep's
# _untouched_copies (hardened in review: a symlink anywhere is refused — a link to arbitrary text used to be "checked"
# by checking nothing, and --trust-one then recorded the target's digest; zero files is not a match; CR is stripped
# only for a CRLF copy; paths never reach awk through -v, which would turn SKIL\114.md into SKILL.md).
_cqrs_shipped(){
  local u rc
  u="$(_untouched_copies skills/cqrs-aop-module)"; rc=$?
  [ "$rc" = 2 ] && return 2
  [ "$u" = skills/cqrs-aop-module ] && [ -f .claude/skills/cqrs-aop-module/SKILL.md ] && [ ! -L .claude/skills/cqrs-aop-module/SKILL.md ]
}
# The gate's answer is read from its output, never through `| grep -q`: grep closing early SIGPIPEs the hook and
# pipefail turns the whole test false — that is how the first version of this block never ran (e2e, C1).
# THE USER'S ANSWER WINS. A recorded answer — trusted-components.txt (yes, any version) or declined-components.txt
# (no) — is never changed here: the updater vouches only when there is none. The RC-1 field run had a user say no,
# and the update vouched anyway, because the no was never written anywhere (skill-trust.sh --decline-one now does).
_pans=""
for _pf in .claude/declined-components.txt .claude/trusted-components.txt; do
  [ -f "$_pf" ] && [ -z "$_pans" ] && grep -qE '[[:space:]]skills/cqrs-aop-module'$'\r''?$' "$_pf" 2>/dev/null && _pans="$_pf"
done
_ptrust=""; [ "$KIT_PRESENT" = 1 ] && [ -f .claude/skills/cqrs-aop-module/SKILL.md ] && [ -z "$_pans" ] \
  && _ptrust="$(CLAUDE_PROJECT_DIR="$PWD" bash .claude/hooks/skill-trust.sh </dev/null 2>/dev/null || true)"
[ "$_pans" = .claude/declined-components.txt ] && [ -f .claude/skills/cqrs-aop-module/SKILL.md ] \
  && say "cqrs-aop-module: you declined to trust it — the update keeps that answer and does not vouch for it."
if grep -qE '(^|[[:space:]])skills/cqrs-aop-module([[:space:]]|$)' <<< "$_ptrust"; then   # exact name: not skills/cqrs-aop-module-x
  _cqrs_shipped; _cqs=$?
  if [ "$_cqs" = 2 ]; then
    say "cqrs-aop-module could not be checked against the copies Crewforth shipped (git or the shipped list is missing) — not vouched for; the next session will ask whether to trust it."
  elif [ "$_cqs" = 0 ]; then
    _tout="$(bash .claude/hooks/skill-trust.sh --trust-one skills/cqrs-aop-module 2>&1)"; _trc=$?
    if [ "$_trc" = 0 ]; then
      say "cqrs-aop-module is now a project skill (Crewforth no longer ships it); backend-expert applies it as your project's pattern."
    else
      say '⚠️  cqrs-aop-module could not be recorded as trusted (skill-trust.sh exit %s: %s) — the next session will ask about it' "$_trc" "${_tout:-no output}"
    fi
  else
    say "cqrs-aop-module is 2.x's .NET pattern, changed since Crewforth shipped it — not vouched for; the next session will ask whether to trust it."
  fi
fi

# stack= is always generic since 3.0; the key is kept for older updaters. Rewritten WITHOUT the pre-2.0
# 'profile=' key: dropping it is what retires the migration notice, so a second refresh stays quiet — and
# writing generic over a former 'dotnet' retires the 3.0 notice the same way.
{ echo "# Written by the Crewforth installer. stack= is always generic since 3.0; the key is kept for older updaters."
  echo "stack=generic"
  echo "installer=${KIT_INSTALLER:-adopt.sh}"
  echo "version=$( [ -f "$HERE/VERSION" ] && head -1 "$HERE/VERSION" || echo unknown )"
  # Only a language somebody chose is recorded (--lang, CREW_LANG, the menu, or the one already recorded). A
  # --yes run with nothing named guesses from the locale, and a guess written down would pin an install that was
  # set up in Turkish to English from its first unattended update on.
  [ "$_LANG_CHOSEN" = 1 ] && echo "lang=$CREW_LANG"
} > .claude/kit.conf
# What changed, for /crew-update to report: the package's own CHANGELOG sections newer than the version this
# project had, and no newer than the one being installed — read from the package on disk, never from the network.
# A fresh adopt has no "before", so it gets no file (and a stale one from an earlier update is removed).
rm -f .claude/.state/whats-new.md 2>/dev/null
_kv="$(printf '%s' "$KIT_VER" | tr -d '\r')"
case "$_kv" in *[!0-9.]*|'') _kv="" ;; [0-9]*.[0-9]*.[0-9]*) ;; *) _kv="" ;; esac   # an odd old version compares as 0.0.0 — every section would look new
if [ "$KIT_PRESENT" = 1 ] && [ -n "$_kv" ] && [ -f "$HERE/CHANGELOG.md" ] && [ -f "$HERE/VERSION" ]; then
  mkdir -p .claude/.state 2>/dev/null
  awk -v from="$_kv" -v to="$(head -1 "$HERE/VERSION" | tr -d '\r')" '
    function cmp(a,b,  x,y,i){ split(a,x,"."); split(b,y,"."); for(i=1;i<=3;i++){ if(x[i]+0>y[i]+0) return 1; if(x[i]+0<y[i]+0) return -1 } return 0 }
    /^## \[/ { v=$0; sub(/^## \[/,"",v); w=v; sub(/\].*/,"",v)
                if (v=="Unreleased") { v=w; sub(/^[^—]*— */,"",v); sub(/[^0-9.].*/,"",v) }
                keep = (v ~ /^[0-9]+\.[0-9]+\.[0-9]+$/ && cmp(v,from)>0 && cmp(v,to)<=0) }
    keep' "$HERE/CHANGELOG.md" | tr -d '\r' > .claude/.state/whats-new.md 2>/dev/null
  [ -s .claude/.state/whats-new.md ] || rm -f .claude/.state/whats-new.md
fi

h1m 'Coexist summary'
# _cnt: "<added>" plus " · N skipped" when something was skipped; result in _v (no subshell, see _mt)
_cnt(){ _v="$1"; if [ "${2:-0}" != 0 ]; then _mt '%s · %s skipped' "$_v" "$2"; _v="$_M"; fi; }
_mt '+%s added' "$A_ADD"; _cnt "$_M" "$A_SKIP"; rowv 'Crewforth agents (crew-)' "$_v"
_cnt "+$S_ADD" "$S_SKIP"; rowv 'skills'   "$_v"
_cnt "+$C_ADD" "$C_SKIP"; rowv 'commands' "$_v"
_cnt "+$H_ADD" "$H_SKIP"; rowv 'hooks'    "$_v"
rowv 'eval' "+$E_ADD"
# The component table is where someone scans for what they got, and it was
# advertising a command that refuses on a machine without node — a row promising
# a capability it had not checked. Qualified from the same preflight query the
# closing line uses, so the version rule keeps one home.
PANEL_CMD="/crew-studio"
bash "$SRC/eval/preflight.sh" --has node 2>/dev/null || { _mt '%s (needs Node 18+)' /crew-studio; PANEL_CMD="$_M"; }
_cnt "+$T_ADD" "${T_SKIP:-0}"; rowv 'studio (panel)' "$_v ${D}— $PANEL_CMD${R}"
_v="$N_PAGENTS"
[ "${N_TAKEN:-0}" != 0 ] && { _mt '%s (%s imported to skills/<name>-local drafts; originals backed up in superseded/)' "$_v" "$N_TAKEN"; _v="$_M"; }
_mt '%s — the rest UNTOUCHED' "$_v"; rowv 'project agents' "$_M"
case "$COLLIDE_MODE" in
  keepmine) [ "$N_COLLIDE" != 0 ] && rowm 'overlap' "keepmine — your agents own: %s (Crewforth's crew- for these NOT installed)" "$COLLIDE" ;;
  coexist)  [ "$N_COLLIDE" != 0 ] && warnm "overlap: %s — BOTH kept; routing between your agent and Crewforth's crew- stays ambiguous" "$COLLIDE" ;;
esac
[ -n "$SKIP_LIST" ] && { warnm "conflicting files (the project's was PRESERVED, Crewforth's skipped):"; for s in $SKIP_LIST; do printf '     %s- %s%s\n' "$D" "$s" "$R"; done; }

# ============ [STAGE 3] DISCIPLINE ACTIVE + SETTINGS MERGE ============
h1m "Stage 3 — activate the Crewforth discipline (without touching the project CLAUDE.md) + settings merge"

# 3a) DISCIPLINE.md: install the discipline half of the payload CLAUDE.md as a separate, FLAT file —
#     everything above the sentinel line. Contains NO @import (leaf) -> no 4-hop trap.
if [ -f "$SRC/CLAUDE.md" ]; then
  kit_require_sentinel "$SRC/CLAUDE.md"
  kit_discipline_of "$SRC/CLAUDE.md" > .claude/DISCIPLINE.md.crew-new
  _owned_refresh DISCIPLINE.md .claude/DISCIPLINE.md.crew-new \
    && say 'DISCIPLINE.md written (Crewforth discipline only; the project template stays out of it)'
  rm -f .claude/DISCIPLINE.md.crew-new
fi

# 3b) single-line @import into the project CLAUDE.md (if present DON'T touch content, only prepend; if absent create).
if [ -f CLAUDE.md ]; then
  if kit_has_import CLAUDE.md; then say 'CLAUDE.md: @import already present (idempotent)'
  elif kit_claude_md_is_legacy CLAUDE.md; then
    # Pre-1.1: the whole discipline sits inline. Blindly prepending the @import would load it TWICE, and leaving
    # it alone means discipline updates never reach this project. Offer the exact swap, with a backup.
    warnm 'CLAUDE.md carries the discipline INLINE (pre-1.1 layout) — discipline updates cannot reach it.'
    BND="$(kit_legacy_boundary CLAUDE.md | head -1)"
    if [ -n "$BND" ] && [ "$BND" -gt 1 ] 2>/dev/null \
       && head -n "$((BND-1))" CLAUDE.md | grep -q '^## Four working principles' \
       && head -n "$((BND-1))" CLAUDE.md | grep -q '^### 4\.5 '; then
      _mt 'the inline block is lines 1-%s; your project section starts at line %s' "$((BND-1))" "$BND"
      printf '     %s%s%s\n' "$D" "$_M" "$R"
      if ask_yes '  Replace that inline block with the single @import line? (a backup is written; this branch is reviewable)'; then
        BK=".claude/CLAUDE.md.pre-kit-${TS:-$(date +%Y%m%d-%H%M%S)}"   # TS is set only when a handover branch was opened
        cp CLAUDE.md "$BK"
        { printf '<!-- Crewforth discipline · on conflict the project rules BELOW win -->\n%s\n\n' "$IMPORT_LINE"
          tail -n +"$BND" CLAUDE.md; } > CLAUDE.md.kit-tmp && mv CLAUDE.md.kit-tmp CLAUDE.md
        say 'CLAUDE.md migrated -> @import + your project section (backup: %s)' "$BK"
      else
        _mt 'Skipped. Discipline updates will NOT reach this project until you migrate.'
        printf '     %s%s%s\n' "$D" "$_M" "$R"
      fi
    else
      _mt 'Project heading not found — migrate by hand: delete everything above it, leave only:  %s' "$IMPORT_LINE"
      printf '     %s%s%s\n' "$D" "$_M" "$R"
    fi
  else
    { printf '<!-- Crewforth discipline · on conflict the project rules BELOW win -->\n%s\n\n' "$IMPORT_LINE"; cat CLAUDE.md; } > CLAUDE.md.kit-tmp && mv CLAUDE.md.kit-tmp CLAUDE.md
    say 'CLAUDE.md: single-line @import prepended (project content untouched)'
  fi
else
  printf '%s\n\n# CLAUDE.md — <PROJECT NAME>\n\n## Project\n<One sentence: what it does, for whom.>\n' "$IMPORT_LINE" > CLAUDE.md
  say 'CLAUDE.md was missing -> @import + project template created'
fi

# 3c) settings.json HOOK-AWARE merge: the kit OWNS its hooks (any command referencing .claude/hooks/), so on update
# kit hook entries are REFRESHED (new events + current timeouts land; stale kit entries drop) while the project's OWN
# custom hooks and permissions are PRESERVED. Non-hook keys deep-merge (project scalar wins, arrays concat+dedup).
# Blind concat would leave a stale duplicate (e.g. an old timeout-10 context-usage hook that then times out).
# RETIRED permission entries are the same problem for rules: concat+dedup never REMOVES, so a rule the kit stopped
# shipping stays in every project that installed it. The four §4.4 `ask` rules are retired because a matching
# ask rule prompts even when a hook returns "allow" (Claude Code permissions doc), which made the hook's
# CLAUDE_GIT_OK pre-authorisation dead: a headless session was refused `git add` and never committed. The hook
# now asks for all four itself. These exact strings are the kit's own; a project that wants them can re-add them.
# ONE path on every OS: the merge is kit/eval/lib/settings-json.awk (POSIX awk; its header holds the
# reader contract and the merge semantics). jq and python3 are absent on a stock Windows Git-Bash, where python3
# is often the Microsoft Store stub (exit 49); the old per-tool arms REPLACED the file there and lost the project's
# own rules. Input that is not a JSON object is refused and left untouched; the output is re-read before use.
KSET="$SRC/settings.json"; PSET=".claude/settings.json"
SET_AWK="$SRC/eval/lib/settings-json.awk"
# Which retired rules the project carries NOW, read before the merge so the removal can be announced by name.
# A string match cannot tell the kit's copy from one the project wrote itself, so the removal is never silent
# and the merge line below does not claim "permissions PRESERVED" when some were not.
SET_NOTE=""; RET_HIT=""; [ -f "$PSET" ] && for _r in 'git add' 'git commit' 'git push' 'git checkout -b'; do
  grep -qF "\"Bash($_r:*)\"" "$PSET" && RET_HIT="$RET_HIT${RET_HIT:+|}$_r"; done
if [ -n "$RET_HIT" ]; then _mt 'custom hooks and every other permission PRESERVED'; else _mt 'custom hooks/permissions PRESERVED'; fi
KEPT="$_M"   # terminal-only (HANDOVER.md words its own line), so translated
SET_FRESH=0
if [ ! -f "$PSET" ]; then
  SET_FRESH=1
  [ -f "$KSET" ] && { cp "$KSET" "$PSET"; say "settings.json: was missing in the project -> Crewforth's was installed"; }
else
  awk -v op=merge -v retired='Bash(git add:*)|Bash(git commit:*)|Bash(git push:*)|Bash(git checkout -b:*)' -f "$SET_AWK" "$KSET" "$PSET" > "$PSET.tmp" 2>/dev/null
  case "$?" in
    0) if [ -s "$PSET.tmp" ] && awk -v op=validate -f "$SET_AWK" "$PSET.tmp" 2>/dev/null; then
         # Written THROUGH the existing file, not swapped in with mv: a symlinked settings.json (a team's shared
         # file) keeps its link and gets the merge, and a 0600 mode survives.
         cat "$PSET.tmp" > "$PSET"; say 'settings.json: hook-aware MERGE (Crewforth hooks refreshed - %s)' "$KEPT"
       else SET_NOTE="merge failed -> project setting PRESERVED (not overwritten)"; fi ;;
    10) SET_NOTE="existing file is INVALID JSON -> merge ABORT (no silent overwrite). Fix it by hand first." ;;
    *) SET_NOTE="merge failed -> project setting PRESERVED (not overwritten)" ;;
  esac
  # SET_NOTE stays English: HANDOVER.md records it verbatim. The terminal gets it translated — each value above
  # is its own table key.
  rm -f "$PSET.tmp"; [ -n "$SET_NOTE" ] && { _mt "$SET_NOTE"; warnm 'settings.json: %s' "$_M"; }
fi
# Announce only what is actually gone: a refused or failed merge leaves the file untouched.
RET_GONE=""; _IFS="$IFS"; IFS='|'; for _r in $RET_HIT; do
  grep -qF "\"Bash($_r:*)\"" "$PSET" 2>/dev/null || RET_GONE="$RET_GONE${RET_GONE:+, }$_r"; done; IFS="$_IFS"
[ -n "$RET_GONE" ] && say 'settings.json: retired §4.4 ask rule(s) REMOVED (%s) — guard-bash.sh now asks for these itself; an ask rule would override its CLAUDE_GIT_OK allow. Re-add one only if your project wants that trade.' "$RET_GONE"
# A refused or failed merge leaves the file as it was, so HANDOVER must not claim a merge that did not run.
if [ -n "$SET_NOTE" ]; then HAND_SET="NOT merged — ${SET_NOTE%.}"
elif [ "$SET_FRESH" = 1 ]; then HAND_SET="Crewforth's settings.json installed (the project had none, so nothing was merged)"
else HAND_SET="hook-aware merge (Crewforth hooks REFRESHED to current — new events + timeouts land; your own custom hooks/permissions PRESERVED${RET_GONE:+, except the retired §4.4 ask rule(s) REMOVED: $RET_GONE — guard-bash.sh asks for these itself})"; fi

# ============ [STAGE 4] GIT-HOOK ARMING (SHIM) + PROOF ============
h1m 'Stage 4 — arm the git gates (SHIM via husky) + PROOF'

# 4a) location of the existing hook chain (the shim calls this too)
ORIG_HOOKS=""
if [ -n "$CURHP" ]; then ORIG_HOOKS="$CURHP"
elif [ -n "$SHIM_CHAIN" ]; then ORIG_HOOKS="$SHIM_CHAIN"   # the chain the shim of an earlier run already runs
elif [ -d .husky ]; then ORIG_HOOKS=".husky"
elif [ -x .git/hooks/pre-commit ] || [ -x .git/hooks/commit-msg ]; then ORIG_HOOKS=".git/hooks"; fi
# never shim the kit onto its OWN hooks (re-adopt) — the shim would exec itself and recurse on every commit
case "$ORIG_HOOKS" in .claude/hooks|.claude/git-shim) ORIG_HOOKS="" ;; esac

if [ -z "$ORIG_HOOKS" ]; then
  git config core.hooksPath .claude/hooks
  say 'core.hooksPath -> .claude/hooks (no existing hook chain)'
else
  mkdir -p .claude/git-shim
  for hk in pre-commit commit-msg; do
    cat > ".claude/git-shim/$hk" <<SHIM
#!/usr/bin/env bash
# kit git-shim: runs the kit hook + the existing project chain IN ORDER (if one fails git stops).
set -e
H="\$(basename "\$0")"
ROOT="\$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
K="\$ROOT/.claude/hooks/\$H"; [ -x "\$K" ] && "\$K" "\$@"
P="\$ROOT/$ORIG_HOOKS/\$H"
if   [ -x "\$P" ]; then "\$P" "\$@"
elif [ -f "\$P" ]; then bash "\$P" "\$@"; fi
exit 0
SHIM
    chmod +x ".claude/git-shim/$hk"
  done
  git config core.hooksPath .claude/git-shim
  say 'SHIM installed -> core.hooksPath=.claude/git-shim (Crewforth + %s run together)' "$ORIG_HOOKS"
fi
[ "$GITKIND" = "worktree/submodule (.git file)" ] && warnm 'worktree/submodule: core.hooksPath may also affect the main checkout (git design).'

# 4b) PROOF — is the kit actually working? (not a claim)
h1m 'Stage 4b — PROOF'
PROOF_OK=1; HP="$(git config --get core.hooksPath 2>/dev/null || echo .claude/hooks)"
# 1) trace-scan git hook: a staged AI trace MUST be BLOCKED (NO real commit; run the hook directly)
# move any allowlist aside so PROOF measures the SCANNER itself, not the project's own exemptions (else a loosened repo fails the proof)
[ -f .trace-allowlist.txt ] && mv .trace-allowlist.txt .trace-allowlist.txt.proofbak 2>/dev/null
printf 'Co-Authored%s: Test <x@y.z>\n' '-By' > .kit-proof.txt   # not contiguous in source (so the trace hook doesn't block itself); full at runtime
# `-f`, and the staging is CHECKED. Without both, a project whose .gitignore happens to cover this probe file
# (`*.txt`, `.kit-*`, anything broad) stages nothing, the scanner reads an empty diff, the hook exits 0 — and
# the proof then accuses a perfectly working gate of letting an AI trace through. Reproduced here: identical
# repos, the only difference a .gitignore line for the probe, and PROOF-1 flipped from BLOCKED to FAILED.
# A proof that can fail for a reason unrelated to what it proves is worse than no proof: it sends the reader
# hunting a gate that is fine. (The allowlist is already handled above by moving it aside.)
if ! git add -f .kit-proof.txt >/dev/null 2>&1 || [ -z "$(git diff --cached --name-only -- .kit-proof.txt 2>/dev/null)" ]; then
  say '~  PROOF-1: skipped — could not stage the probe file (nothing was measured)'
elif bash "$HP/pre-commit" >/tmp/kitproof.$$ 2>&1; then
  warnm 'PROOF-1 FAILED: the trace scan LET THROUGH the AI trace'; PROOF_OK=0
elif grep -qiE 'TRACE-SCANNER|Commit stopped|forbidden' /tmp/kitproof.$$; then
  say 'OK · PROOF-1: staged AI trace BLOCKED by the trace scan'
else say '~  PROOF-1: hook blocked (%s)' "$(head -1 /tmp/kitproof.$$ 2>/dev/null)"; fi
git reset -q .kit-proof.txt 2>/dev/null; rm -f .kit-proof.txt /tmp/kitproof.$$
[ -f .trace-allowlist.txt.proofbak ] && mv .trace-allowlist.txt.proofbak .trace-allowlist.txt 2>/dev/null
# 2) guard-bash git-approval gate: keyless 'git commit' -> block
if printf '{"tool_name":"Bash","tool_input":{"command":"git commit -m x"}}' | bash .claude/hooks/guard-bash.sh >/dev/null 2>&1; then
  warnm 'PROOF-2 FAILED: guard-bash LET THROUGH the keyless commit'; PROOF_OK=0
else say "OK · PROOF-2: guard-bash BLOCKED the keyless 'git commit' (holds in auto/bypass too)"; fi
# 3) can the kit agents + discipline be loaded
NCCK="$(ls .claude/agents/crew-*.md 2>/dev/null | wc -l | tr -d ' ')"
if [ "${NCCK:-0}" -ge 1 ]; then say 'OK · PROOF-3: %s Crewforth agents (crew-) installed + discoverable' "$NCCK"; else warnm 'PROOF-3: no Crewforth agent'; PROOF_OK=0; fi
if [ -s .claude/DISCIPLINE.md ] && grep -qF '@.claude/DISCIPLINE.md' CLAUDE.md; then say 'OK · PROOF-4: DISCIPLINE.md loaded + @import-ed from CLAUDE.md'; else warnm 'PROOF-4: discipline not linked'; PROOF_OK=0; fi
# PROOF-5: a takeover renamed the project's agents to `crew-`, but CLAUDE.md — or an orchestration doc it points to
# (e.g. "detail: docs/AGENTS.md") — may still name the OLD bare agent, which now matches no installed agent, so
# delegation to it silently fails. We follow CLAUDE.md's reference chain (its @imports + docs/…md paths) so the
# pointed-to docs are checked too; the migration cannot safely rewrite hand-authored prose, so we TELL, precisely.
if [ -f CLAUDE.md ] && ls .claude/agents/crew-*.md >/dev/null 2>&1; then
  PULL_AGENTS=" crew-commit-agent crew-session-manager "   # invoked explicitly, not auto-delegated
  SCAN="CLAUDE.md"
  for r in $(grep -oE '@?[A-Za-z0-9_./-]+\.md' CLAUDE.md 2>/dev/null | sed 's/^@//' | sort -u); do
    [ -f "$r" ] && [ "$r" != "CLAUDE.md" ] && SCAN="$SCAN $r"
  done
  # This was agent × document with `sed|head|tr` per agent and `grep|cut|tr|sed` per PAIR — 12 agents × 7 docs ×
  # 4 spawns is ~340 processes to discover, almost always, that nothing is stale. doctor.sh carried the identical
  # loop and was converted to two awk passes in 2.0.1; adopt.sh kept it, which is why an update still crawled on
  # Git Bash. Same conversion, same output (agent order, then file order, comma-joined line numbers).
  STALE=""; STALE_PULL=""
  CREW_AGENT_BASES="$(awk '
    FNR==1 { files[++nf]=FILENAME }
    !got[FILENAME] && /^name:[[:space:]]*/ {
      n=$0; sub(/^name:[[:space:]]*/,"",n); gsub(/[^a-zA-Z0-9-]/,"",n)
      if (n != "") { nm[FILENAME]=n; got[FILENAME]=1 }
    }
    END {
      for (i=1;i<=nf;i++) {
        f=files[i]; n=(f in nm) ? nm[f] : ""
        if (n=="") { n=f; sub(/\.md$/,"",n); sub(/.*\//,"",n) }
        if (n ~ /^crew-/) { b=n; sub(/^crew-/,"",b); print b "\t" n; print b "-csk\t" n }
      }
    }' .claude/agents/crew-*.md 2>/dev/null)"
  export CREW_AGENT_BASES
  while IFS="$(printf '\t')" read -r base aname f lines; do
    [ -n "$base" ] || continue
    _mt '%s line(s): %s' "$f" "$lines"
    entry="
     ↳ \"$base\" → \"$aname\"  ($_M)"
    case "$PULL_AGENTS" in *" $aname "*) STALE_PULL="$STALE_PULL$entry" ;; *) STALE="$STALE$entry" ;; esac
  done <<EOF
$(awk '
  BEGIN {
    n = split(ENVIRON["CREW_AGENT_BASES"], rows, "\n"); k=0
    for (i=1;i<=n;i++) { if (rows[i]=="") continue; split(rows[i], a, "\t"); k++; base[k]=a[1]; full[k]=a[2] }
    nb=k
  }
  FNR==1 { order[++nf]=FILENAME }
  {
    for (i=1;i<=nb;i++)
      if ($0 ~ ("(^|[^a-zA-Z0-9_-]|@agent-)" base[i] "([^a-zA-Z0-9_-]|\$)"))
        hit[i, FILENAME] = (hit[i, FILENAME]=="" ? FNR : hit[i, FILENAME] "," FNR)
  }
  END {
    for (i=1;i<=nb;i++)
      for (j=1;j<=nf;j++)
        if ((i, order[j]) in hit) print base[i] "\t" full[i] "\t" order[j] "\t" hit[i, order[j]]
  }' $SCAN 2>/dev/null)
EOF
  [ -n "$STALE" ] && warnm 'PROOF-5: CLAUDE.md (or a doc it references) names auto-delegated agent(s) by an old bare id — rename each to its crew- id, else delegation to them silently fails:%s' "$STALE"
  [ -n "$STALE_PULL" ] && warnm 'PROOF-5: CLAUDE.md (or a referenced doc) names pull-only agent(s) by an old bare id (still work; rename for consistency):%s' "$STALE_PULL"
fi
[ "$PROOF_OK" = 1 ] && h1m 'PROOF: Crewforth 100%% ACTIVE — gates armed, agents + discipline loaded' || warnm 'PROOF: some gates could not be verified (see above)'

# ============ [STAGE B] APPLY THE DECISIONS ============
h1m 'Stage B — apply the decisions'
# #3 loosen trace gate -> repo-root .trace-allowlist.txt (co-author/sign-off exempt from the trace scan)
if [ "$DEC3" = loosen ]; then
  { [ -f .trace-allowlist.txt ] && cat .trace-allowlist.txt; printf 'Co-Authored%s\n' '-By'; } | sort -u > .trace-allowlist.txt.t && mv .trace-allowlist.txt.t .trace-allowlist.txt
  say '#3 loosen -> .trace-allowlist.txt (co-author trailer exempt)'
else say '#3 keep -> full trace scan'; fi
# #4 share/hide — the payload is ALWAYS committed to the review branch (so the diff is real + rollback stays clean);
# 'hide' becomes a post-merge follow-up in HANDOVER. (Gitignoring .claude BEFORE the commit would drop it from the
# review diff and leave it untracked after a rollback -> 'project untouched' would be a lie.)
HIDE_NOTE=""
if [ "$DEC4" = hide ] && [ "$IGN" = 1 ]; then
  say '#4 hide -> this repo already ignores .claude — nothing to add; Crewforth stays local'
elif [ "$DEC4" = hide ]; then
  # docs/ belongs in this command for the same reason it belongs in .gitignore: the opt-out has to cover
  # the working documents too, or "keep the kit local" leaves the plans, handovers and threat models behind
  # in the shared repository. The two files the adoption force-added are named explicitly, because they are
  # tracked despite the ignore rule and `git rm --cached docs` alone would not reach them.
  HIDE_NOTE="Keep Crewforth local after merging:  git rm -r --cached .claude CLAUDE.md docs  &&  printf '.claude/\nCLAUDE.md\ndocs/\n' >> .gitignore  &&  git commit -m 'crewforth: keep local'"
  say '#4 hide -> recorded; .claude stays TRACKED on the branch (rollback-safe). Post-merge steps in HANDOVER.'
else
  # `share` is a NO-OP by design: the installer never stages a user's files, it only declines to add a
  # .gitignore entry. Saying "tracked + shared with the team" therefore reported an outcome it had neither
  # produced nor checked — and it was wrong in the repo that noticed, where the project's own .gitignore
  # already covers .claude/ and `git ls-files .claude` returns nothing. Report the state that IS true, and
  # say plainly which part is left to the user.
  if [ "$TRACKED" = 1 ]; then
    say '#4 share -> .claude/CLAUDE.md is tracked; nothing added to .gitignore, so it stays shared'
  elif git check-ignore -q .claude 2>/dev/null; then
    say '#4 share -> nothing added to .gitignore, but this repo ALREADY ignores .claude — the stage step skips it, so it is NOT shared'
  else
    say '#4 share -> nothing added to .gitignore; the stage step below adds .claude — commit it to share it'
  fi
fi
# #1 merge: document (NO automatic risky merge — red-team; merging is a human-approved follow-up)
case "$DEC1" in
  takeover) MERGE_NOTE="takeover: Crewforth's crew- agents own the overlapping roles ($COLLIDE); each old agent's domain was imported to a draft skill (skills/<name>-local) the Crewforth agent applies, and the original backed up under superseded/agents/ — refine the drafts" ;;
  keepmine) MERGE_NOTE="keepmine: your agents own the overlapping roles ($COLLIDE); Crewforth's matching crew- agents were not installed" ;;
  *)        MERGE_NOTE="keep: project + Crewforth agents side by side (no overlaps, or overlaps left to coexist)" ;;
esac
# #7 off-repo transfer: paste from the user (interactive; skipped on non-TTY and under --yes)
OFFREPO_TEXT=""
if [ "$DEC7" = transfer ] && [ -t 0 ] && [ "${ASSUME_YES:-0}" != 1 ]; then
  h1m '#7 off-repo decisions — paste them here'
  subm 'Write the decisions made in chat/on the web but NOT in the repo. When done, an EMPTY line (Enter).'
  while IFS= read -r line; do [ -z "$line" ] && break; OFFREPO_TEXT="$OFFREPO_TEXT
- $line"; done
  [ -n "$OFFREPO_TEXT" ] && say '#7 -> %s lines will go into HANDOVER' "$(printf '%s' "$OFFREPO_TEXT" | grep -c .)" || say '#7 -> empty'
fi

# ============ [STAGE 5] HANDOVER.md + ADR (decisions persist) ============
h1m 'Stage 5 — HANDOVER.md + ADR (handover persists; decisions are not lost)'
mkdir -p docs docs/adr
DATE_H="$(date +%Y-%m-%d)"
# compute the decision values first (avoid inner-quote/command-sub tangle in the heredoc)
case "$DEC1" in takeover) D1='takeover (Crewforth crew- owns overlaps; your agents imported to <name>-local skills, originals in superseded/)';; keepmine) D1='keepmine (your agents own overlaps)';; none) D1='none';; *) D1='keep (coexist)';; esac
D2='project wins'   # precedence is fixed (DEC2 not overridable) — no false 'kit wins' record
D3="$([ "$DEC3" = loosen ] && echo 'loosen (.trace-allowlist written)' || echo 'keep (full)')"
D4="$([ "$DEC4" = hide ] && echo 'hide (gitignore)' || echo 'keep sharing')"
D5="$([ -n "$ORIG_HOOKS" ] && echo "SHIM ($ORIG_HOOKS)" || echo 'direct')"
D6="$([ "$DEC6" = absolute ] && echo 'absolute 0/0/0/0' || echo 'baseline+regression')"
case "$DEC7" in transfer) D7='transferred (below)';; skip) D7='knowingly missing';; *) D7='local + ask';; esac
HOOKDESC="$([ -n "$ORIG_HOOKS" ] && echo "SHIM (Crewforth + $ORIG_HOOKS together)" || echo '.claude/hooks direct')"
if [ -n "${OFFREPO_TEXT:-}" ]; then OFFSEC="$OFFREPO_TEXT"
elif [ "$OFFREPO" = 1 ]; then OFFSEC="> WARNING: no local .claude/CLAUDE.md -> decisions may also be in chat/on the web; the tool COULD NOT SEE them.
<!-- Write off-repo decisions here; move the important ones under docs/adr/. -->"
else OFFSEC="<!-- Write potentially in-chat decisions here; move the important ones under docs/adr/. -->"; fi

# 5a) HANDOVER.md — mechanical fact (verifiable) + human section (NO LLM signature)
cat > docs/HANDOVER.md <<HAND
# Handover Note (HANDOVER) — $DATE_H

> This document records what the tool did MECHANICALLY (verifiable) + marks the HUMAN
> sections you need to fill in. The tool does NOT SIGN off anything as "done".

## What was handed over (mechanical)
- Crewforth agents: $NCCK (crew- namespace; no clash with project agents).
- Project agents: $N_PAGENTS — UNTOUCHED, in place + active (recursive discovery).
- Discipline: .claude/DISCIPLINE.md + @import into the project CLAUDE.md (content untouched).
- settings.json: $HAND_SET.
- Git gates: $HOOKDESC.
- Overlapping roles: $MERGE_NOTE.
- $BR_HANDOVER_LINE

## Decisions made (smart suggestion; review/override in Stage B)
| # | Decision | Value |
|---|---|---|
| 1 | Role clash | $D1 |
| 2 | Precedence | $D2 (axis-by-axis; DISCIPLINE.md §4 tighten-only, except the §4.1 trace allowlist of decision 3) |
| 3 | Trace gate | $D3 |
| 4 | Share/hide | $D4 |
| 5 | Git hook | $D5 |
| 6 | Brownfield DoD | $D6 |
| 7 | Off-repo | $D7 |

## CONFIRM (the tool cannot verify — you check)
- [ ] Are the inherited project rules/agents UP TO DATE? (stale rule = regression)
- [ ] Overlapping roles (project + Crewforth same job): which one to use / merge?
- [ ] Has the staged change set been reviewed (editor's Changes panel / git status) before committing?
${HIDE_NOTE:+- [ ] HIDE chosen — after merge run:  $HIDE_NOTE}

## Off-repo / in-chat decisions
$OFFSEC

---
Generated: crewforth adopt · $DATE_H · $GEN_WHERE  (apart from this line there is NO tool SIGNATURE)
HAND
say '%s written' docs/HANDOVER.md

# 5b) ADR-0001 — the handover itself is a persistent decision (never-overwrite)
# 3.0 renamed the file with the product. A project adopted before that already holds its ADR-0001 under the old
# name, and a second one next to it would say the same decision twice: the old file, when present, IS the record,
# and it is left exactly as it is. Either name existing means nothing is written.
ADR1="docs/adr/0001-crewforth-adoption.md"
[ -e "docs/adr/0001-agentic-kit-adoption.md" ] && ADR1="docs/adr/0001-agentic-kit-adoption.md"
if [ ! -e "$ADR1" ]; then
  cat > "$ADR1" <<ADR
# ADR-0001: Crewforth was handed over to this project

- Date: $DATE_H
- Status: $ADR_BR_STATUS

## Context
The existing project was equipped for agentic work with Crewforth, handed over the way one team hands a project to another.
Goal: don't break the project, don't lose decisions already made, and don't leave Crewforth passive (hybrid).

## Decision
- Crewforth's agents were installed under the crew- namespace; the project's agents are preserved side by side, untouched.
- Crewforth's discipline is active via .claude/DISCIPLINE.md + @import; the project CLAUDE.md is untouched.
- On rule conflicts the PROJECT wins (axis-by-axis); in DISCIPLINE.md §4 it can only tighten, never loosen — the one exception is the §4.1 trace allowlist chosen at adoption (decision 3).
- Git gates: $HOOKDESC.
- Every change is on a reviewable git branch; rollback = git.

## Consequence
From now on decisions are written as ADRs under docs/adr/, NOT in chat (persistence).
Inherited stale rules are subject to "confirm"; not authoritative until verified with code.
ADR
  say '%s written (persistent handover decision)' "$ADR1"
else
  say '%s already exists — untouched (never-overwrite)' "$ADR1"
fi

# The §4.6 review record is runtime state, not configuration. `start.sh` gitignores `.claude/` wholesale so it
# is covered there, but an adoption may deliberately TRACK that directory (#4 share) — and then this one file
# would turn up in every `git status` as a change nobody made on purpose. One narrow line, either way.
#
# `docs/` closes a privacy hole rather than expressing a preference. README.md and the adr, teamboard and
# handoff skills all state that docs/ is gitignored in an install, and §4.3 promises internal working
# documents stay private — but only start.sh ever wrote that entry, so an adoption published every one of
# them. Measured across the payload: PLAN.md is named in 7 components, SESSION_STATE.md in 6,
# THREAT_MODEL.md in 6, plus SECURITY_FINDINGS.md, DISCOVERY.md and EVAL.md. A repository receiving this
# adoption was receiving its own threat model and security findings along with it.
# `.claude/.state/` for the same reason as the review record: it is this machine's runtime state (the update
# check's cache and answers, the pre-update snapshot) and a tracked .claude/ would otherwise put it in git status.
gi_add '.claude/review-pass.json' 'docs/' '.claude/.state/'
# TWIN OF start.sh's ga_add, and this path needs it MORE: adopt.sh does not gitignore `.claude/` at all — it
# only ignores review-pass.json and docs/ — so an adopted project TRACKS the kit's configuration by default.
# That is the shared case, which is the one where a Windows teammate's `core.autocrlf=true` rewrites every
# installed hook to CRLF on checkout. Measured on a bare-repo round trip: the committed blob carries 0 CR and
# the working tree comes back with 1345 in guard-bash.sh, 575 in pre-commit and 49 in commit-msg — measured on
# a real Windows machine through this path, with 149 files tracked and `.claude/` not gitignored. Only
# `autocrlf=true` corrupts (`input` and `false` come back clean unpinned), and that is the Git for Windows
# system-level default, so this protects the person who changed nothing.
# The victim is NOT Git Bash: a CRLF hook still runs there, measured against a destructive payload with the
# identical verdict. It is a non-MSYS bash on the same tree — WSL, which the kit's own .gitattributes names
# and which neither of us could measure. The data files the hooks read strip a trailing CR themselves; a
# script cannot strip its own, which is why the pin covers the scripts rather than trusting a strip.
# Asked of git rather than assumed, like the line above: if this repo ignores `.claude/` after all, nothing to do.
if ! git check-ignore -q .claude 2>/dev/null; then
  GA_LINES='.claude/**/*.sh text eol=lf
.claude/hooks/pre-commit text eol=lf
.claude/hooks/commit-msg text eol=lf
.claude/**/*.txt text eol=lf
.claude/**/*.conf text eol=lf'
  if ! git check-attr eol -- .claude/hooks/guard-bash.sh 2>/dev/null | grep -q ': lf$'; then
    [ -e .gitattributes ] || : > .gitattributes
    printf '%s\n' "$GA_LINES" | while IFS= read -r _gal; do
      [ -n "$_gal" ] || continue      # set -e is on from line 898: no `cmd && continue` here
      if grep -qxF "$_gal" .gitattributes 2>/dev/null; then continue; fi
      if [ -s .gitattributes ] && [ "$(tail -c 1 .gitattributes | od -An -tx1 | tr -d ' \n')" != "0a" ]; then
        printf '\n' >> .gitattributes
      fi
      printf '%s\n' "$_gal" >> .gitattributes
    done
    say '+ .gitattributes: eol pins so the shared hooks stay LF on a Windows checkout'
  fi
fi

# Ignoring docs/ and then `git add docs` would stage NOTHING, and that would take the adoption's own record
# out of the review diff — the exact failure recorded in CHANGELOG 2.5.0, where gitignoring before the
# branch commit dropped the payload from the diff and left "the project is untouched" untrue after a
# rollback. So the two files THIS SCRIPT authored are force-added: they are the evidence a reviewer reads,
# and they are the only things under docs/ that the adoption itself put there. Everything the skills write
# later stays private, which is what the guarantee was always about.
git add .claude CLAUDE.md >/dev/null 2>&1
# ...except in a private install. When docs/ is gitignored the owner has said internal documents stay off the
# repository, and Crewforth's own review flagged the force-added pair as a §4.3 leak (RC-1 rehearsal). They are
# written all the same and their place is said out loud; a shared install stages them as before.
if git check-ignore -q docs/HANDOVER.md 2>/dev/null; then
  say 'docs/ is gitignored here (a private install): %s and %s are written but not staged — they stay on this machine' docs/HANDOVER.md "$ADR1"
else
  git add -f docs/HANDOVER.md "$ADR1" >/dev/null 2>&1
fi
[ -e .gitignore ] && git add .gitignore >/dev/null 2>&1
[ -e .trace-allowlist.txt ] && git add .trace-allowlist.txt >/dev/null 2>&1
# NO auto-commit: the change set stays STAGED-but-uncommitted on branch $BR, so every added/changed file shows up
# in your editor's Source Control / Changes panel for review. HEAD is untouched until you commit yourself.

h1m 'Review in your editor — nothing committed yet'
rowv 'staged' "$(git diff --cached --stat 2>/dev/null | tail -1 || echo '(none)')"   # git's own stat line
sub "$ONBRANCH_LINE"
subm 'see it:   open the Source Control / Changes panel (every added + changed file is listed)  ·  or: %s' 'git status'
# The refresh is how an existing project gains the panel, and until now its closing
# summary named neither the panel nor node — so a machine without node finished
# quietly and the user found out later, at first use. That is the report this
# whole round came from.
if bash "$SRC/eval/preflight.sh" --has node 2>/dev/null; then
  subm 'panel:    %s opens it from this project (or: %s)' /crew-studio 'node .claude/studio/server/index.js --open'
else
  subm 'panel:    needs Node 18+, absent here — Crewforth can fetch one (Bash tool, not PowerShell): %s' 'bash .claude/studio/ensure-node.sh --plan'
  _mt '(it asks first, verifies the checksum, and touches nothing outside %s)' '~/.claude/studio-runtime'; sub "          $_M"
fi
sub "$ACCEPT_LINE"
sub "$DISCARD_LINE"
warnm 'If Claude Code is running in this project, run /clear (or quit and relaunch it) — a new session loads the'
_mt 'updated CLAUDE.md and discipline; a session opened before this run keeps the old rules until then.'
printf '     %s%s%s\n' "$D" "$_M" "$R"
# A 2.x variable name still works until 4.0 (eval/lib/crew-env.sh reads it); say its 3.0 name once, here, so the
# user can switch. compgen is a builtin — the list of set names costs no process.
for _v in $(compgen -e); do
  case "$_v" in CSK_CORRECT_STACK) ;; CSK_*)
    case "${_crew_legacy:-}" in
      *" ${_v#CSK_} "*) warnm '%s is set — its 3.0 name is %s (the old name works until 4.0)' "$_v" "CREW_${_v#CSK_}" ;;
      *)                warnm '%s is set but no longer read — set %s instead' "$_v" "CREW_${_v#CSK_}" ;;
    esac ;;
  esac
done
# The star line, once per kit version: a first adopt, or the first update to a new version. lib/star.sh keeps
# the marker (shared with doctor.sh) and owns the text, URL and the CREW_NO_STAR / CI silence.
if [ -f .claude/eval/lib/star.sh ]; then
  _S="$(bash .claude/eval/lib/star.sh --once . 2>/dev/null || true)"
  if [ -n "$_S" ]; then printf '\n%s\n' "$_S"; fi   # an `&&` here was the script's LAST status: rc=1 on every update
fi
