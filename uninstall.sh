#!/bin/bash
# Stop the menu bar app and remove the login LaunchAgent. Leaves the repo,
# the CLI, and recorded history (~/.agent-ram-monitor/) in place.
set -uo pipefail
LABEL="local.agent-ram-monitor-bar"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -f "$HOME/Library/Logs/agent-ram-monitor-bar.log"
[[ -L /usr/local/bin/agent-ram-monitor ]] && rm -f /usr/local/bin/agent-ram-monitor
echo "agent-ram-monitor-bar uninstalled."
