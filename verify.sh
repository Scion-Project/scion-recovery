#!/bin/bash
# Verify a build without a phone. Run after build.sh with the same WORK/OUT.
#  1. A no-op splice (stock image + its own ramdisk) is byte-identical to stock.
#  2. scion-recovery.img vs stock: only ramdisk_size, id and the ramdisk differ;
#     kernel, DT, second and all other header fields are identical.
#  3. The new ramdisk is LZMA like stock; its cpio holds every stock entry
#     unchanged (mode, owner, links, content) plus our additions, and nothing else.
#  4. The image fits RECOVERY (68149248 bytes).
#  5. The added binaries are static aarch64 ELF; the scripts pass shellcheck.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$(realpath -m "${WORK:-$HERE/work}")
OUT=$(realpath -m "${OUT:-$HERE/out}")
MAGISKBOOT=$(realpath -m "${MAGISKBOOT:-$WORK/magiskboot}")
SHELLCHECK=${SHELLCHECK:-shellcheck}
TWRP_NAME=twrp-3.7.0_9-0-starlte.img
RECOVERY_SIZE=68149248
B="python3 $HERE/scripts/bootimg.py"
fail=0
ok() { echo "PASS: $*"; }
bad() { echo "FAIL: $*"; fail=1; }

cd "$WORK"
STOCK=$WORK/$TWRP_NAME
NEW=$OUT/scion-recovery.img

echo "== 1. no-op splice"
$B replace-ramdisk "$STOCK" stock/ramdisk noop.img
if cmp -s noop.img "$STOCK"; then ok "no-op repack is byte-identical to stock ($(sha256sum < noop.img | cut -c1-16)...)"; else bad "no-op repack differs"; fi
rm -f noop.img

echo "== 2. header and segments"
$B compare "$STOCK" "$NEW" | tee compare.txt
diffs=$(grep -E "DIFFERS" compare.txt | awk '{print $2}' | sort | tr '\n' ' ')
if [ "$diffs" = "id ramdisk ramdisk_size " ]; then ok "only ramdisk, ramdisk_size and id differ"; else bad "unexpected differences: $diffs"; fi
$B info "$NEW" | tee info-new.txt | grep -q "id matches sha1(kernel,ramdisk,second,dt): True" && ok "new id is the mkbootimg SHA-1" || bad "id"

echo "== 3. ramdisk"
rm -rf new && mkdir new
$B extract "$NEW" new
fmt=$("$MAGISKBOOT" decompress new/ramdisk new/ramdisk.cpio 2>&1)
case $fmt in *lzma*) ok "new ramdisk is LZMA (stock: LZMA)";; *) bad "new ramdisk format: $fmt";; esac
python3 "$HERE/scripts/cpiodiff.py" stock/ramdisk.cpio new/ramdisk.cpio --allow-added \
	init.recovery.samsungexynos9810.rc sbin/scion sbin/scion-bootlogs sbin/apfs-fuse sbin/apfs-extract \
	sbin/apfsutil sbin/mkapfs sbin/apfsck sbin/apfs-label sbin/apfs-snap sbin/fsck.apfs sbin/mkfs.apfs \
	scion scion/apfs | tee cpiodiff.txt | grep -vE "^ADDED" || true
grep -E "^ADDED" cpiodiff.txt
if tail -1 cpiodiff.txt | grep -q "problems 0"; then ok "all stock entries unchanged, additions only"; else bad "cpio diff"; fi
# Stock's own integrity list must still check out on the new ramdisk.
rm -rf rdx && mkdir rdx && (cd rdx && cpio -id --quiet < ../new/ramdisk.cpio 2>/dev/null) || true
if (cd rdx && sha256sum -c --quiet ramdisk-files.sha256sum); then ok "TWRP's ramdisk-files.sha256sum still verifies"; else bad "ramdisk-files.sha256sum"; fi

echo "== 4. size"
size=$(stat -c %s "$NEW")
if [ "$size" -le "$RECOVERY_SIZE" ]; then ok "size $size <= RECOVERY $RECOVERY_SIZE ($((RECOVERY_SIZE - size)) bytes spare)"; else bad "size $size > $RECOVERY_SIZE"; fi

echo "== 5. binaries and scripts"
for f in apfs-fuse apfs-extract apfsutil mkapfs apfsck apfs-label apfs-snap; do
	p=rdx/sbin/$f
	if python3 "$HERE/scripts/elfcheck.py" "$p"; then ok "$f: $(file -b "$p" | cut -d, -f1-2,4)"; else bad "$f is not static aarch64"; fi
done
[ "$(readlink rdx/sbin/fsck.apfs)" = apfsck ] && [ "$(readlink rdx/sbin/mkfs.apfs)" = mkapfs ] && ok "fsck.apfs, mkfs.apfs links" || bad "links"
if "$SHELLCHECK" -s sh rdx/sbin/scion rdx/sbin/scion-bootlogs; then ok "shellcheck clean: scion, scion-bootlogs"; else bad "shellcheck"; fi
head -1 rdx/sbin/scion | grep -qx '#!/sbin/sh' && [ -x rdx/sbin/sh ] && ok "interpreter /sbin/sh exists in the ramdisk" || bad "interpreter"
grep -q '^import /init.recovery.${ro.hardware}.rc' rdx/init.rc && ok "stock init.rc imports init.recovery.\${ro.hardware}.rc" || bad "import"
grep -q 'samsungexynos9810' rdx/ueventd.samsungexynos9810.rc 2>/dev/null || ls rdx/fstab.samsungexynos9810 >/dev/null && ok "ro.hardware is samsungexynos9810 (fstab/ueventd names)"

echo
sha256sum "$STOCK" "$NEW"
if [ $fail -eq 0 ]; then echo "ALL CHECKS PASSED"; else echo "SOME CHECKS FAILED"; exit 1; fi
