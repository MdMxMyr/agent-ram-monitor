#!/bin/bash
# Build the menu bar app and install it as a login LaunchAgent.
# Safe to re-run after pulling updates.
set -euo pipefail
cd "$(dirname "$0")"

echo "Building menu bar app..."
swiftc -O menubar/main.swift -o menubar/agent-ram-monitor-bar

LABEL="local.agent-ram-monitor-bar"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/agent-ram-monitor-bar.log"
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"

# plistlib handles XML escaping, so clone paths with &, quotes, etc. are safe.
/usr/bin/python3 - "$LABEL" "$PWD/menubar/agent-ram-monitor-bar" "$PLIST" "$LOG" <<'PY'
import plistlib, sys
label, binary, plist_path, log = sys.argv[1:5]
with open(plist_path, "wb") as f:
    plistlib.dump({
        "Label": label,
        "ProgramArguments": [binary],
        "RunAtLoad": True,
        "ProcessType": "Interactive",
        "LimitLoadToSessionType": "Aqua",
        "StandardOutPath": log,
        "StandardErrorPath": log,
    }, f)
PY

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Menu bar app installed and running (starts at login)."

if [[ -w /usr/local/bin ]]; then
  ln -sf "$PWD/agent-ram-monitor" /usr/local/bin/agent-ram-monitor
  echo "CLI linked: /usr/local/bin/agent-ram-monitor"
else
  echo "CLI: add to PATH yourself, e.g. sudo ln -s \"$PWD/agent-ram-monitor\" /usr/local/bin/agent-ram-monitor"
fi
