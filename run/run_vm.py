#!/usr/bin/env python3
"""Run the Googlebook VM once with an explicit QEMU command line.

  run_vm.py WORK RUN_NAME [--seconds N] [--snapshot] [--offline | --isolated | --lan] [--no-audio] [--bluetooth]
            [--webcam] [--microphone] [--display WxH] [--memory MIB] [--cpus N]

WORK is the build folder (host/, image/, UTM-beta/). Logs and sockets go to WORK/logs/RUN_NAME.
The disk is written to unless --snapshot is given. Networking is QEMU user-mode NAT with no
inbound forwards; --offline removes it (the pointer/clipboard helper then cannot connect).
--lan puts the guest on the Mac's own network instead, as one more device next to it (bridged
through the socket_vmnet service that run/lan-setup.sh installs), so phones nearby can find it;
the pointer/clipboard link then reaches the viewer at the Mac's address on that network.
--isolated keeps only the pointer/clipboard link: the guest can't reach the internet or any
service listening on this Mac's loopback (plain NAT maps 10.0.2.2 to the Mac's 127.0.0.1).
On stop, Android is asked to power off through the guest control channel before QEMU is killed.

Graphics are gfxstream (build-gfxstream.sh): Android's Vulkan and GLES (ANGLE) run on the Mac's
GPU through MoltenVK, and frames reach the viewer without a copy through the CPU.

--bluetooth: if the Android emulator's netsimd is installed (SDK "emulator" package, or set
GBOS_NETSIMD), start it as a virtual Bluetooth controller and tell Android it has Bluetooth. Its
raw HCI port is written to WORK/logs/RUN_NAME/bluetooth-port, where the viewer's relay picks it
up to show Android the BLE devices near the Mac (host/bluetooth.m); without the viewer it is a
simulated radio with nothing on it. Without netsimd the guest boots with no Bluetooth at all.

--webcam adds a usb-redir port on WORK/logs/RUN_NAME/webcam.sock; the viewer app connects to it
and plugs in a USB camera backed by the Mac's camera (host/webcam.m). Nothing is plugged in until
something connects, so the option is harmless on its own.
--microphone does the same on mic.sock for a USB microphone backed by the Mac's microphone
(host/microphone.m): QEMU's own audio devices and its coreaudio backend can only play sound.
"""
import argparse, atexit, fcntl, json, math, os, re, secrets, shutil, signal, socket, stat, subprocess, sys, threading, time
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
           # "false", not "0": the same to everything that reads it, but it doesn't match the
           # trigger that starts the non-secure Trusty security VM, which can't run here (its
           # command line needs a property only real hardware sets) and restarted every second
           'androidboot.hypervisor.protected_vm.supported=false '
           'androidboot.vendor.apex.com.android.hardware.keymint.strongbox.desktop=none '
           'androidboot.vendor.apex.com.android.hardware.audio.desktop=none loglevel=3')


LAN_SOCKET = '/var/run/googlebook-lan.sock'   # run/lan-setup.sh


def mac_lan_address():
    """The Mac's IPv4 address on the interface its default route uses (the one bridged for --lan)."""
    route = subprocess.run(['route', '-n', 'get', 'default'], capture_output=True, text=True).stdout
    iface = re.search(r'interface: (\S+)', route)
    if not iface: return None
    addr = subprocess.run(['ipconfig', 'getifaddr', iface.group(1)], capture_output=True, text=True).stdout.strip()
    return addr if re.fullmatch(r'\d+\.\d+\.\d+\.\d+', addr) else None


def qmp(out, *commands):
    """Run QMP commands on the VM (each a dict), in order."""
    with socket.socket(socket.AF_UNIX) as s:
        cwd = os.getcwd(); os.chdir(out)   # macOS limits socket paths to 104 bytes
        try: s.connect('qmp.sock')
        finally: os.chdir(cwd)
        f = s.makefile('rw')
        f.readline()
        for c in ({'execute': 'qmp_capabilities'},) + commands:
            f.write(json.dumps(c) + '\n'); f.flush()
            while 'return' not in (r := json.loads(f.readline())) and 'error' not in r: pass


def follow_lan(proc, out, token, addr):
    """--lan: when the Mac's network changes (Wi-Fi reconnects, or Wi-Fi to Ethernet), the bridge
    service bridges again (run/lan-setup.sh) and QEMU reconnects to it. Then the guest needs an
    address on the new network (its link goes down and up, so Android asks DHCP again) and the
    pointer link the Mac's new address (a new token line; the viewer listens there too)."""
    while proc.poll() is None:
        time.sleep(3)
        now = mac_lan_address()
        if not now or now == addr: continue
        print(f'network changed: the Mac is now {now}', flush=True)
        addr = now
        (out / 'host-address').write_text(addr + '\n')
        time.sleep(5)   # the bridge restarts and QEMU reconnects
        try:
            qmp(out, {'execute': 'set_link', 'arguments': {'name': 'ethernet', 'up': False}})
            time.sleep(1)
            qmp(out, {'execute': 'set_link', 'arguments': {'name': 'ethernet', 'up': True}})
            vm_control.send(out, f'VM_TOKEN {token} {addr}')
        except OSError as e: print('could not follow the network change:', e, flush=True)


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


