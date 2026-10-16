#!/usr/bin/env bash
# ensure-node.sh — find a Node the panel can run on, and when asked, go and get one.
#
# Every gate in this kit is bash and needs nothing installed. The panel is the one
# component that needs a runtime, and a machine without Node used to get a dead end:
# "install Node 18+, then come back". This script is the kit doing that itself.
#
#   ensure-node.sh                  print a usable node's path on stdout; exit 1 if there is none
#   ensure-node.sh --explain        the same, narrating every place it looked (on stderr)
#   ensure-node.sh --plan           say exactly what --install would fetch and where; change nothing
#   ensure-node.sh --install        fetch one into ~/.claude/studio-runtime (asks first)
#   ensure-node.sh --install --yes  fetch without asking (for scripts and CI)
#   ensure-node.sh --probe <path>   exit 0 if that binary is a Node at or above the floor
#
# What it will not do: touch the system. No admin rights, no package manager, no PATH
# edit, no shell profile. The runtime lands in one directory under $HOME and is used by
# its full path. Removing that directory undoes everything this script ever did.
#
# Env: CSK_STUDIO_NODE          a node binary to trust ahead of any search
#      CSK_STUDIO_RUNTIME       where fetched runtimes live (default ~/.claude/studio-runtime)
#      CSK_STUDIO_NODE_VERSION  pin a version instead of asking nodejs.org for the newest LTS
set -u

# The floor is stated here and in eval/preflight.sh. Two copies, because preflight ships
# in editions that carry no panel — so selfcheck pins them equal instead.
FLOOR=18
DIST=https://nodejs.org/dist
# Used only when nodejs.org cannot be reached to ask which release is current.
FALLBACK_VERSION=v24.21.0

# Windows caps a full file path at 260 characters and PowerShell's Expand-Archive enforces it.
# Measured: a 141-character target failed with PathTooLongException at __generated__\google\api\…
# after 17 seconds and left nothing behind, while unzip extracted the same archive to the same
# place in 3 seconds. So the fallback is not merely slower than unzip, it is strictly weaker,
# and the difference only shows on a long path.
WIN_MAX_PATH=260
NODE_DEEPEST_ENTRY=125          # measured inside v24.21.0's zip; a deeper future release makes
                                # this under-warn rather than over-warn, which is the safe side
WIN_DIR_BUDGET=$((WIN_MAX_PATH - NODE_DEEPEST_ENTRY - 1))

RUNTIME="${CSK_STUDIO_RUNTIME:-$HOME/.claude/studio-runtime}"
EXPLAIN=0
YES=0
MODE=resolve
PROBE=""

say() { [ "$EXPLAIN" = 1 ] && printf '%s\n' "$*" >&2; return 0; }
die() { printf '%s\n' "$*" >&2; exit 1; }

