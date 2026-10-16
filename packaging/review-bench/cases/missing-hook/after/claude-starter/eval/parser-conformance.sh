#!/usr/bin/env bash
# PARSER CONFORMANCE — the gate must reach the same verdict whichever JSON tier decoded the payload.
#
# WHY THIS FILE EXISTS. guard-bash.sh reads its payload through a ladder: jq, then python3, then a pure-bash
# slice. Three parsers means three behaviours, and every parser incident this kit has had came from the tiers
# DIVERGING rather than from any one of them being weak:
#   * tier 3 was once `CMD="$INPUT"`, so every `git push` was hard-blocked as a force-push on any session id
#     containing `-f8`. CI never saw it, because CI has jq.
#   * Windows ships a python3 Store stub that satisfies `command -v` and cannot run, so stock desktops took
#     tier 2 and FAILED OPEN.
#   * a Windows-native jq writes stdout in TEXT mode, so tier 1 received `\` + CR + CR + LF where tier 3
#     received JSON's two-character escapes, and an ordinary commit was refused on one platform only.
# Each was found by a single assertion going red long after the change that caused it. This file turns "the
# tiers agree" into one property that is measured directly, so the next divergence fails here and names itself.
#
# EXIT CODES ARE COMPARED, NOT BYTES, and that is deliberate. The tiers legitimately hand the rules different
# bytes: tier 3 drops `\r` at decode (see `r) ;;` in _json_unescape) while tier 1 keeps it until a later fold,
# and tier 3 renders an astral character as `??` where a real parser produces the character. Both resolve to the
# same verdict. A byte comparison would report those as defects and bury the one that is not.
#
# FIXTURES ARE BYTE-CHECKED BEFORE THEY ARE TRUSTED. A corpus of escapes is the easiest thing in this repo to
# measure vacuously: write `\\u002e` and the payload carries an escaped BACKSLASH followed by the letters
# u002e — inert text that every tier agrees about while proving nothing; write it through a shell that expands
# escapes and the payload carries a real `.` and the parser never sees an escape at all. Both shapes happened
# while this corpus was being built, on two different machines. So every escape row declares the escape it needs,
# the payload's bytes are searched for it, and a row whose fixture came out inert is reported as UNMEASURED —
# never as a pass.
#
# Exit 0 = every case agreed. Exit 1 = a divergence, or a fixture that could not be built. Exit 3 = this machine
# has no second parser, so tier 1 could not be reached and nothing was compared.

set -u
LC_ALL=C

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/../hooks/guard-bash.sh"
[ -f "$HOOK" ] || HOOK="$HERE/../../claude-starter/hooks/guard-bash.sh"
if [ ! -f "$HOOK" ]; then echo "parser-conformance: guard-bash.sh bulunamadı ($HOOK)"; exit 1; fi

PASS=0; FAILED=0; UNMEASURED=0; KNOWN_OPEN=0
ok(){   PASS=$((PASS+1));   printf '  \033[32mOK\033[0m   %s\n' "$1"; }
bad(){  FAILED=$((FAILED+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
unm(){  UNMEASURED=$((UNMEASURED+1)); printf '  \033[33m????\033[0m %s\n' "$1"; }
note(){ printf '  ·    %s\n' "$1"; }

W="$(mktemp -d)"
trap 'cd /; rm -rf "$W"' EXIT INT TERM
P="$W/payload.json"

# ---------------------------------------------------------------------------------------------------------
# A REFERENCE PARSER. Tier 1 is only reachable if something on this machine can decode JSON correctly. Real jq
# is preferred because it IS tier 1; otherwise a shim named `jq` is placed on PATH, backed by whatever real
# parser exists, so the hook takes its tier-1 branch against genuinely decoded bytes. The shim writes in binary:
# the Windows text-mode flavour is a separate, already-fixed defect and is not what this file measures.
# perl is tried before python3 because Git Bash ships perl with JSON::PP in core, while the python3 that is on
# PATH there is a Store stub that satisfies `command -v` and cannot run.
# ---------------------------------------------------------------------------------------------------------
REFKIND=""
if command -v jq >/dev/null 2>&1 && printf '{"a":"b"}' | jq -r '.a' 2>/dev/null | grep -qx b; then
  REFKIND="jq"
elif command -v perl >/dev/null 2>&1 && printf '{"a":"b"}' | perl -MJSON::PP -e 'local $/; print decode_json(<STDIN>)->{a}' 2>/dev/null | grep -qx b; then
  REFKIND="perl"
elif command -v python3 >/dev/null 2>&1 && printf '{"a":"b"}' | python3 -c 'import sys,json;sys.stdout.write(json.load(sys.stdin)["a"])' 2>/dev/null | grep -qx b; then
  REFKIND="python3"
elif command -v node >/dev/null 2>&1 && printf '{"a":"b"}' | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).a))' 2>/dev/null | grep -qx b; then
  REFKIND="node"
