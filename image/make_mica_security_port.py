#!/usr/bin/env python3
"""Rebuild the vendor partition for a VM: software KeyMint and the other virtual-device
services replace hardware the VM does not have. Never edits the original image.
Preserves all existing vendor files/metadata through EROFS incremental import.
Only the modified vendor mount omits its obsolete stock AVB hash. Other mounts
retain original AVB; encryption and global SELinux enforcement remain unchanged.
"""
from pathlib import Path
import hashlib,io,json,os,stat,struct,subprocess,sys,tarfile
from cpio_tools import read,write
from erofs_metadata import metadata
from relocate_vendor import relocate
R=Path(__file__).resolve().parents[1];O=R/'artifacts/mica'/sys.argv[1];assert O.parent==R/'artifacts/mica';O.mkdir()
D=R/'experiments/erofs-utils/1.9.4/bin';E=R/'experiments/ext4-tools/e2fsprogs/1.47.4/sbin/debugfs'
raw=R/'artifacts/mica-recovery.raw';off=5647630336;partsize=385949696
payload=R/'artifacts/security-port-review/rust_nonsecure_payload.img'
# Guest components and the policy tool, from build-guest.sh and build-gfxstream.sh (build-image.sh sets these)
GUEST=Path(os.environ['GOOGLEBOOK_GUEST_DIR']);TOOLS=Path(os.environ['GOOGLEBOOK_TOOLS_DIR'])
def ext(path):
 p=subprocess.run([str(E),'-R','cat '+path,str(payload)],capture_output=True,check=True);assert p.stdout;return p.stdout
files={}
def original(path):
 return subprocess.check_output([str(D/'dump.erofs'),f'--offset={off}','--path=/'+path,'--cat',str(raw)])
def add(n,b,label,mode=0o644):files[n]=(b,label,mode)
add('build.prop',original('build.prop')+b'\n# The VM has no StrongBox hardware.\nro.vendor.apex.com.android.hardware.keymint.strongbox.desktop=none\n','vendor_file',0o600)
n='etc/init/hw/init.qti.kernel.rc';b=original(n)
old=b'on post-fs-data\n    # Late attach SOCCP and start ADSP and CDSP\n    wait_for_prop vendor.all.modules.ready 1\n    restart start-subsys'
assert b.count(old)==1
b=b.replace(old,b'# The Qualcomm coprocessors do not exist in a VM.\non post-fs-data && property:ro.boot.vm.qti_subsystems=1\n    wait_for_prop vendor.all.modules.ready 1\n    restart start-subsys')
add(n,b,'vendor_configs_file')
n='etc/init/hw/init.android-desktop.rc';b=original(n)
old=b'on property:sys.boot_completed=1 && property:mmd.enabled_aconfig=*\n    swapon_all /vendor/etc/fstab.zram'
assert b.count(old)==1
b=b.replace(old,b'''# Android's mmd_setup (started by mmd.rc on the same property) sets up zram too, and zram takes its
# backing device only while unconfigured. Run beside it, swapon_all's mkswap could write while
# mmd_setup reset zram: a NULL compressor in zram_submit_bio, and a kernel panic (about one boot in
# twenty here). So set up the swap once mmd_setup is done, or straight away when mmd is off.
on property:sys.boot_completed=1 && property:mmd.enabled_aconfig=false
    swapon_all /vendor/etc/fstab.zram

on property:mmd.enabled_aconfig=true && property:init.svc.mmd_setup=stopped
    swapon_all /vendor/etc/fstab.zram''')
add(n,b,'vendor_configs_file')
n='etc/selinux/vendor_file_contexts'
m=metadata(raw,'/'+n,off)
add(n,original(n)+b'\n/dev/ttyAMA0 u:object_r:console_device:s0\n',m['xattrs']['security.selinux'].decode().split(':')[2],m['mode']&0o7777)
add('bin/hw/android.hardware.security.keymint-service',ext('/bin/hw/android.hardware.security.keymint-service.nonsecure'),'hal_keymint_default_exec',0o755)
# Private crypto avoids replacing the original vendor library for other services.
add('lib64/vm_keymint/libcrypto.so',ext('/lib64/libcrypto.so'),'vendor_file')
add('etc/init/vm-software-keymint.rc',b'''# AOSP software KeyMint: not hardware-backed.
service vendor.keymint-default /vendor/bin/hw/android.hardware.security.keymint-service
    class early_hal
    user nobody
    setenv LD_LIBRARY_PATH /vendor/lib64/vm_keymint:/vendor/lib64
''','vendor_configs_file')
# Crash reports over the emulated UART only: ANRs, framework crashes, native backtraces (debuggerd
# logs them as DEBUG) and Chromium's fatal checks. A broader filter cost about half a guest CPU.
add('etc/init/vm-diagnostic-log.rc',b'''# Offline VM diagnostics over the emulated UART only.
service vm-diagnostic-log /system/bin/sh -c "exec /system/bin/logcat -b all -v threadtime *:S DEBUG:F chromium:F ActivityManager:E AndroidRuntime:E Watchdog:E lmkd:I libc:F am_crash:I am_kill:I am_anr:I"
    class core
    user shell
    group shell log readproc
    seclabel u:r:shell:s0
    console ttyAMA0

on init
    start vm-diagnostic-log
''','vendor_configs_file')
for n in ['keymint','secureclock','sharedsecret']:
 name=f'android.hardware.security.{n}-service.xml'
 add('etc/vintf/manifest/vm-'+name,ext('/etc/vintf/'+name),'vendor_configs_file')
