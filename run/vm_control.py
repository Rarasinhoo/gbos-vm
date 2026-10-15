#!/usr/bin/env python3
"""Send one fixed verb to a running VM's guest control service over its serial socket.
Usage: vm_control.py RUN_DIR VERB
The guest's PL011 serial input stalls if more than its 16-byte FIFO arrives at once, so
bytes are written in small chunks."""
import os, re, socket, sys, threading, time
from pathlib import Path

_cwd_lock = threading.Lock()  # the working directory is process-wide
# What the guest's control service accepts (image/guest_host_control.sh), besides VM_TOKEN and
# VM_DENSITY NNN; the last four only print diagnostics into serial.log.
VERBS = ('VM_POWEROFF', 'VM_STATUS', 'VM_LOG', 'VM_TOP', 'VM_NEARBY')


def send(run_dir, verb):
    data = (verb + '\n').encode()
    # Connect by a short relative path: macOS limits socket paths to 104 bytes.
    with socket.socket(socket.AF_UNIX) as s:
        with _cwd_lock:
            cwd = os.getcwd()
            os.chdir(run_dir)
            try: s.connect('serial.sock')
            finally: os.chdir(cwd)
        for i in range(0, len(data), 8):
            s.sendall(data[i:i + 8]); time.sleep(.03)


if __name__ == '__main__':
    if len(sys.argv) != 3 or not (sys.argv[2] in VERBS or re.fullmatch(r'VM_DENSITY [0-9]{3}', sys.argv[2])):
        sys.exit('usage: vm_control.py RUN_DIR ' + '|'.join(VERBS + ('VM_DENSITY NNN',)))
    send(sys.argv[1], sys.argv[2])
