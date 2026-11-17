#!/usr/bin/env python3
# SPDX-License-Identifier: MIT-0
"""Minimal Android boot image (header v0, Samsung Exynos DT in the dt slot) tool.

  bootimg.py info    IMG
  bootimg.py extract IMG OUTDIR             header.bin kernel ramdisk second dt tail
  bootimg.py replace-ramdisk IMG RAMDISK OUT
        Copies IMG byte for byte except the ramdisk segment, ramdisk_size and the
        id (SHA-1, recomputed the way mkbootimg does). Kernel, second, DT, every
        other header field, padding and anything after the image are kept.
  bootimg.py compare A B                    field-by-field and segment-by-segment diff

Given IMG's own ramdisk, replace-ramdisk gives back IMG exactly (checked by build.sh).
"""
import hashlib
import struct
import sys

HDR = struct.Struct("<8s10I16s512s32s1024s")
FIELDS = ("magic kernel_size kernel_addr ramdisk_size ramdisk_addr second_size "
          "second_addr tags_addr page_size dt_size os_version name cmdline id "
          "extra_cmdline").split()


def parse(data):
    if data[:8] != b"ANDROID!":
        sys.exit("not an Android boot image")
    h = dict(zip(FIELDS, HDR.unpack_from(data, 0)))
    ps = h["page_size"]
    if ps not in (2048, 4096, 16384):
        sys.exit("odd page size %d" % ps)
    # Header v0: the dword after os_version... is part of name here; the v1+
    # header_version field lives in what v0 calls dt_size, so v0 only.
    pad = lambda n: (n + ps - 1) // ps * ps
    off = ps
    seg = {}
    for name in ("kernel", "ramdisk", "second", "dt"):
        size = h[name + "_size"]
        seg[name] = (off, size)
        off += pad(size)
    seg["tail"] = (off, len(data) - off)
    return h, seg


def sha1_id(parts):
    m = hashlib.sha1()
    for p in parts:
        m.update(p)
        m.update(struct.pack("<I", len(p)))
    return m.digest()


def get(data, seg, name):
    o, n = seg[name]
    return data[o:o + n]


def cmd_info(path):
    data = open(path, "rb").read()
    h, seg = parse(data)
    for k in FIELDS:
        v = h[k]
        if isinstance(v, bytes):
            v = v.rstrip(b"\0")
            v = v.hex() if k == "id" else v.decode(errors="replace")
        elif k.endswith("addr") or k == "os_version":
            v = "0x%08x" % v
        print("%-14s %s" % (k, v))
    for k, (o, n) in seg.items():
        print("segment %-7s offset %-9d size %d" % (k, o, n))
    parts = [get(data, seg, s) for s in ("kernel", "ramdisk", "second", "dt")]
    ok = sha1_id(parts) == h["id"][:20]
    print("id matches sha1(kernel,ramdisk,second,dt):", ok)
    print("file size", len(data))


def cmd_extract(path, outdir):
    import os
    data = open(path, "rb").read()
    h, seg = parse(data)
    os.makedirs(outdir, exist_ok=True)
    open(os.path.join(outdir, "header.bin"), "wb").write(data[:h["page_size"]])
    for s in seg:
        open(os.path.join(outdir, s), "wb").write(get(data, seg, s))


def cmd_replace_ramdisk(path, rdpath, out):
    data = open(path, "rb").read()
    rd = open(rdpath, "rb").read()
    h, seg = parse(data)
    ps = h["page_size"]
    pad = lambda n: (n + ps - 1) // ps * ps
    if seg["tail"][1] != 0 and any(data[seg["tail"][0]:]):
        print("note: keeping %d bytes after the image" % seg["tail"][1])
    old_id_std = sha1_id([get(data, seg, s) for s in ("kernel", "ramdisk", "second", "dt")]) == h["id"][:20]
    ro, rn = seg["ramdisk"]
    new = bytearray(data[:ro])                 # header page + kernel (+ its padding)
    new += rd + b"\0" * (pad(len(rd)) - len(rd))
    new += data[ro + pad(rn):]                 # second, dt, tail exactly as they were
    struct.pack_into("<I", new, 16, len(rd))   # ramdisk_size
    if old_id_std:
        _, nseg = parse(bytes(new))
        nid = sha1_id([get(new, nseg, s) for s in ("kernel", "ramdisk", "second", "dt")])
        idoff = 8 + 40 + 16 + 512
        new[idoff:idoff + 32] = nid + b"\0" * 12
    open(out, "wb").write(new)


def cmd_compare(a, b):
    da, db = open(a, "rb").read(), open(b, "rb").read()
    ha, sa = parse(da)
    hb, sb = parse(db)
    diff = 0
    for k in FIELDS:
        if ha[k] != hb[k]:
            print("header %-13s DIFFERS" % k)
            diff += 1
        else:
            print("header %-13s same" % k)
    for s in ("kernel", "ramdisk", "second", "dt"):
        same = get(da, sa, s) == get(db, sb, s)
        print("segment %-7s %s (%d vs %d bytes)" % (s, "same" if same else "DIFFERS",
                                                  sa[s][1], sb[s][1]))
        diff += not same
    print("differences:", diff)


def main(argv):
    if len(argv) < 3:
        sys.exit(__doc__)
    cmd = argv[1]
    if cmd == "info":
        cmd_info(argv[2])
    elif cmd == "extract":
        cmd_extract(argv[2], argv[3])
    elif cmd == "replace-ramdisk":
        cmd_replace_ramdisk(argv[2], argv[3], argv[4])
    elif cmd == "compare":
        cmd_compare(argv[2], argv[3])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv)
