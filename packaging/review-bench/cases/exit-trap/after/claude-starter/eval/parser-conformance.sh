#!/usr/bin/env bash
# PARSER CONFORMANCE — the gate's payload reader must agree with a real JSON parser.
#
# WHY THIS FILE EXISTS. guard-bash.sh read its payload through a ladder: jq, then python3, then a pure-bash
# slice. Three parsers meant three behaviours, and every parser incident this kit has had came from the tiers
# DIVERGING rather than from any one of them being weak:
#   * tier 3 was once `CMD="$INPUT"`, so every `git push` was hard-blocked as a force-push on any session id
#     containing `-f8`. CI never saw it, because CI has jq.
#   * Windows ships a python3 Store stub that satisfies `command -v` and cannot run, so stock desktops took
#     tier 2 and FAILED OPEN.
#   * a Windows-native jq writes stdout in TEXT mode, so tier 1 received `\` + CR + CR + LF where tier 3
#     received JSON's two-character escapes, and an ordinary commit was refused on one platform only.
# Each was found by a single assertion going red long after the change that caused it.
#
# TWO MODES, AND THE FILE CHOOSES BETWEEN THEM BY LOOKING AT THE HOOK.
#   LADDER PRESENT — the payload can still be read two ways, so the property is "both tiers reach the same
#     VERDICT". Exit codes are compared, not bytes: the tiers legitimately hand the rules different bytes and a
#     byte comparison would report those as defects and bury the one that is not.
#   LADDER ABSENT — there is only one reader in production, so a tier comparison would be the slice against
#     itself. The property becomes "the slice DECODES what a real parser decodes", measured against a reference
#     that never goes through the hook at all, plus "the gate still reaches the verdict each row declares".
# The DECODE check runs in BOTH modes on purpose. It costs nothing while the ladder is there and it means the
# normalisations below are already pinned by the time the ladder goes, rather than being written the same day
# they become the only thing standing.
#
# THE MODE DETECTOR IS ITSELF CALIBRATED, IN BOTH DIRECTIONS. It is the one place where this whole file can go
# quiet: a detector that wrongly says "ladder absent" against a ladder-ful hook stops exercising tier selection
# and says nothing about it. So two fixtures are built and the detector must answer each correctly before any
# mode runs.
#
# THE DECODE RULES ARE TAKEN FROM THE HOOK'S CASE ARMS, NOT FROM A MEASUREMENT. Pinning whatever the slice
# happens to do today would make the pin agree with any future change. _json_unescape maps:
#     \n -> LF   \t -> TAB   \r -> DROPPED   \b and \f -> one space
#     \uXXXX matching 00[2-7][0-9a-fA-F] (printable ASCII) -> that character
#     any other \uXXXX -> a single `?`          \<anything else> -> that character literally
# A row whose expected decode is `=` must match the reference EXACTLY; a row that exercises one of those
# normalisations carries the literal it must produce, so each normalisation is a stated fact and not an excuse.
#
# FIXTURES ARE BYTE-CHECKED BEFORE THEY ARE TRUSTED. A corpus of escapes is the easiest thing in this repo to
# measure vacuously: write `\\u002e` and the payload carries an escaped BACKSLASH followed by the letters
# u002e — inert text every reader agrees about while proving nothing; write it through a shell that expands
# escapes and the payload carries a real `.` and no parser ever sees an escape. Both shapes happened while this
# corpus was being built, on two different machines. So every escape row declares the escape it needs, the
# payload's bytes are searched for it, and a row whose fixture came out inert is reported UNMEASURED, never as
# a pass. Every backslash in a fixture is produced at RUN TIME by printf rather than written literally here,
# because a literal one has to survive every layer between an author and this file and in this repo it has not.
#
# Exit 0 = everything agreed. Exit 1 = a divergence, a broken fixture, or a calibration that did not answer.
# Exit 3 = nothing could be compared on this machine (no hook, or no reference parser). Never a pass.

set -u
LC_ALL=C

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/../hooks/guard-bash.sh"
[ -f "$HOOK" ] || HOOK="$HERE/../../claude-starter/hooks/guard-bash.sh"
if [ ! -f "$HOOK" ]; then
  # Not a divergence and not a broken fixture — there was nothing to measure at all, which is what rc 3 means
  # everywhere else in this file. Exiting 1 here would report "the readers disagree" for a file that was merely
  # copied somewhere else, and a caller that maps 1 to "gate failed" would chase a bug that does not exist.
  echo "parser-conformance: guard-bash.sh bulunamadı ($HOOK) — HİÇBİR ŞEY ÖLÇÜLMEDİ, bu bir geçiş değildir"
  exit 3
fi

PASS=0; FAILED=0; UNMEASURED=0; KNOWN_OPEN=0

