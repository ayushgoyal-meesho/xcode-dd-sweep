#!/bin/bash
# xcode-dd-sweep.sh — reclaim stale Xcode/agent build output without touching live builds.
#
# Dry-run by default. Pass --apply to delete.
#   xcode-dd-sweep.sh                        # report only
#   xcode-dd-sweep.sh --apply --hours 12     # delete dirs idle >12h
#   xcode-dd-sweep.sh --apply --lsp-cap 30   # also sweep idle per-project LSP indexes
#   xcode-dd-sweep.sh --apply --mcp          # also sweep idle XcodeBuildMCP workspaces
#   xcode-dd-sweep.sh --apply --repos ~/Documents   # also sweep git-ignored Xcode build
#                                            #   dirs (build/, DerivedData/, dd-*) in checkouts
#   xcode-dd-sweep.sh --apply --floor 40 --notify   # macOS alert when still under floor
#   xcode-dd-sweep.sh --apply --floor 40 --only-when-low   # do nothing unless under floor
#
# Threshold is HOURS, not days: this workload creates 8-16G DerivedData dirs
# several times a day, so a 2-day threshold never fires before the disk fills.
#
# Guards (any one spares a directory):
#   1. a running process's command line mentions the path
#   2. a file inside was modified within GRACE minutes
#   3. lsof reports an open handle under it
# Guard 1 exists because deleting DerivedData under a live build wedges it:
# an interrupted SPM xcframework unzip hangs indefinitely on the vanished path.
# Guard 3 is the one that does most of the real work -- Xcode does not put the
# DerivedData path in its argv, so only lsof reveals the open workspace.

set -uo pipefail

HOURS=12
GRACE=30
LSP_CAP=0                     # GiB; 0 disables LSP handling
LSP_DIR="$HOME/.meesho-lsp-derivedData"
MCP=0                         # 1 enables XcodeBuildMCP workspace sweeping
MCP_DIR="$HOME/Library/Developer/XcodeBuildMCP/workspaces"
XCTEST=0                      # 1 enables XCTest simulator-clone sweeping
XCTEST_DIR="$HOME/Library/Developer/XCTestDevices"
SCRATCH_HOURS=0               # hours; 0 disables Claude session-scratch sweeping
SCRATCH_ROOT="/private/tmp/claude-$(id -u)"
REPO_ROOTS=()                 # --repos DIR (repeatable): scan git checkouts for build dirs
FLOOR=0                       # GiB free below which pressure mode engages; 0 disables
TARGET_MARGIN=15              # GiB of headroom pressure mode tries to restore
ONLY_WHEN_LOW=0               # 1 = exit without doing anything unless free < FLOOR
NOTIFY=0                      # 1 raises a macOS notification when a sweep can't restore the floor
NOTIFY_GAP=21600              # seconds between repeat alerts while under the floor (6h)
CRIT=10                       # GiB; below this, repeat alerts hourly instead
APPLY=0
QUIET=0
LOG="$HOME/Library/Logs/xcode-dd-sweep.log"
LOW_STATE="$HOME/Library/Logs/xcode-dd-sweep.lowcount"   # epoch of the last alert
LOCK="$HOME/Library/Logs/xcode-dd-sweep.lock"

while [ $# -gt 0 ]; do
  case "$1" in
    --apply)    APPLY=1; shift ;;
    --hours)    HOURS="${2:?--hours needs a value}"; shift 2 ;;
    --days)     HOURS=$(( ${2:?--days needs a value} * 24 )); shift 2 ;;
    --grace)    GRACE="${2:?--grace needs a value}"; shift 2 ;;
    --lsp-cap)  LSP_CAP="${2:?--lsp-cap needs a value}"; shift 2 ;;
    --mcp)      MCP=1; shift ;;
    --xctest)   XCTEST=1; shift ;;
    --scratch)  SCRATCH_HOURS="${2:?--scratch needs a value}"; shift 2 ;;
    --repos)    REPO_ROOTS+=("${2:?--repos needs a directory}"); shift 2 ;;
    --floor)    FLOOR="${2:?--floor needs a value}"; shift 2 ;;
    --only-when-low) ONLY_WHEN_LOW=1; shift ;;
    --notify)   NOTIFY=1; shift ;;
    --quiet)    QUIET=1; shift ;;
    -h|--help)  sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