fi

echo "== parser conformance: tier 3 (pure bash) vs tier 1 (a real parser) =="
if [ -z "$REFKIND" ]; then
  echo "  bu makinede ikinci bir JSON çözücü yok (jq, perl, python3, node) — tier 1'e ulaşılamıyor."
  echo "  HİÇBİR ŞEY KARŞILAŞTIRILMADI. Bu bir geçiş değildir."
  exit 3
fi
note "referans çözücü: $REFKIND"

SHIM="$W/shim"; mkdir -p "$SHIM"
if [ "$REFKIND" = "jq" ]; then
  T1PATH=""   # real jq is already on PATH; the hook finds it by itself
else
  case "$REFKIND" in
    perl)    RUN='perl -MJSON::PP -e '\''local $/; my $j=decode_json(<STDIN>); binmode(STDOUT); my $k=$ENV{K}; print(($k eq "cmd" ? ($j->{tool_input}{command} // "") : ($j->{permission_mode} // "")), "\n");'\''' ;;
    python3) RUN='python3 -c '\''import sys,os,json;d=json.load(sys.stdin);k=os.environ["K"];v=(d.get("tool_input",{}).get("command","") if k=="cmd" else d.get("permission_mode",""));sys.stdout.write(v+"\n")'\''' ;;
    node)    RUN='node -e '\''let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{let o;try{o=JSON.parse(s)}catch(e){process.exit(5)}const k=process.env.K;const v=k==="cmd"?((o.tool_input||{}).command||""):(o.permission_mode||"");process.stdout.write(v+"\n")})'\''' ;;
  esac
  {
    echo '#!/usr/bin/env bash'
    echo 'case "$2" in'
    echo "  '.tool_input.command // empty') K=cmd ;;"
    echo "  '.permission_mode // empty')    K=pm  ;;"
    echo '  *) exit 3 ;;'
    echo 'esac'
    echo "export K; $RUN"
  } > "$SHIM/jq"
  chmod +x "$SHIM/jq"
  T1PATH="$SHIM"
fi

# ---------------------------------------------------------------------------------------------------------
# A REPO FOR THE GATE TO JUDGE. §4.6 reads a review record, so without one every commit blocks for a reason
# that has nothing to do with parsing and the corpus would compare two identical refusals.
# ---------------------------------------------------------------------------------------------------------
R="$W/repo"; mkdir -p "$R"
( cd "$R" && git init -q . && git config user.email t@example.com && git config user.name t \
  && echo one > a.txt && git add a.txt && git commit -qm init && echo two >> a.txt && git add a.txt \
  && mkdir -p .claude ) >/dev/null 2>&1
( cd "$R" && printf '{"diff_oid":"%s","head":"%s","ts":"t"}\n' \
    "$(git diff --cached | git hash-object --stdin)" "$(git rev-parse --verify --quiet HEAD)" \
    > .claude/review-pass.json )

t3(){ ( cd "$R" && bash "$HOOK" < "$P" >/dev/null 2>&1; printf '%s' "$?" ); }
t1(){ if [ -n "$T1PATH" ]; then ( cd "$R" && PATH="$T1PATH:$PATH" bash "$HOOK" < "$P" >/dev/null 2>&1; printf '%s' "$?" )
      else ( cd "$R" && bash "$HOOK" < "$P" >/dev/null 2>&1; printf '%s' "$?" ); fi; }

# the payload, built by printf so the ARGUMENT is never escape-expanded (only the format string is)
mk(){ printf '{"cwd":"/tmp","permission_mode":"default","tool_name":"Bash","tool_input":{"command":"%s"},"tool_use_id":"x"}' "$1" > "$P"; }
mkraw(){ printf '%s' "$1" > "$P"; }   # for the adversarial shapes, which are about the OBJECT, not the command

hexof(){ printf '%s' "$1" | od -An -tx1 | tr -d ' \n'; }
bytes(){ od -An -tx1 "$P" | tr -d ' \n'; }

