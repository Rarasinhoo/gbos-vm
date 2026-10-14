#!/usr/bin/env python3
"""Display smoothness benchmark: boot a --perf-test image with the viewer attached, let the guest
scroll Settings (see image/guest_perf_test.sh), and report what each side saw.

  perf.py WORK NAME --image DIR [--display WxH] [--refresh HZ] [--cpus N]

Guest side: Android's own frame statistics per scroll round (frames, janky frames, frame-time
percentiles, missed vsyncs). Host side: the frames the viewer received while the guest was
scrolling (its NATIVE_GL_SCANOUT counter), and how evenly they reached the screen (NATIVE_PRESENT:
the share of frames that stayed up noticeably longer or shorter than the rest). Runs on a snapshot, so the image is never written.

Build the test image beside your own (it never touches WORK/image):
  GBOS_IMAGE_DIR=work/image-perf GBOS_IMAGE_FLAGS=--perf-test ./build-image.sh
  python3 tests/perf.py work perf-60 --image work/image-perf --refresh 60
Set VM_NO_PACING=1 to compare against the viewer without frame pacing.
"""
import json, os, re, signal, statistics, subprocess, sys, time
from pathlib import Path

HERE = Path(__file__).resolve().parents[1]


def new_lines(path, offset):
    """Lines appended to path since offset, and the new offset."""
    try:
        with path.open('rb') as f:
            f.seek(offset); data = f.read()
    except FileNotFoundError:
        return [], offset
    end = data.rfind(b'\n') + 1
    return data[:end].decode(errors='replace').splitlines(), offset + end


