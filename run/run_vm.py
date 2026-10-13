#!/usr/bin/env python3
"""Run the Googlebook VM once with an explicit QEMU command line.

  run_vm.py WORK RUN_NAME [--seconds N] [--snapshot] [--offline] [--no-audio] [--no-bluetooth]
            [--display WxH] [--memory MIB] [--cpus N]

WORK is the build folder (host/, image/, UTM-beta/). Logs and sockets go to WORK/logs/RUN_NAME.
The disk is written to unless --snapshot is given. Networking is QEMU user-mode NAT with no
inbound forwards; --offline removes it (the pointer/clipboard helper then cannot connect).
On stop, Android is asked to power off through the guest control channel before QEMU is killed.

Bluetooth: if the Android emulator's netsimd is installed (SDK "emulator" package, or set
GBOS_NETSIMD), it is started as a virtual Bluetooth controller and Android is told it has
Bluetooth. Otherwise, or with --no-bluetooth, the guest boots with no Bluetooth at all.
"""
import argparse, atexit, fcntl, json, math, os, secrets, signal, socket, subprocess, sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import vm_control

# Kernel command line for the pinned image (mica-user 16471258). The vbmeta values describe the
# original, unmodified vbmeta partition of that image.
CMDLINE = ('console=ttyAMA0,115200 earlycon=pl011,0x9000000 panic=0 root=/dev/ram0 '
           'androidboot.hardware=android-desktop androidboot.hardware.platform=android-desktop '
           'androidboot.slot_suffix=_a androidboot.boot_devices=3f000000.pcie androidboot.vbmeta.size=7680 '
           'androidboot.vbmeta.hash_alg=sha256 '
           'androidboot.vbmeta.digest=9118d58c024a0b43fef17a1dcdf6b999b5ea9cbc053fd4377d5d78c445b15692 '
           'androidboot.vbmeta.device_state=unlocked androidboot.verifiedbootstate=orange '
           'androidboot.veritymode=enforcing printk.devkmsg=on '
           'androidboot.vendor.apex.com.android.hardware.keymint.strongbox.desktop=none '
           'androidboot.vendor.apex.com.android.hardware.audio.desktop=none loglevel=3')


def find_netsimd():
    # The last two are where prereqs.sh puts the SDK when it installs one through Homebrew.
    sdks = [os.environ.get(k) for k in ('ANDROID_SDK', 'ANDROID_HOME', 'ANDROID_SDK_ROOT')] + [
        str(Path.home() / 'Library/Android/sdk'), '/opt/homebrew/share/android-commandlinetools',
        '/usr/local/share/android-commandlinetools']
    for c in [os.environ.get('GBOS_NETSIMD')] + [str(Path(s) / 'emulator/netsimd') for s in sdks if s]:
        if c and os.access(c, os.X_OK): return c


def start_netsimd(binary, out):
    """Start a virtual Bluetooth controller serving HCI on a free loopback port. Returns (process, port).

    netsimd exits by itself when QEMU disconnects; if this script ends before that (QEMU never
    started, say), it is stopped on the way out."""
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0)); port = s.getsockname()[1]
    tmp = out / 'netsim'; tmp.mkdir()
    proc = subprocess.Popen([binary, '--hci-port', str(port), '--no-web-ui', '--no-cli-ui', '--logtostderr', '--instance', '27'],
                            cwd=tmp, env=dict(os.environ, TMPDIR=str(tmp)), stdin=subprocess.DEVNULL,
                            stdout=(out / 'netsim.log').open('wb'), stderr=subprocess.STDOUT, start_new_session=True)
    def stop():
        if proc.poll() is None:
            try: os.killpg(proc.pid, signal.SIGTERM)
            except ProcessLookupError: pass
    atexit.register(stop)
    return proc, port


def qemu_at_refresh(host, hz):
    """A copy of QEMU's library whose display description (EDID) says hz instead of 75 Hz, or
    None if this QEMU build doesn't look like the one we know how to change.

    qemu_edid_generate() uses `info->refresh_rate ?: 75000` (millihertz), and nothing in this
    setup ever fills refresh_rate in. The fallback is two instructions, MOVZ/MOVK Wd building
    75000, right before the CSEL that picks it; we rewrite their immediates. The copy sits beside
    the original (it finds the patched renderer via @loader_path), is ad-hoc signed like the
    original, and is kept for the next boot at the same rate."""
    base = host / 'qemu-aarch64-softmmu'
    mhz = round(hz * 1000)
    if mhz == 75000: return base
    out = host / f'qemu-aarch64-softmmu-{mhz}mhz'
    if out.exists() and out.stat().st_mtime >= base.stat().st_mtime: return out
    tmp = out.with_suffix('.tmp')
    try:
        subprocess.run(['/usr/bin/lipo', '-thin', 'arm64', str(base), '-output', str(tmp)], check=True, capture_output=True)
        code = bytearray(tmp.read_bytes())
        word = lambda o: int.from_bytes(code[o:o + 4], 'little')
        sites = [o for o in range(0, len(code) - 16, 4)
                 if word(o) & 0xFFFFFFE0 == 0x52800000 | 0x24F8 << 5                     # movz wD, #0x24f8
                 and word(o + 4) == 0x72A00020 | word(o) & 31                             # movk wD, #0x1, lsl #16
                 and any(word(o + k) & 0x7FE00C00 == 0x1A800000 for k in (8, 12))]        # csel follows
        if len(sites) != 1: raise ValueError(f'{len(sites)} candidate sites')
        rd = word(sites[0]) & 31
        code[sites[0]:sites[0] + 8] = ((0x52800000 | (mhz & 0xFFFF) << 5 | rd).to_bytes(4, 'little')
                                       + (0x72A00000 | (mhz >> 16) << 5 | rd).to_bytes(4, 'little'))
        tmp.write_bytes(code)
        subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(tmp)], check=True, capture_output=True)
        tmp.rename(out)
        return out
    except (OSError, subprocess.CalledProcessError, ValueError) as e:
        print(f'cannot set the guest refresh rate in this QEMU ({e}); using 60 or 75 Hz', flush=True)
        tmp.unlink(missing_ok=True)
        return None