# ---------------------------------------------------------------------------------------------------------
# CALIBRATION. Four questions, and the corpus is not reported unless all four answer. Each one has been the
# difference between a real measurement and a green that meant nothing, at least once, on one of our machines.
# ---------------------------------------------------------------------------------------------------------
echo
echo "-- kalibrasyon --"
CAL=1
mk 'rm -rf /'
a="$(t3)"; b="$(t1)"
if [ "$a" = 2 ] && [ "$b" = 2 ]; then ok "yıkıcı bir komut iki katmanda da bloklanıyor (kapı koşuyor)"
else bad "kalibrasyon: 'rm -rf /' t3=$a t1=$b — kapı koşmuyor, korpus anlamsız"; CAL=0; fi
mk 'ls -la'
a="$(t3)"; b="$(t1)"
if [ "$a" = 0 ] && [ "$b" = 0 ]; then ok "zararsız bir komut iki katmanda da geçiyor (kapı aşırı bloklamıyor)"
else bad "kalibrasyon: 'ls -la' t3=$a t1=$b"; CAL=0; fi

# the tier-1 branch must really be taken, or the second column is the first column twice. A stub that returns a
# DIFFERENT command for a harmless payload proves the branch is live; with real jq the equivalent proof is that
# jq answers at all.
if [ -n "$T1PATH" ]; then
  cp "$SHIM/jq" "$W/jq.real"
  { echo '#!/usr/bin/env bash'
    echo "case \"\$2\" in '.tool_input.command // empty') printf '%s\\n' 'rm -rf /' ;; '.permission_mode // empty') printf '%s\\n' default ;; *) exit 3 ;; esac"
  } > "$SHIM/jq"; chmod +x "$SHIM/jq"
  mk 'ls -la'; c="$(t1)"
  cp "$W/jq.real" "$SHIM/jq"; chmod +x "$SHIM/jq"
  if [ "$c" = 2 ]; then ok "tier 1 dalı gerçekten koşuluyor (pozitif kontrol: stub başka komut döndürünce rc 0->2)"
  else bad "kalibrasyon: tier 1 dalına girilmiyor — ikinci sütun birincinin kopyası (rc=$c)"; CAL=0; fi
else
  mk 'ls -la'
  if printf '%s' "$(cat "$P")" | jq -r '.tool_input.command // empty' 2>/dev/null | grep -qx 'ls -la'; then
    ok "tier 1 dalı gerçek jq ile koşuluyor"
  else bad "kalibrasyon: gerçek jq beklendiği gibi cevap vermiyor"; CAL=0; fi
fi

# a KNOWN divergence must be visible, or a harness that silently compares nothing would come out all-green.
# tier 3 renders an astral character as `??`; a real parser produces the character. The VERDICT is the same —
# which is the whole point of comparing exit codes — but the decoded bytes must differ, and that is checkable.
mk 'echo a\ud83d\ude00b'
{ echo '#!/usr/bin/env bash'; echo 'INPUT="$(cat)"'
  awk '/^_json_slice\(\)/{f=1} f{print} f&&/^}$/{exit}' "$HOOK"
  awk '/^_json_unescape\(\)/{f=1} f{print} f&&/^}$/{exit}' "$HOOK"
  echo '_json_unescape "$(_json_slice "$INPUT" command)"'; } > "$W/dec3.sh"
if bash -n "$W/dec3.sh" 2>/dev/null; then
  D3="$(bash "$W/dec3.sh" < "$P" 2>/dev/null)"
  if [ -n "$T1PATH" ]; then D1="$(PATH="$T1PATH:$PATH" jq -r '.tool_input.command // empty' < "$P" 2>/dev/null)"
  else D1="$(jq -r '.tool_input.command // empty' < "$P" 2>/dev/null)"; fi
  if [ "$D3" != "$D1" ]; then ok "bilinen bayt ayrışması görünüyor (vekil çift: tier3 '$D3' vs tier1 '$D1') — karşılaştırma canlı"
  else bad "kalibrasyon: bilinen ayrışma görünmüyor, harness boş karşılaştırıyor olabilir"; CAL=0; fi
else
  unm "tier 3 çözücüsü kapıdan çıkarılamadı — bilinen-ayrışma kalibrasyonu koşmadı"
fi

if [ "$CAL" != 1 ]; then
  echo
  echo "KALİBRASYON BAŞARISIZ — korpus raporlanmıyor, çünkü sonucu okunamaz."
  exit 1
fi

