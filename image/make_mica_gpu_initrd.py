#!/usr/bin/env python3
"""Build the VM ramdisk: the original ramdisks, the original signed virtio-pci and virtio-console
modules, and Cuttlefish's virtio GPU, input and block modules, its DMA-heap module, and the
Wi-Fi stack virt_wifi needs (rfkill, cfg80211, virt_wifi; see guest_wifi.sh). Modules load here,
at first stage: once Android is up, this kernel takes no more."""
from pathlib import Path
import hashlib,json,stat,subprocess
from cpio_tools import write
R=Path(__file__).resolve().parents[1];base=R/'artifacts/mica/normal'
donor=R/'artifacts/cuttlefish-arm17/modules';original=R/'artifacts/mica/transport-modules';original.mkdir(exist_ok=True)
names=['virtio_pci_legacy_dev.ko','virtio_pci_modern_dev.ko','virtio_pci.ko','virtio_dma_buf.ko','virtio-gpu.ko','virtio_input.ko','virtio_console.ko',
       'system_heap.ko','virtio_blk.ko','rfkill.ko','cfg80211.ko','virt_wifi.ko']
# Protected core modules must be this kernel's own signed builds, and the rest built for it:
# rfkill from the Googlebook's system_dlkm, cfg80211 from its vendor_dlkm (Qualcomm's build for
# this kernel), virt_wifi from the virtual device (it matches that cfg80211 symbol for symbol).
OWN={'rfkill.ko':8188329984,'cfg80211.ko':8197767168}
e={'lib':(stat.S_IFDIR|0o755,b''),'lib/modules':(stat.S_IFDIR|0o755,b'')};manifest={}
for n in names:
    if n.startswith('virtio_pci') or n=='virtio_console.ko' or n in OWN:
        b=subprocess.check_output([str(R/'experiments/erofs-utils/1.9.4/bin/dump.erofs'),f'--offset={OWN.get(n,8188329984)}',f'--path=/lib/modules/{n}','--cat',str(R/'artifacts/mica-recovery.raw')]);assert b[:4]==b'\x7fELF'
        p=original/n
        if p.exists():assert p.read_bytes()==b
        else:p.write_bytes(b)
        source='original Mica vendor_dlkm' if n=='cfg80211.ko' else 'original signed Mica system_dlkm'
    else:b=(donor/n).read_bytes();source='Android CI 16373615 virtual-device vendor module'
    e['lib/modules/'+n]=(stat.S_IFREG|0o644,b);manifest[n]={'source':source,'sha256':hashlib.sha256(b).hexdigest()}
for n in ['modules.alias','modules.dep','modules.softdep','modules.options']:
    e['lib/modules/'+n]=(stat.S_IFREG|0o644,(donor/n).read_bytes())
mode,dep=e['lib/modules/modules.dep']
for n in ['virtio_console.ko','system_heap.ko','virtio_blk.ko']:
    if f'/{n}:'.encode() not in dep:dep+=f'\n/lib/modules/{n}:\n'.encode()
if b'/virt_wifi.ko:' not in dep:dep+=b'\n/lib/modules/virt_wifi.ko: /lib/modules/cfg80211.ko /lib/modules/rfkill.ko\n'
e['lib/modules/modules.dep']=(mode,dep)
e['lib/modules/modules.load']=(stat.S_IFREG|0o644,('\n'.join(names)+'\n').encode())
e['lib/modules/modules.load.recovery']=e['lib/modules/modules.load']
data=(base/'vendor_0_platform.cpio').read_bytes()+(base/'init_ramdisk.cpio').read_bytes()+write(e)
blob=subprocess.check_output(['lz4','-l','-c'],input=data)
out=base/'virtio_gpu_signed_transport_initrd.img';assert not out.exists();out.write_bytes(blob)
(base/'virtio_gpu_signed_transport_manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
print(out,len(blob),hashlib.sha256(blob).hexdigest())