if '--graphics' in sys.argv:
 from mica_graphics_port import apply
 apply(add,files,GUEST)
 # Tells run_vm.py this image is for the gfxstream device
 (O/'gfxstream.json').write_text(json.dumps({'graphics':'gfxstream','driver_sha256':hashlib.sha256(files['lib64/hw/vulkan.ranchu.so'][0]).hexdigest()})+'\n')
if '--self-test' in sys.argv:
 # Test images only: graphics self-tests at every boot (see guest_vulkan_startup.sh). The probe
 # runs in shell, which already belongs to gpu_sphal_domain.
 add('bin/vm-vulkan-probe',(GUEST/'guest-vulkan-probe').read_bytes(),'shell_exec',0o755)
 add('bin/vm-vulkan-startup.sh',(R/'scripts/guest_vulkan_startup.sh').read_bytes(),'vendor_shell_exec',0o755)
 add('etc/init/vm-vulkan-probe.rc',b'''service vm-vulkan-probe /system/bin/sh /vendor/bin/vm-vulkan-startup.sh
    disabled
    oneshot
    user shell
    group shell graphics log readproc
    seclabel u:r:shell:s0
    console ttyAMA0

on post-fs-data
    start vm-vulkan-probe
''','vendor_configs_file')
extra_dirs,new_dirs=[],['lib64/vm_keymint']
if '--bluetooth' in sys.argv:
 from mica_bluetooth_port import apply as bluetooth
 old,new=bluetooth(add,original,files);extra_dirs+=old;new_dirs+=new
if '--quiet-absent-hardware' in sys.argv:
 # The VM has no TPM or Trusty. Left alone, init restarts these services (and dumps a
 # tombstone) every 5 seconds. Disable them before they first start. (A stop-on-restart
 # trigger does not work for the TPM daemon: a vendor script cannot watch its init.svc property.)
 add('etc/init/vm-absent-hardware.rc',b'''on early-init
    stop android.system.desktop.security.gscd
    stop vendor.secretkeeper.trusty
''','vendor_configs_file')
if '--host-control' in sys.argv:
 # Fixed-verb control channel (power off, paste, density) read from the serial console.
 add('bin/vm-host-control.sh',(R/'scripts/guest_host_control.sh').read_bytes(),'vendor_shell_exec',0o755)
 add('etc/init/vm-host-control.rc',b'''service vm-host-control /system/bin/sh /vendor/bin/vm-host-control.sh
    disabled
    user shell
    group shell graphics log readproc input
    seclabel u:r:shell:s0
    console ttyAMA0

on post-fs-data
    start vm-host-control
''','vendor_configs_file')
if '--host-input' in sys.argv:
 # Absolute pointer and clipboard helper (scrcpy-style injection as shell); see scripts/guest_input.
 add('etc/vm-input.jar',(GUEST/'vm-input.jar').read_bytes(),'vendor_configs_file')
 add('bin/vm-input-service.sh',(R/'scripts/guest_input_service.sh').read_bytes(),'vendor_shell_exec',0o755)
 add('etc/init/vm-input.rc',b'''service vm-input /system/bin/sh /vendor/bin/vm-input-service.sh
    disabled
    user shell
    group shell input log inet readproc uhid
    seclabel u:r:shell:s0
    console ttyAMA0

on property:sys.boot_completed=1
    start vm-input
''','vendor_configs_file')
if '--stress-test' in sys.argv:
 # Test images only: drive theme switches and app launches after boot (see guest_stress_test.sh).
 add('bin/vm-stress-test.sh',(R/'scripts/guest_stress_test.sh').read_bytes(),'vendor_shell_exec',0o755)
 add('etc/init/vm-stress-test.rc',b'''service vm-stress-test /system/bin/sh /vendor/bin/vm-stress-test.sh
    disabled
    oneshot
    user shell
    group shell graphics log readproc input
    seclabel u:r:shell:s0
    console ttyAMA0

on post-fs-data
    start vm-stress-test
''','vendor_configs_file')
if '--perf-test' in sys.argv:
 # Test images only: scroll Settings and print frame statistics after boot (see guest_perf_test.sh).
 add('bin/vm-perf-test.sh',(R/'scripts/guest_perf_test.sh').read_bytes(),'vendor_shell_exec',0o755)
 add('etc/init/vm-perf-test.rc',b'''service vm-perf-test /system/bin/sh /vendor/bin/vm-perf-test.sh
    disabled
    oneshot
    user shell
    group shell graphics log readproc input
    seclabel u:r:shell:s0
    console ttyAMA0

on post-fs-data
    # Read once when input starts: log every event the dispatcher gets, to see what the touchpad
    # turned into (pointer moves, a scroll, a click)
    setprop log.tag.InputDispatcherInboundEvent DEBUG
    start vm-perf-test
''','vendor_configs_file')
if '--audio' in sys.argv:
 from mica_audio_port import apply
 apply(add)
 (O/'audio-port.json').write_text(json.dumps({'source':'official Cuttlefish build 16373615 audio APEX','deselected':'com.android.hardware.audio.desktop','host_audio':'none'})+'\n')
