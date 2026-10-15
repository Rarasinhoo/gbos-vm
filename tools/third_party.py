#!/usr/bin/env python3
"""Third-party notices for the downloadable app, and the sources that go with its release.

  third_party.py RECORD NOTICES.md [--sources DIR]

RECORD lists where each bundled library came from (bundle_dylibs.py --record). Homebrew's files
are named after their formula and version, so each one is looked up there for its licence and
source. NOTICES.md lists them with the components we build from pinned sources. --sources puts
the source archive of every Homebrew formula in DIR (brew fetch), for the release beside the app:
the GPL and LGPL ones need it there.
"""
import json, re, shutil, subprocess, sys
from pathlib import Path

BUILT = [  # built by this project's scripts from pinned sources (see lib.sh and build-gfxstream.sh)
    ('QEMU 10.0.12 (UTM\'s fork), with patches/qemu-gfxstream.patch', 'GPL-2.0-only', 'in the release sources, and https://github.com/utmapp/qemu'),
    ('gfxstream (macOS fork, google/gfxstream#168), with patches/gfxstream-host.patch', 'Apache-2.0', 'https://github.com/google/gfxstream'),
    ('rutabaga_gfx', 'BSD-3-Clause', 'https://github.com/magma-gpu/rutabaga_gfx'),
    ('Mesa (the guest\'s gfxstream Vulkan driver), with patches/mesa-gfxstream-guest.patch', 'MIT', 'https://android.googlesource.com/platform/external/mesa3d'),
    ('libdrm (in the guest)', 'MIT', 'https://gitlab.freedesktop.org/mesa/drm'),
    ('CocoaSpice (in the app), with patches/cocoaspice-viewer.patch', 'Apache-2.0', 'https://github.com/utmapp/CocoaSpice'),
    ('libsepol 3.11 (in the SELinux policy tool)', 'LGPL-2.1-or-later', 'in the release sources, and https://github.com/SELinuxProject/selinux'),
    ('Python 3.13 (python-build-standalone)', 'PSF-2.0', 'https://github.com/astral-sh/python-build-standalone'),
]


def formula(path):
    m = re.search(r'/Cellar/([^/]+)/([^/]+)(/|$)', path)
    return (m.group(1), m.group(2)) if m else None


def main():
    record, notices = Path(sys.argv[1]), Path(sys.argv[2])
    sources = Path(sys.argv[sys.argv.index('--sources') + 1]) if '--sources' in sys.argv else None
    found = {}
    for line in record.read_text().split():
        f = formula(str(Path(line).resolve()))
        if f: found[f[0]] = f[1]
    rows = []
    for name in sorted(found):
        info = json.loads(subprocess.run(['brew', 'info', '--json=v2', name], check=True, capture_output=True, text=True).stdout)['formulae'][0]
        stable = info['versions']['stable']; have = found[name].split('_')[0]
        if sources and have != stable:
            sys.exit(f'{name} {have} is installed but Homebrew\'s source is {stable}: run  brew upgrade {name}  and package again')
        rows.append((f'{name} {have}', info.get('license') or 'see source', info['urls']['stable']['url']))
        if sources:
            sources.mkdir(parents=True, exist_ok=True)
            subprocess.run(['brew', 'fetch', '--quiet', '--build-from-source', '--formula', name], check=True, capture_output=True)
            cached = Path(subprocess.run(['brew', '--cache', '--build-from-source', '--formula', name], check=True, capture_output=True, text=True).stdout.strip())
            shutil.copy(cached, sources / re.sub(r'^[0-9a-f]{64}--', '', cached.name))
    with notices.open('w') as out:
        out.write('# Third-party software in Googlebook VM\n\nGooglebook VM is MIT licensed (see LICENSE). It contains these components, each under '
                  'its own licence. The source of each GPL and LGPL component is published with every release, as '
                  '`Googlebook-VM-sources.tar`, and at the address listed.\n\nNot included, and downloaded on your Mac at setup from their '
                  'publishers: the Googlebook recovery image (Google), the Cuttlefish virtual-device image (Google), and UTM (its '
                  'graphics libraries: MoltenVK, ANGLE, SPICE).\n\n| Component | Licence | Source |\n|---|---|---|\n')
        for r in [*BUILT, *rows]: out.write('| ' + ' | '.join(x.replace('|', '/') for x in r) + ' |\n')
    print(f'{len(rows) + len(BUILT)} components in {notices}')


if __name__ == '__main__':
    main()
