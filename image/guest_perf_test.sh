#!/system/bin/sh
# Display smoothness benchmark (only in images built with --perf-test). After boot it reports the
# display mode, then scrolls Settings back and forth for a fixed time per round and prints that
# round's frame statistics, so the host can compare builds. tests/perf.py drives and reads it.
# Never read the serial console: it is the host control channel's input.
exec </dev/null
n=0
while [ "$(getprop sys.boot_completed)" != 1 ] && [ $n -lt 60 ]; do sleep 3; n=$((n+1)); done
sleep 30
u=$(am get-current-user)
echo "VM_PERF_BEGIN user=$u size=$(wm size | tr '\n' ' ')"
cat /sys/class/drm/card0-Virtual-1/modes 2>&1 | head -8 | sed 's/^/VM_PERF kernel_mode /'
dumpsys display 2>/dev/null | grep -o -E 'supportedModes \[[^]]*\]' | head -1 | cut -c1-600 | sed 's/^/VM_PERF /'
dumpsys display 2>/dev/null | grep -o -E 'renderFrameRate [0-9.]+|refreshRate=[0-9.]+|mActiveSfDisplayMode=[^,]*' | sort -u | head -6 | sed 's/^/VM_PERF display /'
dumpsys SurfaceFlinger 2>/dev/null | grep -i -E 'refresh-rate|vsync-period|present offset|frame rate' | head -6 | cut -c1-140 | sed 's/^/VM_PERF sf /'
# Swipe across the middle of the screen, scaled to the current size.
set -- $(wm size | sed -n 's/.*: \([0-9]*\)x\([0-9]*\).*/\1 \2/p' | tail -1)
x=$(( ${1:-1920} / 2 )); top=$(( ${2:-1200} / 4 )); bottom=$(( ${2:-1200} * 3 / 4 ))
pkg=com.android.settings
am start --user "$u" -a android.settings.SETTINGS >/dev/null 2>&1; sleep 6
round=1
while [ $round -le 3 ]; do
  dumpsys gfxinfo $pkg reset >/dev/null 2>&1
  echo "VM_PERF scroll_start round=$round uptime=$(cut -d' ' -f1 /proc/uptime)"
  i=0
  while [ $i -lt 10 ]; do
    input swipe $x $bottom $x $top 400; input swipe $x $top $x $bottom 400
    i=$((i+1))
  done
  echo "VM_PERF scroll_end round=$round uptime=$(cut -d' ' -f1 /proc/uptime)"
  dumpsys gfxinfo $pkg 2>/dev/null | grep -E '^(Total frames rendered|Janky frames|[0-9]+th percentile|Number Missed Vsync|Number High input latency|Number Slow UI thread|Number Slow bitmap uploads|Number Slow issue draw commands|Number Frame deadline missed)' \
    | head -12 | sed "s/^/VM_PERF round=$round /"
  sleep 5
  round=$((round+1))
done
am start --user "$u" -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null 2>&1
echo VM_PERF_END