mkdir -p "$(dirname "$LOG")"
say() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"; printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }
free_kb()  { df -k /System/Volumes/Data | tail -1 | awk '{print $4}'; }
free_gib() { echo $(( $(free_kb) / 1048576 )); }

if [ "$ONLY_WHEN_LOW" -eq 1 ]; then
  [ "$FLOOR" -gt 0 ] || { echo "--only-when-low needs --floor" >&2; exit 2; }
  # The frequent low-space check: stay silent (no log line) while there's room.
  [ "$(free_gib)" -lt "$FLOOR" ] || exit 0
fi

# One sweep at a time: the 15-minute low-space check and the 3-hourly run can
# coincide, and a pressure sweep can take 15+ minutes. A lock older than 2h is
# left over from a killed run.
if ! mkdir "$LOCK" 2>/dev/null; then
  if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +120 2>/dev/null)" ]; then
    rm -rf "$LOCK"; mkdir "$LOCK" 2>/dev/null || exit 0
  else
    exit 0
  fi
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

# Snapshot once, up front, excluding this shell and its children. Capturing this
# per-directory would self-match: our own du/find/lsof carry the path in argv.
PROCS=$(ps -Ao pid=,ppid=,command= | awk -v s=$$ '$1!=s && $2!=s')

freed_kb=0; del_count=0; skip_count=0

is_live() {
  local d="$1"
  printf '%s' "$PROCS" | grep -Fq -- "$d" && { echo "process references it"; return 0; }
  [ -n "$(find "$d" -type f -mmin "-$GRACE" -print -quit 2>/dev/null)" ] \
    && { echo "modified within ${GRACE}m"; return 0; }
  if command -v lsof >/dev/null 2>&1; then
    [ -n "$(lsof -w +D "$d" 2>/dev/null </dev/null | sed -n '2p')" ] \
      && { echo "open file handle"; return 0; }
  fi
  return 1
}

# Pretty name for the log: repo/build and session/scratchpad/dd are ambiguous on
# their own ("build" x3), so keep the parent for those.
label() {
  case "$1" in
    */scratchpad/*|*/build|*/DerivedData|*/.derivedData) echo "$(basename "$(dirname "$1")")/$(basename "$1")" ;;
    *) basename "$1" ;;
  esac
}

remove_dir() {
  local d="$1"
  # XCTest clones are registered in the device set; let simctl drop the entry too.
  if [ "$(dirname "$d")" = "$XCTEST_DIR" ]; then
    xcrun simctl --set "$XCTEST_DIR" delete "$(basename "$d")" >/dev/null 2>&1 && return 0
  fi
  rm -rf "$d" 2>/dev/null
}

sweep() {
  local d="$1" reason kb human
  [ -d "$d" ] || return
  if reason=$(is_live "$d"); then
    say "SKIP  $(label "$d")  — $reason"; skip_count=$((skip_count+1)); return
  fi
  kb=$(du -sk "$d" 2>/dev/null | cut -f1); kb=${kb:-0}
  human=$(du -sh "$d" 2>/dev/null | cut -f1)
  if [ "$APPLY" -eq 1 ]; then
    if remove_dir "$d"; then
      say "DEL   $(label "$d")  ($human)"; freed_kb=$((freed_kb+kb)); del_count=$((del_count+1))
    else
      say "FAIL  $(label "$d")  — became active during delete, left in place"; skip_count=$((skip_count+1))
    fi
  else
    say "WOULD $(label "$d")  ($human)"; freed_kb=$((freed_kb+kb)); del_count=$((del_count+1))
  fi
}

# Idle by newest file, not the dir's own mtime: LSP and MCP dirs are long-lived and
# rewritten in place, so their top-level mtime stays old while files inside churn.
stale() { [ -z "$(find "$1" -type f -mmin "-$2" -print -quit 2>/dev/null)" ]; }

