# settings-json.awk — Crewforth's one JSON reader for settings.json, POSIX awk only (no jq, no python3), so the
# same code runs on macOS BSD awk, Linux mawk/gawk and Windows Git-Bash gawk.
#
#   awk -v op=validate -f settings-json.awk FILE              rc 0 = FILE is a JSON object, 1 = it is not
#   awk -v op=get -v path=hooks.Stop.0 -f settings-json.awk FILE   the value there, as the merge would print it
#   awk -v op=len -v path=hooks.Stop -f settings-json.awk FILE     how many entries an array/object holds
#   awk -v op=gets -v path='a.b|c.d' -f settings-json.awk FILE   several values in one read, tab-separated, "" if absent
#   awk -v op=strings -v path=permissions.deny -f settings-json.awk FILE   each string element of that array, one per
#       line, quotes off, escapes as written (rc 1 = not an array)
#   awk -v op=keys [-v path=P] -f settings-json.awk FILE   the member names of the object there, one per line, quotes
#       off, in file order (rc 1 = not an object)
#       path = dot-separated keys, a number indexes an array (0-based), empty = the root. rc 1 = no such path
#       (or, for len, a scalar there), 10 = FILE is not a JSON object.
#   awk -v op=get -v path=P -v setk=M -v setv=RAWJSON -f settings-json.awk FILE   the object at P with member M set
#       to RAWJSON (added when absent): a payload rewritten in one field, every other field and escape kept
#       (rc 1 = nothing at P, or not an object)
#   awk -v op=overlay -v key=K [-v setk=M -v setv=RAWJSON] -f settings-json.awk FILE1 FILE2
#       FILE1 with FILE1.K shallow-merged from FILE2.K (FILE2 wins, FILE1's other members and order kept), then
#       member M set to RAWJSON. rc 10 = FILE1 (or its K) is not an object, 11 = FILE2 has no object at K.
#   awk -v op=merge -v retired='R1|R2' -f settings-json.awk KIT PROJECT > OUT
#       rc 0 = merged JSON on stdout · 10 = PROJECT is not a JSON object · 11 = KIT is not · 12 = "hooks" has a
#       shape the merge cannot place (not an object of arrays). Nothing is printed on a non-zero rc. The codes sit
#       clear of awk's own 2 (bad program, unreadable file), so a caller never reads a missing file as bad JSON.
#
# Reader contract: a recursive-descent parse into nodes (T = o/a/s, N = child count, K = key, C = child, V = raw
# scalar text). Strings are kept as their raw token, escapes included and never decoded, so they are written back
# byte-for-byte; two spellings of one string (\u0041 vs A) therefore count as different. Object key order and
# array order are preserved. Numbers are checked against the JSON grammar and kept as written.
#
# Merge semantics (what the former jq program in adopt.sh did, held to it by the parity fixture in
# packaging/e2e.sh): objects deep-merge, the PROJECT's scalar wins, arrays concat+dedup with Crewforth's entries
# first, and "hooks" is rebuilt per event as Crewforth's entries followed by the project's entries that do not
# reference .claude/hooks/ (in "command" or "args"). permissions.ask then loses every rule named in -v retired.
# Output is pretty-printed with two-space indent, the layout jq writes, so merging Crewforth onto itself gives its
# own bytes back.
# The text is split into CH[] once. substr(S,P,1) is O(len) per call on BSD awk, which made a 1 MB file take ~20 s;
# array indexing is O(1), so parsing is linear. split(s, CH, "") splits into characters in onetrue/BSD awk, gawk
# and mawk alike.
function sk(){ while(P<=L && index(" \t\r\n", CH[P])) P++ }
# Strings are held to RFC 8259, the grammar Claude Code's JSON.parse applies: an escape is one of \" \\ \/ \b \f \n
# \r \t or \u + 4 hex digits, and no raw control character (below 0x20). The raw token is returned, escapes kept.
function ps(  t,c,i){ t=CH[P]; P++
  while(P<=L){ c=CH[P]; P++
    if(c=="\\"){ if(P>L) return ""; c=CH[P]; P++
      if(c=="u"){ t=t "\\u"; for(i=0;i<4;i++){ if(P>L || !index("0123456789abcdefABCDEF", CH[P])) return ""; t=t CH[P]; P++ }; continue }
      if(!index("\"\\/bfnrt", c)) return ""; t=t "\\" c; continue }
    if(index(CTL, c)) return ""
    t=t c; if(c=="\"") return t }
  return "" }
