#!/bin/bash
# Install + load the LaunchAgent so DetroitRing runs at login and stays alive.
# The plist is generated here (from $HOME) so no machine-specific path is committed.
# Reversible: ./install_launchagent.sh uninstall
set -euo pipefail
LABEL="com.detroitring.app"
PLIST_DST="$HOME/Library/LaunchAgents/$LABEL.plist"
EXEC="$HOME/Applications/DetroitRing.app/Contents/MacOS/DetroitRing"
DOMAIN="gui/$(id -u)"

if [[ "${1:-install}" == "uninstall" ]]; then
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  rm -f "$PLIST_DST"
  echo "uninstalled $LABEL"
  exit 0
fi

if [[ ! -x "$EXEC" ]]; then
  echo "DetroitRing.app not found at $EXEC — run ./build.sh first." >&2
  exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST_DST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$EXEC</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <!-- Restart on CRASH (non-zero exit) but NOT on a clean Quit (exit 0), so the right-click Quit
       actually sticks; RunAtLoad still brings it back at next login. -->
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>ProcessType</key>
  <string>Interactive</string>
</dict>
</plist>
PLIST

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true   # clear any prior instance
launchctl bootstrap "$DOMAIN" "$PLIST_DST"
launchctl enable "$DOMAIN/$LABEL"
echo "loaded $LABEL into $DOMAIN"
launchctl print "$DOMAIN/$LABEL" 2>/dev/null | grep -E "state|pid|program" | head || true
