#!/system/bin/sh
# Wi-Fi on the VM's network card (vm-wifi, as root): virt_wifi makes the card a Wi-Fi interface,
# wlan0, always connected to a simulated access point, while its traffic still goes out the card
# (to the Mac's network, or QEMU's NAT). So Android and its apps see Wi-Fi: Quick Share and
# Nearby only look for devices over a Wi-Fi network. The card itself is renamed out of the way,
# so Android's Ethernet service doesn't take it too. Prints VM_WIFI lines on the console.
exec </dev/null
# virt_wifi and cfg80211 come in with the ramdisk (make_mica_gpu_initrd.py)
[ -d /sys/module/virt_wifi ] || { echo "VM_WIFI virt_wifi is not loaded"; exit 0; }
for i in $(seq 1 30); do
  card=$(ls /sys/class/net | grep -E '^(eth|usb)[0-9]' | head -1)
  [ -n "$card" ] && break
  sleep 1
done
if [ -z "$card" ]; then echo "VM_WIFI no network card"; exit 0; fi
ip link set "$card" down
ip link set "$card" name buried_eth0 && card=buried_eth0
ip link set "$card" up
if ip link add link "$card" name wlan0 type virt_wifi; then
  ip link set wlan0 up
  echo "VM_WIFI wlan0 on $card"
else
  echo "VM_WIFI virt_wifi failed; giving the card back to Ethernet"
  ip link set "$card" down; ip link set "$card" name eth0; ip link set eth0 up
fi