def main():
    work = Path(sys.argv[1]).resolve(); name = sys.argv[2]
    image = sys.argv[sys.argv.index('--image') + 1]
    display = sys.argv[sys.argv.index('--display') + 1] if '--display' in sys.argv else '1920x1200'
    refresh = ['--refresh', sys.argv[sys.argv.index('--refresh') + 1]] if '--refresh' in sys.argv else []
    refresh += ['--cpus', sys.argv[sys.argv.index('--cpus') + 1]] if '--cpus' in sys.argv else []
    run = work / 'logs' / name
    vm = subprocess.Popen([sys.executable, str(HERE / 'run/run_vm.py'), str(work), name, '--seconds', '900', '--image', image,
                           '--snapshot', '--no-audio', '--display', display] + refresh,
                          stdout=subprocess.DEVNULL, start_new_session=True)
    deadline = time.monotonic() + 30
    while not (run / 'spice.sock').exists():
        if vm.poll() is not None or time.monotonic() > deadline: sys.exit('VM did not start')
        time.sleep(.2)
    env = dict(os.environ, VM_MOUSE_SEAMLESS='0', VM_MOUSE_RELATIVE='0', VM_SELFTEST_GLIDE='1', VM_SELFTEST_TOUCH='1', VM_INPUT_TOKEN=(run / 'token').read_text())
    viewer = subprocess.Popen([str(work / 'host/Googlebook VM.app/Contents/MacOS/GooglebookViewer'), str(run / 'spice.sock')],
                              env=env, stdout=(run / 'viewer.log').open('w'), stderr=subprocess.STDOUT, start_new_session=True)
    # Timestamp both logs on arrival, so viewer samples can be matched to the guest's scroll rounds.
    events = []; offsets = {'serial': 0, 'viewer': 0}; start = time.monotonic(); glided = touched = wheeled = False
    try:
        while vm.poll() is None and time.monotonic() - start < 600:
            time.sleep(.5); now = time.monotonic() - start
            for src, path in (('serial', run / 'serial.log'), ('viewer', run / 'viewer.log')):
                lines, offsets[src] = new_lines(path, offsets[src])
                events += [(now, src, l) for l in lines if 'VM_PERF' in l or 'NATIVE_GL_SCANOUT' in l or 'NATIVE_PRESENT' in l]
            # The guest is timing its mouse: glide it (the viewer's SIGUSR2 hook)
            if not glided and any('VM_PERF mouse_ready' in l for _, _, l in events):
                glided = True; time.sleep(1); os.kill(viewer.pid, signal.SIGUSR2)
            # ...and then its touchpad (the hook's second run)
            if glided and not touched and any('VM_PERF touch_ready' in l for _, _, l in events):
                touched = True; time.sleep(1); os.kill(viewer.pid, signal.SIGUSR2)
            # ...and then its high-resolution wheel (the third run)
            if touched and not wheeled and any('VM_PERF wheel_ready' in l for _, _, l in events):
                wheeled = True; time.sleep(1); os.kill(viewer.pid, signal.SIGUSR2)
            if any('VM_PERF_END' in l for _, _, l in events): break
    finally:
        if vm.poll() is None: os.killpg(vm.pid, signal.SIGTERM)
        try: vm.wait(timeout=60)
        except subprocess.TimeoutExpired: os.killpg(vm.pid, signal.SIGKILL)
        if viewer.poll() is None: os.killpg(viewer.pid, signal.SIGTERM)

    report = {'run': name, 'display': display, 'refresh': refresh[1:], 'finished': any('VM_PERF_END' in l for _, _, l in events),
              'guest_display': [l.split('VM_PERF ', 1)[1] for _, s, l in events if s == 'serial' and re.search(r'VM_PERF (display|sf) ', l)],
              'mouse': [l.split('VM_PERF mouse ', 1)[1] for _, s, l in events if s == 'serial' and 'VM_PERF mouse ' in l],
              'touch': [l.split('VM_PERF ', 1)[1] for _, s, l in events if s == 'serial' and re.search(r'VM_PERF touch', l)],
              'zram': [l.split('VM_PERF zram ', 1)[1] for _, s, l in events if s == 'serial' and 'VM_PERF zram ' in l],
              'wheel': [l.split('VM_PERF wheel ', 1)[1] for _, s, l in events if s == 'serial' and 'VM_PERF wheel ' in l],
              'battery': [l.split('VM_PERF battery ', 1)[1] for _, s, l in events if s == 'serial' and 'VM_PERF battery ' in l],
              'rounds': []}
    (run / 'perf-events.json').write_text(json.dumps(events))
    windows = {}
    for t, s, l in events:
        m = re.search(r'VM_PERF scroll_(start|end) round=(\d+)', l)
        if m: windows.setdefault(int(m.group(2)), {})[m.group(1)] = t
    for rnd, w in sorted(windows.items()):
        stats = {}
        for _, s, l in events:
            m = re.search(rf'VM_PERF round={rnd} (.+?):\s*(.+)$', l)
            if m: stats[m.group(1).strip()] = m.group(2).strip()
        # A viewer sample covers the 5 s before it was printed; keep those wholly inside the round.
        fps = [float(re.search(r'NATIVE_GL_SCANOUT ([0-9.]+)', l).group(1)) for t, s, l in events
               if s == 'viewer' and 'NATIVE_GL_SCANOUT' in l and 'start' in w and 'end' in w and w['start'] + 5 <= t <= w['end'] + 1]
        present = [re.search(r'NATIVE_PRESENT (\d+) frames median ([0-9.]+) ms uneven ([0-9.]+)% dropped ([0-9.]+)% held ([0-9.]+) ms screen (\d+)', l).groups() for t, s, l in events
                   if s == 'viewer' and 'NATIVE_PRESENT' in l and 'start' in w and 'end' in w and w['start'] + 5 <= t <= w['end'] + 1]
        report['rounds'].append({'round': rnd, 'seconds': round(w.get('end', 0) - w.get('start', 0), 1), 'guest': stats,
                                 'viewer_fps': {'samples': fps, 'median': statistics.median(fps) if fps else None},
                                 'on_screen': [{'frames': int(n), 'median_ms': float(m), 'uneven_pct': float(u), 'dropped_pct': float(dr), 'held_ms': float(hd),
                                                'screen_hz': int(h)} for n, m, u, dr, hd, h in present]})
    (run / 'perf.json').write_text(json.dumps(report, indent=1))
    print(json.dumps(report, indent=1))


if __name__ == '__main__':
    main()