# AN ASSERTION THAT RAN IN A SUBSHELL IS INVISIBLE, and this file is as exposed to it as any other. `ok`/`bad`
# move shell VARIABLES, so inside `( … )` or a pipeline they move a copy in a child: the row prints, the total
# does not, and a `bad` there cannot fail the run. Colour cannot find it — only the DELTA can.
# So every assertion also appends the counter's value to a file. A file survives a subshell; a variable does
# not. Walking that log afterwards, each line must show the counter one higher than the line before, and any
# line that repeats means the assertion BEFORE it was lost. The append is a redirect, not a process.
# `$BASHPID != $$` is shorter and exact, and is not used: it does not exist on bash 3.2, which is what macOS
# runs, so it would detect nothing on one of the three supported platforms while looking like it worked.
# The label is stripped of line endings first — a decoded value can contain a real LF, which would split one
# log line into two and manufacture a repeat that is the harness's and not the suite's.
ASSERTLOG="$(mktemp)"
ok(){   PASS=$((PASS+1));   _al "OK  $1"; printf '  \033[32mOK\033[0m   %s\n' "$1"; }
bad(){  FAILED=$((FAILED+1)); _al "BAD $1"; printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
unm(){  UNMEASURED=$((UNMEASURED+1)); _al "UNM $1"; printf '  \033[33m????\033[0m %s\n' "$1"; }
note(){ printf '  ·    %s\n' "$1"; }
_al(){ local l="${1//$'\n'/ }"; l="${l//$'\r'/ }"; printf '%s\t%s\n' "$((PASS+FAILED+UNMEASURED))" "$l" >> "$ASSERTLOG"; }

# THE RULE: the PARENT's logged values are exactly total, total-1, … 1, so walk the log BACKWARD expecting
# that chain. A line on the chain is a parent line; every line that is not was executed in a child.
#
# The first version used "a repeat at N means N-1 was lost", which is only true when each loss sits in its OWN
# subshell. Several assertions inside ONE `( … )` — the shape that actually occurred in this repo, five rows
# at once — make the counter ADVANCE inside the child (P+1, P+2, P+3) and then DROP when the parent resumes;
# that rule saw one drop and named one row, missing the rest. A synthetic fixture had modelled separate
# subshells, so it agreed with itself. Running the real shape is what showed the difference.
# The backward walk needs no special case for runs, for separate subshells, or for a loss at the very end.
_analyse(){ # $1 log, $2 visible total -> prints offenders in file order, then HITS=n
  awk -F'\t' -v final="$2" '
    { n[NR]=$1; lab[NR]=$2 }
    END { e=final+0; h=0
      for (i=NR; i>=1; i--) { if (n[i]+0 == e) e--; else out[++h]=lab[i] }
      for (j=h; j>=1; j--) printf "     >> %s\n", out[j]
      printf "HITS=%d\n", h }' "$1"; }

# Calibrated on a SYNTHETIC log before it is trusted, because a detector that quietly stopped working would
# report "0 findings" — a clean bill of health, and the same failure it exists to catch. The fixture carries
# the shape that broke the previous rule (a RUN inside one subshell) plus a loss at the very end, and a clean
# tail that must not be accused.
_cal="$(mktemp)"
printf '1\tp1\n2\tp2\n3\tRUN-1\n4\tRUN-2\n5\tRUN-3\n3\tp3\n4\tp4\n5\tSON\n' > "$_cal"
_co="$(_analyse "$_cal" 4)"
if [ "$(printf '%s' "$_co" | sed -n 's/^HITS=//p')" = 4 ] \
   && printf '%s' "$_co" | grep -q 'RUN-1' && printf '%s' "$_co" | grep -q 'RUN-2' \
   && printf '%s' "$_co" | grep -q 'RUN-3' && printf '%s' "$_co" | grep -q 'SON' \
   && ! printf '%s' "$_co" | grep -q 'p[1-4]'; then
  _ALZ=1
else
  _ALZ=0; printf '  \033[33m????\033[0m %s\n' "alt-kabuk dedektörü kendi kalibrasyonunu geçemedi — bu koşuda iddia kaybı ARANMAYACAK"
fi
rm -f "$_cal"

W="$(mktemp -d)"
trap 'cd /; rm -rf "$W"' EXIT INT TERM
P="$W/payload.json"
BS="$(printf '\\')"          # one real backslash, never written literally into this file

# ---------------------------------------------------------------------------------------------------------
# THE MODE DETECTOR, and its calibration in both directions.
# ---------------------------------------------------------------------------------------------------------
has_ladder(){ grep -q 'command -v jq' "$1"; }

mkdir -p "$W/det"
printf '%s\n' '#!/usr/bin/env bash' 'CMD=""' \
  'if command -v jq >/dev/null 2>&1 && CMD="$(jq -r .x)"; then :; fi' > "$W/det/with.sh"
printf '%s\n' '#!/usr/bin/env bash' 'CMD=""' 'CMD="$(_json_slice "$INPUT" command)"' > "$W/det/without.sh"

echo "== mod seçici, iki yönde de kalibre ediliyor =="
DETOK=1
if has_ladder "$W/det/with.sh"; then ok "merdivenli bir kapıda seçici 'merdiven VAR' diyor"
else bad "seçici merdivenli kapıyı kaçırdı — kip seçimi güvenilmez"; DETOK=0; fi
if has_ladder "$W/det/without.sh"; then bad "seçici merdivensiz kapıda 'VAR' dedi — sessizleşmenin tersi, yine de yanlış"; DETOK=0
else ok "merdivensiz bir kapıda seçici 'merdiven YOK' diyor"; fi
[ "$DETOK" = 1 ] || { echo; echo "SEÇİCİ KALİBRASYONU BAŞARISIZ — hangi kipin koşacağı bilinemez, hiçbir şey raporlanmıyor"; exit 1; }

LADDER=0; has_ladder "$HOOK" && LADDER=1
note "kapıda okuma merdiveni: $( [ "$LADDER" = 1 ] && echo 'VAR — iki katman karşılaştırılacak' || echo 'YOK — tek okuyucu, referansa karşı çözüm karşılaştırılacak' )"
echo

# ---------------------------------------------------------------------------------------------------------
# A REFERENCE PARSER. Real jq is preferred; otherwise a shim named `jq` is placed on PATH so the hook can still
# take its tier-1 branch while the ladder exists. The shim writes in binary: the Windows text-mode flavour is a
# separate, already-fixed defect and not what this file measures. perl comes before python3 because Git Bash
# ships perl with JSON::PP in core, while the python3 on PATH there is a Store stub that cannot run.
# ---------------------------------------------------------------------------------------------------------
REFKIND=""
if   command -v jq      >/dev/null 2>&1 && printf '{"a":"b"}' | jq -r '.a' 2>/dev/null | grep -qx b; then REFKIND=jq
elif command -v perl    >/dev/null 2>&1 && printf '{"a":"b"}' | perl -MJSON::PP -e 'local $/; print decode_json(<STDIN>)->{a}' 2>/dev/null | grep -qx b; then REFKIND=perl
elif command -v python3 >/dev/null 2>&1 && printf '{"a":"b"}' | python3 -c 'import sys,json;sys.stdout.write(json.load(sys.stdin)["a"])' 2>/dev/null | grep -qx b; then REFKIND=python3
elif command -v node    >/dev/null 2>&1 && printf '{"a":"b"}' | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).a))' 2>/dev/null | grep -qx b; then REFKIND=node
fi
if [ -z "$REFKIND" ]; then
  echo "  bu makinede JSON çözebilen ikinci bir araç yok (jq, perl, python3, node)."
  echo "  HİÇBİR ŞEY KARŞILAŞTIRILMADI. Bu bir geçiş değildir."
  exit 3
fi
note "referans çözücü: $REFKIND"

