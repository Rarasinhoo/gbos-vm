#!/usr/bin/env python3
"""Bring an existing disk image up to date with a freshly built one, keeping its user data.

  sync_super.py EXISTING.raw NEW.raw

Both must come from the same Googlebook recovery image. Only the `super` partition (system,
vendor and their partition table) is copied, and only the blocks that differ. User data and
the metadata partition holding its encryption keys are left alone.
"""
import struct, sys, zlib

BLOCK = 1 << 20


def gpt(path):
    with open(path, 'rb') as f:
        f.seek(512); h = f.read(512); assert h[:8] == b'EFI PART', path
        lba, count, size = struct.unpack_from('<QII', h, 72); f.seek(lba * 512); table = f.read(count * size)
    assert zlib.crc32(table) == struct.unpack_from('<I', h, 88)[0], path
    parts = {}
    for i in range(count):
        e = table[i * size:(i + 1) * size]
        if any(e[:16]):
            first, last = struct.unpack_from('<QQ', e, 32)
            parts[e[56:128].decode('utf-16le').rstrip('\0')] = (first * 512, (last + 1) * 512)
    return parts


def main():
    old, new = sys.argv[1:3]
    a, b = gpt(old), gpt(new)
    # Android's storage may have been resized (run/storage.py); everything else must match
    if {k: v for k, v in a.items() if k != 'userdata'} != {k: v for k, v in b.items() if k != 'userdata'} or a['userdata'][0] != b['userdata'][0]:
        sys.exit('the two images have different partition tables; build a fresh image instead')
    start, end = a['super']; changed = 0
    with open(old, 'r+b') as dst, open(new, 'rb') as src:
        for pos in range(start, end, BLOCK):
            n = min(BLOCK, end - pos)
            src.seek(pos); want = src.read(n); dst.seek(pos)
            if dst.read(n) != want:
                dst.seek(pos); dst.write(want); changed += n
    print(f'updated {changed >> 20} MiB of the system area; user data untouched')


if __name__ == '__main__':
    main()
