#!/usr/bin/env python3
"""First-run setup and updates for the downloadable app (package-app.sh builds it).

  setup.py WORK          set up or update everything in WORK (the app runs this)
  setup.py WORK --check  exit 0 if WORK is ready for this app, 1 if setup has work to do

The app carries the VM engine prebuilt (Resources/runtime: QEMU, gfxstream, the guest pieces, the
image tools and this Python). What may not be redistributed is downloaded here, on the user's
Mac, from its source, and checked against pinned SHA-256s: Google's Googlebook recovery image,
Google's Cuttlefish virtual-device image, and UTM (its graphics libraries). Then Android's vendor
partition is rebuilt for the VM, as build-image.sh does. On an app update only what changed is
redone; the user's data is never touched (a changed system part is synced in, as update-image.sh
does).

Progress goes to stdout as lines the app shows:
  @step N TOTAL Title      @progress FRACTION Detail      @done      @error Message
"""
import hashlib, json, os, re, shutil, subprocess, sys, tempfile, threading, time, urllib.parse, zipfile
from pathlib import Path

RES = Path(__file__).resolve().parent
RT = RES / 'runtime'
MANIFEST = json.loads((RT / 'manifest.json').read_text()) if (RT / 'manifest.json').exists() else {}
PINS = MANIFEST.get('pins', {})


def say(*a): print(*a, flush=True)
def step(n, total, title): say(f'@step {n} {total} {title}')
def progress(f, detail=''): say(f'@progress {max(0.0, min(1.0, f)):.4f} {detail}')
class Failure(Exception): pass


def gb(n): return f'{n / 1e9:.1f} GB'


def sha256(path, label):
    h = hashlib.sha256(); size = path.stat().st_size; done = 0; last = 0
    with path.open('rb') as f:
        while b := f.read(8 << 20):
            h.update(b); done += len(b)
            if time.time() - last > 0.5: progress(done / size, f'Checking {label}…'); last = time.time()
    return h.hexdigest()


def download(url, dest, sha, label):
    """Resumable download with curl (macOS's own, which uses the system's certificates), then
    verification. A file that is already there and matches is kept."""
    if dest.exists() and sha256(dest, label) == sha: return
    dest.unlink(missing_ok=True)
    part = dest.with_name(dest.name + '.part'); dest.parent.mkdir(parents=True, exist_ok=True)
    total = 0
    head = subprocess.run(['/usr/bin/curl', '-sfIL', '--proto', '=https', '--proto-redir', '=https', url], capture_output=True, text=True)
    # The final response's size (Google's servers also send it as x-identity-content-length)
    for m in re.finditer(r'(?im)^(?:x-identity-)?content-length:\s*(\d+)', head.stdout): total = max(total, int(m.group(1)))
    for attempt in range(6):
        p = subprocess.Popen(['/usr/bin/curl', '-sfL', '--proto', '=https', '--proto-redir', '=https', '--retry', '5', '-C', '-', '-o', str(part), url],
                             stderr=subprocess.PIPE, text=True)
        t0, s0 = time.time(), (part.stat().st_size if part.exists() else 0)
        while p.poll() is None:
            time.sleep(0.5)
            have = part.stat().st_size if part.exists() else 0
            rate = (have - s0) / max(time.time() - t0, 0.1)
            left = f', about {int((total - have) / rate / 60) + 1} min left' if total and rate > 1e5 else ''
            progress(have / total if total else 0, f'{label}: {gb(have)}{" of " + gb(total) if total else ""}{left}')
        if p.returncode == 0: break
        err = p.stderr.read().strip()
        if p.returncode == 33 or 'range' in err.lower(): part.unlink(missing_ok=True)   # server won't resume: start over
        if attempt == 5: raise Failure(f"Couldn't download {label}. Check your internet connection and try again. ({err or 'curl ' + str(p.returncode)})")
        time.sleep(3)
    if sha256(part, label) != sha:
        part.unlink(missing_ok=True); raise Failure(f'{label} did not download correctly (its checksum is wrong). Try again.')
    part.rename(dest)


def run(cmd, log, cwd=None, env=None, what='a setup step'):
    with open(log, 'ab') as f:
        f.write(f'\n$ {" ".join(map(str, cmd))}\n'.encode()); f.flush()
        r = subprocess.run([str(c) for c in cmd], cwd=cwd, env=env, stdout=f, stderr=subprocess.STDOUT)
    if r.returncode:
        tail = Path(log).read_text(errors='replace').strip().splitlines()[-8:]
        raise Failure(f'{what} failed. Details are in {log}:\n' + '\n'.join(tail))