# THE REFERENCE'S TRANSPORT IS PART OF THE INSTRUMENT, and it was the one thing here taken on faith. Every
# fixture is byte-checked and the reader's decode is compared byte-exact, but what the reference HANDED BACK
# was never calibrated. A Windows-native jq opens stdout in TEXT mode and turns every LF it writes into CRLF,
# so the one row whose decoded value contains an LF diverges by a byte the READER never had — an instrument
# fault reported as a product divergence, in the file whose whole purpose is to refuse exactly that.
#
# The fix is not to normalise the difference away: a CR that a decode genuinely produced and a CR the pipe
# added look identical after normalisation, so stripping them would hide a real divergence to spare a fake one.
# Instead the reference is asked for BASE64, which is a single line with no embedded newline, so the platform's
# line-ending translation has nothing to act on and is out of the path for every reference equally. bash does
# the decoding, and both sides of the comparison are captured the same way so `$( )` treats them alike.
B64=0
if command -v base64 >/dev/null 2>&1 && [ "$(printf 'a\nb' | base64 | tr -d '\n' | base64 -d 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "610a62" ]; then B64=1; fi

ref_encode(){ # the reference's answer for .tool_input.command, base64 on one line
  case "$REFKIND" in
    jq)      jq -r '.tool_input.command // empty | @base64' < "$P" 2>/dev/null ;;
    # Encode::encode first: JSON::PP hands back a CHARACTER string and encode_base64 wants octets, so an
    # astral character made it return nothing at all. That failure was silent in the worst way — the
    # known-divergence calibration compares the reference against the slice, and empty differs from the
    # slice, so the row passed while the reference was carrying nothing.
    perl)    perl -MJSON::PP -MMIME::Base64 -MEncode -e 'local $/; my $j=decode_json(<STDIN>); print encode_base64(Encode::encode("UTF-8", ($j->{tool_input}{command} // "")), "");' < "$P" 2>/dev/null ;;
    python3) python3 -c 'import sys,json,base64;sys.stdout.write(base64.b64encode(json.load(sys.stdin).get("tool_input",{}).get("command","").encode()).decode())' < "$P" 2>/dev/null ;;
    node)    node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{let o;try{o=JSON.parse(s)}catch(e){process.exit(0)}process.stdout.write(Buffer.from(((o.tool_input||{}).command)||"").toString("base64"))})' < "$P" 2>/dev/null ;;
  esac; }

ref_raw(){ # the direct read, kept as the fallback when nothing can decode base64
  case "$REFKIND" in
    jq)      jq -r '.tool_input.command // empty' < "$P" 2>/dev/null ;;
    perl)    perl -MJSON::PP -e 'local $/; my $j=decode_json(<STDIN>); binmode(STDOUT); print(($j->{tool_input}{command} // ""));' < "$P" 2>/dev/null ;;
    python3) python3 -c 'import sys,json;sys.stdout.write(json.load(sys.stdin).get("tool_input",{}).get("command",""))' < "$P" 2>/dev/null ;;
    node)    node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{let o;try{o=JSON.parse(s)}catch(e){process.exit(0)}process.stdout.write(((o.tool_input||{}).command)||"")})' < "$P" 2>/dev/null ;;
  esac; }

ref_decode(){ if [ "$B64" = 1 ]; then ref_encode | tr -d '\r\n' | base64 -d 2>/dev/null; else ref_raw; fi; }

SHIM="$W/shim"; mkdir -p "$SHIM"; T1PATH=""
if [ "$REFKIND" != jq ]; then
  case "$REFKIND" in
    perl)    RUN='perl -MJSON::PP -e '\''local $/; my $j=decode_json(<STDIN>); binmode(STDOUT); my $k=$ENV{K}; print(($k eq "cmd" ? ($j->{tool_input}{command} // "") : ($j->{permission_mode} // "")), "\n");'\''' ;;
    python3) RUN='python3 -c '\''import sys,os,json;d=json.load(sys.stdin);k=os.environ["K"];sys.stdout.write((d.get("tool_input",{}).get("command","") if k=="cmd" else d.get("permission_mode",""))+"\n")'\''' ;;
    node)    RUN='node -e '\''let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{let o;try{o=JSON.parse(s)}catch(e){process.exit(5)}const k=process.env.K;process.stdout.write((k==="cmd"?((o.tool_input||{}).command||""):(o.permission_mode||""))+"\n")})'\''' ;;
  esac
  { echo '#!/usr/bin/env bash'
    echo 'case "$2" in'
    echo "  '.tool_input.command // empty') K=cmd ;;"
    echo "  '.permission_mode // empty')    K=pm  ;;"
    echo '  *) exit 3 ;;'
    echo 'esac'
    echo "export K; $RUN"; } > "$SHIM/jq"
  chmod +x "$SHIM/jq"; T1PATH="$SHIM"
fi

# ---------------------------------------------------------------------------------------------------------
# THE SLICE, EXTRACTED. This is what production reads with once the ladder is gone, so it is compared against
# the reference directly rather than through the hook — a comparison routed through the hook would be the
# slice against itself the moment the ladder disappears.
# ---------------------------------------------------------------------------------------------------------
{ echo '#!/usr/bin/env bash'; echo 'INPUT="$(cat)"'
  awk '/^_json_slice\(\)/{f=1} f{print} f&&/^}$/{exit}' "$HOOK"
  awk '/^_json_unescape\(\)/{f=1} f{print} f&&/^}$/{exit}' "$HOOK"
  echo '_json_unescape "$(_json_slice "$INPUT" command)"'; } > "$W/dec.sh"
cp "$W/dec.sh" "$W/dec.good.sh"
if ! bash -n "$W/dec.sh" 2>/dev/null; then
  echo "  _json_slice / _json_unescape kapıdan çıkarılamadı — çözüm karşılaştırması yapılamaz"; exit 3; fi
slice_decode(){ bash "$W/dec.sh" < "$P" 2>/dev/null; }

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

# THE PURE-BASH COLUMN HAS TO BE PURE-BASH ON EVERY MACHINE, not only on one that happens to lack jq. Run on
# the ambient PATH, `t3` is whatever rung the machine can reach — so on a jq box the "tier 3" column IS rung
# one, both columns mean the same thing, and a ladder-split row records `t3=0/t1=0` and reports that the
# divergence moved. That is the same defect as a row that only checks rc: the measurement's meaning depended on
# the environment rather than on what it claimed to measure. The interpreters are shadowed with stubs that
# EXIST and FAIL, which is the shape a stock Windows desktop already has (the Store python3), so the fallthrough
# being exercised is the real one and not "the binary is absent".
NOINT="$W/noint"; mkdir -p "$NOINT"
for _i in jq python3 python perl node; do
  printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$NOINT/$_i"; chmod +x "$NOINT/$_i"
