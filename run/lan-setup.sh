#!/bin/bash
# One-time setup for Settings > Network > "Same network as this Mac": puts the VM on your real
# network, as one more device next to the Mac, so phones nearby can find it (Quick Share, Nearby,
# Better Together). macOS only lets root attach a VM to a network interface, so this installs
# socket_vmnet (from Homebrew, the daemon Lima and Colima use) as a small root service bridging
# the interface the Mac uses now; the VM itself still runs as you.
#
#   sudo run/lan-setup.sh            install, or move to the interface the Mac uses now
#   sudo run/lan-setup.sh --remove   uninstall
set -euo pipefail
LABEL=local.googlebook.lan
PLIST=/Library/LaunchDaemons/$LABEL.plist
SOCK=/opt/homebrew/var/run/googlebook-lan.sock
[ "$(id -u)" = 0 ] || { echo "Run it with sudo: sudo $0 $*" >&2; exit 1; }
launchctl bootout system "$PLIST" 2>/dev/null || true
if [ "${1:-}" = --remove ]; then rm -f "$PLIST" "$SOCK"; echo "Removed."; exit 0; fi
BIN=/opt/homebrew/opt/socket_vmnet/bin/socket_vmnet
[ -x "$BIN" ] || { echo "socket_vmnet isn't installed: brew install socket_vmnet" >&2; exit 1; }
IF=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
[ -n "$IF" ] || { echo "The Mac isn't on a network right now." >&2; exit 1; }
mkdir -p "$(dirname "$SOCK")"
cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>$BIN</string><string>--vmnet-mode=bridged</string><string>--vmnet-interface=$IF</string>
    <string>--socket-group=staff</string><string>$SOCK</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>/var/log/googlebook-lan.log</string>
</dict></plist>
EOF
chmod 644 "$PLIST"
launchctl bootstrap system "$PLIST"
for _ in $(seq 1 20); do [ -S "$SOCK" ] && break; sleep 0.5; done
[ -S "$SOCK" ] || { echo "The bridge didn't start; see /var/log/googlebook-lan.log" >&2; exit 1; }
echo "Bridging $IF. Now choose Settings > Network > Same network as this Mac, and restart the VM."
