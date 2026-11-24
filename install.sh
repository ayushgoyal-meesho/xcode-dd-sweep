#!/bin/bash
# install.sh — install (or upgrade / uninstall) the xcode-dd-sweep launchd job.
#
#   ./install.sh                  # install with team defaults, dry-run preview first
#   ./install.sh --report-only    # schedule it in report mode: logs what it WOULD delete
#   ./install.sh --floor 25       # smaller disk? lower the low-space floor (GiB)
#   ./install.sh --hours 24       # more conservative idle threshold
#   ./install.sh --no-notify      # no macOS low-space alerts
#   ./install.sh --only-when-low  # never clean on a schedule; only when free space < floor
#   ./install.sh --repos ~/work   # where your git checkouts live (repeatable; default:
#                                 #   whichever of ~/Documents ~/Developer ~/Projects ~/code ~/work exist)
#   ./install.sh --no-repos       # don't look inside checkouts for build/ dirs
#   ./install.sh --uninstall      # remove the jobs and the script (logs are kept)
#
# Safe to re-run: it replaces the installed script and job in place.

set -euo pipefail

LABEL="com.meesho.xcode-dd-sweep"
LOW_LABEL="$LABEL.low"           # 15-minute check that sweeps only when under the floor
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$HOME/.local/bin"
SCRIPT="$BIN_DIR/xcode-dd-sweep"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOW_PLIST="$HOME/Library/LaunchAgents/$LOW_LABEL.plist"
LOG_DIR="$HOME/Library/Logs"
DOMAIN="gui/$(id -u)"

HOURS=12; FLOOR=40; LSP_CAP=30; SCRATCH=48
APPLY=1; NOTIFY=1; LOAD=1; UNINSTALL=0; ONLY_LOW=0; NO_REPOS=0
REPOS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --report-only) APPLY=0; shift ;;
    --hours)       HOURS="${2:?--hours needs a value}"; shift 2 ;;
    --floor)       FLOOR="${2:?--floor needs a value}"; shift 2 ;;
    --lsp-cap)     LSP_CAP="${2:?--lsp-cap needs a value}"; shift 2 ;;
    --no-notify)   NOTIFY=0; shift ;;
    --only-when-low) ONLY_LOW=1; shift ;;
    --repos)       REPOS+=("${2:?--repos needs a directory}"); shift 2 ;;
    --no-repos)    NO_REPOS=1; shift ;;
    --no-load)     LOAD=0; shift ;;   # write files but don't touch launchd (testing)
    --uninstall)   UNINSTALL=1; shift ;;
    -h|--help)     sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ "$(uname -s)" = Darwin ] || { echo "macOS only." >&2; exit 1; }

if [ "$UNINSTALL" -eq 1 ]; then
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  launchctl bootout "$DOMAIN/$LOW_LABEL" 2>/dev/null || true
  rm -f "$PLIST" "$LOW_PLIST" "$SCRIPT" "$LOG_DIR/xcode-dd-sweep.lowcount"
  rmdir "$LOG_DIR/xcode-dd-sweep.lock" 2>/dev/null || true
  echo "Uninstalled $LABEL. Logs left in $LOG_DIR/xcode-dd-sweep.log"
  exit 0
fi

for n in "$HOURS" "$FLOOR" "$LSP_CAP"; do
  case "$n" in ''|*[!0-9]*) echo "numeric values only: $n" >&2; exit 2 ;; esac
done

mkdir -p "$BIN_DIR" "$(dirname "$PLIST")" "$LOG_DIR"
install -m 0755 "$SRC_DIR/bin/xcode-dd-sweep.sh" "$SCRIPT"

[ "$FLOOR" -gt 0 ] || [ "$ONLY_LOW" -eq 0 ] || { echo "--only-when-low needs a --floor above 0" >&2; exit 2; }

if [ "$NO_REPOS" -eq 0 ] && [ "${#REPOS[@]}" -eq 0 ]; then
  for r in "$HOME/Documents" "$HOME/Developer" "$HOME/Projects" "$HOME/code" "$HOME/work"; do
    [ -d "$r" ] && REPOS+=("$r")
  done
fi
[ "$NO_REPOS" -eq 1 ] && REPOS=()