def qemu_at_refresh(base, hz):
    """A copy of QEMU's library whose display description (EDID) says hz instead of 75 Hz, or
    None if this QEMU build doesn't look like the one we know how to change (a new QEMU version).

    qemu_edid_generate() uses `info->refresh_rate ?: 75000` (millihertz), and nothing in this
    setup ever fills refresh_rate in. The fallback is two instructions, MOVZ/MOVK Wd building
    75000, right before the CSEL that picks it; we rewrite their immediates. The copy sits beside
    the original, is ad-hoc signed like it, and is kept for the next boot at the same rate."""
    mhz = round(hz * 1000)
    if mhz == 75000: return base
    out = base.with_name(f'{base.name}-{mhz}mhz')
    if out.exists() and out.stat().st_mtime >= base.stat().st_mtime: return out
    tmp = out.with_suffix('.tmp')
    try:
        shutil.copyfile(base, tmp)
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
        print(f'cannot set the guest refresh rate in this QEMU ({e}); using 75 Hz', flush=True)
        tmp.unlink(missing_ok=True)
        return None


def guest_refresh(host_hz, cap=120):
    """The guest refresh rate that paces best on a host_hz screen: the largest whole fraction of
    the screen's rate up to cap (120 -> 120, 144 -> 72), so every frame stays up for the same
    number of refreshes. A screen up to 90 Hz that would drop below 50 that way keeps its own rate."""
    fits = [host_hz / k for k in range(1, 9) if host_hz / k <= cap + 1e-6]
    best = fits[0] if fits else cap
    return best if best >= 50 or host_hz > 90 else host_hz


def send_token(proc, out, token, host_addr):
    """Hand the per-boot token to the guest over the serial console, which only this user can
    reach, once its control service is up. It used to go on the kernel command line, where any
    guest app that can read ro.boot.* properties could see it."""
    serial = out / 'serial.log'
    def seen(marker):
        # Match at a line start so guest log text can't fake a marker.
        try: return re.search(rb'(?m)^' + re.escape(marker), serial.read_bytes()) is not None
        except OSError: return False
    deadline = time.monotonic() + 300
    while not seen(b'VM_CONTROL_READY'):
        if proc.poll() is not None or time.monotonic() > deadline: return
        time.sleep(.5)
    err = None
    for _ in range(6):
        try: vm_control.send(out, f'VM_TOKEN {token} {host_addr}')
        except OSError as e: err = e
        for _ in range(10):
            if seen(b'VM_CONTROL token set'): return
            if proc.poll() is not None: return
            time.sleep(.5)
    print('WARNING: the guest never acknowledged the input token' + (f' ({err})' if err else '') +
          '; the pointer/clipboard link will not connect', file=sys.stderr, flush=True)


