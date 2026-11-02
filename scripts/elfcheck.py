#!/usr/bin/env python3
"""elfcheck.py FILE: exit 0 if FILE is a 64-bit little-endian aarch64 ELF
executable with no PT_INTERP and no DT_NEEDED: fully static (plain static, or
static-pie, whose PT_DYNAMIC only carries its own relocations)."""
import struct
import sys

d = open(sys.argv[1], "rb").read()
if d[:4] != b"\x7fELF" or d[4] != 2 or d[5] != 1:
    sys.exit("not ELF64 LE")
e_type, e_machine = struct.unpack_from("<HH", d, 16)
if e_machine != 183:
    sys.exit("machine %d, not aarch64" % e_machine)
if e_type not in (2, 3):
    sys.exit("not an executable")
phoff, = struct.unpack_from("<Q", d, 32)
phentsize, phnum = struct.unpack_from("<HH", d, 54)
for i in range(phnum):
    p_type, = struct.unpack_from("<I", d, phoff + i * phentsize)
    if p_type == 3:
        sys.exit("has PT_INTERP (dynamic)")
    if p_type == 2:
        off, = struct.unpack_from("<Q", d, phoff + i * phentsize + 8)
        filesz, = struct.unpack_from("<Q", d, phoff + i * phentsize + 32)
        for j in range(0, filesz, 16):
            tag, = struct.unpack_from("<q", d, off + j)
            if tag == 0:
                break
            if tag == 1:
                sys.exit("has DT_NEEDED (dynamic)")