# ---------------------------------------------------------------------------------------------------------
# THE CORPUS. Every row states the verdict it expects, so a divergence can be reported with its DIRECTION:
# a tier answering 0 where 2 was expected is a BLIND GATE (something dangerous got through); a tier answering
# 2 where 0 was expected is an OVER-BLOCK (the user is taught to reach for --no-verify, which disarms all of §4).
# Equality is the headline; the direction is what a reviewer needs in order to know how bad a red row is.
#
# `need` is the two-character escape the fixture must really carry. The payload's bytes are searched for
# backslash + that character, and for the doubled form that would mean the escape was written inert. `-` means
# the row carries no escape and no byte check applies.
# ---------------------------------------------------------------------------------------------------------
echo
echo "-- korpus: hüküm eşitliği (rc), bayt değil --"

run_row(){ # $1 label  $2 expected rc  $3 need-escape-char or -  $4 command
  local label="$1" exp="$2" need="$3" cmd="$4" a b h nh dh
  mk "$cmd"
  if [ "$need" != "-" ]; then
    h="$(bytes)"
    # A single character means "the payload must carry backslash + that character, and NOT the doubled form" —
    # the doubled form is JSON for an escaped backslash followed by a letter, which is inert text every tier
    # agrees about. Rows whose escape legitimately FOLLOWS an escaped backslash (a line continuation is
    # `\\` then `\n`) cannot use that rule, because the doubled form is exactly what they are supposed to
    # contain; they name the whole byte sequence instead, as `hex:…`.
    case "$need" in
      hex:*) nh="${need#hex:}"; dh="" ;;
      *)     nh="5c$(hexof "$need")"; dh="5c5c$(hexof "$need")" ;;
    esac
    if [ -n "$dh" ]; then
      case "$h" in
        *"$dh"*) unm "$label — fixture ATIL: kaçış çift yazılmış ($dh), satır hiçbir şey ölçmez"; return ;;
      esac
    fi
    case "$h" in
      *"$nh"*) ;;
      *)       unm "$label — fixture ATIL: payload'da $nh baytları yok, kabuk kaçışı yutmuş"; return ;;
    esac
  fi
  a="$(t3)"; b="$(t1)"
  if [ "$a" = "$b" ]; then
    if [ "$a" = "$exp" ]; then ok "$label (rc=$a)"
    else bad "$label — iki katman da rc=$a, beklenen $exp $( [ "$exp" = 2 ] && echo '(KÖR KAPI: ikisi de kaçırıyor)' || echo '(AŞIRI BLOK: ikisi de reddediyor)' )"; fi
  else
    if [ "$a" = "$exp" ]; then bad "$label — AYRIŞIYOR: tier1 rc=$b, beklenen $exp $( [ "$exp" = 2 ] && echo '(tier1 KÖR)' || echo '(tier1 AŞIRI BLOKLUYOR)' )"
    else bad "$label — AYRIŞIYOR: tier3 rc=$a, beklenen $exp $( [ "$exp" = 2 ] && echo '(tier3 KÖR)' || echo '(tier3 AŞIRI BLOKLUYOR)' )"; fi
  fi
}

#         etiket                                  bekl  kaçış  komut
run_row 'düz commit'                               2 -  'git commit -m c'
run_row 'pathspec commit'                          2 -  'git commit -m c -- a.txt'
run_row 'ters bölü devam + LF'                     2 hex:5c5c5c6e  'git commit \\\n  -m c'
run_row 'ters bölü devam + CRLF'                   2 hex:5c5c5c72  'git commit \\\r\n  -m c'
run_row 'CRLF ayraç'                               2 r  'git commit -m c\r\necho done'
run_row 'yalnız CR'                                2 r  'git commit -m c\recho done'
run_row 'sekme ayraçlı'                            2 t  'git commit\t-m\tc'
run_row 'kaçışlı tırnak'                           2 '"' 'git commit -m \"a b\"'
run_row 'rm -rf kök'                               2 -  'rm -rf /'
run_row 'force push'                               2 -  'git push --force'
run_row 'git add -f'                               2 -  'git add -f secrets.env'
run_row 'PowerShell özyinelemeli sil'              2 -  'Remove-Item -Recurse -Force C:\\x'
run_row 'gate betiğini yeniden yazma (düz)'        2 -  'echo x > .claude/hooks/guard-bash.sh'
run_row 'gate betiğini yeniden yazma (\u kaçışlı)' 2 u  'echo x > \u002eclaude/hooks/guard-bash.sh'
run_row 'gate yolunu okuma (\u kaçışlı)'           0 u  'cat \u002eclaude/hooks/guard-bash.sh'
run_row 'latin kaçışları'                          0 u  'echo \u00e7\u011f\u0131'
run_row 'vekil çift'                               0 u  'echo a\ud83d\ude00b'
run_row 'NUL kaçışı'                               0 u  'echo a\u0000b'
run_row 'backspace'                                0 b  'echo a\bb'
run_row 'formfeed'                                 0 f  'echo a\fc'
run_row 'kaçışlı bölü'                             0 /  'cat a\/b\/c.txt'
run_row 'zararsız komut'                           0 -  'echo not-a-command'
run_row 'boş komut'                                0 -  ''

