<!-- SPDX-License-Identifier: MIT-0 -->
# Changelog

## scion 4 (18 November 2026): no wipe, no clipped text, a clean start

- **Nothing in TWRP can wipe USERDATA**: `/data` is out of TWRP's fstab (TWRP 3.7.0 gives `/data` the wipe
  and factory-reset flags by its mount point); every other file system line says
  `canbewiped=0;wipeingui=0;wipeduringfactoryreset=0`; the backup-only image lines (RECOVERY, SYSTEM, VENDOR,
  ODM images) are gone. `fstab.py check` enforces all of it.
- **No Wipe or Restore button** on Scion's home page or TeamWin's; Partition SD Card's swipe removed;
  `theme.py lint` fails on any wipe, format, restore, change-file-system, partition-SD or flash-image action
  outside its allowed list.
- **Text no longer cut off** at 1440x2960: TWRP draws each line unwrapped at the theme size x 4/3 at 300 dpi,
  so the long notes ran past the screen's edge. They are shorter, and `theme.py lint` measures every Scion line
  with TWRP's font.
- **Home key** on every Scion page.
- **A clean start-up**: no red mount errors. `/system` (SYSTEM holds iOS 16.5's disk, not ext4) is out of the
  fstab, `/cache` is TWRP's settings storage instead of `/data/media`, and MTP (which failed) is off at start.

## Unreleased (17 November 2026): Scion's own recovery

Not run on a phone yet (TESTING.md).

- **Theme and home page** (pull request 3): Scion's colours, logo, splash screen and home page with Scion's
  actions first, made at build time from TWRP's stock theme by `scripts/theme.py`; TeamWin's home page kept.
- **CI** (3): every push builds the tools, the image and the previews on GitHub's runners and runs every
  check; the image is the run's artifact.
- **apfs-extract's source** in the repository (3): it was only in a tarball shipped beside an earlier image.
- **The write policy** (4): `/etc/scion-partitions.conf`, BOOT and USERDATA only, a never list for identity,
  modem, boot loader and secure storage; TWRP's fstab made to agree with it; TWRP's Install Image behind an
  Advanced switch.
- **Scion actions** (4): install an iOS root to USERDATA, a boot image to BOOT; switch Android, iOS 16.5 and
  iOS 27 from a boot library; back up and restore the iOS root; back up BOOT; copy EFS read only; phone facts;
  inspect and check the iOS disks. Every write verified (hash before, read back after) and locked.
- **fastboot** (5): `scion-fastbootd` on TWRP's FunctionFS gadget: `fastboot flash boot|userdata`, `getvar`,
  `erase`, `reboot [bootloader|recovery]`, BOOT and USERDATA only, read back before OKAY.
- **Docs** (6): README, TESTING.md, this file, NOTICE.

## 2 November 2026

- Stock TWRP 3.7.0_9-0 for starlte with HFS Plus and APFS tools, `scion` (logs, mountvar, pull, flash BOOT)
  and boot-time log capture added to its ramdisk.