def guest_refresh(host_hz, any_rate=True, cap=120):
    """The guest refresh rate that paces best on a host_hz screen. With a QEMU we can patch
    (any_rate), that is the largest whole fraction of the screen's rate up to cap (with the default
    120: 120 -> 120, 144 -> 72; with 75: 120 -> 60), so every frame stays up for the same number of
    refreshes; a screen up to 90 Hz that would drop below 50 that way (85 -> 42.5 under a 75 cap)
    keeps its own rate instead. A lower cap lightens the guest: at native resolution and 120 Hz,
    2-4% of frames miss their deadline while scrolling, against about 0.5% at 60-85 Hz.
    Otherwise only 60 Hz (no EDID: the guest driver's own 59.95 Hz mode) and 75 Hz (QEMU's EDID)
    are on offer: a screen that is a whole multiple of one shows every frame for the same time,
    and failing that the rate with fewer uneven frames per second (the beat against the nearest
    multiple) wins."""
    if any_rate:
        fits = [host_hz / k for k in range(1, 9) if host_hz / k <= cap + 1e-6]
        best = fits[0] if fits else cap
        return best if best >= 50 or host_hz > 90 else host_hz
    beat = lambda r: min(abs(host_hz - k * r) for k in range(1, 5))
    return min((60, 75), key=lambda r: beat(59.95 if r == 60 else 75))


