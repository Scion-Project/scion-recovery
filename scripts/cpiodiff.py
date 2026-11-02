#!/usr/bin/env python3
"""Compare two newc cpio archives entry by entry (mode, uid, gid, nlink,
rdev, link target / content sha256).

  cpiodiff.py OLD.cpio NEW.cpio [--allow-added PREFIX ...]

Exit 0 only if every OLD entry is in NEW unchanged, and every entry that is
new in NEW is under one of the allowed names/prefixes (if any were given).
mtime is reported but not compared.
"""
import hashlib
import sys


def read_cpio(path):
    d = open(path, "rb").read()
    off = 0
    entries = {}
    while True:
        if d[off:off + 6] not in (b"070701", b"070702"):
            sys.exit("%s: bad cpio magic at %d" % (path, off))
        f = [int(d[off + 6 + 8 * i: off + 14 + 8 * i], 16) for i in range(13)]
        ino, mode, uid, gid, nlink, mtime, fsize, dmaj, dmin, rmaj, rmin, nsize, _ = f
        off += 110
        name = d[off:off + nsize - 1].decode()
        off = (off + nsize + 3) & ~3
        body = d[off:off + fsize]
        off = (off + fsize + 3) & ~3
        if name == "TRAILER!!!":
            break
        entries[name] = dict(mode=oct(mode), uid=uid, gid=gid, nlink=nlink,
                             rdev=(rmaj, rmin), size=fsize,
                             sha256=hashlib.sha256(body).hexdigest(), mtime=mtime)
    return entries


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    old, new = read_cpio(sys.argv[1]), read_cpio(sys.argv[2])
    allowed = sys.argv[sys.argv.index("--allow-added") + 1:] if "--allow-added" in sys.argv else None
    bad = 0
    same = 0
    keys = ("mode", "uid", "gid", "nlink", "rdev", "size", "sha256")
    for name, e in sorted(old.items()):
        n = new.get(name)
        if n is None:
            print("REMOVED  %s" % name)
            bad += 1
            continue
        changed = [k for k in keys if e[k] != n[k]]
        if changed:
            print("CHANGED  %s: %s" % (name, ", ".join(changed)))
            bad += 1
        else:
            same += 1
    added = sorted(set(new) - set(old))
    for name in added:
        e = new[name]
        ok = allowed is None or any(name == a or name.startswith(a.rstrip("/") + "/") for a in allowed)
        print("ADDED    %-40s mode %s uid %d gid %d size %d %s" % (
            name, e["mode"], e["uid"], e["gid"], e["size"], "" if ok else "  <- NOT ALLOWED"))
        bad += not ok
    print("old entries %d, new entries %d, unchanged %d, added %d, problems %d" % (
        len(old), len(new), same, len(added), bad))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
