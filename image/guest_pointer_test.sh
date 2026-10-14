#!/system/bin/sh
# Test images only (--pointer-test): installs and opens the pointer capture test app once the
# desktop is up, and copies what it logs to the console (see tests/pointer_capture.py).
exec </dev/null
until [ "$(getprop sys.boot_completed)" = 1 ]; do sleep 2; done
# Past the switch from the user picker to the desktop user
sleep 30
u=$(am get-current-user)
echo "VM_POINTER_TEST install $(pm install --user "$u" /vendor/etc/vm-pointer-test.apk 2>&1 | tr '\n' ' ')"
logcat -T 1 -v brief -s VMPointerTest:W | while IFS= read -r l; do echo "VM_POINTER_TEST $l"; done &
echo "VM_POINTER_TEST start $(am start --user "$u" -W -n vm.pointertest/.Main 2>&1 | tr '\n' ' ')"
sleep 120
kill $! 2>/dev/null
echo VM_POINTER_TEST_END
