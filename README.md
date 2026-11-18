<!-- SPDX-License-Identifier: MIT-0 -->
# Scion recovery

The recovery for Scion on the Samsung Galaxy S9 (SM-G960F, starlte, Exynos 9810): TeamWin's TWRP 3.7.0
with Scion's own theme, pages and tools. It installs iOS (a root image to USERDATA, a boot image to BOOT,
the iOS 16.5 installer zip), switches between Android, iOS 16.5 and iOS 27, backs up and restores the iOS
root, reads iOS's HFS Plus and APFS volumes, keeps the logs a run leaves behind, and gives a computer
**fastboot** (`fastboot flash boot|userdata`, `fastboot reboot`), which the S9's own boot loader does not have.
Everything TWRP does is still there.

**Nothing in this repository has been run on a phone yet** (17 November 2026). What is tested, and how, is in
"Tests" below; what to do on a phone, in what order, is in [TESTING.md](TESTING.md).

Pictures of the home page and of every Scion page are made by CI on each run (the `scion-recovery-preview`
artifact of the [build workflow](https://github.com/Scion-Project/scion-recovery/actions/workflows/build.yml)).
They are drawn by `scripts/preview.py`, an approximation of TWRP's renderer, not by TWRP.

## What it writes, and what it never writes

Scion's tools (the GUI's Scion pages, `/sbin/scion`, `scion-fastbootd`) write **BOOT and USERDATA, nothing
else**. The one list is [`overlay/etc/scion-partitions.conf`](overlay/etc/scion-partitions.conf)
(`/etc/scion-partitions.conf` in the image):

- `write BOOT USERDATA`
- `never EFS SEC_EFS CPEFS RADIO CP_DEBUG NAD_REFER BOTA0 BOTA1 SBOOT CM PARAM UP_PARAM KEYSTORAGE TIMA RPMB STEADY PERSISTENT DQMDBG`

Every write is checked against it by name, by the kernel's PARTNAME of the device the by-name link resolves to,
and against every `never` partition's device (a link that resolves to EFS's device is refused whatever it is
called); without the file every write is refused. Every write hashes the source first (and refuses it if it
does not match its `.sha256`), logs the old contents' hash to `/tmp/scion-actions.log`, writes, flushes, reads
back and compares. One write at a time: `/tmp/scion-write.lock`, shared by the GUI, `scion` and fastboot.