done
t3(){ ( cd "$R" && PATH="$NOINT:$PATH" bash "$HOOK" < "$P" >/dev/null 2>&1; printf '%s' "$?" ); }
t1(){ if [ -n "$T1PATH" ]; then ( cd "$R" && PATH="$T1PATH:$PATH" bash "$HOOK" < "$P" >/dev/null 2>&1; printf '%s' "$?" )
      else ( cd "$R" && bash "$HOOK" < "$P" >/dev/null 2>&1; printf '%s' "$?" ); fi; }

mk(){ printf '{"cwd":"/tmp","permission_mode":"default","tool_name":"Bash","tool_input":{"command":"%s"},"tool_use_id":"x"}' "$1" > "$P"; }
mkraw(){ printf '%s' "$1" > "$P"; }
hexof(){ printf '%s' "$1" | od -An -tx1 | tr -d ' \n'; }
bytes(){ od -An -tx1 "$P" | tr -d ' \n'; }

# ---------------------------------------------------------------------------------------------------------
# CALIBRATION. Nothing below is reported unless every question here answers.
# ---------------------------------------------------------------------------------------------------------
echo
echo "-- kalibrasyon --"
CAL=1
mk 'rm -rf /'; a="$(t3)"
if [ "$a" = 2 ]; then ok "yıkıcı bir komut bloklanıyor (kapı gerçekten koşuyor)"; else bad "kalibrasyon: 'rm -rf /' rc=$a"; CAL=0; fi
mk 'ls -la';   a="$(t3)"
if [ "$a" = 0 ]; then ok "zararsız bir komut geçiyor (kapı aşırı bloklamıyor)"; else bad "kalibrasyon: 'ls -la' rc=$a"; CAL=0; fi

if [ "$LADDER" = 1 ]; then
  # BOTH COLUMNS MUST MEAN WHAT THEY SAY, and each needs its own control because they fail in opposite ways.
  #
  # The rung-one column must really reach an interpreter: a stub that returns a DIFFERENT command for a
  # harmless payload flips rc 0 -> 2 only if the branch is taken. Without this the second column can silently
  # be the first column twice.
  if [ -n "$T1PATH" ]; then
    cp "$SHIM/jq" "$W/jq.real"
    { echo '#!/usr/bin/env bash'
      echo "case \"\$2\" in '.tool_input.command // empty') printf '%s\\n' 'rm -rf /' ;; '.permission_mode // empty') printf '%s\\n' default ;; *) exit 3 ;; esac"
    } > "$SHIM/jq"; chmod +x "$SHIM/jq"
    mk 'ls -la'; c="$(t1)"
    cp "$W/jq.real" "$SHIM/jq"; chmod +x "$SHIM/jq"
    if [ "$c" = 2 ]; then ok "rung-1 sütunu gerçekten bir yorumlayıcıya ulaşıyor (stub başka komut döndürünce rc 0->2)"
    else bad "kalibrasyon: rung-1 dalına girilmiyor — ikinci sütun birincinin kopyası (rc=$c)"; CAL=0; fi
  else
    mk 'ls -la'
    if jq -r '.tool_input.command // empty' < "$P" 2>/dev/null | grep -qx 'ls -la'; then
      ok "rung-1 sütunu gerçek jq ile koşuluyor"
    else bad "kalibrasyon: gerçek jq beklendiği gibi cevap vermiyor"; CAL=0; fi
  fi

  # The MIRROR control, and it is the one this file did not have: the pure-bash column must IGNORE a working
  # interpreter that is reachable. Run on the ambient PATH, `t3` was whatever rung the machine could reach — so
  # on a jq box the "pure bash" column WAS rung one, both columns meant the same thing, and a ladder-split row
  # recorded no divergence and reported that the divergence had moved. Same class as a row that only checks rc:
  # the measurement's meaning depended on which binaries happened to be installed.
  # A WORKING jq shim is placed BEHIND the shadow on the path t3 uses. If the shadow holds, `command -v jq`
  # finds the failing stub first, the rung falls through and the slice answers `ls -la` for rc=0. If the shim is
  # reached it returns `rm -rf /` and the row reads 2, which IS the shadow not taking.
  DECOYBIN="$W/decoybin"; mkdir -p "$DECOYBIN"
  { echo '#!/usr/bin/env bash'
    echo "case \"\$2\" in '.tool_input.command // empty') printf '%s\\n' 'rm -rf /' ;; '.permission_mode // empty') printf '%s\\n' default ;; *) exit 3 ;; esac"
  } > "$DECOYBIN/jq"; chmod +x "$DECOYBIN/jq"
  mk 'ls -la'
  c="$( cd "$R" && PATH="$NOINT:$DECOYBIN:$PATH" bash "$HOOK" < "$P" >/dev/null 2>&1; printf '%s' "$?" )"
  if [ "$c" = 0 ]; then ok "saf-bash sütunu erişilebilir bir yorumlayıcıyı GÖRMEZDEN geliyor (gölge tutuyor)"
  else bad "kalibrasyon: gölge tutmuyor — saf-bash sütunu bir yorumlayıcıya ulaştı (rc=$c); bu sütun ortamın kurulu ikililerine bağlı demektir"; CAL=0; fi
else
  # With one reader the shadow is a no-op, so asserting it would prove nothing. What is worth asserting instead
  # is WHY it is a no-op: the hook names no interpreter on any line that also touches the payload. A rung that
  # wrote $INPUT to a temp file and parsed the FILE would not name INPUT on the parsing line, so this looks for
  # the interpreter and the payload variable independently and reports the pair rather than requiring them to
  # share a line.
  _INTERP="$(grep -nE '(^|[^A-Za-z_])(jq|python3?|perl|node|ruby)([^A-Za-z0-9_]|$)' "$HOOK" | grep -v '^[0-9]*: *#' | grep -vc '^$' || true)"
  if [ "${_INTERP:-0}" = 0 ]; then ok "tek okuyucu: kapıda hiçbir yorumlayıcı adı geçmiyor (gölgeye gerek yok)"
  else note "tek okuyucu: kapıda $_INTERP satırda yorumlayıcı adı geçiyor — payload'ı okumuyorlarsa sorun değil, ama yapısal kontrol onları adlandırmalı"; fi
fi

