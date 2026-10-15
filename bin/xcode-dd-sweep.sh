#!/bin/bash
# xcode-dd-sweep.sh — reclaim stale Xcode/agent DerivedData without touching live builds.
#
# Dry-run by default. Pass --apply to delete.
#   xcode-dd-sweep.sh                        # report only
#   xcode-dd-sweep.sh --apply --hours 12     # delete dirs idle >12h
#   xcode-dd-sweep.sh --apply --lsp-cap 30   # also sweep idle per-project LSP indexes
#   xcode-dd-sweep.sh --apply --mcp          # also sweep idle XcodeBuildMCP workspaces
#   xcode-dd-sweep.sh --apply --floor 40 --notify  # macOS alert when still under floor
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
XCTEST=0                     # 1 enables XCTest simulator-clone sweeping
XCTEST_DIR="$HOME/Library/Developer/XCTestDevices"
SCRATCH_HOURS=0               # hours; 0 disables Claude session-scratch sweeping
SCRATCH_ROOT="/private/tmp/claude-$(id -u)"
FLOOR=0                       # GiB free below which pressure mode engages; 0 disables
TARGET_MARGIN=15              # GiB of headroom pressure mode tries to restore
NOTIFY=0                      # 1 raises a macOS notification on sustained low space
NOTIFY_AFTER=2                # consecutive under-floor runs before the first alert
NOTIFY_EVERY=8                # then re-alert every N runs (8 = daily at 3h cadence)
APPLY=0
QUIET=0
LOG="$HOME/Library/Logs/xcode-dd-sweep.log"
LOW_STATE="$HOME/Library/Logs/xcode-dd-sweep.lowcount"

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
    --floor)    FLOOR="${2:?--floor needs a value}"; shift 2 ;;
    --notify)   NOTIFY=1; shift ;;
    --quiet)    QUIET=1; shift ;;
    -h|--help)  sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

mkdir -p "$(dirname "$LOG")"
say() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"; printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }

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

sweep() {
  local d="$1" reason kb human
  [ -d "$d" ] || return
  if reason=$(is_live "$d"); then
    say "SKIP  $(basename "$d")  — $reason"; skip_count=$((skip_count+1)); return
  fi
  kb=$(du -sk "$d" 2>/dev/null | cut -f1); kb=${kb:-0}
  human=$(du -sh "$d" 2>/dev/null | cut -f1)
  if [ "$APPLY" -eq 1 ]; then
    if rm -rf "$d" 2>/dev/null; then
      say "DEL   $(basename "$d")  ($human)"; freed_kb=$((freed_kb+kb)); del_count=$((del_count+1))
    else
      say "FAIL  $(basename "$d")  — became active during delete, left in place"; skip_count=$((skip_count+1))
    fi
  else
    say "WOULD $(basename "$d")  ($human)"; freed_kb=$((freed_kb+kb)); del_count=$((del_count+1))
  fi
}

# Idle by newest file, not the dir's own mtime: LSP and MCP dirs are long-lived and
# rewritten in place, so their top-level mtime stays old while files inside churn.
stale() { [ -z "$(find "$1" -type f -mmin "-$2" -print -quit 2>/dev/null)" ]; }

MINS=$((HOURS*60))
say "=== sweep start (mode=$([ $APPLY -eq 1 ] && echo apply || echo dry-run), idle>${HOURS}h, grace=${GRACE}m, lsp-cap=${LSP_CAP}GiB, mcp=${MCP}, xctest=${XCTEST}, scratch=${SCRATCH_HOURS}h, floor=${FLOOR}GiB) ==="
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
while IFS= read -r d; do sweep "$d"; done < <(
  find /private/tmp -mindepth 1 -maxdepth 1 -type d -mmin "+$MINS" \
    \( -name '*-dd' -o -name 'dd-*' -o -name '*-derived-data' \
       -o -name '*-derivedData' -o -name '*derived-data*' \
       -o -name 'DerivedData-*' -o -name '*-DerivedData' \) 2>/dev/null
)

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

