#!/usr/bin/env python3
"""End-to-end test of the automatic pointer's lock, without the viewer or a mouse.

  tests/pointer_capture/build.sh
  GBOS_IMAGE_DIR=work/image-pointer GBOS_IMAGE_FLAGS=--pointer-test ./build-image.sh
  python3 tests/pointer_capture.py work work/image-pointer

Boots the image (a snapshot) and stands in for the viewer on the pointer link: it proves the
token, keeps the link busy with hover moves, and when the guest reports that an app asked for
pointer capture it locks (Q 1) and sends relative motion and a click. The test app on the image
logs what it receives; this passes when it got relative mouse motion and the click, and the
guest reported the release when the app let go. The viewer's own pointer link port (27183)
must be free: quit the app first."""
import hashlib, hmac, os, secrets, select, signal, socket, subprocess, sys, threading, time
from pathlib import Path

HERE = Path(__file__).resolve().parents[1]


def mac(token, msg):
    return hmac.new(token.encode(), msg.encode(), hashlib.sha256).hexdigest()


def main():
    work, image = Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve()
    name = 'pointer-test-' + time.strftime('%H%M%S')
    run = work / 'logs' / name
    listener = socket.create_server(('127.0.0.1', 27183))
    vm = subprocess.Popen([sys.executable, '-I', str(HERE / 'run/run_vm.py'), str(work), name, '--seconds', '420',
                           '--image', str(image), '--snapshot', '--no-audio'], start_new_session=True)
    events = []
    try:
        while not (run / 'token').exists(): time.sleep(0.5)
        token = (run / 'token').read_text().strip()
        listener.settimeout(240)
        conn, _ = listener.accept()
        conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        f = conn.makefile('rwb', buffering=0)
        lock = threading.Lock()

        def send(line):
            with lock:
                conn.sendall((line + '\n').encode()); events.append('> ' + line)
        host_nonce = secrets.token_hex(16)
        send('N ' + host_nonce)
        hello = f.readline().decode().split()
        assert hello[0] == 'a' and hmac.compare_digest(hello[2], mac(token, f'gbos-guest:{host_nonce}:{hello[1]}')), hello
        send('A ' + mac(token, f'gbos-host:{hello[1]}:{host_nonce}'))
        print('link up', flush=True)
        stop = threading.Event()

        def hover():  # keeps the guest watching for pointer capture (it only does while in use)
            while not stop.wait(1): send('M 600 400')
        threading.Thread(target=hover, daemon=True).start()
        released = False
        deadline = time.time() + 300
        while time.time() < deadline and not released:
            if not select.select([conn], [], [], 5)[0]: continue
            line = f.readline().decode().strip()
            if not line: break
            events.append('< ' + line)
            if line == 'k 1':
                send('Q 1'); time.sleep(2)
                for _ in range(5): send('R 10.5 -4.25'); time.sleep(0.05)
                send('D 1'); time.sleep(0.1); send('U 1')
            elif line == 'k 0':
                send('Q 0'); released = True
        stop.set()
        time.sleep(3)
    finally:
        os.killpg(vm.pid, signal.SIGINT)
        vm.wait(120)
        listener.close()
    log = (run / 'serial.log').read_bytes().decode(errors='replace')
    app = [l for l in log.splitlines() if 'VM_POINTER_TEST' in l or 'VM_INPUT' in l]
    print('\n'.join(events[-12:] + app[-40:]))
    rel = [l for l in app if 'captured action=2' in l and 'source=0x20004' in l]  # ACTION_MOVE, SOURCE_MOUSE_RELATIVE
    click = any('captured action=11' in l for l in app)                              # ACTION_BUTTON_PRESS
    ok = bool(rel) and click and released
    print(f'\nrelative moves {len(rel)}, click {click}, release reported {released}: {"PASS" if ok else "FAIL"}')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
