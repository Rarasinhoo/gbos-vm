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
sleep 3
# Mouse: the host glides the captured mouse evenly for 5 s once it sees mouse_ready (tests/perf.py).
# Time every report the guest's USB mouse delivers, and how far each one moves.
dev=
for d in /dev/input/event*; do getevent -p "$d" 2>/dev/null | grep -q 'QEMU USB Mouse' && dev=$d; done
if [ -n "$dev" ]; then
  echo "VM_PERF mouse_ready dev=$dev"
  timeout 9 getevent -t "$dev" > /data/local/tmp/vm-perf-mouse.txt 2>/dev/null
  # Lines are "[ seconds] type code value" in hex. One report = REL_X/REL_Y up to a SYN_REPORT.
  tr -d '[]' < /data/local/tmp/vm-perf-mouse.txt | awk '
    function hex(s,  i, v) { v = 0; for (i = 1; i <= length(s); i++) v = v * 16 + index("0123456789abcdef", substr(tolower(s), i, 1)) - 1
                             return v >= 2147483648 ? v - 4294967296 : v }
    $2 == "0002" && ($3 == "0000" || $3 == "0001") { m += ($3 == "0000" ? 1 : 0) * hex($4); my += ($3 == "0001" ? 1 : 0) * hex($4); moved = 1 }
    $2 == "0000" && $3 == "0000" && moved {
      t[n] = $1; dx[n] = m < 0 ? -m : m; n++; m = 0; my = 0; moved = 0 }
    END {
      # Keep only the glide: drop anything before the last pause of over a second (stale reports)
      for (i = 1; i < n; i++) if (t[i] - t[i-1] > 1) s0 = i
      for (i = s0; i < n; i++) { t[i - s0] = t[i]; dx[i - s0] = dx[i] } n -= s0
      if (n < 10) { print "VM_PERF mouse reports=" n; exit }
      for (i = 1; i < n; i++) { g = (t[i] - t[i-1]) * 1000; gap[i] = g; if (g > 12) late++; if (g > maxg) maxg = g; sum += g }
      for (i = 0; i < n; i++) { h[dx[i] > 4 ? 5 : dx[i]]++ }
      # Display frames at 120 Hz: how many got no report, one, or several
      t0 = t[0]; for (i = 0; i < n; i++) { f = int((t[i] - t0) * 120); c[f]++; if (f > last) last = f }
      for (f = 0; f <= last; f++) { k = c[f] + 0; if (k == 0) z++; else if (k == 1) one++; else many++ }
      printf "VM_PERF mouse reports=%d seconds=%.2f mean_gap_ms=%.1f max_gap_ms=%.1f gaps_over_12ms=%d\n", n, t[n-1] - t0, sum / (n - 1), maxg, late
      printf "VM_PERF mouse dx_px 0=%d 1=%d 2=%d 3=%d 4=%d 5+=%d\n", h[0], h[1], h[2], h[3], h[4], h[5]
      printf "VM_PERF mouse frames_at_120hz none=%d one=%d several=%d\n", z, one, many
    }'
fi
# Touchpad: the host creates the virtual touchpad, glides one finger, then scrolls Settings with two.
am start --user "$u" -a android.settings.SETTINGS >/dev/null 2>&1; sleep 4
dumpsys gfxinfo $pkg reset >/dev/null 2>&1
echo "VM_PERF touch_ready"
sleep 12
dumpsys input 2>/dev/null | awk '/VM Touchpad/ {f = 1} f && /Sources|Classes|Touchpad|Gesture/ {print; if (++c >= 4) exit}' | cut -c1-140 | sed 's/^ */VM_PERF touch device /'
dumpsys gfxinfo $pkg 2>/dev/null | grep -E '^(Total frames rendered|Janky frames)' | sed 's/^/VM_PERF touch /'
echo "VM_PERF touch settings tap=$(settings --user "$u" get system touchpad_tap_to_click) natural=$(settings --user "$u" get system touchpad_natural_scrolling)"
echo VM_PERF_END