if '--camera' in sys.argv:
 from mica_camera_port import apply
 (O/'camera-port.json').write_text(json.dumps(apply(add,original,raw,off))+'\n')
if '--vm-compat' in sys.argv:
 # Keep A/B boot-control behaviour without the ChromeOS firmware calls.
 add('bin/hw/android.hardware.boot-service.android-desktop',(R/'artifacts/security-port-review/boot-service.default').read_bytes(),'hal_bootctl_default_exec',0o755)
 (O/'original-policy').write_bytes(original('etc/selinux/precompiled_sepolicy'))
 subprocess.run([str(TOOLS/'guest_graphics_memfd_policy'),str(O/'original-policy'),str(O/'graphics-policy')],check=True)
 m=metadata(raw,'/etc/selinux/precompiled_sepolicy',off)
 add('etc/selinux/precompiled_sepolicy',(O/'graphics-policy').read_bytes(),m['xattrs']['security.selinux'].decode().split(':')[2],m['mode']&0o7777)
 (O/'vm-compat.json').write_text(json.dumps({'boot_control':'official AOSP default, original service identity','selinux':'enforcing; only three observed graphics clients get read/write/map/getattr on allocator memfd buffers'})+'\n')
if '--locksettings' in sys.argv:
 from mica_locksettings_port import apply
 apply(add)
 (O/'locksettings-port.json').write_text(json.dumps({'gatekeeper':'official AOSP nonsecure build 16373615','weaver':'not advertised; AOSP optional-service fallback','security':'software-only VM-generated secrets; not hardware-backed'})+'\n')
if '--offline-desktop' in sys.argv:
 # Equivalent provisioning flags to official AOSP Provision DefaultActivity,
 # applied to fresh userdata, before any account exists.
 add('etc/init/vm-offline-desktop.rc',b'''service vm-offline-desktop /system/bin/sh /vendor/bin/vm-offline-desktop.sh
    disabled
    oneshot
    user shell
    group shell log readproc graphics
    seclabel u:r:shell:s0
    console ttyAMA0

on property:sys.boot_completed=1
    start vm-offline-desktop

# The Mac decides when this machine sleeps; Android must never suspend it. Nothing the viewer
# sends (network input, or even the USB keyboard) wakes a suspended VM, so the window would stay
# black. Android suspends only once nothing holds a wake lock: hold one for good.
on boot
    write /sys/power/wake_lock gbos_vm
''','vendor_configs_file')
 add('bin/vm-offline-desktop.sh',(R/'scripts/guest_offline_desktop.sh').read_bytes(),'vendor_shell_exec',0o755)
 (O/'offline-desktop.json').write_text(json.dumps({'purpose':'skip first-run setup on fresh userdata','source':'AOSP Provision DefaultActivity provisioning flags','accounts':'none','consumer_onboarding':'not completed'})+'\n')
with tarfile.open(O/'overlay.tar','w',format=tarfile.PAX_FORMAT) as t:
 dirs=['.','bin','bin/hw','etc','etc/init','etc/init/hw','etc/selinux','etc/vintf','etc/vintf/manifest','lib64','lib64/hw','lib64/vm_keymint']
 if '--audio' in sys.argv:dirs.append('apex')
 if '--camera' in sys.argv and 'apex' not in dirs:dirs.append('apex')
 dirs+=extra_dirs+new_dirs[1:]
 for n in dirs:
  m=metadata(raw,'/'+n if n!='.' else '/',off) if n not in new_dirs else {'mode':0o40755,'uid':0,'gid':2000,'mtime':1230768000,'xattrs':{'security.selinux':b'u:object_r:vendor_file:s0' if n.startswith('lib64') else b'u:object_r:vendor_configs_file:s0'}}
  ti=tarfile.TarInfo(n);ti.type=tarfile.DIRTYPE;ti.mode=m['mode']&0o7777;ti.uid=m['uid'];ti.gid=m['gid'];ti.mtime=m['mtime']
  ti.pax_headers={} if n=='.' else {'SCHILY.xattr.'+k:v.decode() for k,v in m['xattrs'].items()};t.addfile(ti)
 for n,(b,label,mode) in files.items():
  ti=tarfile.TarInfo(n);ti.size=len(b);ti.mode=mode;ti.uid=0;ti.gid=0;ti.mtime=1230768000
  ti.pax_headers={'SCHILY.xattr.security.selinux':f'u:object_r:{label}:s0'}
  t.addfile(ti,io.BytesIO(b))