# XCTest simulator clones. XCTest spawns a fresh clone per test run and never
# reaps them; seven had accumulated to a nominal 28G. They are APFS clones of the
# base runtime, so du overstates the real reclaim. Only sweep when nothing is
# testing: a clone deleted under a live run takes the run down with it.
# Match on comm= anchored to the binary name, NOT a substring of the full command:
# 'xcodebuildmcp' (an always-running MCP server) contains 'xcodebuild', and a
# substring match on it kept this guard permanently tripped -- it skipped every
# run for a full day without ever sweeping a single clone.
if [ "$XCTEST" -eq 1 ] && [ -d "$XCTEST_DIR" ]; then
  if xcrun simctl list devices booted 2>/dev/null | grep -qi booted; then
    say "XCTestDevices: simulator booted — skipping all clones"
  elif ps -Ao comm= | grep -Eiq '(^|/)(xcodebuild|xctest)$'; then
    say "XCTestDevices: test run in progress — skipping all clones"
  else
    while IFS= read -r d; do sweep "$d"; done < <(
      find "$XCTEST_DIR" -mindepth 1 -maxdepth 1 -type d -mmin "+$MINS" 2>/dev/null)
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
fi

# Pressure mode. The age threshold alone cannot keep up with this workload: it
# creates 11-16G DerivedData roots every couple of hours and runs six at once, so
# dirs that are idle but only 2-3h old are what actually fill the disk. When free
# space falls under the floor, sweep idle dirs oldest-first -- ignoring the age
# threshold but enforcing every liveness guard unchanged -- until headroom returns.
free_gib() { echo $(( $(df -k /System/Volumes/Data | tail -1 | awk '{print $4}') / 1048576 )); }
pressure_roots=()
[ -d "$DD" ] && pressure_roots+=("$DD")
[ "$LSP_CAP" -gt 0 ] && [ -d "$LSP_DIR" ] && pressure_roots+=("$LSP_DIR")
[ "$MCP" -eq 1 ] && [ -d "$MCP_DIR" ] && pressure_roots+=("$MCP_DIR")
if [ "$FLOOR" -gt 0 ] && [ "$(free_gib)" -lt "$FLOOR" ] && [ "${#pressure_roots[@]}" -gt 0 ]; then
  target=$((FLOOR + TARGET_MARGIN))
  say "PRESSURE: $(free_gib)GiB free < floor ${FLOOR}GiB — sweeping idle dirs oldest-first toward ${target}GiB"
  while IFS= read -r line; do
    d=${line#* }
    [ "$(free_gib)" -ge "$target" ] && { say "PRESSURE: reached $(free_gib)GiB — stopping"; break; }
    case "$(basename "$d")" in Unsaved_Xcode_Document_*|*.noindex) continue ;; esac
    sweep "$d"
  done < <(find "${pressure_roots[@]}" -mindepth 1 -maxdepth 1 -type d -mmin "+$GRACE" \
             -exec stat -f '%m %N' {} + 2>/dev/null | sort -n)
  say "PRESSURE: ended at $(free_gib)GiB free"
fi

say "--- summary ---"
if [ "$APPLY" -eq 1 ]; then
  say "deleted $del_count dirs, reclaimed ~$((freed_kb/1048576))Gi, skipped $skip_count as live"
else
  say "would delete $del_count dirs, reclaiming ~$((freed_kb/1048576))Gi, skipping $skip_count as live"
fi
say "free after:  $(df -h /System/Volumes/Data | tail -1 | awk '{print $4}')"

# Sustained-low alert. Early Oct ran under the floor for ~3 weeks -- pressure mode on
# nearly every run, reclaiming almost nothing because the big dirs were held open --
# and the first sign was 133MB free. Alert on the 2nd consecutive under-floor run,
# then daily while it persists; reset once a run ends above the floor.
if [ "$NOTIFY" -eq 1 ] && [ "$APPLY" -eq 1 ] && [ "$FLOOR" -gt 0 ]; then
  low=$(cat "$LOW_STATE" 2>/dev/null); case "$low" in ''|*[!0-9]*) low=0 ;; esac
  if [ "$(free_gib)" -lt "$FLOOR" ]; then
    low=$((low+1))
    if [ "$low" -eq "$NOTIFY_AFTER" ] || { [ "$low" -gt "$NOTIFY_AFTER" ] && [ $(( (low-NOTIFY_AFTER) % NOTIFY_EVERY )) -eq 0 ]; }; then
      msg="$(free_gib) GiB free (floor ${FLOOR}) for ${low} runs. Last sweep freed ~$((freed_kb/1048576)) GiB; ${skip_count} dirs skipped as in use."
      osascript -e "display notification \"$msg\" with title \"Disk space low\" subtitle \"xcode-dd-sweep\" sound name \"Basso\"" >/dev/null 2>&1
      say "NOTIFY: $msg"
    fi
  else
    low=0
  fi
  printf '%s\n' "$low" > "$LOW_STATE"
fi
say "=== sweep end ==="