# An Xcode derived-data tree, whatever it is named: xcodebuild -derivedDataPath X
# always creates X/Build or X/Index.noindex. Checking the shape (not the name)
# keeps us off unrelated build/ dirs (Gradle, JS bundles, ...).
is_xcode_dd() { [ -d "$1/Build/Products" ] || [ -d "$1/Build/Intermediates.noindex" ] || [ -d "$1/Index.noindex" ]; }

# Build dirs inside git checkouts (xcodebuild -derivedDataPath build). Three of these
# reached 56G unnoticed because nothing looked in ~/Documents. Only top-level dirs of
# a checkout, only if git ignores them and tracks nothing inside, only Xcode-shaped.
repo_build_dirs() {
  local root repo d name
  for root in ${REPO_ROOTS[@]+"${REPO_ROOTS[@]}"}; do
    [ -d "$root" ] || continue
    while IFS= read -r g; do
      repo=$(dirname "$g")
      for d in "$repo"/*/ "$repo"/.derivedData/; do
        d=${d%/}; [ -d "$d" ] || continue
        name=$(basename "$d")
        case "$name" in
          build|Build|DerivedData|derivedData|.derivedData|dd|dd-*|*-dd|*-derived-data|*-DerivedData) ;;
          *) continue ;;
        esac
        is_xcode_dd "$d" || continue
        git -C "$repo" check-ignore -q "$name" 2>/dev/null || continue
        [ -z "$(git -C "$repo" ls-files -- "$name" 2>/dev/null | head -1)" ] || continue
        printf '%s\n' "$d"
      done
    done < <(find "$root" -maxdepth 3 -name .git -prune -print 2>/dev/null)
  done
}

# Build dirs inside Claude Code session scratchpads. A session that stays open for
# days keeps its scratch "live" as a whole, while a 7G dd-* build inside it sits idle.
scratch_build_dirs() {
  [ -d "$SCRATCH_ROOT" ] || return
  while IFS= read -r d; do
    is_xcode_dd "$d" && printf '%s\n' "$d"
  done < <(find "$SCRATCH_ROOT" -mindepth 4 -maxdepth 4 -type d -path '*/scratchpad/*' 2>/dev/null)
}

MINS=$((HOURS*60))
start_kb=$(free_kb)
say "=== sweep start (mode=$([ $APPLY -eq 1 ] && echo apply || echo dry-run)$([ $ONLY_WHEN_LOW -eq 1 ] && echo ',only-when-low'), idle>${HOURS}h, grace=${GRACE}m, lsp-cap=${LSP_CAP}GiB, mcp=${MCP}, xctest=${XCTEST}, scratch=${SCRATCH_HOURS}h, repos=${#REPO_ROOTS[@]}, floor=${FLOOR}GiB) ==="
say "free before: $(df -h /System/Volumes/Data | tail -1 | awk '{print $4}')"

DD="$HOME/Library/Developer/Xcode/DerivedData"
if [ -d "$DD" ]; then
  while IFS= read -r d; do
    case "$(basename "$d")" in
      Unsaved_Xcode_Document_*|*.noindex) continue ;;
    esac
    sweep "$d"
  done < <(find "$DD" -mindepth 1 -maxdepth 1 -type d -mmin "+$MINS" 2>/dev/null)
fi

# Per-task DerivedData from agent runs. Both suffix (foo-dd) and prefix (dd-foo)
# naming appear in practice, plus assorted -derived-data spellings.
tmp_dd_dirs() {
  find /private/tmp -mindepth 1 -maxdepth 1 -type d \
    \( -name '*-dd' -o -name 'dd-*' -o -name '*-derived-data' \
       -o -name '*-derivedData' -o -name '*derived-data*' \
       -o -name 'DerivedData-*' -o -name '*-DerivedData' \) "$@" 2>/dev/null
}
while IFS= read -r d; do sweep "$d"; done < <(tmp_dd_dirs -mmin "+$MINS")

# LSP index: one subdir per project (8-20G each). Treating the whole dir as one unit
# never fired -- the active project kept it live while an idle 20G sibling sat there.
# Sweep each project index once idle past HOURS; if the total is still over the cap,
# also sweep idle-past-GRACE ones oldest-first. Deleting forces a cold re-index.
lsp_gib() { echo $(( $(du -sk "$LSP_DIR" 2>/dev/null | cut -f1) / 1048576 )); }
if [ "$LSP_CAP" -gt 0 ] && [ -d "$LSP_DIR" ]; then
  while IFS= read -r d; do
    stale "$d" "$MINS" && sweep "$d"
  done < <(find "$LSP_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
  if [ "$(lsp_gib)" -ge "$LSP_CAP" ]; then
    say "LSP index at $(lsp_gib)GiB (cap ${LSP_CAP}) — sweeping idle projects oldest-first"
    while IFS= read -r line; do
      d=${line#* }
      [ "$(lsp_gib)" -lt "$LSP_CAP" ] && break
      sweep "$d"
    done < <(find "$LSP_DIR" -mindepth 1 -maxdepth 1 -type d -exec stat -f '%m %N' {} + 2>/dev/null | sort -n)
  fi
  say "LSP index at $(lsp_gib)GiB"
fi

# XcodeBuildMCP workspaces: per-project build trees the MCP server never reaps
# (two reached 19-22G within days). Each is recreated on the next MCP build.
if [ "$MCP" -eq 1 ] && [ -d "$MCP_DIR" ]; then
  while IFS= read -r d; do
    stale "$d" "$MINS" && sweep "$d"
  done < <(find "$MCP_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
fi

# Xcode build dirs inside git checkouts, idle past HOURS.
while IFS= read -r d; do
  stale "$d" "$MINS" && sweep "$d"
done < <(repo_build_dirs)

# XCTest simulator clones. XCTest spawns a fresh clone per test run and never
# reaps them; seven had accumulated to a nominal 28G. They are APFS clones of the
# base runtime, so du overstates the real reclaim. A clone deleted under a live
# run takes the run down with it, so skip everything while a test is running.
# Otherwise skip only clones that are themselves booted -- the old rule ("any
# simulator booted anywhere") was nearly always true and let 27G pile up.
# Match on comm= anchored to the binary name, NOT a substring of the full command:
# 'xcodebuildmcp' (an always-running MCP server) contains 'xcodebuild', and a
# substring match on it kept this guard permanently tripped.
if [ "$XCTEST" -eq 1 ] && [ -d "$XCTEST_DIR" ]; then
  if ps -Ao comm= | grep -Eiq '(^|/)(xcodebuild|xctest)$'; then
    say "XCTestDevices: test run in progress — skipping all clones"
  else
    booted=$(xcrun simctl --set "$XCTEST_DIR" list devices booted 2>/dev/null \
               | grep -Eo '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}')
    while IFS= read -r d; do
      if [ -n "$booted" ] && printf '%s\n' "$booted" | grep -Fqx "$(basename "$d")"; then
        say "SKIP  $(basename "$d")  — clone is booted"; skip_count=$((skip_count+1)); continue
      fi
      sweep "$d"
    done < <(find "$XCTEST_DIR" -mindepth 1 -maxdepth 1 -type d -mmin "+$MINS" 2>/dev/null)
  fi
fi

# Claude Code session scratch. Dirs for finished sessions are never cleaned up and
# two had reached 8G apiece. $CLAUDE_SESSION_ID (when exported) is the live session
# -- never sweep it, and the guards catch any other still-running session.
if [ "$SCRATCH_HOURS" -gt 0 ] && [ -d "$SCRATCH_ROOT" ]; then
  while IFS= read -r d; do
    case "$(basename "$d")" in "${CLAUDE_SESSION_ID:-__none__}") continue ;; esac
    sweep "$d"
  done < <(find "$SCRATCH_ROOT" -mindepth 2 -maxdepth 2 -type d -mmin "+$((SCRATCH_HOURS*60))" 2>/dev/null)
  # Build dirs inside sessions that are still open: same idle rule as DerivedData.
  while IFS= read -r d; do
    stale "$d" "$MINS" && sweep "$d"
  done < <(scratch_build_dirs)
fi

# Pressure mode. The age threshold alone cannot keep up with this workload: it
# creates 11-16G DerivedData roots every couple of hours and runs six at once, so
# dirs that are idle but only 2-3h old are what actually fill the disk. When free
# space falls under the floor, sweep idle dirs oldest-first -- ignoring the age
# threshold but enforcing every liveness guard unchanged -- until headroom returns.
# Candidates span every build-output location above, not just DerivedData: on
# Nov 24 pressure mode ran out of DerivedData at 18G free while 70G of idle
# build dirs sat in checkouts and open Claude sessions.
pressure_candidates() {
  local roots=()
  [ -d "$DD" ] && roots+=("$DD")
  [ "$LSP_CAP" -gt 0 ] && [ -d "$LSP_DIR" ] && roots+=("$LSP_DIR")
  [ "$MCP" -eq 1 ] && [ -d "$MCP_DIR" ] && roots+=("$MCP_DIR")
  [ "${#roots[@]}" -gt 0 ] && find "${roots[@]}" -mindepth 1 -maxdepth 1 -type d -mmin "+$GRACE" 2>/dev/null
  tmp_dd_dirs -mmin "+$GRACE"
  repo_build_dirs
  [ "$SCRATCH_HOURS" -gt 0 ] && scratch_build_dirs
  return 0
}
if [ "$FLOOR" -gt 0 ] && [ "$(free_gib)" -lt "$FLOOR" ]; then
  target=$((FLOOR + TARGET_MARGIN))
  say "PRESSURE: $(free_gib)GiB free < floor ${FLOOR}GiB — sweeping idle dirs oldest-first toward ${target}GiB"
  while IFS= read -r line; do
    d=${line#* }
    [ "$(free_gib)" -ge "$target" ] && { say "PRESSURE: reached $(free_gib)GiB — stopping"; break; }
    case "$(basename "$d")" in Unsaved_Xcode_Document_*|*.noindex) continue ;; esac
    sweep "$d"
  done < <(pressure_candidates | while IFS= read -r p; do [ -d "$p" ] && stat -f '%m %N' "$p"; done | sort -n)
  say "PRESSURE: ended at $(free_gib)GiB free"
fi

say "--- summary ---"
if [ "$APPLY" -eq 1 ]; then
  say "deleted $del_count dirs, reclaimed ~$((freed_kb/1048576))Gi, skipped $skip_count as live"
else
  say "would delete $del_count dirs, reclaiming ~$((freed_kb/1048576))Gi, skipping $skip_count as live"
fi
# du double-counts APFS clones and rounds per run; this is what the disk actually gained
# (anything else writing during the run counts against it).
say "free change: $(( ($(free_kb) - start_kb) / 1024 ))Mi"
say "free after:  $(df -h /System/Volumes/Data | tail -1 | awk '{print $4}')"

# Low-space alert. Fires as soon as a sweep ends still under the floor (it has done
# all it safely can, so a human is needed), then every 6h while it persists --
# hourly once under CRIT GiB. Nov 24 went from 20G to 119M between two runs.
if [ "$NOTIFY" -eq 1 ] && [ "$APPLY" -eq 1 ] && [ "$FLOOR" -gt 0 ]; then
  if [ "$(free_gib)" -lt "$FLOOR" ]; then
    now=$(date +%s)
    last=$(cat "$LOW_STATE" 2>/dev/null); case "$last" in ''|*[!0-9]*) last=0 ;; esac
    gap=$NOTIFY_GAP; [ "$(free_gib)" -lt "$CRIT" ] && gap=3600
    if [ $((now - last)) -ge "$gap" ]; then
      msg="$(free_gib) GiB free (floor ${FLOOR}). Sweep freed ~$((freed_kb/1048576)) GiB; ${skip_count} dirs in use. Quit idle Xcode/Claude sessions or simulators."
      osascript -e "display notification \"$msg\" with title \"Disk space low\" subtitle \"xcode-dd-sweep\" sound name \"Basso\"" >/dev/null 2>&1
      say "NOTIFY: $msg"
      printf '%s\n' "$now" > "$LOW_STATE"
    fi
  else
    rm -f "$LOW_STATE"
  fi
fi
say "=== sweep end ==="