# ---------------------------------------------------------------------------------------------------------
# ADVERSARIAL SHAPES. The rows above are representative; these are built to make the pure-bash SLICE disagree
# with a real parser, because that is the disagreement that would matter if the ladder were ever collapsed to
# one tier. They are written as whole objects rather than as commands: the question is which VALUE each parser
# reads for `command`, not what the command says.
#
# A note on `command` appearing twice: RFC 8259 leaves duplicate names undefined, so "the right answer" is not
# a standards question. What matters here is only that the two tiers pick the SAME one — if they ever pick
# differently, a payload could show the user one command and hand the rules another.
# ---------------------------------------------------------------------------------------------------------
echo
echo "-- düşmanca biçimler: dilim ile gerçek çözücü burada ayrışır mı? --"

adv(){ # $1 label  $2 expected rc  $3 raw payload  [$4 = "known-open:<t3rc>/<t1rc>"]
  local label="$1" exp="$2" a b known="${4:-}"
  mkraw "$3"
  a="$(t3)"; b="$(t1)"
  # A KNOWN-OPEN row is a divergence this file FOUND and that nothing has fixed yet. Under
  # CSK_CONFORMANCE_KNOWN_OPEN=1 it is reported but does not fail the run, so the file can be wired into CI
  # while the finding is still open — and it is pinned to the EXACT shape observed, so it cannot rot:
  #   * the shape changes  -> FAIL, because the finding moved and the record is now wrong
  #   * the row starts passing -> FAIL, because it was FIXED and the marker has to come out
  # Without the variable the row fails like any other, which is the contract CI asks for once this is closed.
  if [ -n "$known" ] && [ "${CSK_CONFORMANCE_KNOWN_OPEN:-0}" = 1 ]; then
    local want="${known#known-open:}"
    if [ "$a" = "$b" ] && [ "$a" = "$exp" ]; then
      bad "$label — ARTIK GEÇİYOR: bu bulgu düzeltilmiş, known-open işareti kaldırılmalı"
      return
    fi
    if [ "$a/$b" = "$want" ]; then
      KNOWN_OPEN=$((KNOWN_OPEN+1))
      printf '  \033[33mAÇIK\033[0m %s — bilinen ayrışma, kayıtlı: tier3 rc=%s · tier1 rc=%s (beklenen %s)\n' "$label" "$a" "$b" "$exp"
      return
    fi
    bad "$label — bilinen ayrışma DEĞİŞTİ: kayıt $want, ölçülen $a/$b — kayıt güncellenmeli"
    return
  fi
  if [ "$a" = "$b" ]; then
    if [ "$a" = "$exp" ]; then ok "$label (rc=$a)"
    else bad "$label — iki katman da rc=$a, beklenen $exp $( [ "$exp" = 2 ] && echo '(KÖR KAPI)' || echo '(AŞIRI BLOK)' )"; fi
  else
    bad "$label — AYRIŞIYOR: tier3 rc=$a · tier1 rc=$b (beklenen $exp) $( { [ "$a" = 0 ] || [ "$b" = 0 ]; } && [ "$exp" = 2 ] && echo '<< bir katman KÖR' || echo '<< bir katman AŞIRI BLOKLUYOR' )"
  fi
}

# The destructive command sits in the SECOND `command`. RFC 8259 leaves duplicate names undefined, so neither
# "first wins" nor "last wins" is wrong on its own — but the two tiers must not answer differently, and here they
# do: the slice takes the FIRST and reads `ls -la`, a real parser takes the LAST and reads `rm -rf /`. The slice
# is the blind one. This row was found by REVIEWING this file rather than by running it: an earlier edit had left
# both values as `ls -la`, so the row agreed trivially and hid the divergence underneath it.
adv 'command anahtarı iki kez (ikincisi yıkıcı)' 2 \
  '{"cwd":"/tmp","permission_mode":"default","tool_name":"Bash","tool_input":{"command":"ls -la","command":"rm -rf /"},"tool_use_id":"x"}' \
  known-open:0/2
