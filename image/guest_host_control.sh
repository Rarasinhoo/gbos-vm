#!/system/bin/sh
# Fixed-verb control channel from the host over this VM's private serial
# console. Runs as shell; anything not listed below is ignored.
# VM_TOKEN carries a secret: don't echo it.
stty -echo 2>/dev/null
# Per boot token for the pointer helper. The host sends it once per boot, so keep it across
# service restarts and drop a stale one on the first start of a boot (kernel boot id).
TOKEN_FILE=/data/local/tmp/vm-input.token
BOOT_MARK=/data/local/tmp/vm-input.bootid
boot_id=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
if [ -z "$boot_id" ] || [ "$(cat "$BOOT_MARK" 2>/dev/null)" != "$boot_id" ]; then
  rm -f "$TOKEN_FILE"
  echo "$boot_id" >"$BOOT_MARK" 2>/dev/null || true
fi
echo VM_CONTROL_READY
handle() {
  case "$line" in
    VM_POWEROFF) echo VM_CONTROL poweroff; setprop sys.powerctl shutdown ;;
    VM_TOKEN\ *)
      t=${line#VM_TOKEN }; tok=${t%% *}; addr=${t#* }
      case "$tok" in *[!0-9a-f]*) return ;; esac
      [ ${#tok} -eq 32 ] || return
      # The viewer: QEMU's host address, its isolated-mode forward, or the Mac on its own network
      case "$addr" in *[!0-9.]*|*..*|.*|*.) return ;; *.*.*.*) ;; *) return ;; esac
      (umask 077; printf '%s\n%s\n' "$tok" "$addr" >"$TOKEN_FILE.new" && mv -f "$TOKEN_FILE.new" "$TOKEN_FILE") && echo "VM_CONTROL token set" ;;
    VM_DENSITY\ [0-9][0-9][0-9])
      timeout 8 wm density "${line#VM_DENSITY }"
      echo "VM_CONTROL density $(timeout 5 wm density | tr '\n' ' ')" ;;
    VM_LOG)
      # Recent warnings and errors, and what is on screen, for diagnosing a misbehaving app
      timeout 10 logcat -d -b main,system,crash -t 4000 '*:W' 2>/dev/null | grep -v -E 'audit|avc:|libperfmgr|touchpad-inhibitor|ServiceManagerCppClient|ctl.interface_start|QMI_FW|pd-mapper|memtrack|[sac]+dsprpcd|sscrpcd|QSEECOMD|ssgqmigd|MinkDaemon|timberslide|PerMgr|tftp_server|WakeLock|PlayCommon' | tail -120 | cut -c1-220 | sed 's/^/VM_CONTROL log /'
      timeout 10 logcat -d -b main,system,events -t 20000 2>/dev/null | grep -E 'ActivityTaskManager|am_create_activity|am_crash|am_proc_died|wm_finish_activity|ActivityStarter' | tail -30 | cut -c1-220 | sed 's/^/VM_CONTROL starts /'
      timeout 8 dumpsys window 2>/dev/null | grep -E 'mCurrentFocus|mFocusedApp' | head -4 | cut -c1-200 | sed 's/^/VM_CONTROL focus /'
      timeout 8 dumpsys activity activities 2>/dev/null | grep -E 'ResumedActivity|\* Task\{|  \* Hist' | head -12 | cut -c1-200 | sed 's/^/VM_CONTROL activity /' ;;
    VM_NEARBY)
      # Quick Share and Nearby: what they log about discovery, Bluetooth and Wi-Fi
      timeout 10 logcat -d -b main,system -t 60000 2>/dev/null | grep -i -E 'nearby|quickshare|sharing|fastpair|mdns|nsd|medium|bluetoothle|BtGatt|suspend|bt_|bluetooth|scanmanager|scanner|l2cap|wifilan' | grep -v -i -E 'instantOnLost|instant on lost|AdvertiseSuspend|Suspending!|clearcut|RateLimit|bluetooth-cf|certificate' | tail -400 | cut -c1-230 | sed 's/^/VM_CONTROL nearby /' ;;
    VM_TOP)
      # What is using the guest's CPUs: one snapshot of the busiest processes and threads
      timeout 10 top -b -n 1 -m 20 2>&1 | head -30 | cut -c1-150 | sed 's/^/VM_CONTROL top /'
      timeout 10 top -b -H -n 1 -m 12 2>&1 | tail -n +5 | head -16 | cut -c1-150 | sed 's/^/VM_CONTROL thread /' ;;
    VM_STATUS)
      echo "VM_CONTROL boot=$(getprop sys.boot_completed) user=$(timeout 5 am get-current-user) size=$(timeout 5 wm size | tr '\n' ' ') density=$(timeout 5 wm density | tr '\n' ' ')"
      timeout 5 cat /proc/asound/cards 2>&1 | sed 's/^/VM_CONTROL asound /'
      timeout 5 cmd device_state state 2>&1 | head -3 | sed 's/^/VM_CONTROL device_state /'
      timeout 5 cmd device_state print-states 2>&1 | head -12 | sed 's/^/VM_CONTROL device_states /'
      timeout 6 dumpsys input 2>/dev/null | grep -i -m6 -E 'lid|SW_|switch' | cut -c1-160 | sed 's/^/VM_CONTROL lid /'
      echo "VM_CONTROL bluetooth feature=$(timeout 5 pm list features 2>/dev/null | grep -c 'hardware.bluetooth$') on=$(timeout 5 settings get global bluetooth_on) hal=$(getprop init.svc.vendor.bluetooth-aidl-qti) gscd=$(getprop init.svc.android.system.desktop.security.gscd)"
      timeout 6 dumpsys bluetooth_manager 2>/dev/null | grep -m4 -i -E '^ *(enabled|state|address|name):' | cut -c1-80 | sed 's/^/VM_CONTROL btmgr /' ;;
  esac
}
# Commands must not read the console, or they would swallow later verbs.
while IFS= read -r line; do
  line=${line%$'\r'}
  handle </dev/null
  echo VM_CONTROL done
done
