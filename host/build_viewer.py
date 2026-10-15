#!/usr/bin/env python3
"""Build the app.  build_viewer.py COCOASPICE_SRC UTM_FRAMEWORKS VIEWER_M OUT_DIR RUN_SCRIPTS_DIR WORK
Links the SPICE client libraries that ship inside the UTM app (nothing is copied out of it).
The app can start the VM itself: the runner scripts are bundled and WORK is recorded in Info.plist."""
import os, plistlib, shutil, subprocess, sys
from pathlib import Path

src, frameworks, viewer_m, out, run_scripts, work = [Path(p).resolve() for p in sys.argv[1:7]]
S = src / 'Sources'
app = out / 'Googlebook VM.app/Contents'
build = out / 'viewer-build'
for p in (app / 'MacOS', app / 'Resources', build / 'modules', build / 'module-cache'):
    p.mkdir(parents=True, exist_ok=True)
(build / 'modules/module.modulemap').write_text(
    'module CocoaSpiceRenderer { umbrella "' + str(S / 'CocoaSpiceRenderer/include') + '" export * }\n')
shader = (S / 'CocoaSpiceRenderer/CSShaders.metal').read_text().replace(
    '#import "include/CSShaderTypes.h"', (S / 'CocoaSpiceRenderer/include/CSShaderTypes.h').read_text())
(app / 'Resources/VMShaders.metal').write_text(shader)
for name in ('run_vm.py', 'vm_control.py', 'lan-setup.sh', 'storage.py'):
    shutil.copyfile(run_scripts / name, app / 'Resources' / name)
(app / 'Info.plist').write_bytes(plistlib.dumps({
    'CFBundleIdentifier': 'local.googlebook.viewer', 'CFBundleName': 'Googlebook VM', 'GBOSWork': str(work),
    'CFBundleExecutable': 'GooglebookViewer', 'CFBundlePackageType': 'APPL', 'NSHighResolutionCapable': True,
    'NSCameraUsageDescription': 'Android in the VM uses this Mac’s camera as a USB webcam. '
                                'It only runs while an Android app is using the camera.',
    'NSMicrophoneUsageDescription': 'Android in the VM uses this Mac’s microphone as a USB microphone. '
                                    'It only runs while an Android app is recording.',
    'NSBluetoothAlwaysUsageDescription': 'Android in the VM sees the Bluetooth LE devices near this Mac, '
                                         'and its apps connect to them through it.'}))
skip = {'CSUSBDevice.m', 'CSUSBManager.m', 'CSSession+Sharing.m', 'gst_ios_init.m'}
sources = [str(p) for p in sorted((S / 'CocoaSpice').glob('*.m')) if p.name not in skip]
sources += [str(S / 'CocoaSpiceRenderer/CSMetalRenderer.m'), str(viewer_m), str(viewer_m.parent / 'webcam.m'),
            str(viewer_m.parent / 'microphone.m'), str(viewer_m.parent / 'bluetooth.m')]
cmd = ['clang', '-fobjc-arc', '-fblocks', '-fmodules', f'-fmodules-cache-path={build}/module-cache', '-O2',
       '-Wno-incomplete-implementation', '-w']
headers = S / 'CocoaSpice/ExternalHeaders'
for p in [build / 'modules', S / 'CocoaSpice/include', S / 'CocoaSpice', S / 'CocoaSpiceRenderer/include',
          S / 'CocoaSpiceRenderer', headers, *[headers / n for n in ('glib-2.0', 'gstreamer-1.0', 'spice-1', 'spice-client-glib-2.0')]]:
    cmd += ['-I', str(p)]
cmd += sources
for n in ('AppKit', 'Metal', 'MetalKit', 'CoreGraphics', 'CoreImage', 'IOSurface', 'CoreVideo', 'IOKit',
          'AVFoundation', 'CoreMedia', 'ImageIO', 'CoreBluetooth', 'ApplicationServices'):
    cmd += ['-framework', n]
for n in ('spice-client-glib-2.0.8', 'glib-2.0.0', 'gobject-2.0.0', 'gio-2.0.0', 'gstreamer-1.0.0'):
    cmd.append(str(frameworks / (n + '.framework') / n))
# Second rpath: relative to the app, so the whole work folder can be moved or copied elsewhere.
cmd += ['-Wl,-rpath,' + str(frameworks), '-Wl,-rpath,@executable_path/../../../../UTM-beta/UTM.app/Contents/Frameworks',
        '-o', str(app / 'MacOS/GooglebookViewer')]
subprocess.run(cmd, check=True)
# App icon: host/AppIcon.png (1024 px, drawn from host/AppIcon.svg) as Resources/AppIcon.icns.
iconset = build / 'AppIcon.iconset'
shutil.rmtree(iconset, ignore_errors=True); iconset.mkdir()
for size in (16, 32, 128, 256, 512):
    for scale, suffix in ((1, ''), (2, '@2x')):
        subprocess.run(['sips', '-z', str(size * scale), str(size * scale), str(viewer_m.parent / 'AppIcon.png'),
                        '--out', str(iconset / f'icon_{size}x{size}{suffix}.png')], check=True, capture_output=True)
subprocess.run(['iconutil', '-c', 'icns', str(iconset), '-o', str(app / 'Resources/AppIcon.icns')], check=True)
info = plistlib.loads((app / 'Info.plist').read_bytes())
(app / 'Info.plist').write_bytes(plistlib.dumps({**info, 'CFBundleIconFile': 'AppIcon'}))
# build-host.sh's local certificate when there is one (a stable identity for macOS's permissions)
sign = ['--keychain', os.environ['GBOS_SIGN_KEYCHAIN'], '--sign', os.environ['GBOS_SIGN_ID']] if os.environ.get('GBOS_SIGN_ID') else ['--sign', '-']
subprocess.run(['codesign', '--force', *sign, str(app.parent)], check=True, capture_output=True)
print(app.parent)