# a literal `"command":"` inside ANOTHER value: a greedy search would relocate the parse and walk past the rules
adv 'gövdede sahte command anahtarı'          2 \
  '{"cwd":"/tmp","permission_mode":"default","tool_name":"Bash","tool_input":{"description":"\"command\":\"ls\"","command":"rm -rf /"},"tool_use_id":"x"}'
# a nested object BEFORE the real key
adv 'gerçek anahtardan önce iç içe nesne'      2 \
  '{"cwd":"/tmp","permission_mode":"default","tool_name":"Bash","tool_input":{"meta":{"command":"ls -la"},"command":"rm -rf /"},"tool_use_id":"x"}' \
  known-open:0/2
# an escaped quote immediately before the closing quote: the slice must not end the value one byte early
adv 'kapanış tırnağından önce kaçışlı tırnak'  2 \
  '{"cwd":"/tmp","permission_mode":"default","tool_name":"Bash","tool_input":{"command":"rm -rf / --no-preserve-root \"x\""},"tool_use_id":"x"}'
# an escaped BACKSLASH immediately before the closing quote: the quote really does end the value here
adv 'kapanış tırnağından önce kaçışlı ters bölü' 0 \
  '{"cwd":"/tmp","permission_mode":"default","tool_name":"Bash","tool_input":{"command":"echo C:\\\\"},"tool_use_id":"x"}'
# key order is not a contract: tool_input before tool_name, permission_mode last
adv 'anahtar sırası: tool_input önce'          2 \
  '{"tool_input":{"command":"rm -rf /"},"tool_name":"Bash","cwd":"/tmp","permission_mode":"default","tool_use_id":"x"}'
# The key NAME written with a unicode escape. A real parser decodes it to `command` and judges `rm -rf /`; the
# slice searches for the literal bytes `"command"`, finds nothing, and the hook exits 0 with no command to judge.
# The safe answer is the BLOCK, so 2 is expected here and a tier answering 0 is BLIND, not lenient.
# The backslash is produced at RUN TIME by printf rather than written literally here. A literal one has to
# survive every layer between an author and this file, and in this repo it has not: a `c` written by hand
# arrived as `\\u0063` — JSON for an escaped backslash — which is inert text both tiers agree about, so the row
# would have reported a pass while measuring nothing. The byte assertion below is what makes that impossible to
# ship silently; it is the same rule the escape rows in the corpus follow.
BS="$(printf '\\')"
ESCKEY="{\"cwd\":\"/tmp\",\"permission_mode\":\"default\",\"tool_name\":\"Bash\",\"tool_input\":{\"${BS}u0063ommand\":\"rm -rf /\"},\"tool_use_id\":\"x\"}"
case "$(printf '%s' "$ESCKEY" | od -An -tx1 | tr -d ' \n')" in
  *5c5c7530303633*) bad "düşmanca fixture ATIL: kaçışlı anahtar adı çift ters bölü taşıyor, satır hiçbir şey ölçmez" ;;
  *5c7530303633*)   adv 'anahtar adı \u kaçışlı' 2 "$ESCKEY" known-open:0/2 ;;
  *)                bad "düşmanca fixture ATIL: kaçışlı anahtar adı kurulamadı" ;;
esac

# ---------------------------------------------------------------------------------------------------------
echo
printf 'PARSER-CONFORMANCE: %s geçti · %s başarısız · %s ölçülemedi · %s bilinen-açık  (referans: %s)\n' \
  "$PASS" "$FAILED" "$UNMEASURED" "$KNOWN_OPEN" "$REFKIND"
if [ "$KNOWN_OPEN" -gt 0 ]; then
  echo "$KNOWN_OPEN bilinen ayrışma AÇIK ve bu koşuda başarısızlık sayılmadı (CSK_CONFORMANCE_KNOWN_OPEN=1)."
  echo "Merdiven bunlar kapanmadan SİLİNMEZ; değişken olmadan koşmak satırları kırmızı gösterir."
fi
if [ "$FAILED" -gt 0 ]; then
  echo "Katmanlar ayrıştı ya da bir fixture kurulamadı. Merdiven SİLİNMEDEN önce bu kapatılmalı."
  exit 1
fi
if [ "$UNMEASURED" -gt 0 ]; then
  echo "Bazı satırlar ölçülemedi — bu bir geçiş değildir, fixture'ları düzeltin."
  exit 1
fi
echo "Her iki katman da her vakada aynı hükmü verdi."
exit 0
