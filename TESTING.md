<!-- SPDX-License-Identifier: MIT-0 -->
# Testing Scion recovery on a phone

Nothing in this recovery has been run on a phone yet. This is the order to try it in, from what cannot change
anything to what writes, with what to look for. Each step says what it writes. Stop at the first surprise and
keep `/tmp/recovery.log`, `/tmp/scion-actions.log` and `/tmp/scion-fastbootd.log` (`adb pull`).

**Before anything.** A Galaxy S9 SM-G960F with an unlocked boot loader and TWRP in RECOVERY. Keep stock TWRP
(`twrp-3.7.0_9-0-starlte.img`, sha256 `905f8190...9e46a4e`) and heimdall or Odin at hand: Download mode is how
you go back (RESTORE.md, C). On the project's own test phones, **writing RECOVERY needs the owner's explicit go**:
their standing write allow-list is BOOT and USERDATA.

## 0. Get the image (no phone)

From the latest green run of the build workflow: the `scion-recovery` artifact holds `scion-recovery.img`,
`scion-recovery.tar` and `SHA256SUMS`. Check the hash (`shasum -a 256 -c SHA256SUMS`).

## 1. Flash RECOVERY (writes RECOVERY: the owner's step)

From TWRP over adb (RESTORE.md, A: keeps a copy of the current RECOVERY first and compares hashes), or with
heimdall from Download mode (RESTORE.md, B). Then reboot to recovery (Volume Up + Bixby + Power).

Look for: the Scion splash (logo, "Scion recovery", "Built on TWRP 3.7.0_9-0 by TeamWin"), then the home page:
slate header with the logo, "Scion" with eight buttons, "TWRP" with eight. If the screen stays black or loops:
RESTORE.md, C (stock TWRP back from Download mode; BOOT and USERDATA are not affected).

## 2. Read only (writes nothing)

1. **Phone info**: model SM-G960F, the boot loader version, battery %, partition sizes, what USERDATA holds.
2. **Save logs** > Save the logs of the last run: a `.tar.gz` path in `/tmp/scion-logs`; `adb pull` it.
3. **iOS disks** > Inspect; > Mount iOS's /private/var (if USERDATA holds HFS Plus); > Unmount.
4. **Scion settings** > Show the write policy: "Scion may write: BOOT USERDATA", and both resolved to
   `/dev/block/sdaNN`.
5. Every page's back and home buttons; the console output on each action; the last line `RESULT: OK`.
6. TWRP's own pages: Install (no "Install Image" button), Mount (no EFS, no Modem), Backup (no EFS, no
   Baseband), Settings > brightness and timeout, Reboot (System, Recovery, Download, Power Off),
   Advanced > Terminal, File Manager.
7. Scion settings > Advanced on: Install > Install Image lists **Boot only**. Turn it off again.

From the computer: `adb shell scion facts`, `adb shell scion policy`, `adb shell scion check EFS` (must
refuse), `adb shell scion check BOOT`.

## 3. Copies to the SD card (writes files on the SD card or USB drive only)

Insert an exFAT SD card. **Back up** > Back up BOOT; > Copy EFS (read only); > Back up the iOS root
(when USERDATA holds one). Each file gets a `.sha256`; check one on the computer. Keep the EFS copy private.

## 4. BOOT (writes BOOT)

1. Switch system > Save BOOT now as Android's (or iOS 27's, whatever BOOT holds now): a file in `scion/`.
2. Install iOS > Boot image > pick the same image back: "read-back OK". Reboot: the same system starts.
3. With two boot images in the library: Switch system > Start iOS 27 next (refused with the reason when
   USERDATA does not hold the iOS 27 root), then reboot.

## 5. fastboot (writes BOOT, then USERDATA)

1. **Fastboot** > Start fastboot. The computer: `fastboot devices` lists the phone; `fastboot getvar all`.
   If nothing shows: Fastboot > Status and log, and `/tmp/scion-fastbootd.log` (pull it after Stop). The
   question is whether TWRP's kernel lets the FunctionFS function (`ffs.adb`) be taken over this way.
2. `fastboot flash efs x.img` and `fastboot flash recovery x.img`: both refused, nothing written.
3. `fastboot flash boot BOOT.img` (the image saved in 4): OKAY after "written and read back".
4. Fastboot > Stop fastboot: `adb devices` shows the phone again within a few seconds.
5. Only with a root to install and Android's data not needed: `fastboot flash userdata root-full.img`.
   The client sends it in 256 MiB sparse pieces; time it.

## 6. USERDATA from the SD card (writes USERDATA; erases Android's data)

Install iOS > iOS root image > pick `root-full.img` on an exFAT SD card (with `root-full.img.sha256` beside
it for the up-front check): every 16 pieces a progress line, at the end "every piece read back and
matched". Time it. Back up > Restore with a backup made in 3.

## What to report

The step, what the screen showed, the last lines of the console, and the three logs above. Nothing in them is
private except the EFS copy (never send it) and the serial number in `getprop` output.