# the decode comparison must be able to SEE a difference, and must be able to FAIL
mk "echo a${BS}ud83d${BS}ude00b"
d_s="$(slice_decode)"; d_r="$(ref_decode)"
# BOTH SIDES have to be checked, not just their inequality. An empty reference differs from the slice too, so
# "they differ" passed while the reference was carrying nothing at all — which is how a broken transport hid
# itself here for one run. The reference must produce the astral character; the slice must produce `??`.
if [ -z "$d_r" ]; then bad "kalibrasyon: referans vekil çift için BOŞ döndü — taşıma bozuk, 'farklılar' yanlış sebepten geçerdi"; CAL=0
elif [ "$d_s" = "$d_r" ]; then bad "kalibrasyon: bilinen fark görünmüyor — çözüm karşılaştırması boş olabilir"; CAL=0
elif [ "$d_s" = 'echo a??b' ]; then ok "bilinen çözüm farkı görünüyor (dilim '$d_s' · referans '$d_r')"
else bad "kalibrasyon: dilim vekil çift için 'echo a??b' vermedi ('$d_s') — belgelenen normalleştirme değişmiş"; CAL=0; fi

# MUTATION MUST-FAIL: break the extracted slice and require the comparison to notice
printf '%s\n' '#!/usr/bin/env bash' 'cat >/dev/null' "printf '%s' 'MUTASYON'" > "$W/dec.sh"
mk 'ls -la'; d_s="$(slice_decode)"; d_r="$(ref_decode)"
cp "$W/dec.good.sh" "$W/dec.sh"
if [ "$d_s" != "$d_r" ]; then ok "bozulmuş bir dilim çözüm karşılaştırmasında YAKALANIYOR (mutasyon testi)"
else bad "kalibrasyon: dilim kasten bozuldu ve karşılaştırma fark etmedi — kontrol ölü"; CAL=0; fi
mk 'ls -la'
if [ "$(slice_decode)" = "ls -la" ]; then ok "mutasyondan sonra gerçek dilim geri geldi"
else bad "kalibrasyon: mutasyon geri alınamadı, kalan satırlar bozuk dilimle ölçülürdü"; CAL=0; fi

# THE REFERENCE'S TRANSPORT, calibrated on values whose bytes are known before they are sent. This is the one
# the file did not have, and its absence produced a CI failure that named the reader for a fault in the
# measuring path. A reference that cannot carry a line ending intact cannot be used to judge one.
REF_LOSSY=0
mk "a${BS}nb"; _t="$(ref_decode | od -An -tx1 | tr -d ' \n')"
if [ "$_t" = "610a62" ]; then ok "referans gömülü bir LF'i bozmadan taşıyor ($( [ "$B64" = 1 ] && echo 'base64 taşıma' || echo 'doğrudan okuma' ))"
else REF_LOSSY=1; bad "referans TAŞIMASI BOZUK: LF için 610a62 beklenirken $_t döndü — bu ölçü aletinin kusuru, kapının değil"; fi
mk "a${BS}rb"; _t="$(ref_decode | od -An -tx1 | tr -d ' \n')"
if [ "$_t" = "610d62" ]; then ok "referans gömülü bir CR'i bozmadan taşıyor"
else REF_LOSSY=1; bad "referans TAŞIMASI BOZUK: CR için 610d62 beklenirken $_t döndü"; fi
# Deliberately NOT normalised away: a CR the decode really produced and a CR the pipe added are the same byte
# afterwards, so stripping them would hide a real divergence in order to spare a fake one. A lossy transport
# makes the CR/LF-bearing rows UNMEASURED instead, which is a result the next reader can act on.
[ "$REF_LOSSY" = 0 ] || note "taşıma kayıplı — satır sonu taşıyan satırlar ölçülemedi sayılacak, normalleştirilmeyecek"

if [ "$CAL" != 1 ]; then
  echo; echo "KALİBRASYON BAŞARISIZ — korpus raporlanmıyor, çünkü sonucu okunamaz."; exit 1; fi

# ---------------------------------------------------------------------------------------------------------
# THE CORPUS. Every row declares the verdict it expects, so a divergence is reported with its DIRECTION: a
# reader answering 0 where 2 was expected is a BLIND GATE; 2 where 0 was expected is an OVER-BLOCK, which
# teaches the user to reach for --no-verify and disarms all of §4.
#   $3 `need`  : the escape the fixture must really carry (`-` none, `hex:…` a whole byte sequence)
#   $5 `dec`   : `=` the slice must decode exactly what the reference decodes
#                anything else: the literal the documented normalisation must produce
# ---------------------------------------------------------------------------------------------------------
echo
echo "-- korpus --"

check_decode(){ # $1 label  $2 expectation
  local s r; s="$(slice_decode)"
  # A lossy transport cannot judge a line ending, so those rows say so rather than being compared against a
  # value the instrument mangled. The rows WITHOUT a line ending are unaffected and still run.
  if [ "$REF_LOSSY" = 1 ]; then
    case "$2$s" in
      *$'\n'*|*$'\r'*) unm "$1 · satır sonu taşıyor ve referans taşıması kayıplı — ÖLÇÜLEMEDİ"; return ;;
    esac
  fi
  if [ "$2" = "=" ]; then
    r="$(ref_decode)"
    if [ "$s" = "$r" ]; then ok "$1 · çözüm referansla aynı"
    else bad "$1 · ÇÖZÜM AYRIŞIYOR: dilim [$s] · referans [$r]"; fi
  else
    if [ "$s" = "$2" ]; then ok "$1 · çözüm belgelenen normalleştirmeyi veriyor [$2]"
    else bad "$1 · NORMALLEŞTİRME BOZULDU: beklenen [$2] · ölçülen [$s]"; fi
  fi; }

run_row(){ # $1 label  $2 expected rc  $3 need  $4 command  $5 decode expectation
  local label="$1" exp="$2" need="$3" cmd="$4" dec="$5" a b h nh dh
  mk "$cmd"
  if [ "$need" != "-" ]; then
    h="$(bytes)"
    case "$need" in
      hex:*) nh="${need#hex:}"; dh="" ;;
      *)     nh="5c$(hexof "$need")"; dh="5c5c$(hexof "$need")" ;;
    esac
    if [ -n "$dh" ]; then case "$h" in *"$dh"*) unm "$label — fixture ATIL: kaçış çift yazılmış ($dh)"; return ;; esac; fi
    case "$h" in *"$nh"*) ;; *) unm "$label — fixture ATIL: payload'da $nh baytları yok"; return ;; esac
  fi
  check_decode "$label" "$dec"
  a="$(t3)"
  if [ "$LADDER" = 1 ]; then
    b="$(t1)"
    if [ "$a" != "$b" ]; then
      if [ "$a" = "$exp" ]; then bad "$label · AYRIŞIYOR: tier1 rc=$b, beklenen $exp $( [ "$exp" = 2 ] && echo '(tier1 KÖR)' || echo '(tier1 AŞIRI BLOKLUYOR)' )"
      else bad "$label · AYRIŞIYOR: tier3 rc=$a, beklenen $exp $( [ "$exp" = 2 ] && echo '(tier3 KÖR)' || echo '(tier3 AŞIRI BLOKLUYOR)' )"; fi
      return
    fi
  fi
  if [ "$a" = "$exp" ]; then ok "$label · hüküm rc=$a"
  else bad "$label · HÜKÜM YANLIŞ: rc=$a, beklenen $exp $( [ "$exp" = 2 ] && echo '(KÖR KAPI)' || echo '(AŞIRI BLOK)' )"; fi; }