def main():
    a = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    a.add_argument('work'); a.add_argument('name')
    a.add_argument('--seconds', type=int, default=3600)
    a.add_argument('--snapshot', action='store_true'); a.add_argument('--offline', action='store_true')
    a.add_argument('--no-audio', action='store_true'); a.add_argument('--no-bluetooth', action='store_true')
    a.add_argument('--display', default='1920x1200'); a.add_argument('--memory', type=int, default=4096)
    a.add_argument('--cpus', type=int, default=6)
    a.add_argument('--host-refresh', type=float, help="the Mac screen's refresh rate; picks the guest rate that paces best on it")
    a.add_argument('--refresh', type=float, help='guest refresh rate in Hz (overrides --host-refresh; default 75)')
    a.add_argument('--refresh-cap', type=float, default=120, help='highest guest rate --host-refresh may pick (default 120)')
    a.add_argument('--image', help='image folder (default WORK/image)')
    args = a.parse_args()
    work = Path(args.work).resolve()
    assert args.name.replace('-', '').replace('_', '').isalnum() and 10 <= args.seconds <= 86400
    image = Path(args.image).resolve() if args.image else work / 'image'
    host, utm = work / 'host', work / 'UTM-beta/UTM.app'
    for p in (host / 'qemu-interop', host / 'qemu-aarch64-softmmu', host / 'virgl_render_server',
              image / 'googlebook.raw', image / 'initrd.img', image / 'kernel.Image', utm / 'Contents/Frameworks'):
        if not p.exists(): sys.exit(f'missing: {p}')
    width, height = args.display.split('x')
    refresh = args.refresh or (guest_refresh(args.host_refresh, cap=args.refresh_cap) if args.host_refresh else 75)
    qemu, edid = qemu_at_refresh(host, refresh), True
    if qemu is None:  # an unknown QEMU build: fall back to the two rates it offers unmodified
        refresh = guest_refresh(args.host_refresh or refresh, any_rate=False)
        qemu, edid = host / 'qemu-aarch64-softmmu', refresh != 60
        if not edid: refresh = 59.95
    print(f'guest refresh: {refresh:g} Hz' + (f' (Mac screen {args.host_refresh:g} Hz)' if args.host_refresh else ''), flush=True)
    (work / 'logs').mkdir(exist_ok=True)
    lock = (work / 'logs/vm.lock').open('a')
    try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError: sys.exit('another VM from this folder is already running')
    out = work / 'logs' / args.name; out.mkdir()
    # Random per-boot secret for the pointer/clipboard link (see guest/input).
    token = secrets.token_hex(16)
    (out / 'token').write_text(token); os.chmod(out / 'token', 0o600)
    (out / 'refresh').write_text(f'{refresh:g}\n')  # the viewer locks its presentation to it

    netsim, cmdline = None, CMDLINE + ' androidboot.gbos_token=' + token
    netsimd = None if args.no_bluetooth else find_netsimd()
    if netsimd:
        netsim, bt_port = start_netsimd(netsimd, out)
        cmdline += ' androidboot.product.vendor.sku=vmbt'
    print('bluetooth:', f'virtual controller ({netsimd})' if netsimd else 'none', flush=True)

    cmd = [str(host / 'qemu-interop'), '-L', str(utm / 'Contents/Resources/qemu'), '-nodefaults', '-vga', 'none',
           '-nic', 'none', '-device', 'virtio-gpu-gl-pci,hostmem=8G,blob=true,venus=true',
           '-global', f'virtio-gpu-gl-pci.xres={width}', '-global', f'virtio-gpu-gl-pci.yres={height}',
           *([] if edid else ['-global', 'virtio-gpu-gl-pci.edid=off']),
           '-cpu', 'host', '-smp', f'cpus={args.cpus},sockets=1,cores={args.cpus},threads=1',
           '-machine', 'virt,gic-version=3,highmem=on,highmem-ecam=off', '-accel', 'hvf,ipa-granule-size=0x1000',
           '-m', str(args.memory), '-audio', 'none',
           '-kernel', str(image / 'kernel.Image'), '-initrd', str(image / 'initrd.img'), '-append', cmdline,
           '-drive', f'if=none,media=disk,id=driveimage,format=raw,file={image / "googlebook.raw"}',
           '-device', 'virtio-blk-pci,drive=driveimage', '-device', 'virtio-serial', '-no-reboot',
           '-device', 'qemu-xhci,id=xhci,addr=0x5', '-device', 'usb-kbd,id=keyboard,bus=xhci.0',
           '-device', 'usb-mouse,id=mouse,bus=xhci.0',
           '-display', 'none',
           '-spice', 'unix=on,addr=spice.sock,disable-ticketing=on,disable-copy-paste=on,disable-agent-file-xfer=on,gl=es',
           '-chardev', 'socket,id=serial0,path=serial.sock,server=on,wait=off,logfile=serial.log',
           '-serial', 'chardev:serial0', '-qmp', 'unix:qmp.sock,server=on,wait=off']
    if args.snapshot: cmd.append('-snapshot')
    if not args.offline:
        cmd += ['-netdev', 'user,id=googlebooknet,ipv6=off',
                '-device', 'usb-net,id=ethernet,netdev=googlebooknet,bus=xhci.0,mac=52:54:00:12:34:56']
    if netsim:
        # /dev/hvc0 in the guest; the Bluetooth service there speaks HCI over it.
        cmd += ['-chardev', f'socket,id=bluetooth,host=127.0.0.1,port={bt_port},reconnect-ms=500',
                '-device', 'virtconsole,chardev=bluetooth']
    if not args.no_audio:
        cmd += ['-audiodev', 'coreaudio,id=audio0', '-device', 'usb-audio,audiodev=audio0,bus=xhci.0']
    env = dict(os.environ, VM_QEMU_LIBRARY=str(qemu),
               DYLD_FRAMEWORK_PATH=str(utm / 'Contents/Frameworks'),
               RENDER_SERVER_EXEC_PATH=str(host / 'virgl_render_server'),
               VK_DRIVER_FILES=str(utm / 'Contents/Resources/vulkan/icd.d/MoltenVK_icd.json'),
               ANGLE_DEFAULT_PLATFORM='metal', XDG_RUNTIME_DIR=str(out), TMPDIR=str(out))
    env.pop('APP_SANDBOX_GROUP_ID', None)
    (out / 'command.json').write_text(json.dumps({'command': cmd, 'seconds': args.seconds}, indent=2))
    with (out / 'host.log').open('wb') as log:
        proc = subprocess.Popen(cmd, cwd=out, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        print('PID', proc.pid, 'logs', out, flush=True)
        def interrupt(signum, frame): raise KeyboardInterrupt
        signal.signal(signal.SIGTERM, interrupt)
        rc = None
        try: rc = proc.wait(timeout=args.seconds)
        except (subprocess.TimeoutExpired, KeyboardInterrupt): pass
        finally:
            if proc.poll() is None:
                try:
                    vm_control.send(out, 'VM_POWEROFF'); rc = proc.wait(timeout=30)
                except Exception: pass
            if proc.poll() is None:
                os.killpg(proc.pid, signal.SIGTERM)
                try: rc = proc.wait(timeout=8)
                except subprocess.TimeoutExpired: os.killpg(proc.pid, signal.SIGKILL); rc = proc.wait()
            if netsim and netsim.poll() is None:
                try: netsim.wait(timeout=3)
                except subprocess.TimeoutExpired: os.killpg(netsim.pid, signal.SIGTERM)
        (out / 'result.json').write_text(json.dumps({'exit_code': rc}))
        print('exit', rc, flush=True)


if __name__ == '__main__':
    main()
