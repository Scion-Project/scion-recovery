#!/usr/bin/env python3
# SPDX-License-Identifier: MIT-0
"""TWRP's fstab (etc/recovery.fstab) made to agree with Scion's write policy.

TWRP's own pages write what its fstab lets them: Restore writes every
partition a backup holds that has backup=1, Install Image every image
partition ("emmc") that is flashable, which TWRP assumes unless the line says
flashimg=0. So:

  - a partition on a "never" line of overlay/etc/scion-partitions.conf (EFS,
    RADIO, ...) is taken out of the fstab: TWRP can neither restore it nor
    flash it. (Scion's copy-efs still copies EFS, read only.)
  - an image partition not on a "write" line gets flashimg=0: TWRP's
    Install Image lists only BOOT. That page is also behind Scion's advanced
    switch (theme/scion.xml).

  fstab.py apply POLICY STOCK_FSTAB OUT_FSTAB
  fstab.py check POLICY FSTAB        exit 1 if FSTAB disagrees with POLICY
"""
import re
import sys


def policy(path):
    kinds = {"write": set(), "never": set()}
    for line in open(path):
        words = line.split("#", 1)[0].split()
        if words and words[0] in kinds:
            kinds[words[0]].update(w.upper() for w in words[1:])
    if not kinds["write"] or not kinds["never"]:
        sys.exit("fstab.py: %s has no write or no never line" % path)
    if kinds["write"] & kinds["never"]:
        sys.exit("fstab.py: on both lists: %s" % sorted(kinds["write"] & kinds["never"]))
    return kinds


def parse(line):
    """(mount, fstype, NAME, flags) of an fstab line, or None."""
    s = line.strip()
    if not s or s.startswith("#"):
        return None
    f = s.split()
    m = re.search(r"/by-name/([A-Za-z0-9_]+)$", f[2])
    i = s.find("flags=")
    flags = s[i + len("flags="):] if i >= 0 else ""
    return f[0], f[1], m.group(1).upper() if m else None, flags


def no_flash(flags):
    return re.search(r"(^|;)flashimg=0(;|$)", flags) is not None


def apply(pol, src, dst):
    out = []
    for line in open(src).read().splitlines():
        p = parse(line)
        if p is None:
            out.append(line)
            continue
        mount, fstype, name, flags = p
        if name in pol["never"]:
            out.append("# Scion: %s (%s) is on the policy's never list: not for TWRP to back up, restore or flash" % (mount, name))
            out.append("# " + line)
            continue
        if fstype == "emmc" and name not in pol["write"] and not no_flash(flags):
            if re.search(r"(^|;)flashimg(=[^;]*)?(;|$)", flags):
                i = line.index("flags=") + len("flags=")
                line = line[:i] + re.sub(r"(^|;)flashimg(=[^;]*)?(?=;|$)", r"\1flashimg=0", line[i:])
            elif "flags=" in line:
                line = line.rstrip() + ";flashimg=0"
            else:
                line = line.rstrip() + "        flags=flashimg=0"
        out.append(line)
    open(dst, "w").write("\n".join(out) + "\n")


def check(pol, path):
    bad = []
    for line in open(path):
        p = parse(line)
        if p is None:
            continue
        mount, fstype, name, flags = p
        if name in pol["never"]:
            bad.append("%s (%s) is on the never list" % (mount, name))
        if fstype == "emmc" and name not in pol["write"] and not no_flash(flags):
            bad.append("%s (%s) is flashable in TWRP and not on the write list" % (mount, name))
        if re.search(r"(^|;)flashimg(=1|=y|=Y)?(;|$)", flags) and name not in pol["write"]:
            bad.append("%s (%s) has flashimg and is not on the write list" % (mount, name))
    return bad


def main():
    if len(sys.argv) == 5 and sys.argv[1] == "apply":
        apply(policy(sys.argv[2]), sys.argv[3], sys.argv[4])
    elif len(sys.argv) == 4 and sys.argv[1] == "check":
        bad = check(policy(sys.argv[2]), sys.argv[3])
        for b in bad:
            print("fstab: " + b)
        if bad:
            sys.exit(1)
        print("fstab: %s agrees with %s" % (sys.argv[3], sys.argv[2]))
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