v=O/'vendor.erofs'
with raw.open('rb') as f:
 f.seek(off+1024);sb=f.read(128);assert sb[:4]==bytes.fromhex('e2e1f5e0')
 size=struct.unpack_from('<I',sb,36)[0]*4096
 f.seek(off);v.write_bytes(f.read(size))
subprocess.run([str(D/'mkfs.erofs'),'--incremental=data','--tar=f','-x0','-b4096','-T1230768000','-zlz4hc',str(v),str(O/'overlay.tar')],check=True)
# mkfs incremental tar import clears root xattrs, and cannot grow this inode.
# Restore its existing shared-xattr reference exactly; original shared table stays.
with raw.open('rb') as f:
 f.seek(off+54*32);old=f.read(48)
with v.open('r+b') as f:
 f.seek(54*32);new=f.read(48)
 assert old[2:4]==new[2:4] and not (old[0]&1 or new[0]&1)
 f.seek(54*32+32);f.write(old[32:48])
 # EROFS CRC32C covers the rest of the first 4 KiB block, including root inode.
 f.seek(1024);b=bytearray(f.read(3072));b[4:8]=bytes(4);crc=0xffffffff
 for value in b:
  crc^=value
  for _ in range(8):crc=(crc>>1)^(0x82f63b78 if crc&1 else 0)
 f.seek(1028);f.write(struct.pack('<I',crc))
assert v.stat().st_size<1024*1024*1024
subprocess.run([str(D/'fsck.erofs'),str(v)],check=True)
# Validate old init files survived and all additions match byte-for-byte.
for n,(b,label,mode) in files.items():
 assert subprocess.check_output([str(D/'dump.erofs'),'--path=/'+n,'--cat',str(v)])==b,n
for p in ['/etc/init/hw/init.android-desktop.rc','/etc/selinux/precompiled_sepolicy']:
 if p=='/etc/selinux/precompiled_sepolicy' and '--vm-compat' in sys.argv:continue
 if p[1:] in files:continue  # changed on purpose, and checked against the change above
 assert subprocess.check_output([str(D/'dump.erofs'),'--path='+p,'--cat',str(v)])==subprocess.check_output([str(D/'dump.erofs'),'--offset='+str(off),'--path='+p,'--cat',str(raw)])
for n in [p for p in dirs if p not in new_dirs]:
 assert metadata(v,'/'+n if n!='.' else '/')==metadata(raw,'/'+n if n!='.' else '/',off),n
# APFS clone is a separate regular file; writes copy-on-write, not shared writes.
copy=O/'googlebook.raw';subprocess.run(['cp','-c',str(raw),str(copy)],check=True)
if v.stat().st_size>partsize:
 (O/'relocation.json').write_text(json.dumps(relocate(copy,v),indent=2)+'\n')
else:
 with copy.open('r+b') as f:f.seek(off);f.write(v.read_bytes());f.write(bytes(partsize-v.stat().st_size))
base=R/'artifacts/mica/normal'
ram=subprocess.check_output(['lz4','-d','-c',str(base/'virtio_gpu_signed_transport_initrd.img')])
entries=read((base/'vendor_0_platform.cpio').read_bytes());name='first_stage_ramdisk/fstab.android-desktop'
mode,b=entries[name];s=b.decode();s='\n'.join(l.replace(',avb=vbmeta','') if l.startswith('vendor ') else l for l in s.splitlines())+'\n'
ram+=write({name:(mode,s.encode())})
(O/'initrd.img').write_bytes(subprocess.check_output(['lz4','-l','-c'],input=ram))
(O/'manifest.json').write_text(json.dumps({'source':'official Android CI 16373615 software KeyMint','changed_mount':'vendor only; stock AVB removed only for modified vendor filesystem','selinux':('enforcing; three graphics-client memfd sharing rules added' if '--vm-compat' in sys.argv else 'enforcing, policy unchanged'),'encryption':'unchanged','files':{n:{'sha256':hashlib.sha256(b).hexdigest(),'label':label,'mode':oct(mode)} for n,(b,label,mode) in files.items()},'vendor_bytes':v.stat().st_size},indent=2)+'\n')
print(O)
