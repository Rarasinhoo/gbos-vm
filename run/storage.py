#!/usr/bin/env python3
"""Give Android a fresh data partition of a new size: a factory reset with more (or less) room.

  storage.py WORK GIB        resize (erases Android's apps, accounts and files)
  storage.py WORK            print the current size in GiB

Android encrypts its data partition, so it can't be grown in place. This moves the end of the
userdata partition (always the last one on the disk) and empties it, and puts back the
metadata partition, which holds that encryption's keys, as it came in the recovery image;
Android formats both on the next boot, as after a factory reset. The disk file is sparse:
the Mac stores only what Android writes. The previous disk is kept as
googlebook.raw.before-update (a copy-on-write clone), until the next update replaces it.
"""
import fcntl, struct, subprocess, sys, zlib
from pathlib import Path

MIN_GIB, MAX_GIB = 16, 1024


def table(f):
    f.seek(512); h = bytearray(f.read(512)); assert h[:8] == b'EFI PART', 'no GPT'
    hs = struct.unpack_from('<I', h, 12)[0]
    lba, n, es = struct.unpack_from('<QII', h, 72); assert lba == 2 and es == 128
    f.seek(lba * 512); entries = bytearray(f.read(n * es))
    assert zlib.crc32(entries) == struct.unpack_from('<I', h, 88)[0], 'damaged partition table'
    parts = {}
    for i in range(n):
        e = entries[i * es:(i + 1) * es]
        if any(e[:16]): parts[e[56:128].decode('utf-16le').rstrip('\0')] = (i, *struct.unpack_from('<QQ', e, 32))
    return h, hs, n, es, entries, parts


def main():
    work = Path(sys.argv[1]).resolve(); image = work / 'image/googlebook.raw'
    with image.open('rb') as f: parts = table(f)[5]
    _, first, last = parts['userdata']
    if len(sys.argv) == 2: print((last - first + 1) * 512 >> 30); return
    gib = int(sys.argv[2]); assert MIN_GIB <= gib <= MAX_GIB, f'between {MIN_GIB} and {MAX_GIB} GiB'
    lock = (work / 'logs/vm.lock').open('a')
    try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError: sys.exit('the VM is running; quit it first')
    pristine = work / 'googlebook/mica-recovery.raw'
    with pristine.open('rb') as f: clean = table(f)[5]
    _, m0, m1 = parts['metadata']; assert clean['metadata'][1:] == (m0, m1), 'metadata moved'
    assert all(b < first for name, (_, a, b) in parts.items() if name != 'userdata'), 'userdata is not last'
    backup = image.with_name('googlebook.raw.before-update'); backup.unlink(missing_ok=True)
    subprocess.run(['cp', '-c', str(image), str(backup)], check=True)
    with image.open('r+b') as f, pristine.open('rb') as src:
        h, hs, n, es, entries, parts = table(f)
        i = parts['userdata'][0]; end = first + gib * (1 << 30) // 512 - 1
        backup_entries = end + 1; newlast = backup_entries + n * es // 512
        struct.pack_into('<QQ', entries, i * es + 32, first, end)
        def checksum(x): struct.pack_into('<I', x, 16, 0); struct.pack_into('<I', x, 16, zlib.crc32(x[:hs])); return x
        struct.pack_into('<Q', h, 32, newlast); struct.pack_into('<Q', h, 48, end)
        struct.pack_into('<I', h, 88, zlib.crc32(entries)); checksum(h)
        bh = bytearray(h); struct.pack_into('<QQ', bh, 24, newlast, 1); struct.pack_into('<Q', bh, 72, backup_entries); checksum(bh)
        # Empty userdata: cut the file where it starts, then grow it back as a hole
        f.truncate(first * 512); f.truncate((newlast + 1) * 512)
        src.seek(m0 * 512); f.seek(m0 * 512); f.write(src.read((m1 - m0 + 1) * 512))
        f.seek(512); f.write(h); f.seek(1024); f.write(entries)
        f.seek(backup_entries * 512); f.write(entries); f.write(bh)
        f.seek(446); mbr = bytearray(f.read(16)); assert mbr[4] == 0xee
        struct.pack_into('<I', mbr, 12, min(newlast, 0xffffffff)); f.seek(446); f.write(mbr)
        f.flush()
    with image.open('rb') as f: assert table(f)[5]['userdata'][1:] == (first, end)
    print(f'Android storage is now {gib} GiB, empty; the previous disk is {backup.name}')


if __name__ == '__main__':
    main()