U="${BS}u"     # the two characters a JSON unicode escape starts with, built at run time
run_row 'düz commit'                    2 -  'git commit -m c'                    '='
run_row 'pathspec commit'               2 -  'git commit -m c -- a.txt'           '='
run_row 'devam + LF'                    2 hex:5c5c5c6e  "git commit ${BS}${BS}${BS}n  -m c"   '='
run_row 'devam + CRLF'                  2 hex:5c5c5c72  "git commit ${BS}${BS}${BS}r${BS}n  -m c"  "git commit ${BS}"$'\n'"  -m c"
run_row 'CRLF ayraç'                    2 r  "git commit -m c${BS}r${BS}necho done"  "git commit -m c"$'\n'"echo done"
run_row 'yalnız CR'                     2 r  "git commit -m c${BS}recho done"        'git commit -m cecho done'
run_row 'sekme ayraçlı'                 2 t  "git commit${BS}t-m${BS}tc"             "git commit"$'\t'"-m"$'\t'"c"
run_row 'kaçışlı tırnak'                2 '"' "git commit -m ${BS}\"a b${BS}\""      'git commit -m "a b"'
run_row 'rm -rf kök'                    2 -  'rm -rf /'                           '='
run_row 'force push'                    2 -  'git push --force'                   '='
run_row 'git add -f'                    2 -  'git add -f secrets.env'             '='
run_row 'PowerShell özyinelemeli sil'   2 -  "Remove-Item -Recurse -Force C:${BS}${BS}x"  "Remove-Item -Recurse -Force C:${BS}x"
run_row 'gate betiği (düz)'             2 -  'echo x > .claude/hooks/guard-bash.sh'  '='
run_row 'gate betiği (\u kaçışlı)'      2 u  "echo x > ${U}002eclaude/hooks/guard-bash.sh"  'echo x > .claude/hooks/guard-bash.sh'
run_row 'gate yolunu okuma (\u)'        0 u  "cat ${U}002eclaude/hooks/guard-bash.sh"      'cat .claude/hooks/guard-bash.sh'
run_row 'latin kaçışları -> ?'          0 u  "echo ${U}00e7${U}011f${U}0131"        'echo ???'
run_row 'vekil çift -> ??'              0 u  "echo a${U}d83d${U}de00b"              'echo a??b'
run_row 'NUL kaçışı -> ?'               0 u  "echo a${U}0000b"                      'echo a?b'
run_row 'backspace -> boşluk'           0 b  "echo a${BS}bb"                        'echo a b'
run_row 'formfeed -> boşluk'            0 f  "echo a${BS}fc"                        'echo a c'
run_row 'kaçışlı bölü'                  0 /  "cat a${BS}/b${BS}/c.txt"              'cat a/b/c.txt'
run_row 'zararsız komut'                0 -  'echo not-a-command'                 '='
run_row 'boş komut'                     0 -  ''                                   '='

# ---------------------------------------------------------------------------------------------------------
# ADVERSARIAL SHAPES — whole objects rather than commands, because the question is which VALUE each reader
# takes for a key, not what the command says. RFC 8259 leaves duplicate names undefined, so neither "first
# wins" nor "last wins" is wrong on its own; what matters is that the gate does not judge one value while
# showing the user another.
# ---------------------------------------------------------------------------------------------------------
echo
echo "-- düşmanca biçimler --"
# AN EXIT CODE IS NOT A REASON. A row asserting rc=2 passes while the gate refuses for a rule that has nothing
# to do with the shape under test, and then keeps passing until the fixture changes. That happened here twice:
#   * a payload whose only `"command"` sat in a SIBLING object was read as "the refusal closed the hole" — the
#     slice had in fact read the sibling value and §4.5's `destructive rm -rf` fired on it. The harmless twin
#     (`ls -la` in the same place) returns 0, which is what makes the real behaviour visible: the gate judges a
#     string that is not the command that will run.
#   * every adversarial payload carried `"cwd":"/tmp"`, where no review record exists, so each row whose
#     command was a commit was refused by §4.6 before its own rule was ever reached.
# So: the payload's cwd is the prepared repo, each row may name the RULE it expects to fire, and the string the
# slice actually read is printed on every failure.
# EVERYTHING UP TO THE CLOSING PAREN, rather than a class of the characters a tag is expected to contain. A
# refusal protecting two sections is tagged `GUARD (§4.4/§4.5)`, and two narrower attempts both failed on it:
# `§[0-9.]+` stopped at the `/` and captured `GUARD (§4.4` with no closing paren, then `§[0-9./]+` stopped at
# the SECOND `§` and matched nothing at all, so the row reported "no rule fired" for a refusal that names two.
# Adding `§` to the class would also be fragile under `LC_ALL=C`, where it is two bytes. `[^)]*` has no opinion
# about what a tag may contain, which is the right amount of opinion for something whose job is to read one.
t3err(){ ( cd "$R" && PATH="$NOINT:$PATH" bash "$HOOK" < "$P" 2>&1 >/dev/null ) | tr -d '\r' | grep -oE 'GUARD \([^)]*\)' | head -1; }
slice_reads(){ bash "$W/dec.sh" < "$P" 2>/dev/null; }

