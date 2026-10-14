#!/usr/bin/env python3
"""Start the Googlebook desktop with its viewer window.  launch.py WORK [--fullscreen] [--display WxH]
Closing the viewer shuts Android down cleanly. Data in WORK/image/googlebook.raw persists."""
import datetime, json, os, re, signal, subprocess, sys, threading, time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import vm_control


def native_display():
    """Main display's pixel width, with a 16:10 height (the area below a MacBook notch)."""
    try:
        info = json.loads(subprocess.check_output(['/usr/sbin/system_profiler', 'SPDisplaysDataType', '-json'], timeout=20))
        for gpu in info['SPDisplaysDataType']:
            for d in gpu.get('spdisplays_ndrvs', []):
                if d.get('spdisplays_main') == 'spdisplays_yes':
                    w, h = [int(x) for x in d['_spdisplays_pixels'].split(' x ')]
                    return w, min(h, round(w / 1.6))
    except Exception:
        pass
    return 1920, 1200


def setting(key, default):
    """Read one of the viewer's Settings values (stored in its macOS preferences)."""
    try:
        return subprocess.check_output(['/usr/bin/defaults', 'read', 'local.googlebook.viewer', key],
                                       text=True, stderr=subprocess.DEVNULL).strip()
    except subprocess.CalledProcessError:
        return default


def main():
    work = Path(sys.argv[1]).resolve()
    viewer_app = work / 'host/Googlebook VM.app/Contents/MacOS/GooglebookViewer'
    if not viewer_app.is_file(): sys.exit(f'viewer not built: {viewer_app}')
    if any(c.strip().endswith('/qemu-interop') for c in subprocess.check_output(['/bin/ps', '-axo', 'comm='], text=True).splitlines()):
        sys.exit('A Googlebook VM is already running; close it first.')
    resolution = setting('Resolution', 'native')
    if '--display' in sys.argv: width, height = [int(x) for x in sys.argv[sys.argv.index('--display') + 1].split('x')]
    elif 'x' in resolution: width, height = [int(x) for x in resolution.split('x')]
    else: width, height = native_display()
    fullscreen = '--fullscreen' in sys.argv or setting('StartFullscreen', '0') == '1'
    # Android 16 with Google's services swaps hard in 4 GB; 8 GB on Macs that have the room
    big = int(subprocess.check_output(['/usr/sbin/sysctl', '-n', 'hw.memsize'], text=True)) >= 24 << 30
    options = ['--memory', setting('MemoryMiB', '8192' if big else '4096'), '--cpus', setting('CPUs', '6')]
    network = setting('Network', 'full')
    if network == 'off': options.append('--offline')
    elif network == 'isolated': options.append('--isolated')
    if setting('Audio', '1') == '0': options.append('--no-audio')
    density = 320  # macOS's own 2x, unless the viewer says otherwise for this screen
    try:  # pace the guest to the main screen (see guest_refresh in run_vm.py), and size its UI like macOS
        hz, d = subprocess.check_output([str(viewer_app), '--screen', str(width)], text=True, timeout=10).split()
        density = int(d); options += ['--host-refresh', str(float(hz))]
    except (subprocess.SubprocessError, OSError, ValueError):
        pass
    name = 'desktop-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
    run_dir = work / 'logs' / name
    children = []
    def interrupt(signum, frame): raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupt); signal.signal(signal.SIGINT, interrupt)
    print(f'Googlebook desktop {width}x{height}: {name}. If you see the user picker, click "User".', flush=True)
    try:
        vm = subprocess.Popen([sys.executable, str(HERE / 'run_vm.py'), str(work), name, '--display', f'{width}x{height}'] + options,
                              start_new_session=True); children.append(vm)
        sock = run_dir / 'spice.sock'; deadline = time.monotonic() + 30
        while not sock.exists():
            if vm.poll() is not None or time.monotonic() > deadline: raise RuntimeError(f'VM did not start; see {run_dir}')
            time.sleep(.2)
        # The emulated USB mouse stays plugged in but idle: steering it leaves a second cursor on
        # screen, and unplugging it while the helper's tablet registers crashed system_server.
        venv = dict(os.environ, VM_MOUSE_SEAMLESS='0', VM_MOUSE_RELATIVE='0', VM_INPUT_TOKEN=(run_dir / 'token').read_text())
        with (run_dir / 'viewer.log').open('w') as log:
            viewer = subprocess.Popen([str(viewer_app), str(sock)] + (['--fullscreen'] if fullscreen else []),
                                      env=venv, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            children.append(viewer)
            serial = run_dir / 'serial.log'; configured = False; start = time.monotonic()
            while vm.poll() is None and viewer.poll() is None:
                time.sleep(.5)
                # Once Android is up, match the display density to the resolution (persists).
                if not configured and time.monotonic() - start > 20 and serial.exists() and re.search(rb'(?m)^VM_BOOT_COMPLETED', serial.read_bytes()):
                    configured = True
                    try:
                        time.sleep(8); vm_control.send(run_dir, f'VM_DENSITY {density}')
                        # macOS already accelerates the mouse; stop Android doing it a second time.
                        # Later, once the density verb is handled, without holding up this loop.
                        threading.Timer(12, lambda: vm_control.send(run_dir, 'VM_POINTER_ACCEL_OFF')).start()
                    except OSError: pass
    except KeyboardInterrupt:
        print('\nStopping.', flush=True)
    finally:
        for child in reversed(children):
            if child.poll() is None: os.killpg(child.pid, signal.SIGTERM)
        for child in reversed(children):
            try: child.wait(timeout=45)
            except subprocess.TimeoutExpired: os.killpg(child.pid, signal.SIGKILL); child.wait()


if __name__ == '__main__':
    main()
