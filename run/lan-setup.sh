#!/bin/bash
# One-time setup for Settings > Network > "Same network as this Mac" (the app runs it, asking
# for your password, when you choose that; it can also be run by hand): puts the VM on your real
# network, as one more device next to the Mac, so phones nearby can find it (Quick Share, Nearby,
# Better Together). macOS only lets root attach a VM to a network interface, so this installs
# socket_vmnet (from Homebrew, the daemon Lima and Colima use) as a small root service bridging
# the interface the Mac uses; the VM itself still runs as you.
#
# The service follows the Mac's network: when Wi-Fi reconnects, or the Mac moves between Wi-Fi
# and Ethernet, it bridges again (vmnet keeps a dead link otherwise), and the VM reconnects.
#
#   sudo run/lan-setup.sh            install or update
#   sudo run/lan-setup.sh --remove   uninstall
set -euo pipefail
VERSION=2   # the app compares this with the installed service's, to offer an update
LABEL=local.googlebook.lan
PLIST=/Library/LaunchDaemons/$LABEL.plist
DIR="/Library/Application Support/Googlebook VM"
SOCK=/opt/homebrew/var/run/googlebook-lan.sock
[ "$(id -u)" = 0 ] || { echo "Run it with sudo: sudo $0 $*" >&2; exit 1; }
launchctl bootout system "$PLIST" 2>/dev/null || true
if [ "${1:-}" = --remove ]; then rm -rf "$PLIST" "$SOCK" "$DIR"; echo "Removed."; exit 0; fi
BIN=/opt/homebrew/opt/socket_vmnet/bin/socket_vmnet
[ -x "$BIN" ] || { echo "socket_vmnet isn't installed (./prereqs.sh installs it, or: brew install socket_vmnet)" >&2; exit 1; }
mkdir -p "$DIR" "$(dirname "$SOCK")"
# Root runs this, so it lives where only root can change it
cat >"$DIR/lan-bridge.sh" <<EOF
#!/bin/bash
# Googlebook VM network bridge, version $VERSION (installed by lan-setup.sh). Bridges the
# interface of the Mac's default route, and starts over whenever that or its address changes.
current() { local i; i=\$(route -n get default 2>/dev/null | awk '/interface:/{print \$2}'); echo "\$i \$(ipconfig getifaddr "\$i" 2>/dev/null)"; }
trap 'kill \$pid 2>/dev/null; exit 0' TERM INT
while true; do
  now=\$(current); iface=\${now%% *}
  if [ -z "\$iface" ] || [ "\$now" = "\$iface " ]; then sleep 3; continue; fi   # no network yet
  echo "bridging \$now"
  rm -f "$SOCK"
  "$BIN" --vmnet-mode=bridged --vmnet-interface="\$iface" --socket-group=staff "$SOCK" & pid=\$!
  while kill -0 \$pid 2>/dev/null && [ "\$(current)" = "\$now" ]; do sleep 3; done
  kill \$pid 2>/dev/null; wait \$pid 2>/dev/null
  echo "network changed"
done
EOF
chmod 755 "$DIR/lan-bridge.sh"; chown -R root:wheel "$DIR"
cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$DIR/lan-bridge.sh</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/var/log/googlebook-lan.log</string>
  <key>StandardErrorPath</key><string>/var/log/googlebook-lan.log</string>
</dict></plist>
EOF
chmod 644 "$PLIST"
launchctl bootstrap system "$PLIST"
for _ in $(seq 1 20); do [ -S "$SOCK" ] && break; sleep 0.5; done
[ -S "$SOCK" ] || { echo "The bridge didn't start; see /var/log/googlebook-lan.log" >&2; exit 1; }
echo "Done. Now choose Settings > Network > Same network as this Mac, and restart the VM."
