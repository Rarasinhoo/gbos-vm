#!/usr/bin/env python3
"""Make Mach-O files self-contained: copy every library they need from outside macOS (Homebrew's,
the build tree's) into one folder, and point them all at it.

  bundle_dylibs.py [--record LIST] LIB_DIR FILE...

Each FILE (an executable or a library already in its final place) and every library copied into
LIB_DIR then finds its libraries through @rpath, with an rpath relative to itself (@loader_path),
so the folder they are in can move. Frameworks named @rpath/X.framework (UTM's, found at run time
through DYLD_FRAMEWORK_PATH) and macOS's own libraries are left as they are. Rpaths that point
into this build machine are removed. Everything changed is ad-hoc signed again. --record appends
where each copied library came from to LIST (for the third-party notices).
"""
import os, re, shutil, subprocess, sys
from pathlib import Path

SYSTEM = ('/usr/lib/', '/System/')


def deps(f):
    out = subprocess.run(['otool', '-L', str(f)], check=True, capture_output=True, text=True).stdout.splitlines()[1:]
    return [l.strip().split(' (')[0] for l in out if l.strip()]


def rpaths(f):
    out = subprocess.run(['otool', '-l', str(f)], check=True, capture_output=True, text=True).stdout
    return re.findall(r'cmd LC_RPATH\n\s+cmdsize \d+\n\s+path (.+?) \(offset', out)


def install_id(f):
    out = subprocess.run(['otool', '-D', str(f)], check=True, capture_output=True, text=True).stdout.splitlines()
    return out[1].strip() if len(out) > 1 else None


def resolve(dep, f, search):
    # f is where the file came from, so its relative rpaths mean what they did at build time
    if dep.startswith('@rpath/'):
        for r in rpaths(f) + [str(Path(f).parent)] + search:
            r = r.replace('@loader_path', str(Path(f).parent)).replace('@executable_path', str(Path(f).parent))
            p = Path(r) / dep[7:]
            if p.exists(): return p.resolve()
        return None
    if dep.startswith('@'): return None
    return Path(dep).resolve() if Path(dep).exists() else None


def local(dep):
    return not dep.startswith(SYSTEM) and not re.match(r'@rpath/[^/]+\.framework/', dep)


def main():
    argv = sys.argv[1:]; record = None
    if argv[0] == '--record': record, argv = argv[1], argv[2:]
    lib = Path(argv[0]).resolve(); lib.mkdir(parents=True, exist_ok=True)
    todo = [Path(p).resolve() for p in argv[1:]]; done = set(); search = ['/opt/homebrew/lib']
    origin = {}   # copied library -> where it came from
    while todo:
        f = todo.pop()
        if f in done: continue
        done.add(f)
        args = []
        # @rpath means the rpaths of everything that loads it, so remember every absolute one seen
        search += [r for r in rpaths(origin.get(f, f)) if r.startswith('/') and r not in search]
        for dep in deps(f):
            if dep == install_id(f) or not local(dep): continue
            name = Path(dep).name
            if dep == f'@rpath/{name}' and (lib / name).exists():
                if (lib / name) not in done: todo.append(lib / name)
                continue
            src = resolve(dep, origin.get(f, f), search)
            if src is None: sys.exit(f'{f}: cannot find {dep}')
            dst = lib / name
            if not dst.exists():
                shutil.copyfile(src, dst); os.chmod(dst, 0o755); origin[dst] = src
                if record:
                    with open(record, 'a') as r: r.write(f'{src}\n')
                subprocess.run(['install_name_tool', '-id', f'@rpath/{name}', str(dst)], check=True, capture_output=True)
            todo.append(dst)
            args += ['-change', dep, f'@rpath/{name}']
        rel = '@loader_path' if f.parent == lib else '@loader_path/' + os.path.relpath(lib, f.parent)
        have = rpaths(f)
        for r in have:
            if r.startswith(('/Users/', '/opt/', '/private/', '/tmp/')):
                args += ['-delete_rpath', r]
        if rel not in have: args += ['-add_rpath', rel]
        if args: subprocess.run(['install_name_tool', *args, str(f)], check=True, capture_output=True)
        subprocess.run(['codesign', '--force', '--sign', '-', str(f)], check=True, capture_output=True)
    # Nothing may point back into this machine
    for f in done:
        bad = [d for d in deps(f) if d.startswith(('/opt/', '/Users/', '/usr/local/'))]
        if bad: sys.exit(f'{f} still needs {bad}')
    print(f'{len(done)} files, libraries in {lib}')


if __name__ == '__main__':
    main()