def main():
    a = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    a.add_argument('work'); a.add_argument('name')
    a.add_argument('--seconds', type=int, help='power the VM off after this long (default: run until stopped)')
    a.add_argument('--snapshot', action='store_true'); a.add_argument('--offline', action='store_true')
    a.add_argument('--isolated', action='store_true'); a.add_argument('--lan', action='store_true')
    a.add_argument('--no-audio', action='store_true'); a.add_argument('--bluetooth', action='store_true')
    a.add_argument('--webcam', action='store_true'); a.add_argument('--microphone', action='store_true')
    a.add_argument('--display', default='1920x1200'); a.add_argument('--memory', type=int, default=4096)
    a.add_argument('--cpus', type=int, default=6)
    a.add_argument('--host-refresh', type=float, help="the Mac screen's refresh rate; picks the guest rate that paces best on it")
    a.add_argument('--refresh', type=float, help='guest refresh rate in Hz (overrides --host-refresh; default 75)')
    a.add_argument('--image', help='image folder (default WORK/image)')
    args = a.parse_args()
    work = Path(args.work).resolve()
    if not args.name.replace('-', '').replace('_', '').isalnum(): a.error('RUN_NAME: letters, digits, - and _ only')
    if args.seconds is not None and not 10 <= args.seconds <= 86400: a.error('--seconds: 10 to 86400')
    if args.offline + args.isolated + args.lan > 1: a.error('--offline, --isolated and --lan: one at most')
    lan_addr = None
    if args.lan:
        if not stat.S_ISSOCK(os.stat(LAN_SOCKET).st_mode if os.path.exists(LAN_SOCKET) else 0):
            sys.exit('the network bridge isn\'t set up: run  sudo run/lan-setup.sh  once')
        lan_addr = mac_lan_address()
        if not lan_addr: sys.exit('the Mac has no IPv4 address on its network right now')
    image = Path(args.image).resolve() if args.image else work / 'image'
    if not (image / 'gfxstream.json').exists():
        sys.exit(f'{image} was built for the old virgl graphics; run ./update-image.sh (your data stays)')
    built = work / 'build/qemu-gfx/libqemu-aarch64-softmmu.dylib'
    if not built.exists(): sys.exit('missing the gfxstream QEMU; run ./build-gfxstream.sh')
    host, utm = work / 'host', work / 'UTM-beta/UTM.app'
    for p in (host / 'qemu-interop', image / 'googlebook.raw', image / 'initrd.img', image / 'kernel.Image', utm / 'Contents/Frameworks'):
        if not p.exists(): sys.exit(f'missing: {p}')
    width, height = args.display.split('x')
    # One VM per folder: the lock is held by QEMU too (pass_fds below), so it lasts as long as the disk is in use
    (work / 'logs').mkdir(exist_ok=True)
    lock = (work / 'logs/vm.lock').open('a')
    try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError: sys.exit('another VM from this folder is already running')
    refresh = args.refresh or (guest_refresh(args.host_refresh) if args.host_refresh else 75)
    # Our own QEMU build (UTM's has no rutabaga device). The launcher loads only from its own
    # folder, so keep a copy of it there; copies at other refresh rates go stale with it.
    base = host / 'qemu-gfx-aarch64-softmmu'
    if not base.exists() or base.stat().st_mtime < built.stat().st_mtime:
        for old in host.glob(base.name + '-*mhz'): old.unlink()
        shutil.copyfile(built, base.with_suffix('.tmp')); base.with_suffix('.tmp').rename(base)
    qemu = qemu_at_refresh(base, refresh)
    if qemu is None: qemu, refresh = base, 75
    print(f'guest refresh: {refresh:g} Hz' + (f' (Mac screen {args.host_refresh:g} Hz)' if args.host_refresh else ''), flush=True)
    # Private: holds the token and the QMP, SPICE and serial sockets.
    out = work / 'logs' / args.name; out.mkdir(mode=0o700)
    # Random per-boot secret for the pointer/clipboard link (see guest/input).
    token = secrets.token_hex(16)
    with os.fdopen(os.open(out / 'token', os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'w') as f: f.write(token)
    (out / 'refresh').write_text(f'{refresh:g}\n')  # the viewer locks its presentation to it

    gpu = 'virtio-gpu-rutabaga-pci'
    netsim, cmdline = None, CMDLINE
    netsimd = find_netsimd() if args.bluetooth else None
    if netsimd:
        netsim, bt_port = start_netsimd(netsimd, out)
        cmdline += ' androidboot.product.vendor.sku=vmbt'
    print('bluetooth:', f'virtual controller ({netsimd})' if netsimd else 'none', flush=True)
    # For the viewer, whose Bluetooth relay joins the same virtual radio (host/bluetooth.m)
    if args.bluetooth: (out / ('bluetooth-port' if netsim else 'bluetooth-none')).write_text(f'{bt_port}\n' if netsim else '')

    cmd = [str(host / 'qemu-interop'), '-nodefaults', '-vga', 'none',
           '-nic', 'none', '-device', gpu + ',hostmem=8G,gfxstream-vulkan=on' + os.environ.get('GBOS_GFXSTREAM_DEVICE', ''),
           '-global', f'{gpu}.xres={width}', '-global', f'{gpu}.yres={height}',
           '-cpu', 'host', '-smp', f'cpus={args.cpus},sockets=1,cores={args.cpus},threads=1',
           '-machine', 'virt,gic-version=3,highmem=on,highmem-ecam=off', '-accel', 'hvf,ipa-granule-size=0x1000',
           '-m', str(args.memory), '-audio', 'none',
           '-kernel', str(image / 'kernel.Image'), '-initrd', str(image / 'initrd.img'), '-append', cmdline,
           '-drive', f'if=none,media=disk,id=driveimage,format=raw,file={image / "googlebook.raw"}',
           '-device', 'virtio-blk-pci,drive=driveimage', '-device', 'virtio-serial', '-no-reboot',
           # Eight USB 2 ports: with the default four, keyboard, mouse, network and audio fill them
           # and anything else lands on a full-speed hub, too slow for the webcam.
           '-device', 'qemu-xhci,id=xhci,addr=0x5,p2=8,p3=8', '-device', 'usb-kbd,id=keyboard,bus=xhci.0',
           '-device', 'usb-mouse,id=mouse,bus=xhci.0',
           '-display', 'none',
           '-spice', 'unix=on,addr=spice.sock,disable-ticketing=on,disable-copy-paste=on,disable-agent-file-xfer=on,gl=es',
           '-chardev', 'socket,id=serial0,path=serial.sock,server=on,wait=off,logfile=serial.log',
           '-serial', 'chardev:serial0', '-qmp', 'unix:qmp.sock,server=on,wait=off']
    if args.snapshot: cmd.append('-snapshot')
    if args.lan:
        # Reconnects when the bridge service starts over (the Mac's network changed)
        cmd += ['-netdev', f'stream,id=googlebooknet,server=off,reconnect-ms=1000,addr.type=unix,addr.path={LAN_SOCKET}',
                '-device', 'usb-net,id=ethernet,netdev=googlebooknet,bus=xhci.0,mac=52:54:00:12:34:56']
        (out / 'host-address').write_text(lan_addr + '\n')   # the viewer listens there too
    elif not args.offline:
        # Isolated: only the one forward to the viewer's loopback port.
        isolate = ',restrict=on,guestfwd=tcp:10.0.2.100:27183-cmd:/usr/bin/nc 127.0.0.1 27183' if args.isolated else ''
        cmd += ['-netdev', 'user,id=googlebooknet,ipv6=off' + isolate,
                '-device', 'usb-net,id=ethernet,netdev=googlebooknet,bus=xhci.0,mac=52:54:00:12:34:56']
    if netsim:
        # /dev/hvc0 in the guest; the Bluetooth service there speaks HCI over it.
        cmd += ['-chardev', f'socket,id=bluetooth,host=127.0.0.1,port={bt_port},reconnect-ms=500',
                '-device', 'virtconsole,chardev=bluetooth']
    if not args.no_audio:
        cmd += ['-audiodev', 'coreaudio,id=audio0', '-device', 'usb-audio,audiodev=audio0,bus=xhci.0']
    if args.webcam:
        cmd += ['-chardev', 'socket,id=webcam,path=webcam.sock,server=on,wait=off',
                '-device', 'usb-redir,chardev=webcam,id=webcam,bus=xhci.0']
    if args.microphone:
        cmd += ['-chardev', 'socket,id=mic,path=mic.sock,server=on,wait=off',
                '-device', 'usb-redir,chardev=mic,id=mic,bus=xhci.0']
    # The launcher loads only builds from its own folder, chosen by file name
    env = dict(os.environ, VM_QEMU_LIBRARY=qemu.name,
               DYLD_FRAMEWORK_PATH=str(utm / 'Contents/Frameworks'),
               ANGLE_DEFAULT_PLATFORM='metal', TMPDIR=str(out),
               # HVF cannot map Metal's own memory into the guest: give gfxstream ordinary memory
               # for everything the guest maps, imported into Vulkan (VK_EXT_external_memory_host).
               # Android's UI renderer insists on two graphics queues; MoltenVK runs with one, so
               # gfxstream offers a second that feeds the same Metal queue.
               GFXSTREAM_RENDERER_FEATURES=os.environ.get('GFXSTREAM_RENDERER_FEATURES',
                                                          'VulkanAllocateHostMemory:enabled,VulkanVirtualQueue:enabled'),
               # gfxstream's own MoltenVK set-up (its settings, and the Metal interop extensions
               # the zero-copy display needs), with the manifest build-gfxstream.sh writes
               ANDROID_EMU_VK_ICD='moltenvk')
    env.pop('APP_SANDBOX_GROUP_ID', None)
    (out / 'command.json').write_text(json.dumps({'command': cmd, 'seconds': args.seconds}, indent=2))
    with (out / 'host.log').open('wb') as log:
        proc = subprocess.Popen(cmd, cwd=out, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True,
                                pass_fds=(lock.fileno(),))
        print('PID', proc.pid, 'logs', out, flush=True)
        threading.Thread(target=send_token, args=(proc, out, token, lan_addr or ('10.0.2.100' if args.isolated else '10.0.2.2')), daemon=True).start()
        if args.lan: threading.Thread(target=follow_lan, args=(proc, out, token, lan_addr), daemon=True).start()
        def interrupt(signum, frame): raise KeyboardInterrupt
        signal.signal(signal.SIGTERM, interrupt)
        rc = None
        try: rc = proc.wait(timeout=args.seconds)
        except (subprocess.TimeoutExpired, KeyboardInterrupt): pass
        finally:
            signal.signal(signal.SIGTERM, signal.SIG_IGN)  # a second stop request must not cut this short
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
        (out / 'token').unlink(missing_ok=True)
        (out / 'result.json').write_text(json.dumps({'exit_code': rc}))
        print('exit', rc, flush=True)


if __name__ == '__main__':
    main()
