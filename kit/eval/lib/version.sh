# Sourced, not run. The ONE definition of how Crewforth reads and orders its own version numbers.
#
# An install's VERSION holds X.Y.Z, or X.Y.Z-rc.N when it came from a release candidate. An rc comes before its
# final (3.2.0-rc.1 < 3.2.0), so someone who tried the rc is offered the final when it ships. Read by the update
# check (hooks/session-update-check.sh), doctor and adopt.sh; each used to split on "." and read 3.2.0-rc.1 as 3.2.0.
#
# Builtins only: sourcing this costs no process, which matters in hooks on Git Bash.

# The version an install may hold in its own VERSION file: X.Y.Z or X.Y.Z-rc.N, nothing else; printed, or rc 1.
# A value off the network is not read with this: the update check holds that to X.Y.Z alone.
crew_local_version(){
  local v="${1:-}" base n
  v="${v//[!0-9A-Za-z.-]/}"
  base="${v%%-rc.*}"
  case "$base" in
    *[!0-9.]*|'')           return 1 ;;
    [0-9]*.[0-9]*.[0-9]*.*) return 1 ;;
    [0-9]*.[0-9]*.[0-9]*)   ;;
    *)                      return 1 ;;
  esac
  if [ "$base" != "$v" ]; then
    n="${v#"$base"-rc.}"
    case "$n" in ''|*[!0-9]*) return 1 ;; esac
  fi
  printf '%s' "$v"
}

# vcmp(a, b): 1 when a is newer, -1 when older, 0 when the same. Prepended to an awk program:
#   awk -v a="$X" -v b="$Y" "$CREW_VCMP_AWK"' BEGIN { exit !(vcmp(a, b) > 0) }'
CREW_VCMP_AWK='
function vrc(v) { return match(v, /-rc\.[0-9]+$/) ? substr(v, RSTART + 4) + 0 : -1 }
function vcmp(a, b,   x, y, i, ra, rb) {
  ra = vrc(a); rb = vrc(b); sub(/-.*/, "", a); sub(/-.*/, "", b)
  split(a, x, "."); split(b, y, ".")
  for (i = 1; i <= 3; i++) { if (x[i] + 0 > y[i] + 0) return 1; if (x[i] + 0 < y[i] + 0) return -1 }
  if (ra == rb) return 0
  if (ra < 0) return 1
  if (rb < 0) return -1
  return ra > rb ? 1 : -1
}
'
