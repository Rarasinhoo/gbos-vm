"""Wi-Fi for the VM.

With virt_wifi (guest_wifi.sh), the VM's network card is a Wi-Fi interface, wlan0. The Qualcomm
Wi-Fi HAL can't work it: it looks for its own chip and driver, dies, and after two restarts
Android turns Wi-Fi off for good. Replace it with the generic Wi-Fi HAL from the Android virtual
device (Cuttlefish's com.android.hardware.wifi), which drives any nl80211 interface. It runs at
the Qualcomm service's path and under its name, so its SELinux domain and interface declaration
carry over, with its own libraries from a private folder (the vendor ones of the same names are
Qualcomm's). wpa_supplicant stays the Googlebook's: it speaks plain nl80211 too.
"""
from pathlib import Path
R=Path(__file__).resolve().parents[1]
W=R/'artifacts/cuttlefish-wifi'
def apply(add):
 add('bin/hw/android.hardware.wifi-service',(W/'android.hardware.wifi-service').read_bytes(),'hal_wifi_default_exec',0o755)
 for lib in sorted((W/'lib64').iterdir()):
  add('lib64/vm_wifi/'+lib.name,lib.read_bytes(),'vendor_file')
 add('etc/init/android.hardware.wifi-service.rc',b'''# The generic Wi-Fi HAL in place of the Qualcomm one (image/mica_wifi_port.py)
service vendor.wifi_hal_legacy /vendor/bin/hw/android.hardware.wifi-service
    interface aidl android.hardware.wifi.IWifi/default
    class hal
    capabilities NET_ADMIN NET_RAW SYS_MODULE
    user wifi
    group wifi gps
    setenv LD_LIBRARY_PATH /vendor/lib64/vm_wifi
''','vendor_configs_file')
 return ['lib64/vm_wifi']
