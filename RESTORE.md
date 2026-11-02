# Flashing Scion recovery, and getting stock TWRP back

Phone: Samsung Galaxy S9, SM-G960F (starlte, Exynos 9810), bootloader already OEM-unlocked
with TWRP in RECOVERY. Nothing here touches the bootloader, EFS, PARAM or BOOT.

Files (from `out/`, check them first):

    shasum -a 256 scion-recovery.img twrp-3.7.0_9-0-starlte.img
    # compare with out/SHA256SUMS. Stock TWRP must be
    # 905f81903849a5b981fe8915c91d2ba025358f79324e2427c2b704a4f9e46a4e  twrp-3.7.0_9-0-starlte.img
    # (the hash dl.twrp.me publishes; its GPG signature is by TeamWin, key 9570 7D42 307C 9D41 D09B F709 1D85 97D7 891A 43DF)

Key combos (phone off; on the S9 "off" means: hold Vol Down + Power ~7 s to force a restart,
then switch to the next combo as soon as the screen goes black):

- Download mode: Vol Down + Bixby + Power (or Vol Down + Bixby, then plug the USB cable in).
  At the blue warning screen press Vol Up to continue. Download mode lives in the bootloader,
  which we never write, so it is always there whatever RECOVERY or BOOT hold.
- Recovery: Vol Up + Bixby + Power, let go when the Samsung logo shows.

## A. Flash Scion recovery from TWRP (normal way, phone in TWRP, adb working)

    adb push scion-recovery.img /tmp/
    # 1. keep a copy of what is in RECOVERY now
    adb shell 'dd if=/dev/block/platform/11120000.ufs/by-name/RECOVERY of=/tmp/recovery-before.img bs=4096'
    adb pull /tmp/recovery-before.img
    # 2. write RECOVERY by name, then read it back
    adb shell 'sha256sum /tmp/scion-recovery.img'
    adb shell 'dd if=/tmp/scion-recovery.img of=/dev/block/platform/11120000.ufs/by-name/RECOVERY bs=4096 conv=fsync && sync'
    adb shell 'head -c $(stat -c %s /tmp/scion-recovery.img) /dev/block/platform/11120000.ufs/by-name/RECOVERY | sha256sum'
    # the two sha256 lines must be identical; then
    adb reboot recovery

TWRP's GUI does the same: Install > Install Image > pick scion-recovery.img > Recovery.
(`/dev/block/by-name/RECOVERY` may also exist; the platform path above always does in TWRP.)

Once in Scion recovery: `adb shell scion info`, and the previous run's logs are already in
`/tmp/scion-boot` (`adb pull /tmp/scion-boot`).

## B. Flash Scion recovery from a Mac with heimdall (Download mode)

    heimdall detect
    heimdall print-pit --no-reboot | grep -B2 -A12 'Partition Name: RECOVERY'   # name check, optional
    heimdall flash --RECOVERY scion-recovery.img --no-reboot --resume          # --resume only after print-pit

Then leave Download mode straight into recovery: hold Vol Down + Power until the screen
goes black, then at once Vol Up + Bixby + Power.

Odin (Windows) alternative: `out/scion-recovery.tar` (contains `recovery.img`) in the AP slot,
Auto Reboot unticked.

## C. It doesn't boot: put stock TWRP back (macOS, heimdall)

Symptoms: the Vol Up + Bixby + Power combo shows a bootloop, a black screen, or "No command".
BOOT (HakiOS) and Download mode are not affected by RECOVERY.

1. Force the phone off: Vol Down + Power for ~7 s.
2. As soon as the screen goes black: Vol Down + Bixby + Power, then Vol Up at the warning
   screen. The screen says "Downloading... Do not turn off target".
3. On the Mac (USB cable to the phone):

       heimdall detect
       heimdall flash --RECOVERY twrp-3.7.0_9-0-starlte.img --no-reboot

   If heimdall prints "ERROR: Failed to receive session end confirmation" after the upload
   reached 100%, the write already happened; that message is a known heimdall/Samsung quirk.
   If it fails before 100%: unplug, force off, enter Download mode again, and retry.
   If an earlier heimdall command in this Download-mode session used `--no-reboot` (for
   example `print-pit --no-reboot`), add `--resume` to the flash command; if it still fails,
   restart Download mode and run only the flash command.
4. Vol Down + Power until black, then at once Vol Up + Bixby + Power: stock TWRP 3.7.0 comes up.
5. If you made `recovery-before.img` in step A, that file works in place of the stock image:
   `heimdall flash --RECOVERY recovery-before.img --no-reboot`.

Getting heimdall on macOS: `brew install heimdall` (the maintained fork by Grimler,
https://git.sr.ht/~grimler/Heimdall; the old Glass Echidna 1.4.2 build doesn't work on recent
macOS). No driver is needed on macOS.

Note on stock Android: if Samsung's stock Android is ever booted with a stock BOOT, it can put
back Samsung's own recovery. That does not happen with HakiOS in BOOT. If it does, just repeat
B or C.

## What is safe and what is not

- Writing RECOVERY can never brick the phone: Download mode is in the bootloader (SBOOT),
  which none of this touches.
- Don't flash anything to EFS, PARAM, BOTA*, SBOOT/CM/UP_PARAM. `scion flash` refuses every
  partition except BOOT, and checks the kernel's own partition name before writing.
