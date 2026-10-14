#!/usr/bin/env python3
"""Start the Googlebook desktop from a terminal: the same as opening the app, and it waits until
the app quits.  launch.py WORK [--display WxH] [--fullscreen]

--display and --fullscreen are saved as the app's Resolution and StartFullscreen settings, so
they also apply the next time you open the app."""
import subprocess, sys
from pathlib import Path


def main():
    if len(sys.argv) < 2: sys.exit(__doc__)
    app = Path(sys.argv[1]).resolve() / 'host/Googlebook VM.app'
    if not app.is_dir(): sys.exit(f'app not built: {app} (run ./install.sh)')
    defaults = ['/usr/bin/defaults', 'write', 'local.googlebook.viewer']
    if '--display' in sys.argv:
        subprocess.run(defaults + ['Resolution', sys.argv[sys.argv.index('--display') + 1]], check=True)
    if '--fullscreen' in sys.argv:
        subprocess.run(defaults + ['StartFullscreen', '-bool', 'YES'], check=True)
    sys.exit(subprocess.run(['/usr/bin/open', '-W', '-n', str(app)]).returncode)


if __name__ == '__main__':
    main()