adv(){ # $1 label  $2 expected rc  $3 rule  $4 raw payload  [$5 known-open:<t3>/<t1>]
  #   $3 = `-`            do not check why it answered
  #        `§4.x`         the hook's own tag must contain this
  #                       An ambiguity refusal is named this way rather than by the destructive rule that used
  #                       to fire: the kit refuses a payload it cannot read unambiguously instead of picking a
  #                       winner, so the refusal comes FIRST and no command is judged at all. A row naming the
  #                       destructive rule would be asserting a last-wins policy this kit does not have.
  #        `ladder-split` while a reader ladder exists this payload is EXPECTED to diverge, because the
  #                       divergence IS the ladder's defect; with one reader the row must reach $2 instead.
  local label="$1" exp="$2" want="$3" a b r known="${5:-}"
  mkraw "${4//@CWD@/$R}"; a="$(t3)"
  if [ "$LADDER" = 1 ]; then b="$(t1)"; else b="$a"; fi
  if [ -n "$known" ] && [ "${CSK_CONFORMANCE_KNOWN_OPEN:-0}" = 1 ]; then
    # A known-open row is a divergence this file FOUND that nothing has fixed yet. It is pinned to the exact
    # shape observed so it cannot rot: if the shape moves, or if the row starts passing, this FAILS and says so.
    local want="${known#known-open:}"
    if [ "$a" = "$b" ] && [ "$a" = "$exp" ]; then bad "$label — ARTIK GEÇİYOR: bulgu düzeltilmiş, known-open işareti kaldırılmalı"; return; fi
    if [ "$a/$b" = "$want" ]; then KNOWN_OPEN=$((KNOWN_OPEN+1))
      printf '  \033[33mAÇIK\033[0m %s — bilinen ayrışma, kayıtlı: %s (beklenen %s)\n' "$label" "$a/$b" "$exp"; return; fi
    bad "$label — bilinen ayrışma DEĞİŞTİ: kayıt $want, ölçülen $a/$b"; return
  fi
  if [ "$want" = "ladder-split" ]; then
    # Two readers, one of which cannot see this shape at all — that IS the ladder's defect, so while the ladder
    # exists the row asserts the divergence rather than pretending it is absent. Pinned to the exact pair, so a
    # change in the shape fails, and so does the divergence DISAPPEARING while the ladder is still there: that
    # would mean something else moved and the row is no longer describing what it says it describes.
    if [ "$LADDER" = 1 ]; then
      if [ "$a" = 2 ] && [ "$b" = 0 ]; then ok "$label · merdiven dururken AYRIŞIYOR (t3=2 t1=0) — merdivenin kusuru, silinince kapanmalı"
      else bad "$label · merdivenli ayrışma DEĞİŞTİ: kayıt t3=2/t1=0, ölçülen t3=$a/t1=$b · dilim okudu [$(slice_reads)]"; fi
      return
    fi
    if [ "$a" = "$exp" ]; then ok "$label · tek okuyucuda kapandı (rc=$a)"
    else bad "$label · merdiven gitti ama HÂLÂ AÇIK: rc=$a, beklenen $exp · dilim okudu [$(slice_reads)]"; fi
    return
  fi
  if [ "$LADDER" = 1 ] && [ "$a" != "$b" ]; then
    bad "$label — AYRIŞIYOR: tier3 rc=$a · tier1 rc=$b (beklenen $exp) · dilim okudu [$(slice_reads)]"; return; fi
  if [ "$a" != "$exp" ]; then
    bad "$label — rc=$a, beklenen $exp $( [ "$exp" = 2 ] && echo '(KÖR KAPI)' || echo '(AŞIRI BLOK)' ) · dilim okudu [$(slice_reads)]"; return; fi
  if [ "$want" != "-" ]; then
    # the hook prints `GUARD (§4.5): …`, the row names `§4.5`, so this is a containment test and not equality —
    # written as equality first, which reported "beklenen §4.5, ateşlenen GUARD (§4.5)" on rows that were right.
    r="$(t3err)"
    case "$r" in
      *"$want"*) ok "$label (rc=$a, $want)"; return ;;
      *) bad "$label — rc=$exp DOĞRU AMA SEBEP YANLIŞ: beklenen $want, ateşlenen ${r:-hiçbir kural} · dilim okudu [$(slice_reads)]"; return ;;
    esac
  fi
  ok "$label (rc=$a)"; }

adv 'command anahtarı iki kez'                 2 '§4.4' \
  '{"cwd":"@CWD@","permission_mode":"default","tool_name":"Bash","tool_input":{"command":"ls -la","command":"rm -rf /"},"tool_use_id":"x"}'
adv 'gövdede sahte command anahtarı'           2 '§4.5' \
  '{"cwd":"@CWD@","permission_mode":"default","tool_name":"Bash","tool_input":{"description":"\"command\":\"ls\"","command":"rm -rf /"},"tool_use_id":"x"}'
adv 'gerçek anahtardan önce iç içe nesne'      2 '§4.4' \
  '{"cwd":"@CWD@","permission_mode":"default","tool_name":"Bash","tool_input":{"meta":{"command":"ls -la"},"command":"rm -rf /"},"tool_use_id":"x"}'
adv 'kapanıştan önce kaçışlı tırnak'           2 '§4.5' \
  '{"cwd":"@CWD@","permission_mode":"default","tool_name":"Bash","tool_input":{"command":"rm -rf / --no-preserve-root \"x\""},"tool_use_id":"x"}'
adv 'kapanıştan önce kaçışlı ters bölü'        0 '-' \
  '{"cwd":"@CWD@","permission_mode":"default","tool_name":"Bash","tool_input":{"command":"echo C:\\\\"},"tool_use_id":"x"}'
adv 'anahtar sırası: tool_input önce'          2 '§4.5' \
  '{"tool_input":{"command":"rm -rf /"},"tool_name":"Bash","cwd":"@CWD@","permission_mode":"default","tool_use_id":"x"}'

# THE SLICE MUST NOT READ A VALUE FROM OUTSIDE tool_input, and the pair below is what makes that visible. The
# dangerous shape alone proves nothing: it is refused, but by §4.5 firing on the string the slice pulled out of
# the SIBLING object — the gate judging text that is not the command that will run. The harmless twin is the
# row that shows it, because there is nothing in `ls -la` for any rule to catch.
# Reported once as "the refusal closes this hole". It does not. It was the twin that was missing.
adv 'kardeş nesnede yıkıcı komut'              2 'ladder-split' \
  '{"cwd":"@CWD@","permission_mode":"default","tool_name":"Bash","tool_input":{"foo":1},"meta":{"command":"rm -rf /"},"tool_use_id":"x"}'
adv 'kardeş nesnede zararsız komut (İKİZ)'     0 '-' \
  '{"cwd":"@CWD@","permission_mode":"default","tool_name":"Bash","tool_input":{"foo":1},"meta":{"command":"ls -la"},"tool_use_id":"x"}'
adv 'sade payload hâlâ geçiyor (ikiz)'         0 '-' \
  '{"cwd":"@CWD@","permission_mode":"default","tool_name":"Bash","tool_input":{"command":"ls -la"},"tool_use_id":"x"}'