function pv(  id,c,k,q,st){ sk(); c=CH[P]; id=++NN; N[id]=0
  if(c=="{" || c=="["){ T[id]=(c=="{" ? "o" : "a"); P++; sk()
    if(CH[P]==(c=="{" ? "}" : "]")){ P++; return id }
    while(1){ k=""
      if(c=="{"){ sk(); if(CH[P]!="\"" || (k=ps())=="") return 0; sk(); if(CH[P++]!=":") return 0 }
      if(!(q=pv())) return 0
      N[id]++; K[id,N[id]]=k; C[id,N[id]]=q; sk(); st=CH[P++]
      if(st==(c=="{" ? "}" : "]")) return id
      if(st!=",") return 0 } }
  T[id]="s"
  if(c=="\""){ V[id]=ps(); return (V[id]=="" ? 0 : id) }
  st=""; while(P<=L && CH[P] ~ /[-+.0-9A-Za-z]/){ st=st CH[P]; P++ }; V[id]=st
  return (V[id] ~ /^(true|false|null|-?(0|[1-9][0-9]*)([.][0-9]+)?([eE][-+]?[0-9]+)?)$/ ? id : 0) }
# doc(f): parse file number f. CH[] is built from that file's lines directly: gluing the lines into one string
# first was itself quadratic (each append copies the whole buffer) on a many-line file.
function doc(f,  r,i,j,n,tc){ split("",CH); L=0
  for(i=1;i<=NL[f];i++){ n=split(LN[f,i],tc,""); for(j=1;j<=n;j++) CH[++L]=tc[j]; CH[++L]="\n" }
  P=1
  if(CTL==""){ for(r=1;r<32;r++) CTL=CTL sprintf("%c",r) }
  r=pv(); sk(); return (r && P>L && T[r]=="o") ? r : 0 }
# A duplicated key: the LAST value wins, as in JSON.parse and jq — the value Claude Code actually reads.
function get(o,k,  i){ for(i=N[o];i>=1;i--) if(K[o,i]==k) return C[o,i]; return 0 }
function isnull(id){ return T[id]=="s" && V[id]=="null" }
function at(id,path,  n,sg,i){ n=split(path,sg,".")
  for(i=1;i<=n && id;i++) id=(T[id]=="o") ? get(id,"\"" sg[i] "\"") : (T[id]=="a" && sg[i] ~ /^[0-9]+$/ && sg[i]<N[id]) ? C[id,sg[i]+1] : 0
  return id }
function mk(t){ NN++; T[NN]=t; N[NN]=0; return NN }
function add(o,k,c){ N[o]++; K[o,N[o]]=k; C[o,N[o]]=c }
# Member k of object o set to the raw JSON v, added at the end when o has none (overlay and get share it).
function setm(o,k,v,  sn,i,x){ sn=mk("s"); V[sn]=v; x=0
  for(i=1;i<=N[o];i++) if(K[o,i]=="\"" k "\""){ C[o,i]=sn; x=1 }
  if(!x) add(o,"\"" k "\"",sn) }
function canon(id,  i,j,n,s,t,ord){
  if(T[id]=="s") return V[id]
  if(T[id]=="a"){ s="["; for(i=1;i<=N[id];i++) s=s (i>1 ? "," : "") canon(C[id,i]); return s "]" }
  n=N[id]; for(i=1;i<=n;i++) ord[i]=i
  for(i=2;i<=n;i++) for(j=i;j>1 && K[id,ord[j-1]]>K[id,ord[j]];j--){ t=ord[j]; ord[j]=ord[j-1]; ord[j-1]=t }
  s="{"; for(i=1;i<=n;i++) s=s (i>1 ? "," : "") K[id,ord[i]] ":" canon(C[id,ord[i]]); return s "}" }
