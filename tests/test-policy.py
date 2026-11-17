#!/usr/bin/env python3
# SPDX-License-Identifier: MIT-0
"""The write policy itself, and scripts/fstab.py on an fstab laid out like
TWRP's for starlte. No phone, no image needed.

  python3 -I tests/test-policy.py
"""
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
POLICY = os.path.join(HERE, "overlay", "etc", "scion-partitions.conf")
sys.path.insert(0, os.path.join(HERE, "scripts"))
import fstab  # noqa: E402

fails = 0


def t(name, cond):
    global fails
    print(("  ok: " if cond else "  FAIL: ") + name)
    fails += not cond


pol = fstab.policy(POLICY)
t("write list is exactly BOOT and USERDATA", pol["write"] == {"BOOT", "USERDATA"})
must_never = {"EFS", "SEC_EFS", "CPEFS", "RADIO", "BOTA0", "BOTA1", "SBOOT", "CM", "PARAM", "UP_PARAM",
              "KEYSTORAGE", "STEADY", "PERSISTENT", "RPMB"}
t("never list holds EFS, modem, boot loader, keystorage/steady/persistent, RPMB",
  must_never <= pol["never"])
t("no name on both lists", not (pol["write"] & pol["never"]))

SAMPLE = """# Android fstab file.
/system         ext4   /dev/block/platform/11120000.ufs/by-name/SYSTEM        flags=backup=0;display="System"
/boot           emmc   /dev/block/platform/11120000.ufs/by-name/BOOT
/recovery       emmc   /dev/block/platform/11120000.ufs/by-name/RECOVERY      flags=backup=1
/odm_image      emmc   /dev/block/platform/11120000.ufs/by-name/ODM           flags=backup=1;flashimg;display="ODM Image"
/data           ext4   /dev/block/platform/11120000.ufs/by-name/USERDATA      flags=encryptable=footer;length=-20480
/modem          emmc   /dev/block/platform/11120000.ufs/by-name/RADIO         flags=backup=1;display="Baseband"
/efs            ext4   /dev/block/platform/11120000.ufs/by-name/EFS           flags=backup=1;display="EFS"
/misc           emmc   /dev/block/platform/11120000.ufs/by-name/MISC
/param          emmc   /dev/block/platform/11120000.ufs/by-name/PARAM         flags=flashimg=1
/external_sd    vfat   /dev/block/mmcblk0p1 /dev/block/mmcblk0                flags=display="Micro SDcard";storage;wipeingui;removable
"""
with tempfile.TemporaryDirectory() as d:
    src, out = os.path.join(d, "in"), os.path.join(d, "out")
    open(src, "w").write(SAMPLE)
    t("the sample, as TWRP ships it, disagrees with the policy", len(fstab.check(pol, src)) >= 5)
    fstab.apply(pol, src, out)
    t("after fstab.py apply it agrees", fstab.check(pol, out) == [])
    text = open(out).read()
    active = [ln for ln in text.splitlines() if ln.strip() and not ln.startswith("#")]
    t("EFS, RADIO and PARAM are out", not any(n in ln for ln in active for n in ("/EFS", "/RADIO", "/PARAM")))
    t("BOOT stays flashable", any(ln.startswith("/boot") and "flashimg=0" not in ln for ln in active))
    t("RECOVERY, ODM, MISC get flashimg=0", all("flashimg=0" in ln for ln in active
                                                  if ln.split()[0] in ("/recovery", "/odm_image", "/misc")))
    t("a quoted display name survives", 'display="ODM Image"' in text)
    t("ODM's own flashimg is turned off, not doubled", "flashimg;" not in text)
    t("non-image lines unchanged", "/external_sd    vfat" in text and "/data           ext4" in text)
    r = subprocess.run([sys.executable, "-I", os.path.join(HERE, "scripts", "fstab.py"), "check", POLICY, src],
                       capture_output=True, text=True)
    t("fstab.py check exits 1 on the stock layout", r.returncode == 1)

print("passed" if not fails else "%d failed" % fails)
sys.exit(1 if fails else 0)