def tick(base, span, seconds, detail, stop):
    """Slow progress for steps that can't report their own (unpacking, building): from base
    towards base + span over about that many seconds."""
    t0 = time.time()
    while not stop.is_set():
        progress(base + span * min(0.95, (time.time() - t0) / seconds), detail); stop.wait(1)


def tools_env():
    env = dict(os.environ, PATH=f'{RT / "tools"}:/usr/bin:/bin:/usr/sbin:/sbin')
    env.pop('PYTHONHOME', None); return env


def install_runtime(work):
    """The engine goes where the runner and the image build expect it, as a dev build lays it out."""
    stamp = work / 'host/runtime-version'
    if stamp.exists() and stamp.read_text().strip() == MANIFEST['version']: return False
    for sub in ('host', 'build', 'guest', 'tools'):
        src = RT / sub
        if not src.exists(): continue
        dst = work / sub; dst.mkdir(parents=True, exist_ok=True)
        for p in src.iterdir():
            t = dst / p.name
            if t.is_dir() and not t.is_symlink(): shutil.rmtree(t)
            elif t.exists() or t.is_symlink(): t.unlink()
            subprocess.run(['/bin/cp', '-cR', str(p), str(t)], check=True)
    # The app was opened once the user allowed it; its engine, copied out of it, runs from here
    # (macOS would otherwise stop each tool with its downloaded-from-the-internet warning)
    subprocess.run(['/usr/bin/xattr', '-dr', 'com.apple.quarantine', *(str(work / d) for d in ('host', 'build', 'guest', 'tools') if (work / d).exists())],
                   capture_output=True)
    # Old refresh-rate copies of QEMU belong to the previous engine
    for old in (work / 'host').glob('qemu-gfx-aarch64-softmmu*'): old.unlink()
    stamp.write_text(MANIFEST['version'] + '\n'); return True


def vulkan_manifest(work):
    """gfxstream finds the Vulkan loader and MoltenVK beside the launcher (build-gfxstream.sh)."""
    fw = work / 'UTM-beta/UTM.app/Contents/Frameworks'; d = work / 'host/lib64/vulkan'; d.mkdir(parents=True, exist_ok=True)
    link = d / 'libvulkan.dylib'
    if link.is_symlink() or link.exists(): link.unlink()
    link.symlink_to(fw / 'vulkan.1.framework/Versions/A/vulkan.1')
    (d / 'MoltenVK_icd.json').write_text(json.dumps({'file_format_version': '1.0.0', 'ICD': {
        'library_path': str(fw / 'MoltenVK.framework/Versions/Current/MoltenVK'), 'api_version': '1.4.0', 'is_portability_driver': True}}, indent=4) + '\n')


def utm(work, downloads, log):
    app = work / 'UTM-beta/UTM.app'
    if (app / 'Contents/Frameworks').exists(): return
    dmg = downloads / 'UTM-5.0.6.dmg'
    download(PINS['UTM_DMG_URL'], dmg, PINS['UTM_DMG_SHA256'], 'UTM graphics libraries')
    progress(0.99, 'Copying the graphics libraries…')
    mnt = Path(tempfile.mkdtemp())
    run(['/usr/bin/hdiutil', 'attach', '-quiet', '-nobrowse', '-readonly', '-mountpoint', mnt, dmg], log, what='Opening the UTM download')
    try:
        app.parent.mkdir(parents=True, exist_ok=True); tmp = app.with_name('UTM.app.tmp'); shutil.rmtree(tmp, ignore_errors=True)
        subprocess.run(['/bin/cp', '-R', str(mnt / 'UTM.app'), str(tmp)], check=True); tmp.rename(app)
    finally:
        subprocess.run(['/usr/bin/hdiutil', 'detach', '-quiet', str(mnt)]); shutil.rmtree(mnt, ignore_errors=True)
    dmg.unlink(missing_ok=True)