FLAGS=(--hours "$HOURS" --lsp-cap "$LSP_CAP" --mcp --xctest --scratch "$SCRATCH" --floor "$FLOOR")
for r in ${REPOS[@]+"${REPOS[@]}"}; do FLAGS+=(--repos "$r"); done
[ "$NOTIFY" -eq 1 ] && FLAGS+=(--notify)

echo "== Preview (dry run, nothing deleted) =="
"$SCRIPT" "${FLAGS[@]}" | sed -n '/sweep start/,/sweep end/p' | grep -E 'WOULD|SKIP|PRESSURE|would delete|free' || true
echo

RUN_HINT="$SCRIPT --apply ${FLAGS[*]}"
[ "$APPLY" -eq 1 ] && FLAGS=(--apply "${FLAGS[@]}")
FLAGS+=(--quiet)

# write_plist <label> <path> <schedule-xml> <args...>
write_plist() {
  local label="$1" path="$2" sched="$3"; shift 3
  {
    cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$SCRIPT</string>
EOF
    for f in "$@"; do printf '    <string>%s</string>\n' "$f"; done
    cat <<EOF
  </array>
$sched
  <key>RunAtLoad</key><false/>
  <key>StandardErrorPath</key><string>$LOG_DIR/xcode-dd-sweep.err</string>
  <key>LowPriorityIO</key><true/>
  <key>Nice</key><integer>5</integer>
</dict>
</plist>
EOF
  } > "$path"
  plutil -lint "$path" >/dev/null
}

CAL="  <key>StartCalendarInterval</key>
  <array>"
for h in 0 3 6 9 12 15 18 21; do
  CAL="$CAL
    <dict><key>Hour</key><integer>$h</integer><key>Minute</key><integer>45</integer></dict>"
done
CAL="$CAL
  </array>"
EVERY15="  <key>StartInterval</key><integer>900</integer>"

# Scheduled job (every 3h): idle-age cleanup plus low-space mode. Skipped with --only-when-low.
if [ "$ONLY_LOW" -eq 0 ]; then
  write_plist "$LABEL" "$PLIST" "$CAL" "${FLAGS[@]}"
else
  rm -f "$PLIST"
fi
# Low-space check (every 15 min): exits at once unless free space is under the floor,
# so a burst of builds between scheduled runs gets caught within minutes.
if [ "$FLOOR" -gt 0 ] && [ "$APPLY" -eq 1 ]; then
  write_plist "$LOW_LABEL" "$LOW_PLIST" "$EVERY15" "${FLAGS[@]}" --only-when-low
else
  rm -f "$LOW_PLIST"
fi

if [ "$LOAD" -eq 1 ]; then
  for pair in "$LABEL:$PLIST" "$LOW_LABEL:$LOW_PLIST"; do
    launchctl bootout "$DOMAIN/${pair%%:*}" 2>/dev/null || true
    [ -f "${pair#*:}" ] && launchctl bootstrap "$DOMAIN" "${pair#*:}"
  done
fi

mode=$([ "$APPLY" -eq 1 ] && echo "cleaning (deletes idle build dirs)" || echo "report-only (logs only)")
cat <<EOF
== Installed ==
  mode:     $mode
  schedule: $([ "$ONLY_LOW" -eq 1 ] && echo "no scheduled cleanup (--only-when-low)" || echo "every 3h at :45 (00:45, 03:45 ... 21:45)")
  low-space: $([ -f "$LOW_PLIST" ] && echo "checked every 15 min; sweeps only under ${FLOOR} GiB" || echo off)
  repos:    $([ "${#REPOS[@]}" -gt 0 ] && echo "${REPOS[*]}" || echo none)
  idle:     ${HOURS}h   low-space floor: ${FLOOR} GiB   alerts: $([ "$NOTIFY" -eq 1 ] && echo on || echo off)
  script:   $SCRIPT
  jobs:     $(ls "$PLIST" "$LOW_PLIST" 2>/dev/null | tr '\n' ' ')$([ "$LOAD" -eq 1 ] || echo " (not loaded: --no-load)")
  log:      $LOG_DIR/xcode-dd-sweep.log

Run it now:     $RUN_HINT
Preview again:  $SCRIPT
Uninstall:      $SRC_DIR/install.sh --uninstall
EOF
