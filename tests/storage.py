#!/usr/bin/env python3
"""Test run/storage.py on a small made-up disk laid out like the Googlebook's (a few partitions,
metadata, and userdata last), in a temporary folder: no VM and no real disk involved.

  tests/storage.py

Checks that a resize gives userdata its new size and leaves it empty, puts the metadata partition
back as in the recovery image, keeps every other partition byte for byte, writes valid primary
and backup partition tables, keeps a backup of the previous disk, and that an update
(image/sync_super.py) still accepts the resized disk.
"""
import os, struct, subprocess, sys, tempfile, uuid, zlib
from pathlib import Path

R = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(R / 'image'))
import sync_super  # noqa: E402

MiB = 1 << 20
LAYOUT = [('super', 4), ('misc', 1), ('metadata', 2), ('userdata', 8)]   # MiB each, in order


def make_disk(path, metadata_fill):
    n, es = 128, 128
    entries = bytearray(n * es); lba = 2048; parts = {}
    for i, (name, mib) in enumerate(LAYOUT):
        first, last = lba, lba + mib * MiB // 512 - 1
        e = uuid.uuid4().bytes + uuid.uuid4().bytes + struct.pack('<QQQ', first, last, 0) + name.encode('utf-16le')
        entries[i * es:i * es + len(e)] = e; parts[name] = (first, last); lba = last + 1
    last_usable = lba - 1; backup_entries = lba; disk_last = backup_entries + n * es // 512
    def header(me, other, entries_lba):
        h = bytearray(512)
        struct.pack_into('<8sIIIIQQQQ16sQIII', h, 0, b'EFI PART', 0x10000, 92, 0, 0, me, other, 34, last_usable,
                         uuid.uuid4().bytes, entries_lba, n, es, zlib.crc32(entries))
        struct.pack_into('<I', h, 16, zlib.crc32(h[:92])); return h
    with open(path, 'wb') as f:
        mbr = bytearray(512); mbr[446 + 4] = 0xee; struct.pack_into('<II', mbr, 446 + 8, 1, disk_last); mbr[510:] = b'\x55\xaa'
        f.write(mbr); f.write(header(1, disk_last, 2)); f.write(entries)
        for name, (first, last) in parts.items():
            fill = metadata_fill if name == 'metadata' else name[0].encode()
            f.seek(first * 512); f.write(fill * ((last - first + 1) * 512))
        f.seek(backup_entries * 512); f.write(entries); f.write(header(disk_last, 1, backup_entries))
    return parts


def check_tables(path):
    with open(path, 'rb') as f:
        f.seek(512); h = f.read(512); assert zlib.crc32(h[:16] + b'\0' * 4 + h[20:92]) == struct.unpack_from('<I', h, 16)[0]
        backup = struct.unpack_from('<Q', h, 32)[0]
        f.seek(backup * 512); b = f.read(512); assert b[:8] == b'EFI PART', 'no backup header at the end'
        assert zlib.crc32(b[:16] + b'\0' * 4 + b[20:92]) == struct.unpack_from('<I', b, 16)[0], 'backup header checksum'
        assert backup == os.path.getsize(path) // 512 - 1, 'backup header is not the last sector'
        ents = struct.unpack_from('<Q', b, 72)[0]; f.seek(ents * 512)
        assert zlib.crc32(f.read(128 * 128)) == struct.unpack_from('<I', b, 88)[0], 'backup entries checksum'


def main():
    with tempfile.TemporaryDirectory() as t:
        work = Path(t); (work / 'image').mkdir(); (work / 'logs').mkdir(); (work / 'googlebook').mkdir()
        make_disk(work / 'googlebook/mica-recovery.raw', b'M')
        image = work / 'image/googlebook.raw'; parts = make_disk(image, b'K')   # K: keys of the old data
        before = image.read_bytes()
        out = subprocess.run([sys.executable, str(R / 'run/storage.py'), str(work), '16'], capture_output=True, text=True)
        assert out.returncode == 0, out.stderr
        check_tables(image)
        size = subprocess.run([sys.executable, str(R / 'run/storage.py'), str(work)], capture_output=True, text=True).stdout.strip()
        assert size == '16', size
        new = sync_super.gpt(str(image)); old = sync_super.gpt(str(work / 'googlebook/mica-recovery.raw'))
        assert new['userdata'] == (old['userdata'][0], old['userdata'][0] + (16 << 30)), new['userdata']
        with open(image, 'rb') as f:
            for name, (first, last) in parts.items():
                f.seek(first * 512); data = f.read((last - first + 1) * 512)
                if name == 'userdata': assert not any(data), 'userdata not emptied'
                elif name == 'metadata': assert data == b'M' * len(data), 'metadata not as in the recovery image'
                else: assert data == before[first * 512:(last + 1) * 512], f'{name} changed'
        assert (work / 'image/googlebook.raw.before-update').read_bytes() == before, 'no backup of the previous disk'
        assert os.stat(image).st_blocks * 512 < 64 * MiB, 'the resized disk is not sparse'
        # An update builds a disk with the original userdata size; it must still sync into this one
        assert {k: v for k, v in new.items() if k != 'userdata'} == {k: v for k, v in old.items() if k != 'userdata'}
        r = subprocess.run([sys.executable, str(R / 'image/sync_super.py'), str(image), str(work / 'googlebook/mica-recovery.raw')], capture_output=True, text=True)
        assert r.returncode == 0, r.stdout + r.stderr
        # Out of range sizes and a running VM are refused
        assert subprocess.run([sys.executable, str(R / 'run/storage.py'), str(work), '8'], capture_output=True).returncode != 0
        import fcntl
        with open(work / 'logs/vm.lock', 'a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            assert subprocess.run([sys.executable, str(R / 'run/storage.py'), str(work), '32'], capture_output=True).returncode != 0
    print('storage: ok')


if __name__ == '__main__':
    main()
