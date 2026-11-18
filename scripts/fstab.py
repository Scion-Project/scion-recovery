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
  - /data (USERDATA) is taken out altogether. TWRP 3.7.0_9 gives /data
    "can be wiped", "wipe in GUI" and "wipe during factory reset" by its mount
    point (partition.cpp, Process_Fstab_Line), so Wipe, Format Data and a
    factory reset would erase USERDATA, where the iOS root lives. Every /data
    lookup in TWRP's partition manager is null-checked; Scion's tools reach
    USERDATA by its by-name link. TWRP keeps its logs on /cache.
  - the image ("emmc") lines that are there only for TWRP's Backup and Restore
    (/recovery, /system_image, /vendor_image, /odm_image) are taken out: only
    /boot and /misc stay.
  - /system (SYSTEM) stays (TWRP's SAR detection needs a /system line: without
    one, its first pass sets up every partition on a throwaway partition
    manager and TWRP does not come up), but gets "removable": on these phones
    SYSTEM holds iOS 16.5's disk (HFS Plus or APFS) or nothing, never ext4,
    and TWRP's start-up size check of a removable partition does not print
    "Failed to mount '/system'". Scion reaches SYSTEM by its by-name link.
  - /cache gets "storage;settingsstorage": with no /data, TWRP keeps its
    settings, backups folder and storage path on /cache instead of trying
    /data/media ("Unable to mount storage", "Unable to mount
    /data/media/TWRP/.twrps").
  - every remaining file system line (system, vendor, odm, cache, preload,
    external_sd, usb-otg) gets canbewiped=0;wipeingui=0;wipeduringfactoryreset=0,
    replacing any wipe flag it had: TWRP's Wipe and factory reset list nothing.

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


EMMC_KEEP = {"BOOT", "MISC"}
WIPE_FLAGS = ("canbewiped", "wipeingui", "wipeduringfactoryreset", "formattable")
NO_WIPE = "canbewiped=0;wipeingui=0;wipeduringfactoryreset=0"
CACHE_STORAGE = "storage;settingsstorage"
FLAG_ON = r"(^|;)(%s)(=[yY1][^;]*)?(?=;|$)"


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
        if mount == "/data" or name == "USERDATA":
            out.append("# Scion: %s (%s) is not in TWRP's fstab: TWRP would wipe it by its mount point (Wipe, Format Data, factory reset)" % (mount, name))
            out.append("# " + line)
            continue
        if mount == "/system" and not re.search(r"(^|;)removable(;|$)", flags):
            line = line.rstrip() + (";" if "flags=" in line else "        flags=") + "removable"
        if mount == "/cache":
            line = line.rstrip() + (";" if "flags=" in line else "        flags=") + CACHE_STORAGE
        if fstype == "emmc" and name not in EMMC_KEEP:
            out.append("# Scion: %s (%s) was there only for TWRP's Backup and Restore of the raw image" % (mount, name))
            out.append("# " + line)
            continue
        if fstype != "emmc":
            i = line.find("flags=")
            if i < 0:
                line = line.rstrip() + "        flags=" + NO_WIPE
            else:
                i += len("flags=")
                rest = re.sub(r"(^|;)(%s)(=[^;]*)?(?=;|$)" % "|".join(WIPE_FLAGS), "", line[i:]).lstrip(";")
                line = line[:i] + (rest + ";" if rest else "") + NO_WIPE
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
    mounts = []
    for line in open(path):
        p = parse(line)
        if p is None:
            continue
        mount, fstype, name, flags = p
        mounts.append(mount)
        if name in pol["never"]:
            bad.append("%s (%s) is on the never list" % (mount, name))
        if mount == "/system" and not re.search(r"(^|;)removable(;|$)", flags):
            bad.append("/system (%s) is not removable: TWRP would print its failed mount at start-up" % name)
        if mount == "/cache" and not re.search(r"(^|;)settingsstorage(;|$)", flags):
            bad.append("/cache (%s) is not TWRP's settings storage" % name)
        if fstype == "emmc" and name not in pol["write"] and not no_flash(flags):
            bad.append("%s (%s) is flashable in TWRP and not on the write list" % (mount, name))
        if re.search(r"(^|;)flashimg(=1|=y|=Y)?(;|$)", flags) and name not in pol["write"]:
            bad.append("%s (%s) has flashimg and is not on the write list" % (mount, name))
        if mount == "/data" or name == "USERDATA":
            bad.append("%s (%s): TWRP wipes /data by its mount point; it must not be in the fstab" % (mount, name))
        if fstype == "emmc" and name not in EMMC_KEEP:
            bad.append("%s (%s): an image line other than BOOT or MISC" % (mount, name))
        if re.search(FLAG_ON % "|".join(WIPE_FLAGS), flags):
            bad.append("%s (%s) has a wipe flag on" % (mount, name))
        if re.search(r"(^|;)wipeduringfactoryreset(?!=[0nN])", flags):
            bad.append("%s (%s) has the factory-reset flag" % (mount, name))
        if fstype != "emmc":
            for f in WIPE_FLAGS[:3]:
                if not re.search(r"(^|;)%s=0(;|$)" % f, flags):
                    bad.append("%s (%s) does not say %s=0 (TWRP's default for a file system is wipeable)" % (mount, name, f))
    if "/system" not in mounts:
        bad.append("no /system line: TWRP's SAR detection needs one")
    if "/cache" not in mounts:
        bad.append("no /cache line: TWRP needs it for its settings and logs")
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