# THE KEY NAME AS A VALUE. `_json_slice` searches for the bytes `"key"` and does not require the colon that
# follows a real key, so a payload carrying the key's NAME as a VALUE relocates the parse — and the ambiguity
# gates that count `"key":` do not see the same thing the parser found. Here the slice reads `ls` while the
# command that will actually run is `rm -rf /`.
adv 'anahtar adı DEĞER olarak (command)'       2 '§4.5' \
  '{"cwd":"@CWD@","a":"command","ls":1,"permission_mode":"default","tool_name":"Bash","tool_input":{"command":"rm -rf /"},"tool_use_id":"x"}'
adv 'kontrol: aynı komut, gölgesiz (ikiz)'     2 '§4.5' \
  '{"cwd":"@CWD@","permission_mode":"default","tool_name":"Bash","tool_input":{"command":"rm -rf /"},"tool_use_id":"x"}'

# WHITESPACE BEFORE THE COLON is legal JSON and the parser and its guard must agree about it. The unspaced twin
# sits next to it so a red row can be read: if both are red the cause is the nested key, if only the spaced one
# is red the cause is the spacing.
adv 'iki noktadan önce boşluk'                 2 '§4.5' \
  '{"cwd":"@CWD@","permission_mode":"default","tool_name":"Bash","tool_input":{"command" : "rm -rf /"},"tool_use_id":"x"}'
adv 'kontrol: boşluksuz ikiz'                  2 '§4.5' \
  '{"cwd":"@CWD@","permission_mode":"default","tool_name":"Bash","tool_input":{"command":"rm -rf /"},"tool_use_id":"x"}'

# permission_mode: §4.4 fails CLOSED under bypassPermissions, so a key that shadows the real one moves the gate
# from refuse to ask, and under bypass the harness answers ask with allow. The cwd is the prepared repo, not
# /tmp: with no review record §4.6 refuses a commit before §4.4 is ever reached, and every one of these rows
# would have passed on that unrelated rule. That is exactly what they did before this was fixed.
adv 'permission_mode iki kez (gölgeli bypass)' 2 '§4.4' \
  '{"cwd":"@CWD@","meta":{"permission_mode":"default"},"permission_mode":"bypassPermissions","tool_name":"Bash","tool_input":{"command":"git commit -m x"},"tool_use_id":"x"}'
adv 'permission_mode DEĞER olarak'             2 '§4.4' \
  '{"cwd":"@CWD@","a":"permission_mode","default":1,"permission_mode":"bypassPermissions","tool_name":"Bash","tool_input":{"command":"git commit -m x"},"tool_use_id":"x"}'
adv 'dürüst bypass (ikiz)'                     2 '§4.4' \
  '{"cwd":"@CWD@","permission_mode":"bypassPermissions","tool_name":"Bash","tool_input":{"command":"git commit -m x"},"tool_use_id":"x"}'
adv 'permission_mode yok (ikiz, meşru)'        2 '§4.4' \
  '{"cwd":"@CWD@","tool_name":"Bash","tool_input":{"command":"git commit -m x"},"tool_use_id":"x"}'
adv 'dürüst default: ask, blok değil (ikiz)'   0 '-' \
  '{"cwd":"@CWD@","permission_mode":"default","tool_name":"Bash","tool_input":{"command":"git commit -m x"},"tool_use_id":"x"}'

# The key NAME written as a unicode escape. A reader that decodes key names finds `command` and judges
# `rm -rf /`; one that searches for the literal bytes finds nothing and the gate has no command to judge. The
# safe answer is the refusal either way, so 2 is expected and a reader answering 0 is BLIND, not lenient.
# The backslash is built at run time and the payload's BYTES are checked before the row is allowed to count:
# written literally, the escape has arrived here as an escaped backslash — inert text every reader agrees
# about — and the row would have reported a pass while measuring nothing.
ESCKEY="{\"cwd\":\"@CWD@\",\"permission_mode\":\"default\",\"tool_name\":\"Bash\",\"tool_input\":{\"${BS}u0063ommand\":\"rm -rf /\"},\"tool_use_id\":\"x\"}"
case "$(printf '%s' "$ESCKEY" | od -An -tx1 | tr -d ' \n')" in
  *5c5c7530303633*) bad 'anahtar adı \u kaçışlı — fixture ATIL: çift ters bölü' ;;
  *5c7530303633*)   adv 'anahtar adı \u kaçışlı' 2 '-' "$ESCKEY" ;;
  *)                bad 'anahtar adı \u kaçışlı — fixture kurulamadı' ;;
esac

echo
# Every assertion must have been visible to the parent. A row lost to a subshell is worse than a red one: a
# `bad` there prints and cannot fail the run, so the gate is silently always-green from that line onward.
if [ "$_ALZ" = 1 ]; then
  _ao="$(_analyse "$ASSERTLOG" "$((PASS+FAILED+UNMEASURED))")"
  _ah="$(printf '%s' "$_ao" | sed -n 's/^HITS=//p')"
  if [ "${_ah:-0}" != 0 ]; then
    printf '  \033[31mFAIL\033[0m %s\n' "$_ah iddia ALT KABUKTA koştu — sayaca ulaşmadılar, bir 'bad' orada görünmez olurdu:"
    printf '%s\n' "$_ao" | grep '>>'
    FAILED=$((FAILED+1))
  fi
fi
rm -f "$ASSERTLOG"
printf 'PARSER-CONFORMANCE: %s geçti · %s başarısız · %s ölçülemedi · %s bilinen-açık  (kip: %s · referans: %s)\n' \
  "$PASS" "$FAILED" "$UNMEASURED" "$KNOWN_OPEN" \
  "$( [ "$LADDER" = 1 ] && echo 'merdivenli' || echo 'tek okuyucu' )" "$REFKIND"
if [ "$KNOWN_OPEN" -gt 0 ]; then
  echo "$KNOWN_OPEN bilinen ayrışma AÇIK ve bu koşuda başarısızlık sayılmadı (CSK_CONFORMANCE_KNOWN_OPEN=1)."
fi
if [ "$FAILED" -gt 0 ]; then echo "Okuyucu referanstan ayrıştı ya da bir hüküm yanlış. Bu kapatılmalı."; exit 1; fi
if [ "$UNMEASURED" -gt 0 ]; then echo "Bazı satırlar ölçülemedi — bu bir geçiş değildir, fixture'ları düzeltin."; exit 1; fi
echo "Kapının okuyucusu her vakada referansla aynı sonuca vardı."
exit 0