def cuttlefish(work, downloads, log):
    unpacker = RT / 'scripts/unpack_cuttlefish.py'
    uid = hashlib.sha256(unpacker.read_bytes()).hexdigest()
    if (work / 'cuttlefish/.unpacker').exists() and (work / 'cuttlefish/.unpacker').read_text().strip() == uid: return False
    zipf = downloads / PINS['CUTTLEFISH_ZIP']
    if not zipf.exists() or sha256(zipf, 'Android parts') != PINS['CUTTLEFISH_SHA256']:
        # The public CI page hands out a short-lived storage URL for the artifact
        page = f"https://ci.android.com/builds/submitted/{PINS['CUTTLEFISH_BUILD']}/aosp_cf_arm64_only_phone-userdebug/latest/{PINS['CUTTLEFISH_ZIP']}"
        html = subprocess.run(['/usr/bin/curl', '-sfL', '--proto', '=https', page], capture_output=True, text=True).stdout
        m = re.search(r'var JSVariables = (\{.*?\});', html)
        if not m: raise Failure("Couldn't reach Android's build server (ci.android.com). Check your internet connection and try again.")
        url = json.loads(m.group(1))['artifactUrl']; host = (urllib.parse.urlsplit(url).hostname or '').lower()
        if not url.startswith('https://') or not any(host == d or host.endswith('.' + d) for d in ('googleapis.com', 'googleusercontent.com', 'google.com', 'android.com')):
            raise Failure('Android\'s build server sent an unexpected download address.')
        download(url, zipf, PINS['CUTTLEFISH_SHA256'], 'Android virtual-device parts')
    stop = threading.Event(); threading.Thread(target=tick, args=(0, 1, 120, 'Unpacking the Android parts…', stop), daemon=True).start()
    try:
        shutil.rmtree(work / 'cuttlefish', ignore_errors=True)
        run([sys.executable, unpacker, zipf, work / 'cuttlefish'], log, env=tools_env(), what='Unpacking the Android parts')
        (work / 'cuttlefish/.unpacker').write_text(uid + '\n')
    finally: stop.set()
    zipf.unlink(missing_ok=True); return True


def googlebook(work, downloads, log):
    raw = work / 'googlebook/mica-recovery.raw'
    if raw.exists(): return
    zipf = downloads / 'mica-recovery.zip'
    download(PINS['GOOGLEBOOK_URL'], zipf, PINS['GOOGLEBOOK_ZIP_SHA256'], 'Googlebook OS from Google')
    raw.parent.mkdir(parents=True, exist_ok=True); part = raw.with_name(raw.name + '.part'); h = hashlib.sha256(); last = 0
    with zipfile.ZipFile(zipf) as z, z.open('android-desktop_signed_recovery_image.bin') as f, part.open('wb') as out:
        size = z.getinfo('android-desktop_signed_recovery_image.bin').file_size; done = 0
        while b := f.read(8 << 20):
            out.write(b); h.update(b); done += len(b)
            if time.time() - last > 0.5: progress(done / size, f'Unpacking Googlebook OS: {gb(done)} of {gb(size)}'); last = time.time()
    if h.hexdigest() != PINS['GOOGLEBOOK_RAW_SHA256']: part.unlink(); raise Failure('The Googlebook image did not unpack correctly. Try again.')
    part.rename(raw); zipf.unlink(missing_ok=True)


def build_image(work, image_dir, log):
    """build-image.sh, with the app's own tools."""
    ws = work / 'ws'; shutil.rmtree(ws, ignore_errors=True)
    for d in ('scripts', 'artifacts/mica', 'artifacts/graphics-port-review', 'artifacts/cuttlefish-arm17',
              'experiments/erofs-utils/1.9.4', 'experiments/ext4-tools/e2fsprogs/1.47.4'):
        (ws / d).mkdir(parents=True)
    for p in (RT / 'scripts/image').iterdir(): shutil.copy(p, ws / 'scripts')
    cf = work / 'cuttlefish'
    links = {'artifacts/mica-recovery.raw': work / 'googlebook/mica-recovery.raw', 'artifacts/security-port-review': cf / 'security',
             'artifacts/graphics-port-review/extracted': cf / 'graphics/extracted', 'artifacts/graphics-port-review/cf-composer': cf / 'graphics/cf-composer',
             'artifacts/cuttlefish-arm17/modules': cf / 'modules', 'artifacts/cuttlefish-audio-config': cf / 'audio-config',
             'artifacts/cuttlefish-bluetooth': cf / 'bluetooth', 'artifacts/cuttlefish-wifi': cf / 'wifi', 'artifacts/cuttlefish-camera': cf / 'camera',
             'experiments/erofs-utils/1.9.4/bin': RT / 'tools', 'experiments/ext4-tools/e2fsprogs/1.47.4/sbin': RT / 'tools'}
    for k, v in links.items(): (ws / k).symlink_to(v)
    env = dict(tools_env(), GOOGLEBOOK_GUEST_DIR=str(work / 'guest'), GOOGLEBOOK_TOOLS_DIR=str(work / 'tools'))
    py = sys.executable; s = ws / 'scripts'
    parts = [([py, s / 'extract_mica_normal.py'], 'Reading the Googlebook image'), ([py, s / 'make_mica_gpu_initrd.py'], 'Preparing the startup files'),
             ([py, s / 'make_mica_security_port.py', 'base'], 'Adapting Android to the VM'), ([py, s / 'expand_mica_userdata.py', 'artifacts/mica/base/googlebook.raw'], 'Making room for your data')]
    for i, (cmd, what) in enumerate(parts):
        stop = threading.Event()
        threading.Thread(target=tick, args=(i / len(parts), 1 / len(parts), 90, what + '…', stop), daemon=True).start()
        try: run(cmd, log, cwd=ws, env=env, what=what)
        finally: stop.set()
    image_dir.mkdir(parents=True, exist_ok=True); os.chmod(image_dir, 0o700)
    for n in ('googlebook.raw', 'initrd.img'): (ws / 'artifacts/mica/base' / n).rename(image_dir / n)
    os.chmod(image_dir / 'googlebook.raw', 0o600)
    shutil.copy(ws / 'artifacts/mica/normal/kernel.Image', image_dir / 'kernel.Image')
    for j in (ws / 'artifacts/mica/base').glob('*.json'): shutil.copy(j, image_dir)
    shutil.rmtree(ws, ignore_errors=True)


