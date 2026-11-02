# Scion recovery

The recovery image for HakiOS on the Samsung Galaxy S9 (SM-G960F, starlte, Exynos 9810).
HakiOS (XNU with iOS 16.5 user space) boots from BOOT; RECOVERY holds this image, which is
our safety net and debug station: it reads (and can create) APFS, and it collects the logs a
HakiOS run leaves behind.

It is **stock TWRP 3.7.0_9-0 for starlte with files added to its ramdisk**. Nothing else
changes: the kernel, the Exynos DT table and every boot-image header field except
`ramdisk_size` and the `id` checksum are copied byte for byte from TeamWin's image, and every
file already in TWRP's ramdisk is kept unchanged (mode, owner, content). "It must boot" was the
first requirement, so the design adds as little as possible to what TWRP's init already does.

## What's in it

Added to the ramdisk (nothing else):

| Path | What |
|---|---|
| `/sbin/scion` | the helper, below (POSIX sh, runs under TWRP's mksh) |
| `/sbin/scion-bootlogs`, `/init.recovery.samsungexynos9810.rc` | boot-time log copy, below |
| `/sbin/apfs-fuse` | FUSE APFS driver (read-only), static aarch64, libfuse 3.16.2 built in |
| `/sbin/apfs-extract` | APFS reader without FUSE: `vols`, `ls`, `stat`, `cat`, `get`, `tar` |
| `/sbin/apfsutil` | container/volume info |
| `/sbin/mkapfs` (+ `mkfs.apfs`) | makes an APFS container (apfsprogs) |
| `/sbin/apfsck` (+ `fsck.apfs`) | APFS checker (apfsprogs) |
| `/sbin/apfs-label`, `/sbin/apfs-snap` | apfsprogs: volume labels, snapshots |
| `/scion/`, `/scion/apfs/` | mount points |

All binaries are static aarch64 (musl), so they need neither bionic nor TWRP's linker.

### `scion`

    scion logs [DIR]        last_kmsg, pstore, Samsung reset info, dmesg, reserved log
                            regions -> DIR/<timestamp>/ + .tar.gz (default /tmp/scion-logs)
    scion mountvar [VOL]    apfs-fuse USERDATA read-only at /scion/apfs, /scion/var -> its var dir
    scion umountvar
    scion pull [DIR]        CrashReporter logs (/scion/var/mobile/Library/Logs/CrashReporter) -> tar.gz
    scion flash IMG [BOOT]  dd IMG to BOOT, sha256 read-back; refuses every other partition
    scion info

Details:

- **logs**: `/proc/last_kmsg` (Samsung sec_debug's copy of the previous kernel's log),
  everything in `/sys/fs/pstore` (ramoops in the Exynos-snapshot `log_pstore` region at
  0xFED10000: where the HakiOS loader leaves its own log and the tail of XNU's), the
  sec_debug files `/proc/reset_reason`, `reset_reason_extra_info`, `extra`, `auto_comment`,
  `pwrsrc`, `reset_history`, plus `dmesg`, `/proc/cmdline`, mounts, getprop and the ramoops
  parameters. It also lists the reserved-memory log regions from the device tree
  (`log_kernel`, `log_pstore`, ...) with their addresses, and dumps them raw if `/dev/mem`
  exists. It doesn't on TWRP's kernel (`CONFIG_DEVMEM` is off), so the ESS kernel-log region is
  reachable only through last_kmsg/pstore; that is stated in `reserved-log-regions.txt`.
  Logs go to `/tmp` (RAM) because /data is not mountable when it holds APFS; `adb pull` the
  printed `.tar.gz`.
- **mountvar** tries USERDATA, then SYSTEM (`SCION_VAR_PARTS` overrides), volumes 0-4
  (or the one given), and takes the first volume whose root is the var tree (`mobile/`) or
  contains `private/var/mobile`. apfs-fuse shows a volume under `<mnt>/root`, so `/scion/var`
  is a symlink to the right directory under `/scion/apfs/root`. Read-only.
- **pull** uses `/scion/var` when it can, else reads the volume directly with
  `apfs-extract ... tar` (no FUSE needed).
- **flash** writes only BOOT: the name argument must be `BOOT`, the by-name link is resolved and
  the kernel's `PARTNAME` for the resolved device must be `BOOT`, the image must fit, and must
  start with `ANDROID!` (override with `SCION_FORCE=1`). After `dd ... conv=fsync` it drops the
  page cache and compares the sha256 of what is read back with the file's.

### Boot-time log copy

TWRP's stock `init.rc` already has `import /init.recovery.${ro.hardware}.rc`; on the S9
`ro.hardware` is `samsungexynos9810` and stock TWRP ships no such file. We add it, with one
`oneshot` service declared exactly like TWRP's own `set_permissive` (class default,
`seclabel u:r:recovery:s0`), which runs `scion logs --boot /tmp/scion-boot`. init does not
wait for it and nothing depends on it; if it fails the only effect is an empty
`/tmp/scion-boot`. No stock file is edited. adb is TWRP's, untouched: `ro.secure=0`,
`persist.sys.usb.config=adb`, adbd started by TWRP, no authorization prompt.

## Build

Needs bash, python3, curl, unzip, and (for the apfsprogs build) git and make; x86_64 Linux.

    # apfsprogs, static aarch64 with zig (downloaded, sha256-pinned)
    scripts/build-apfsprogs.sh                       # -> work/apfsprogs-aarch64/
    # apfs-fuse/apfs-extract/apfsutil: see third_party/apfs-fuse/ (Alpine, docker)
    APFS_BIN=/path/to/apfs-fuse/bin/aarch64 APFSPROGS_BIN=work/apfsprogs-aarch64 ./build.sh
    SHELLCHECK=/path/to/shellcheck ./verify.sh

`build.sh` downloads `https://dl.twrp.me/starlte/twrp-3.7.0_9-0-starlte.img`, checks its
sha256 against the value pinned in the script (the one dl.twrp.me publishes; TeamWin's GPG
signature on it was checked too), gets magiskboot from Magisk v31.1 (used only for LZMA and
for editing the cpio archive in place) and writes `out/scion-recovery.img`,
`out/scion-recovery.tar` (Odin) and `out/SHA256SUMS`. The build is reproducible (same inputs,
same image hash). `scripts/bootimg.py` does the image surgery: it keeps every byte of the
stock image except the ramdisk segment, `ramdisk_size` and `id`.

### Verification (`verify.sh`, no phone needed)

1. A no-op splice (stock image + its own ramdisk) is byte-identical to stock.
2. New image vs stock: only `ramdisk_size`, `id` and the ramdisk differ; kernel, DT (Samsung
   DTBH table, 303104 bytes), second and all other header fields identical.
3. The ramdisk is LZMA like stock; the cpio has all 3541 stock entries unchanged plus the 14
   additions above, nothing else; TWRP's own `ramdisk-files.sha256sum` still verifies.
4. Size fits RECOVERY: 68149248 bytes (`BOARD_RECOVERYIMAGE_PARTITION_SIZE` in LineageOS
   `android_device_samsung_universal9810-common`).
5. Binaries are static aarch64 ELF (no PT_INTERP/DT_NEEDED); scripts pass shellcheck.

`tests/test-scion.sh` exercises `scion` itself under mksh in a privileged Alpine container: a
GPT disk on a loop device with BOOT/RECOVERY/EFS/SYSTEM/USERDATA (so the kernel reports
PARTNAME as on the phone), the shipped aarch64 tools under qemu-user, real FUSE mounts of
APFS test images. `tests/test-apfsprogs.sh` makes, checks and corrupts an APFS image with the
shipped mkapfs/apfsck.

## Flashing and recovery

See [RESTORE.md](RESTORE.md): flashing from TWRP by partition name, from a Mac with heimdall,
and putting stock TWRP back from Download mode if Scion recovery doesn't boot.

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
  (musl fixes, apfs-extract). Complete source: `apfs-fuse-src-66b86bd-patched.tar.gz`.
  Statically linked: libfuse 3.16.2 (LGPL-2.1, `fuse-3.16.2.tar.gz`), zlib, bzip2 1.0.8, lzfse,
  musl 1.2.5, libstdc++/libgcc 13.2 (GPL-3 with the runtime exception).
- **apfsprogs** (mkapfs, apfsck, apfs-label, apfs-snap): GPL-2.0,
  https://github.com/linux-apfs/apfsprogs at 1bd1c1c2140d13d1b6d2e03379316572bee70aa3,
  unmodified (built with `-D_GNU_SOURCE -Dloff_t=off_t` for musl). `apfsprogs-1bd1c1c.tar.gz`.
- `scion`, `scion-bootlogs`, the build scripts: ours, GPL-2.0 like the rest of the image.

Anyone who redistributes `scion-recovery.img` must pass these sources (or a written offer)
along with it.

## Not done (yet)

Read-write APFS in the kernel (linux-apfs-rw built into a rebuilt TWRP kernel) was planned as
phase 2 and was dropped: it means replacing TWRP's kernel, and booting reliably matters more.
apfs-fuse is read-only; `mkapfs` can still make a fresh container.
