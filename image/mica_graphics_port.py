"""Add the graphics stack to the vendor overlay: gfxstream's Vulkan driver and libdrm (built by
build-gfxstream.sh), the Cuttlefish minigbm allocator and the generic DRM composer. GLES is
Android's own ANGLE on that Vulkan driver, which reaches the Mac's GPU through MoltenVK."""
from pathlib import Path
R=Path(__file__).resolve().parents[1]
def apply(add,files,guest):
 # The driver must speak the same protocol revision as the Mac's renderer: build-gfxstream.sh
 # builds it from the matching Mesa.
 add('lib64/hw/vulkan.ranchu.so',(guest/'vulkan.gfxstream.so').read_bytes(),'same_process_hal_file')
 add('lib64/libdrm.so',(guest/'libdrm.so').read_bytes(),'same_process_hal_file')
 donor=R/'artifacts/graphics-port-review/extracted'
 for n in ['libminigbm_gralloc.so','libminigbm_gralloc4_utils.so','android.hardware.graphics.allocator-V3-ndk.so','android.hardware.graphics.common-V7-ndk.so']:
  add('lib64/'+n,(donor/n).read_bytes(),'same_process_hal_file')
 add('lib64/hw/mapper.minigbm.so',(donor/'mapper.minigbm.so').read_bytes(),'same_process_hal_file')
 add('lib64/hw/gralloc.default.so',(donor/'gralloc.default.so').read_bytes(),'same_process_hal_file')
 # The stock compositor embeds Qualcomm SnapAlloc metadata readers.
 # Keep its service identity/policy; use AOSP's matching generic DRM implementation.
 composer=R/'artifacts/graphics-port-review/cf-composer'
 n='android.hardware.composer.hwc3-service.drm'
 add('bin/hw/'+n,(composer/n).read_bytes(),'hal_graphics_composer_default_exec',0o755)
 # The linker ignores LD_LIBRARY_PATH for a service with capabilities, so the composer
 # loaded the stock reporter library, whose C++ ABI differs. Replace that one library
 # where the linker actually looks.
 n='drm_hwcomposer_atom_reporter.so'
 add('lib64/'+n,(composer/n).read_bytes(),'same_process_hal_file')
 n='android.hardware.graphics.allocator-service.minigbm';add('bin/hw/'+n,(donor/n).read_bytes(),'hal_graphics_allocator_default_exec',0o755)
 add('etc/init/vendor.qti.hardware.display.allocator-service.rc',b'''# AOSP minigbm replaces the Qualcomm allocator.
service vendor.graphics.allocator /vendor/bin/hw/android.hardware.graphics.allocator-service.minigbm
    class hal animation
    user system
    group graphics drmrpc
    capabilities SYS_NICE
    onrestart restart surfaceflinger
    task_profiles ServiceCapacityLow
''','vendor_configs_file')
 add('etc/vintf/manifest/vendor.qti.hardware.display.allocator-service.xml',b'''<manifest version="9.0" type="device"><hal format="aidl"><name>android.hardware.graphics.allocator</name><version>3</version><fqname>IAllocator/default</fqname></hal></manifest>\n''','vendor_configs_file')
 add('etc/vintf/manifest/mapper.qti.xml',b'''<manifest version="9.0" type="device"><hal format="native"><name>mapper</name><fqname>@5.0/minigbm</fqname></hal></manifest>\n''','vendor_configs_file')
# SurfaceFlinger and app UI render with Vulkan; GLES is ANGLE; buffers are minigbm's, which
 # gfxstream's driver reads as such. One composition client, no wide colour or HDR.
 props={'ro.hardware.egl':'angle','ro.hardware.vulkan':'ranchu','ro.hardware.gralloc':'minigbm','ro.hwui.use_vulkan':'true',
        'debug.renderengine.backend':'skiavkthreaded','debug.renderengine.vulkan':'true','debug.renderengine.graphite_desktop_optin':'false',
        'debug.hwui.renderer':'skiavk','ro.gfx.angle.supported':'false','ro.vendor.hwcomposer.mode':'client',
        'ro.surface_flinger.has_wide_color_display':'false','ro.surface_flinger.has_HDR_display':'false','ro.vendor.hwc.drop_drm_master':'0'}
 b,label,mode=files['build.prop']  # keeps what the caller already added (no StrongBox, say)
 lines=[l for l in b.decode().splitlines() if l.split('=',1)[0] not in props]
 lines+=['# The VM graphics stack: gfxstream, ANGLE and the virtual buffer allocator.']+[k+'='+v for k,v in props.items()]
 add('build.prop',('\n'.join(lines)+'\n').encode(),label,mode)
 # Label only the emulated GPU's sysfs subtree using Google's existing GPU type.
 n='etc/selinux/vendor_file_contexts';b,label,mode=files[n]
 add(n,b+b'/sys/devices/platform/3f000000\\.pcie/pci0000:00/0000:00:01\\.0(/.*)? u:object_r:sysfs_gpu:s0\n',label,mode)
 add('etc/init/vm-graphics.rc',b'''# This path is the QEMU virtual GPU only, not host hardware.
on init
    restorecon_recursive /sys/devices/platform/3f000000.pcie/pci0000:00/0000:00:01.0
    start vm-gpu-state

service vm-gpu-state /system/bin/sh -c "ls -lZ /dev/dri /sys/class/drm; ls -lZ /sys/bus/pci/devices/0000:00:01.0/; cat /sys/bus/pci/devices/0000:00:01.0/uevent; getprop drm.gpu.vendor_name"
    disabled
    oneshot
    user shell
    group shell graphics log readproc
    seclabel u:r:shell:s0
    console ttyAMA0
''','vendor_configs_file')