function cat(a,b,  r,i,c,seen){ r=mk("a")
  for(i=1;i<=N[a];i++){ c=canon(C[a,i]); if(!(c in seen)){ seen[c]=1; add(r,"",C[a,i]) } }
  for(i=1;i<=N[b];i++){ c=canon(C[b,i]); if(!(c in seen)){ seen[c]=1; add(r,"",C[b,i]) } }
  return r }
function dm(a,b,  r,i,x){ r=mk("o")
  for(i=1;i<=N[a];i++){ x=get(b,K[a,i]); add(r,K[a,i], !x ? C[a,i] : (T[C[a,i]]=="o" && T[x]=="o") ? dm(C[a,i],x) : (T[C[a,i]]=="a" && T[x]=="a") ? cat(C[a,i],x) : x) }
  for(i=1;i<=N[b];i++) if(!get(a,K[b,i])) add(r,K[b,i],C[b,i])
  return r }
function has_kit(s){ return T[s]=="s" && index(V[s], ".claude/hooks/") }
function is_kit(e,  hs,i,h,a,j){ hs=get(e,"\"hooks\""); if(T[e]!="o" || T[hs]!="a") return 0
  for(i=1;i<=N[hs];i++){ h=C[hs,i]; if(T[h]!="o") continue
    if(has_kit(get(h,"\"command\""))) return 1
    a=get(h,"\"args\""); if(T[a]=="a") for(j=1;j<=N[a];j++) if(has_kit(C[a,j])) return 1 }
  return 0 }
function hooks(kh,ph,  r,i,e,a,x,y,j){ r=mk("o")
  for(i=1;i<=N[kh];i++){ e=K[kh,i]; if(!get(r,e)) add(r,e,mk("a")) }
  for(i=1;i<=N[ph];i++){ e=K[ph,i]; if(!get(r,e)) add(r,e,mk("a")) }
  for(i=1;i<=N[r];i++){ e=K[r,i]; a=C[r,i]; x=get(kh,e); y=get(ph,e)
    if(isnull(x)) x=0; if(isnull(y)) y=0          # null event = no entries, as the jq merge's `// []` read it
    if((x && T[x]!="a") || (y && T[y]!="a")) return 0
    for(j=1;j<=N[x];j++) add(a,"",C[x,j])
    for(j=1;j<=N[y];j++) if(!is_kit(C[y,j])) add(a,"",C[y,j]) }
  return r }
function put(id,ind,  i,s,o){
  if(T[id]=="s") return V[id]
  o=(T[id]=="o"); if(!N[id]) return (o ? "{}" : "[]")
  s=(o ? "{" : "["); for(i=1;i<=N[id];i++) s=s (i>1 ? "," : "") "\n" ind "  " (o ? K[id,i] ": " : "") put(C[id,i], ind "  ")
  return s "\n" ind (o ? "}" : "]") }
# dls(s): parse one string (a JSONL record) the same way.
function dls(s,  r,n){ split("",CH); L=split(s,CH,""); P=1
  if(CTL==""){ for(r=1;r<32;r++) CTL=CTL sprintf("%c",r) }
  r=pv(); sk(); return (r && P>L && T[r]=="o") ? r : 0 }
