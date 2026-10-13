#!/system/bin/sh
# Startup diagnostics: runs the Vulkan self-test even if boot never completes.
sleep 35
echo VM_VULKAN_STARTUP_BEGIN
getprop sys.boot_completed
getprop init.svc.surfaceflinger
getprop init.svc.zygote
getprop init.svc.bootanim
getprop ro.hardware.vulkan
ps -A -o PID,PPID,STAT,WCHAN,NAME | grep -E 'surfaceflinger|system_server|zygote|composer|allocator|bootanim|vulkan'
logcat -d -b all -t 1200 -v threadtime '*:E' | grep -E -i 'vulkan|venus|EGL|gralloc|SurfaceFlinger|RenderEngine|shader|fence|avc: denied|linker' | tail -100
timeout 25 /vendor/bin/vm-vulkan-probe
echo VM_VULKAN_PROBE_EXIT=$?
timeout 25 /vendor/bin/vm-vulkan-probe --ahb
echo VM_AHB_PROBE_EXIT=$?
timeout 25 /vendor/bin/vm-vulkan-probe --ahb-render
echo VM_AHB_RENDER_PROBE_EXIT=$?
timeout 25 /vendor/bin/vm-vulkan-probe --ahb-render-bgra
echo VM_AHB_BGRA_PROBE_EXIT=$?
# Video: decoders hand over YUV buffers (flexible 4:2:0 and YV12)
for f in 0x23 0x32315659; do timeout 25 /vendor/bin/vm-vulkan-probe --yuv $f; echo VM_YUV_PROBE_EXIT=$f,$?; done
# ANGLE, EGL and buffer errors too (GLES runs on ANGLE with --gfxstream images)
logcat -d -b all -t 3000 -v threadtime | grep -E -i 'angle|libEGL|gfxstream|AHardwareBuffer|GraphicBuffer|Skia|RenderEngine|minigbm|gralloc' | grep -E ' [EWF] ' | tail -60
# The 60 log lines (any process, info and up) before SurfaceFlinger's first fatal error
logcat -d -b all -v threadtime | grep -v -E ' [VD] ' | awk '/F SurfaceFlinger: Failed to create a valid texture/ {for (i = NR - 60; i < NR; i++) if (i > 0) print b[i % 60]; exit} {b[NR % 60] = $0}' | sed 's/^/VM_SF /'
logcat -d -b all -t 1500 -v threadtime | grep -E -i 'MESA-VIRTIO|venus|vulkan|avc: denied' | tail -100
dumpsys -t 5 SurfaceFlinger | grep -E 'GLES|EGL|Vulkan|RenderEngine|Composition'
echo VM_VULKAN_STARTUP_END
