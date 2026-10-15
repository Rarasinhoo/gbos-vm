#!/system/bin/sh
# A lid switch that is always open (vm-lid). With none, Android's device state is CLOSED, a
# laptop with its lid shut, and Bluetooth suspends with it: no advertising and filtered scans, so
# Quick Share and the like never find a phone. EV_SW 5, SW_LID 0 (0 = open); configuration
# type 109 is UI_SET_SWBIT. The device lasts as long as uinput runs.
exec </dev/null
{
  echo '{"id":1,"command":"register","name":"VM Lid","vid":6900,"pid":30469,"bus":"usb","configuration":[{"type":100,"data":[5]},{"type":109,"data":[0]}]}'
  sleep 2
  echo '{"id":1,"command":"inject","events":[5,0,0,0,0,0]}'
  exec sleep 2147483647
} | /system/bin/uinput -