def system_current(work):
    return (work / 'image/system-inputs.sha256').exists() and (work / 'image/system-inputs.sha256').read_text().strip() == MANIFEST['system']


def ready(work):
    return ((work / 'host/runtime-version').exists() and (work / 'host/runtime-version').read_text().strip() == MANIFEST['version']
            and (work / 'image/googlebook.raw').exists() and system_current(work) and (work / 'UTM-beta/UTM.app/Contents/Frameworks').exists())


def main():
    work = Path(sys.argv[1]).expanduser().resolve()
    if '--check' in sys.argv: sys.exit(0 if ready(work) else 1)
    work.mkdir(parents=True, exist_ok=True); (work / 'logs').mkdir(exist_ok=True)
    log = work / 'logs/setup.log'
    downloads = Path(os.environ.get('GOOGLEBOOK_DOWNLOADS') or work / 'downloads')
    fresh = not (work / 'image/googlebook.raw').exists()
    try:
        if os.uname().machine != 'arm64': raise Failure('Googlebook VM needs a Mac with Apple silicon (M1 or newer).')
        need = (45 if fresh else 25) * 10**9
        free = shutil.disk_usage(work).free
        if free < need: raise Failure(f'Googlebook VM needs about {need // 10**9} GB of free disk space to set up, and this Mac has {gb(free)} free. Free up some space and try again.')
        steps = ['Installing the VM engine', 'Getting the graphics libraries', 'Getting Android\'s virtual-device parts',
                 'Downloading Googlebook OS from Google', 'Building Android for your Mac' if fresh else 'Updating Android']
        n = len(steps)
        step(1, n, steps[0]); install_runtime(work); progress(1)
        step(2, n, steps[1]); utm(work, downloads, log); vulkan_manifest(work); progress(1)
        step(3, n, steps[2]); changed = cuttlefish(work, downloads, log); progress(1)
        step(4, n, steps[3]); googlebook(work, downloads, log); progress(1)
        step(5, n, steps[4])
        if fresh:
            build_image(work, work / 'image', log)
        elif not system_current(work) or changed:
            # update-image.sh: a fresh image beside the old one, then only the system area is copied over
            new = Path(tempfile.mkdtemp(dir=work, prefix='image-new.'))
            try:
                build_image(work, new, log)
                backup = work / 'image/googlebook.raw.before-update'; backup.unlink(missing_ok=True)
                subprocess.run(['/bin/cp', '-c', str(work / 'image/googlebook.raw'), str(backup)], check=True)
                progress(0.97, 'Updating the system part of your disk (your data stays)…')
                r = subprocess.run([sys.executable, RT / 'scripts/image/sync_super.py', work / 'image/googlebook.raw', new / 'googlebook.raw'], capture_output=True, text=True)
                if r.returncode: backup.rename(work / 'image/googlebook.raw'); raise Failure('Updating Android failed; your disk is unchanged. ' + r.stdout + r.stderr)
                for n_ in ('initrd.img', 'kernel.Image'): (new / n_).replace(work / 'image' / n_)
                for j in (work / 'image').glob('*.json'): j.unlink()
                for j in new.glob('*.json'): shutil.copy(j, work / 'image')
            finally: shutil.rmtree(new, ignore_errors=True)
        (work / 'image/system-inputs.sha256').write_text(MANIFEST['system'] + '\n')
        progress(1); say('@done')
    except Failure as e:
        say('@error ' + str(e).replace('\n', ' ⏎ ')); sys.exit(1)
    except Exception as e:
        with open(log, 'a') as f: f.write(f'\n{type(e).__name__}: {e}\n')
        say(f'@error Setup stopped unexpectedly ({type(e).__name__}: {e}). Details are in {log}.'); sys.exit(1)


if __name__ == '__main__':
    main()