TWRP's own pages are held to the same list where TWRP's configuration allows it (`scripts/fstab.py`, at build
time): `/efs` and `/modem` (RADIO) are out of TWRP's fstab; so is `/data` (USERDATA, where the iOS root lives:
TWRP 3.7.0 wipes `/data` by its mount point); the only
image lines left are BOOT and MISC; every file system line says `canbewiped=0;wipeingui=0;wipeduringfactoryreset=0`,
so TWRP's Wipe and factory reset list nothing; `/cache` holds TWRP's settings and logs. The home pages have no
Wipe or Restore button, Partition SD Card has no swipe, and `scripts/theme.py lint` fails the build if a page
erases, formats or restores outside its short allowed list. TWRP's **Install Image** is shown only with Scion
settings' **Advanced** switch on, and lists only BOOT. EFS can be *copied*, read only (`scion copy-efs`). Not
held to the list: the terminal and zips (a root shell can write anything; that is TWRP's nature).

Nothing here writes the boot loader, flashes RECOVERY, touches Knox, attestation or signatures, or changes
secure firmware. Download mode lives in the boot loader, which nothing here writes: it is always the way back.

## What's in it

| Page (GUI) | `scion` command | Writes |
|---|---|---|
| Install iOS > root image | `write-root IMG --yes [--from N]` | USERDATA (erases Android's data): 64 MiB pieces, each read back |
| Install iOS > boot image | `flash IMG` | BOOT (an Android boot image) |
| Install iOS > installer zip | TWRP's Install (the iOS 16.5 zip's own `update-binary`) | what the zip writes (BOOT, SYSTEM) |
| Install iOS > ADB sideload | TWRP's sideload | as above |
| Fastboot | `fastboot start\|stop\|status` | BOOT, USERDATA (from the computer) |
| Switch system > Android / iOS 16.5 / iOS 27 | `switch android\|ios165\|ios27 [--anyway]` | BOOT only, from the boot library |
| Switch system > Save BOOT as ... | `bootlib save OS` | a file on the SD card or USB drive |
| Back up > iOS root | `backup-root [DIR]` | a file (the HFS Plus/APFS volume, by its header), with `.sha256` |
| Back up > Restore | `restore-root IMG --yes` | USERDATA; needs `IMG.sha256` |
| Back up > BOOT | `backup-boot [DIR]` | a file, with `.sha256` |
| Back up > Copy EFS | `copy-efs [DIR]` | files: EFS, SEC_EFS, CPEFS, read only |
| Save logs | `logs`, `pull` | files in `/tmp` |
| iOS disks | `mountvar`, `umountvar`, `inspect`, `fsck` | nothing (read only; `fsck` is apfsck, which reports) |
| Phone info | `facts` | nothing: model, boot loader, battery, memory, partitions, storage |
| Scion settings | `policy`, the Advanced switch, the log of writes | nothing |

TWRP's own pages are there below Scion's: Install, Backup, Mount (and MTP), Settings
(brightness, screen timeout, time zone, vibration, language), Advanced (file manager, terminal, ADB sideload,
copy log, fix contexts), Reboot (System, Recovery, Download, Power Off). TWRP's decryption of Android's data is
TWRP's, as built by TeamWin.

**The boot library** is the folder `scion/` on the SD card or a USB drive: `boot-android.img`,
`boot-ios165.img`, `boot-ios27.img`, each with its `.sha256` (`sha256sum`'s format). Switch system writes the
chosen one to BOOT after checking it, and after checking that the system can start: iOS 27 needs its root on
USERDATA (HFS Plus with `System/Library/CoreServices/SystemVersion.plist`), iOS 16.5 an HFS Plus or APFS SYSTEM,
Android ext4 or f2fs on USERDATA. Fill it with Switch system > Save BOOT as ..., with each system's boot image
in BOOT, or copy the files there.

**Storage.** USERDATA is where an iOS root goes, so a root image cannot come from internal storage while it
is being written: put it on the SD card or a USB drive formatted **exFAT** (FAT32 holds files up to 4 GiB; a
root is about 32 GiB with 20 GiB used), or send it with fastboot.

### fastboot

The S9's boot loader has Download mode (Odin, heimdall) and no fastboot. Scion recovery adds one:
`scion-fastbootd` (ours, `fastbootd/scion-fastbootd.c`) on TWRP's USB gadget. Fastboot > Start stops adb and
brings the USB port up as a fastboot device (18d1:4ee0); Stop brings adb back.

    fastboot devices
    fastboot getvar all
    fastboot flash boot xnu-boot-ios27.img
    fastboot flash userdata root-full.img        # erases Android's data; sent as sparse pieces of 256 MiB
    fastboot reboot                              # reboot bootloader = Download mode; reboot recovery

Only BOOT and USERDATA: anything else, `flashing`, `oem` (but `oem scion-policy`) and `fastboot boot` are
refused with the reason. Each flash is read back and compared before the answer OKAY. It needs no kernel
change: TWRP's kernel has FunctionFS (`CONFIG_USB_CONFIGFS_F_FS=y`) and TWRP's init already sets up the
configfs gadget with one FunctionFS function (`ffs.adb`, which Samsung's kernel names "adb"); fastboot takes
that function over while it runs. Use platform-tools 30 or newer on the computer (replies up to 256 bytes).
The USB side has not run on a phone: if it does not come up, adb stays the way in
(`tools/ios27/s9/flash.sh` in scion-kernel does the same writes over adb).

### The theme

TWRP's GUI is drawn from `/twres` in the ramdisk. `scripts/theme.py` makes Scion's theme at build time from the
stock files (nothing of TeamWin's theme is committed here): the colours of scion-project.github.io's dark scheme,
a slate header with a green line, TeamWin's PNGs recoloured (shapes unchanged), the Scion logo in the header and
on the splash screen (rendered from `theme/art/scion-logo.svg`), Scion's home page and pages
(`theme/scion.xml`), and TeamWin's home page kept as `twrp_home`. Every edit of a stock file checks its anchor
first, and `theme.py lint` checks that every page, style, template, image, action and variable it names exists.

### The iOS disk tools

Added to the ramdisk, all static aarch64 (musl), so they need neither bionic nor TWRP's linker:

| Path | What |
|---|---|
| `/sbin/scion` | the helper (POSIX sh, runs under TWRP's mksh) |
| `/sbin/scion-fastbootd` | fastboot (above) |
| `/etc/scion-partitions.conf` | the write policy |
| `/sbin/scion-bootlogs`, `/init.recovery.samsungexynos9810.rc` | copies the last run's logs to `/tmp/scion-boot` at boot |
| `/sbin/hfsfuse`, `/sbin/hfsdump` | HFS Plus/HFSX, read only, through FUSE or without it |
| `/sbin/apfs-fuse`, `/sbin/apfs-extract`, `/sbin/apfsutil` | APFS, read only |
| `/sbin/mkapfs` (`mkfs.apfs`), `/sbin/apfsck` (`fsck.apfs`), `/sbin/apfs-label`, `/sbin/apfs-snap` | apfsprogs |

`scion logs` collects `/proc/last_kmsg`, `/sys/fs/pstore` (where the iOS loader and the tail of XNU's log land),
Samsung's reset reason files, dmesg, the command line, mounts and properties, and lists the reserved log regions
of the device tree. `scion mountvar` mounts HakiOS' `/private/var` (journaled HFSX on USERDATA) or an APFS
volume read only at `/scion/var`; `scion pull` tars the CrashReporter logs, with FUSE or without it. A journal
that was not flushed is mounted anyway and said so. The iOS 27 root on USERDATA is HFS Plus too: `inspect`
shows its header, `mountvar` mounts it read only.

## Build

CI (`.github/workflows/build.yml`) builds every push and pull request on GitHub's runners in about two minutes:
the tools (hfsfuse and apfs-fuse in Alpine containers, apfsprogs and scion-fastbootd with zig), then `build.sh`,
`verify.sh`, the tests, and the theme's previews. The run's artifacts are `scion-recovery.img`,
`scion-recovery.tar` (Odin) and `SHA256SUMS`, and `scion-recovery-preview`.

By hand, x86_64 Linux with bash, python3 (Pillow), curl, unzip, cpio, `rsvg-convert` (librsvg), git, make,
docker (for the Alpine builds):

    scripts/build-apfsprogs.sh                   # -> work/apfsprogs-aarch64/
    scripts/build-fastbootd.sh                   # -> work/fastbootd-aarch64/
    # hfsfuse: third_party/hfsfuse/build-in-alpine.sh; apfs-fuse: third_party/apfs-fuse/ (see SOURCE and CI)
    HFS_BIN=... APFS_BIN=... APFSPROGS_BIN=work/apfsprogs-aarch64 FASTBOOTD_BIN=work/fastbootd-aarch64 ./build.sh
    ./verify.sh

`build.sh` downloads TeamWin's `twrp-3.7.0_9-0-starlte.img` from dl.twrp.me and checks its sha256 (pinned; the
one dl.twrp.me publishes, GPG-signed by TeamWin), gets magiskboot from Magisk v31.1 for LZMA and in-place cpio
edits, and writes `out/scion-recovery.img`, `out/scion-recovery.tar` and `out/SHA256SUMS`. Only the ramdisk
changes: the kernel, the Exynos DT table and every header field but `ramdisk_size` and `id` are TeamWin's bytes.

## Tests (no phone)

- `verify.sh`: a no-op repack is byte-identical to stock; only the ramdisk, `ramdisk_size` and `id` differ;
  the ramdisk is LZMA like stock; every stock entry is unchanged except the theme's `twres/` files and
  `etc/recovery.fstab` (content only), which must be exactly what `theme.py` and `fstab.py` make; the theme
  lints; the fstab agrees with the write policy; TWRP's `ramdisk-files.sha256sum` verifies for every other
  file; the image fits RECOVERY (68,149,248 bytes, `BOARD_RECOVERYIMAGE_PARTITION_SIZE` of LineageOS'
  universal9810-common; about 45 MB used); the binaries are static aarch64; the scripts pass shellcheck.
- `tests/test-actions.sh [SHELL]`: `scion` in mksh, busybox sh and dash against fake partitions (plain files
  and a fake `/sys/class/block` with PARTNAMEs): 109 checks each, every protected name refused, lying by-name
  links refused, hash mismatches refused before anything is written, the lock, write-root, restore-root,
  backup-root, switch, fastboot start/stop against a fake gadget, and EFS, SEC_EFS, CPEFS, RADIO, PARAM,
  BOTA0, RECOVERY, SYSTEM and VENDOR byte for byte unchanged at the end.
- `tests/test-fastbootd.sh [BINARY]`: the real `fastboot` client (Ubuntu's platform-tools 34) against
  scion-fastbootd over TCP, fake partitions: 53 checks; CI runs it on a native build and on the aarch64 build
  under qemu.
- `tests/test-policy.py`: the policy and `fstab.py`.
- `tests/test-scion.sh`, `tests/test-apfsprogs.sh`: the iOS disk tools on real HFSX/APFS images, in a
  privileged Alpine container (the APFS test images are not in the repository; CI does not run these).

**Not run on a phone:** all of it. In particular: TWRP drawing the theme, the GUI's actions, TWRP honouring
`flashimg=0`, the SD card and USB drive mount points, fastboot's USB side (FunctionFS descriptors, the gadget
switch, adb coming back), timings.

## Flashing it

Flashing RECOVERY is **your** step, done the way Samsung and TWRP document it; nothing in Scion's tools
writes RECOVERY. It needs an OEM-unlocked S9 (SM-G960F). On the project's own test phones RECOVERY is written
only with the owner's explicit go (their standing write allow-list is BOOT and USERDATA).

See [RESTORE.md](RESTORE.md): from TWRP (`dd` by partition name, with the hash compared), from a computer in
Download mode with heimdall or Odin (`out/scion-recovery.tar` in AP), and how to put stock TWRP back if Scion
recovery does not start. Download mode is never affected.

## Licences and sources (GPL)

The image contains GPL software. Sources, as shipped next to the image in `out/sources/`:

- **TWRP** (Apache-2.0 / GPL parts) and its **Linux kernel 4.9.118-g36e6ddff22b9** (GPL-2.0),
  unmodified, from TeamWin's starlte build: device tree
  https://github.com/TeamWin/android_device_samsung_starlte (branch android-9.0; the kernel is
  a prebuilt there), TWRP https://github.com/TeamWin/android_bootable_recovery. Samsung's
  kernel source for SM-G960F: https://opensource.samsung.com (search SM-G960F); our fork:
  https://github.com/Scion-Project/android_kernel_samsung_exynos9810. The kernel config is
  in the image (`/proc/config.gz`, or `extract-ikconfig`).
- **apfs-fuse**, **apfsutil**, **apfs-extract**: GPL-2.0-or-later,
  https://github.com/sgan81/apfs-fuse at 66b86bd525e8 plus `third_party/apfs-fuse/apfs-fuse-local.patch`
  (musl fixes) and `third_party/apfs-fuse/apfs-extract/apfs-extract.cpp` (the extractor, on ApfsLib).
  Complete source: that commit plus those two files.
  Statically linked: libfuse 3.16.2 (LGPL-2.1, `fuse-3.16.2.tar.gz`), zlib, bzip2 1.0.8, lzfse,
  musl 1.2.5, libstdc++/libgcc 13.2 (GPL-3 with the runtime exception).
- **hfsfuse**, **hfsdump**: https://github.com/0x09/hfsfuse tag 0.469 (e2a84c602cbc),
  unmodified; hfsfuse's own code is MIT, with NetBSD's libhfs (BSD-2-Clause), utf8proc, ublio,
  uthash, LZFSE and LZVN bundled under their own licences (`third_party/hfsfuse/COPYING`,
  `third_party/hfsfuse/SOURCE`). Complete source: `hfsfuse-0.469.tar.gz`. Statically linked:
  libfuse 3.16.2 (LGPL-2.1), zlib, musl, libgcc.
- **apfsprogs** (mkapfs, apfsck, apfs-label, apfs-snap): GPL-2.0,
  https://github.com/linux-apfs/apfsprogs at 1bd1c1c2140d13d1b6d2e03379316572bee70aa3,
  unmodified (built with `-D_GNU_SOURCE -Dloff_t=off_t` for musl). `apfsprogs-1bd1c1c.tar.gz`.
- **scion-fastbootd**: ours, written from scratch (MIT-0), from the fastboot protocol and the Android
  sparse format as AOSP documents them; no AOSP code. Statically linked against musl (MIT).
- `scion`, `scion-bootlogs`, `scion-partitions.conf`, the theme's `scion.xml` and `splash.xml`, the
  build and test scripts: ours, MIT-0 (each file's SPDX line). The theme's other files in the image
  (`ui.xml`, `portrait.xml`, the PNGs) are TeamWin's, edited at build time by `scripts/theme.py`, and
  stay under TWRP's licence; `logo.png` and `splashlogo.png` are the Scion logo
  (`theme/art/SOURCE`).

Anyone who redistributes `scion-recovery.img` must pass these sources (or a written offer)
along with it.


## Not done

- Read-write APFS (linux-apfs-rw) would need a rebuilt TWRP kernel; booting reliably matters more. apfs-fuse
  is read only; `mkapfs` can still make a fresh container.
- An HFS Plus checker: `fsck_hfs` is Apple's and is not here; `scion fsck` shows the volume header and journal
  state instead.
- TWRP's time fix and USB-OTG are TWRP's as built by TeamWin (the kernel has no `CONFIG_USB_OTG`; whether a
  USB drive mounts at `/usb-otg` is untested).
- Streaming a root over adb into `write-root` (stdin): fastboot is that path now.
