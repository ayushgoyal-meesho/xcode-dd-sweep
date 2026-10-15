#!/bin/bash
# install.sh — install (or upgrade / uninstall) the xcode-dd-sweep launchd job.
#
#   ./install.sh                  # install with team defaults, dry-run preview first
#   ./install.sh --report-only    # schedule it in report mode: logs what it WOULD delete
#   ./install.sh --floor 25       # smaller disk? lower the low-space floor (GiB)
#   ./install.sh --hours 24       # more conservative idle threshold
#   ./install.sh --no-notify      # no macOS low-space alerts
#   ./install.sh --uninstall      # remove the job and the script (logs are kept)
#
# Safe to re-run: it replaces the installed script and job in place.

set -euo pipefail

LABEL="com.meesho.xcode-dd-sweep"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$HOME/.local/bin"
SCRIPT="$BIN_DIR/xcode-dd-sweep"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/Library/Logs"
DOMAIN="gui/$(id -u)"

HOURS=12; FLOOR=40; LSP_CAP=30; SCRATCH=48
APPLY=1; NOTIFY=1; LOAD=1; UNINSTALL=0

while [ $# -gt 0 ]; do
  case "$1" in
    --report-only) APPLY=0; shift ;;
    --hours)       HOURS="${2:?--hours needs a value}"; shift 2 ;;
    --floor)       FLOOR="${2:?--floor needs a value}"; shift 2 ;;
    --lsp-cap)     LSP_CAP="${2:?--lsp-cap needs a value}"; shift 2 ;;
    --no-notify)   NOTIFY=0; shift ;;
    --no-load)     LOAD=0; shift ;;   # write files but don't touch launchd (testing)
    --uninstall)   UNINSTALL=1; shift ;;
    -h|--help)     sed -n '2,11p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ "$(uname -s)" = Darwin ] || { echo "macOS only." >&2; exit 1; }

if [ "$UNINSTALL" -eq 1 ]; then
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  rm -f "$PLIST" "$SCRIPT" "$LOG_DIR/xcode-dd-sweep.lowcount"
  echo "Uninstalled $LABEL. Logs left in $LOG_DIR/xcode-dd-sweep.log"
  exit 0
fi

for n in "$HOURS" "$FLOOR" "$LSP_CAP"; do
  case "$n" in ''|*[!0-9]*) echo "numeric values only: $n" >&2; exit 2 ;; esac
done

mkdir -p "$BIN_DIR" "$(dirname "$PLIST")" "$LOG_DIR"
install -m 0755 "$SRC_DIR/bin/xcode-dd-sweep.sh" "$SCRIPT"

FLAGS=(--hours "$HOURS" --lsp-cap "$LSP_CAP" --mcp --xctest --scratch "$SCRATCH" --floor "$FLOOR")
[ "$NOTIFY" -eq 1 ] && FLAGS+=(--notify)

echo "== Preview (dry run, nothing deleted) =="
"$SCRIPT" "${FLAGS[@]}" | sed -n '/sweep start/,/sweep end/p' | grep -E 'WOULD|SKIP|PRESSURE|would delete|free' || true
echo

RUN_HINT="$SCRIPT --apply ${FLAGS[*]}"
[ "$APPLY" -eq 1 ] && FLAGS=(--apply "${FLAGS[@]}")
FLAGS+=(--quiet)

{
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$SCRIPT</string>
EOF
  for f in "${FLAGS[@]}"; do printf '    <string>%s</string>\n' "$f"; done
  cat <<EOF
  </array>
  <key>StartCalendarInterval</key>
  <array>
EOF
  for h in 0 3 6 9 12 15 18 21; do
    printf '    <dict><key>Hour</key><integer>%d</integer><key>Minute</key><integer>45</integer></dict>\n' "$h"
  done
  cat <<EOF
  </array>
  <key>RunAtLoad</key><false/>
  <key>StandardErrorPath</key><string>$LOG_DIR/xcode-dd-sweep.err</string>
  <key>LowPriorityIO</key><true/>
  <key>Nice</key><integer>5</integer>
</dict>
</plist>
EOF
} > "$PLIST"
plutil -lint "$PLIST" >/dev/null

if [ "$LOAD" -eq 1 ]; then
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  launchctl bootstrap "$DOMAIN" "$PLIST"
fi

mode=$([ "$APPLY" -eq 1 ] && echo "cleaning (deletes idle build dirs)" || echo "report-only (logs only)")
cat <<EOF
== Installed ==
  mode:     $mode
  schedule: every 3h at :45 (00:45, 03:45 ... 21:45)
  idle:     ${HOURS}h   low-space floor: ${FLOOR} GiB   alerts: $([ "$NOTIFY" -eq 1 ] && echo on || echo off)
  script:   $SCRIPT
  job:      $PLIST$([ "$LOAD" -eq 1 ] || echo "  (not loaded: --no-load)")
  log:      $LOG_DIR/xcode-dd-sweep.log

Run it now:     $RUN_HINT
Preview again:  $SCRIPT
Uninstall:      $SRC_DIR/install.sh --uninstall
EOF