FILENAME!=cur{ f++; cur=FILENAME } { LN[f,++NL[f]]=$0 }
END{
  # op=usage (hooks/context-usage.sh): FILE is a transcript tail (JSONL). Walking from the LAST line back, print the
  # context total of the last record that is a real top-level `type: assistant`, not a sidechain, carrying
  # message.usage.cache_read_input_tokens — the predicate the former jq program applied. Each candidate is PARSED:
  # a regex over the line matched the same key names inside tool inputs and results, and could count a nested
  # object instead of the record's own usage. A line that does not parse (the window's cut first line) is skipped.
  if(op=="usage"){ for(i=NL[1];i>=1;i--){ l=LN[1,i]; if(!index(l,"cache_read_input_tokens")) continue
      if(!(r=dls(l))) continue
      x=get(r,"\"isSidechain\""); if(x && !(isnull(x) || V[x]=="false")) continue
      x=get(r,"\"type\""); if(!x || V[x]!="\"assistant\"") continue
      u=at(r,"message.usage"); if(T[u]!="o") continue
      cr=get(u,"\"cache_read_input_tokens\""); if(!cr || isnull(cr)) continue
      it=get(u,"\"input_tokens\""); cc=get(u,"\"cache_creation_input_tokens\"")
      print (it && !isnull(it) ? V[it] : 0) + V[cr] + (cc && !isnull(cc) ? V[cc] : 0); exit 0 }
    exit 0 }
  if(op=="validate") exit !doc(1)
  # gets: several paths in one read (path = "a.b|c.d"), their values on one line, tab-separated; an absent one is
  # empty. One process for what a hot caller (the status line) would otherwise read with one awk per field.
  if(op=="gets"){ if(!(r=doc(1))) exit 10; n=split(path,pp,"|"); o=""
    for(i=1;i<=n;i++){ x=at(r,pp[i]); o=o (i>1?"\t":"") (x ? put(x,"") : "") } print o; exit 0 }
  if(op=="get" || op=="len"){ if(!(r=doc(1))) exit 10; if(!(r=at(r,path))) exit 1
    if(op=="get"){ if(setk!=""){ if(T[r]!="o") exit 1; setm(r,setk,setv) } print put(r,""); exit 0 }
    if(T[r]=="s") exit 1; print N[r]; exit 0 }
  if(op=="strings"){ if(!(r=doc(1))) exit 10; if(!(r=at(r,path))) exit 1; if(T[r]!="a") exit 1
    for(i=1;i<=N[r];i++){ c=C[r,i]; if(T[c]=="s" && substr(V[c],1,1)=="\"") print substr(V[c],2,length(V[c])-2) }
    exit 0 }
  if(op=="keys"){ if(!(r=doc(1))) exit 10; if(!(r=at(r,path))) exit 1; if(T[r]!="o") exit 1
    for(i=1;i<=N[r];i++){ k=K[r,i]; print substr(k,2,length(k)-2) } exit 0 }
  if(op=="overlay"){ if(!(t=doc(1))) exit 10; if(!(q=doc(2))) exit 11; kk="\"" key "\""
    qv=get(q,kk); if(T[qv]!="o") exit 11; tv=get(t,kk); if(tv && T[tv]!="o") exit 10
    nv=mk("o"); for(i=1;i<=N[tv];i++){ x=get(qv,K[tv,i]); add(nv,K[tv,i], x ? x : C[tv,i]) }
    for(i=1;i<=N[qv];i++) if(!get(nv,K[qv,i])) add(nv,K[qv,i],C[qv,i])
    if(setk!="") setm(nv,setk,setv)
    x=0; for(i=1;i<=N[t];i++) if(K[t,i]==kk){ C[t,i]=nv; x=1 }
    if(!x) add(t,kk,nv)
    print put(t,""); exit 0 }
  if(!(k=doc(1))) exit 11
  if(!(p=doc(2))) exit 10
  kh=get(k,"\"hooks\""); ph=get(p,"\"hooks\""); if(isnull(kh)) kh=0; if(isnull(ph)) ph=0
  if((kh && T[kh]!="o") || (ph && T[ph]!="o")) exit 12
  r=dm(k,p); if(!(h=hooks(kh ? kh : mk("o"), ph ? ph : mk("o")))) exit 12
  for(i=1;i<=N[r];i++) if(K[r,i]=="\"hooks\""){ C[r,i]=h; h=0 }
  if(h) add(r,"\"hooks\"",h)
  n=split(retired,rr,"|"); for(i=1;i<=n;i++) ret["\"" rr[i] "\""]=1
  pm=get(r,"\"permissions\""); ak=(T[pm]=="o" ? get(pm,"\"ask\"") : 0)
  if(T[ak]=="a"){ na=mk("a"); for(i=1;i<=N[ak];i++) if(T[C[ak,i]]!="s" || !(V[C[ak,i]] in ret)) add(na,"",C[ak,i])
    for(i=1;i<=N[pm];i++) if(K[pm,i]=="\"ask\"") C[pm,i]=na }
  print put(r,"")
}