# A name that resolves is not a working interpreter: the Windows Store ships a stub that
# satisfies `command -v`, prints nothing and exits 49. So run it and read the major it
# reports. The cheap tests come first so an unmatched glob never costs a process — on
# Git Bash a fork is 20-50 ms and this list is long.
works() {
  [ -n "${1:-}" ] || return 1
  case "$1" in
    */*) [ -f "$1" ] || return 1 ;;
    *)   command -v "$1" >/dev/null 2>&1 || return 1 ;;
  esac
  v="$("$1" -p 'process.versions.node.split(".")[0]' 2>/dev/null)" || return 1
  case "$v" in ''|*[!0-9]*) return 1 ;; esac
  [ "$v" -ge "$FLOOR" ]
}

# Everywhere a Node might be that a non-interactive shell would not see. A version manager
# puts its node on PATH from a login shell only, so "nvm is installed" and "this script can
# find node" are different facts, and the second one is the one that matters here.
candidates() {
  [ -n "${CSK_STUDIO_NODE:-}" ] && printf '%s\n' "$CSK_STUDIO_NODE"
  printf 'node\n'
  # Guarded, because that pipeline costs three processes whether or not anything is there,
  # and a process is not always cheap: measured at 880-1483 ms on a Windows box whose EDR
  # inspects every creation. A directory test costs none.
  if [ -d "$RUNTIME" ]; then
    ls -1d "$RUNTIME"/node-v*/ 2>/dev/null | sort -r | while read -r d; do
      printf '%s\n' "${d}bin/node" "${d}node.exe"
    done
  fi
  printf '%s\n' \
    "$HOME"/.nvm/versions/node/*/bin/node \
    "$HOME"/.local/share/fnm/node-versions/*/installation/bin/node \
    "$HOME"/.fnm/node-versions/*/installation/bin/node \
    "$HOME"/.volta/tools/image/node/*/bin/node \
    "$HOME"/.asdf/installs/nodejs/*/bin/node \
    "$HOME"/n/bin/node \
    /opt/homebrew/bin/node \
    /usr/local/bin/node \
    /usr/bin/node \
    "${LOCALAPPDATA:-$HOME/AppData/Local}/Programs/nodejs/node.exe" \
    "${ProgramFiles:-/c/Program Files}/nodejs/node.exe" \
    "/c/Program Files/nodejs/node.exe" 2>/dev/null
}

resolve() {
  candidates | while read -r c; do
    [ -n "$c" ] || continue
    if works "$c"; then printf '%s\n' "$c"; return 0; fi
  done | head -1
}

# --- platform ------------------------------------------------------------------

plat_arch() {
  p="" a=""
  case "$(uname -s 2>/dev/null)" in
    Darwin)                     p=darwin ;;
    Linux)                      p=linux ;;
    MINGW*|MSYS*|CYGWIN*|Windows_NT) p=win ;;
    *) return 1 ;;
  esac
  case "$(uname -m 2>/dev/null)" in
    arm64|aarch64)  a=arm64 ;;
    x86_64|amd64)   a=x64 ;;
    armv7l)         a=armv7l ;;
    *) return 1 ;;
  esac
  printf '%s %s\n' "$p" "$a"
}

fetcher() {
  if command -v curl >/dev/null 2>&1; then printf 'curl\n'
  elif command -v wget >/dev/null 2>&1; then printf 'wget\n'
  else return 1; fi
}

get() { # get <url> <dest|->
  case "$(fetcher)" in
    curl) curl -fsSL --max-time 600 -o "$2" "$1" ;;
    wget) wget -q -T 600 -O "$2" "$1" ;;
    *)    return 1 ;;
  esac
}

# No checksum tool means no install. An unverified runtime is a worse answer than an honest
# refusal, so this fails closed rather than trusting the transfer.
#
# And the tool is not trusted for resolving either. A name that resolves is not a working
# program — the same lesson as the Windows Store's node stub — and a hash tool that returns
# something plausible but wrong would turn the verification step into theatre. So each
# candidate is run against an answer already known, and the first one that gets it right is
# the one used.
SHA_TOOL=""
SHA_VECTOR=ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad   # sha256("abc")

sha256_with() { # sha256_with <tool> <file>
  # Three of the four read stdin, and that is why they are fed that way: given a path they
  # print it beside the digest, and a path is attacker-shaped input as far as a parser is
  # concerned. Measured: with the file under a directory whose name is 64 hex characters,
  # openssl and certutil put that path where a first-match rule finds it and the wrong value
  # gets compared. From stdin there is no path in the output at all.
  #
  # certutil cannot be fed stdin, so it is read from the end instead: it prints the path in a
  # header line before the digest, and nothing after the digest is hex.
  pick=first
  case "$1" in
    sha256sum) out="$(sha256sum < "$2" 2>/dev/null)" ;;
    shasum)    out="$(shasum -a 256 < "$2" 2>/dev/null)" ;;
    openssl)   out="$(openssl dgst -sha256 < "$2" 2>/dev/null)" ;;
    certutil)  out="$(certutil -hashfile "$2" SHA256 2>/dev/null)"; pick=last ;;
    *)         return 1 ;;
  esac
  # Four tools, four shapes, and a per-tool field rule gets one of them wrong every time:
  #   sha256sum / shasum   <hash> *file          hash is field 1
  #   openssl 3.x          SHA2-256(file)= <hash>\r   hash is the LAST field, label is not "SHA256"
  #   certutil             a header line, then <hash>\r, then a footer   not a field at all
  # Windows builds also append CR, and a trailing CR is enough to fail the comparison and
  # silently drop a tool that works. One rule covers all four shapes AND the CR: take the
  # first 64-hex token anywhere in the output. CR is not a hex character, so it ends a token
  # rather than joining one — an explicit strip here would be a line no test could fail.
  printf '%s' "$out" | tr 'A-Z' 'a-z' | tr -cs '0-9a-f' '\n' |
    awk -v pick="$pick" '
      length($0) == 64 { h = $0; if (pick == "first") { print; exit } }
      END { if (pick == "last" && h != "") print h }'
}

sha256_calibrate() {
  [ -n "$SHA_TOOL" ] && return 0
  probe="$(mktemp 2>/dev/null || printf '%s/csk-sha-%s' "${TMPDIR:-/tmp}" "$$")" || return 1
  printf abc > "$probe" || { rm -f "$probe"; return 1; }
  for t in sha256sum shasum openssl certutil; do
    command -v "$t" >/dev/null 2>&1 || continue
    if [ "$(sha256_with "$t" "$probe")" = "$SHA_VECTOR" ]; then SHA_TOOL="$t"; break; fi
  done
  rm -f "$probe"
  [ -n "$SHA_TOOL" ]
}

sha256_of() {
  sha256_calibrate || return 1
  sha256_with "$SHA_TOOL" "$1"
}

# index.tab is the same release list as index.json in a form that needs no JSON parser —
# which matters, because the machine running this is by definition the one without Node.
# Column 10 is `lts`, and `-` there means the release is not one.
newest_lts() {
  [ -n "${CSK_STUDIO_NODE_VERSION:-}" ] && { printf '%s\n' "$CSK_STUDIO_NODE_VERSION"; return 0; }
  tab="$(get "$DIST/index.tab" - 2>/dev/null)" || return 1
  printf '%s\n' "$tab" | awk -F'\t' 'NR>1 && $10!="-" && $10!="" { print $1; exit }'
}

# Exit codes are not the answer here, so every branch is judged by what landed on disk.
# Measured on Windows 11: Info-ZIP's unzip returns 1 for "extracted, with warnings" — files
# present, status 1 — so `unzip || fallback` runs the fallback after a success and
# `unzip && ok` calls a success a failure. What the archive was meant to leave behind is the
# only thing worth checking.
extract() { # extract <archive> <into> <expected-dir-name>
  case "$1" in
    *.zip)
      tar -xf "$1" -C "$2" 2>/dev/null            # bsdtar reads zip; GNU tar, on Git Bash, does not
      [ -d "$2/$3" ] && return 0

      if command -v unzip >/dev/null 2>&1; then
        unzip -q -o "$1" -d "$2" >/dev/null 2>&1
        [ -d "$2/$3" ] && return 0
      fi

      if command -v powershell >/dev/null 2>&1; then
        # Expand-Archive is a Windows program and reads Windows paths. Handed a POSIX one it
        # exits 1 having written nothing — measured, not assumed — so convert first.
        #
        # -wa, not -w: -w leaves a relative path relative, and measured on Windows, a relative
        # path handed to a Windows program that is not running from the same directory fails
        # to find the file. That failure would arrive as "the download is broken", which is
        # the wrong suspect.
        pa="$1"; pb="$2"
        if command -v cygpath >/dev/null 2>&1; then
          pa="$(cygpath -wa "$1" 2>/dev/null || printf '%s' "$1")"
          pb="$(cygpath -wa "$2" 2>/dev/null || printf '%s' "$2")"
        fi
        # Said BEFORE, not after. Measured on Windows 11: Expand-Archive takes 26 s on Node's
        # zip where unzip takes 3 s — and this branch only runs on machines with no unzip, so
        # the person who waits is the one with no alternative. A minute of silence reads as a
        # hang, and by the time an explanation arrives they have already decided that.
        printf 'unpacking with PowerShell (no unzip on this machine) — this can take up to a minute\n' >&2
        powershell -NoProfile -Command "Expand-Archive -LiteralPath '$pa' -DestinationPath '$pb' -Force" >/dev/null 2>&1
        [ -d "$2/$3" ] && return 0
      fi
      return 1 ;;
    *)
      tar -xzf "$1" -C "$2" 2>/dev/null
      [ -d "$2/$3" ] && return 0
      return 1 ;;
  esac
}

# --- the plan ------------------------------------------------------------------

# Everything --install would do, computed without doing any of it. Kept as one function so
# --plan and --install cannot describe different downloads.
plan() {
  pa="$(plat_arch)" || die "ensure-node.sh: unsupported platform $(uname -s 2>/dev/null)/$(uname -m 2>/dev/null) — nodejs.org publishes no build for it."
  PLAT="${pa%% *}"; ARCH="${pa##* }"
  fetcher >/dev/null || die "ensure-node.sh: neither curl nor wget is here, so nothing can be fetched. Install Node yourself: https://nodejs.org"
  VERSION="$(newest_lts)" || VERSION=""
  if [ -z "$VERSION" ]; then
    VERSION="$FALLBACK_VERSION"
    VERSION_SOURCE="pinned fallback — nodejs.org could not be reached to ask"
  elif [ -n "${CSK_STUDIO_NODE_VERSION:-}" ]; then
    VERSION_SOURCE="pinned by CSK_STUDIO_NODE_VERSION"
  else
    VERSION_SOURCE="newest LTS on nodejs.org"
  fi
  case "$PLAT" in win) EXT=zip ;; *) EXT=tar.gz ;; esac
  ARTIFACT="node-$VERSION-$PLAT-$ARCH.$EXT"
  URL="$DIST/$VERSION/$ARTIFACT"
  SUMS="$DIST/$VERSION/SHASUMS256.txt"
  TARGET="$RUNTIME/node-$VERSION-$PLAT-$ARCH"

  # Asked here, before anything is fetched. Learning that the runtime cannot fit after a 37 MB
  # download and a 17-second failure is the wrong order, and the failure names the archive when
  # the archive is fine. Only when unzip is absent: unzip is not bound by the cap, so where it
  # exists the chain stops there and this does not apply.
  TOO_LONG=""
  if [ "$PLAT" = win ] && ! command -v unzip >/dev/null 2>&1; then
    wt="$TARGET"
    if command -v cygpath >/dev/null 2>&1; then
      wt="$(cygpath -wa "$TARGET" 2>/dev/null || printf '%s' "$TARGET")"
    fi
    [ "${#wt}" -gt "$WIN_DIR_BUDGET" ] && TOO_LONG="${#wt}"
  fi
}

human_size() {
  b="$1"
  case "$b" in ''|*[!0-9]*) printf 'size unknown\n'; return ;; esac
  printf '%s MB\n' "$(( (b + 524288) / 1048576 ))"
}

remote_size() {
  command -v curl >/dev/null 2>&1 || { printf 'unknown\n'; return; }
  curl -fsSLI --max-time 30 "$1" 2>/dev/null |
    awk 'tolower($1)=="content-length:"{v=$2} END{gsub(/\r/,"",v); print (v==""?"unknown":v)}'
}

# --- modes ---------------------------------------------------------------------

# Everything above is definitions, so the file can be sourced to reach one function at a
# time. The checksum refusal and the empty-search branch are only reachable on a machine
# with no Node at all, and the tests run on machines that have one.
main() {

while [ $# -gt 0 ]; do
  case "$1" in
    --resolve)  MODE=resolve ;;
    --explain)  MODE=resolve; EXPLAIN=1 ;;
    --plan)     MODE=plan ;;
    --install)  MODE=install ;;
    --probe)    MODE=probe; shift; PROBE="${1:-}" ;;
    --yes|-y)   YES=1 ;;
    -h|--help)  sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)          printf 'ensure-node.sh: unknown argument %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

case "$MODE" in
  probe)
    works "${PROBE:-}" && exit 0 || exit 1
    ;;

  resolve)
    say "looking for a Node $FLOOR or newer"
    found="$(resolve)"
    if [ -n "$found" ]; then
      say "found: $found"
      printf '%s\n' "$found"
      exit 0
    fi
    say "nothing usable on PATH, in $RUNTIME, or in any version manager's directory"
    exit 1
    ;;

  plan)
    plan
    printf 'CSK Studio needs Node %s+. This machine has none that runs.\n\n' "$FLOOR"
    printf '  fetch     %s\n' "$URL"
    printf '  size      %s (%s)\n' "$(human_size "$(remote_size "$URL")")" "$VERSION_SOURCE"
    printf '  verify    %s  (refuses to install if the hash does not match)\n' "$SUMS"
    printf '  unpack    %s\n' "$TARGET"
    if [ -n "$TOO_LONG" ]; then
      printf '\n  %s\n' "WILL NOT WORK HERE — that path is $TOO_LONG characters."
      printf '  %s\n' "Windows caps a full file path at $WIN_MAX_PATH, Node's deepest entry inside the zip is"
      printf '  %s\n' "$NODE_DEEPEST_ENTRY, and this machine has no unzip — only PowerShell's Expand-Archive, which"
      printf '  %s\n' "enforces the cap. Point CSK_STUDIO_RUNTIME at a path of $WIN_DIR_BUDGET characters or fewer,"
      printf '  %s\n' "or install unzip, which is not bound by it."
    fi
    printf '\nNothing outside that directory is touched: no admin rights, no package manager,\n'
    printf 'no PATH or profile edit. Delete it and this never happened.\n'
    printf '\n  do it     bash %s --install\n' "$0"
    printf '  or your own way, if you would rather the system owned it:\n'
    printf '            Windows  winget install OpenJS.NodeJS.LTS\n'
    printf '            macOS    brew install node\n'
    printf '            Linux    see https://nodejs.org/en/download/package-manager\n'
    exit 0
    ;;

  install)
    found="$(resolve)"
    if [ -n "$found" ]; then printf '%s\n' "$found"; exit 0; fi
    plan

    [ -z "$TOO_LONG" ] ||
      die "ensure-node.sh: $TARGET is $TOO_LONG characters as a Windows path, and the runtime cannot be unpacked there.
Windows caps a full file path at $WIN_MAX_PATH, Node's deepest entry inside the zip is $NODE_DEEPEST_ENTRY, and this
machine has no unzip — only PowerShell's Expand-Archive, which enforces that cap. Nothing was downloaded.
Point CSK_STUDIO_RUNTIME at a path of $WIN_DIR_BUDGET characters or fewer, or install unzip."

    sha256_calibrate ||
      die "ensure-node.sh: no SHA-256 tool here that returns the right answer for a known input (tried sha256sum, shasum, openssl, certutil), so a download could not be verified. Refusing to install one unchecked. Install Node yourself: https://nodejs.org"

    if [ "$YES" != 1 ]; then
      # `[ -r /dev/tty ]` is true on a machine that has one even when this process cannot
      # open it. Opening it is the only honest test, and getting that wrong printed a
      # prompt nobody could answer into a pipe.
      reply=""
      ask="Fetch $ARTIFACT ($(human_size "$(remote_size "$URL")")) into $RUNTIME? [y/N] "
      if [ -t 0 ]; then
        printf '%s' "$ask" >&2; read -r reply || reply=""
      elif ( exec 3< /dev/tty ) 2>/dev/null; then
        printf '%s' "$ask" >&2; read -r reply < /dev/tty || reply=""
      else
        die "ensure-node.sh: no terminal to ask on, and --yes was not given. See what it would do: bash $0 --plan"
      fi
      case "$reply" in y|Y|yes|YES) ;; *) die "ensure-node.sh: not fetching anything." ;; esac
    fi

    mkdir -p "$RUNTIME" || die "ensure-node.sh: cannot create $RUNTIME"
    tmp="$RUNTIME/.tmp.$$"
    rm -rf "$tmp"; mkdir -p "$tmp" || die "ensure-node.sh: cannot create $tmp"
    trap 'rm -rf "$tmp"' EXIT INT TERM

    printf 'fetching %s\n' "$URL" >&2
    get "$URL" "$tmp/$ARTIFACT" || die "ensure-node.sh: download failed — $URL"
    get "$SUMS" "$tmp/SHASUMS256.txt" || die "ensure-node.sh: could not fetch the checksum list, so the download cannot be verified. Nothing installed."

    want="$(awk -v f="$ARTIFACT" '$2==f || $2=="*"f {print $1; exit}' "$tmp/SHASUMS256.txt")"
    [ -n "$want" ] || die "ensure-node.sh: $ARTIFACT is not listed in SHASUMS256.txt. Nothing installed."
    got="$(sha256_of "$tmp/$ARTIFACT")" || die "ensure-node.sh: could not hash the download. Nothing installed."
    [ "$want" = "$got" ] || die "ensure-node.sh: checksum mismatch for $ARTIFACT
  expected $want
  got      $got
Nothing installed."
    printf 'checksum ok\n' >&2

    src="node-$VERSION-$PLAT-$ARCH"
    extract "$tmp/$ARTIFACT" "$tmp" "$src" ||
      die "ensure-node.sh: unpacking $ARTIFACT did not produce $src (tried tar, unzip and powershell).
The archive matched its published checksum a moment ago, so this is the unpacker on this machine, not the download.
Nothing installed."
    src="$tmp/$src"

    rm -rf "$TARGET"
    mkdir -p "$(dirname "$TARGET")"
    mv "$src" "$TARGET" || die "ensure-node.sh: could not move the runtime into $TARGET"

    bin="$TARGET/bin/node"; [ -f "$bin" ] || bin="$TARGET/node.exe"
    works "$bin" || die "ensure-node.sh: unpacked $TARGET but its node does not run. Left in place so you can look at it."
    printf 'installed %s\n' "$TARGET" >&2
    printf '%s\n' "$bin"
    exit 0
    ;;
esac

}

# Sourced for a test, or run for real. `${BASH_SOURCE[0]}` is this file either way; `$0` is
# this file only when it was executed.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then main "$@"; fi
