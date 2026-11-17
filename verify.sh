#!/bin/bash
# SPDX-License-Identifier: MIT-0
# Verify a build without a phone. Run after build.sh with the same WORK/OUT.
#  1. A no-op splice (stock image + its own ramdisk) is byte-identical to stock.
#  2. scion-recovery.img vs stock: only ramdisk_size, id and the ramdisk differ;
#     kernel, DT, second and all other header fields are identical.
#  3. The new ramdisk is LZMA like stock; its cpio holds every stock entry
#     unchanged (mode, owner, links, content) plus our additions, and nothing
#     else, except the theme files under twres/ that scripts/theme.py replaces
#     (content only: mode and owner as stock), which must be exactly the files
#     a fresh theme.py run makes, and pass theme.py lint.
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
	sbin/hfsfuse sbin/hfsdump scion scion/apfs scion/hfs twres/scion.xml etc/scion-partitions.conf \
	--allow-changed twres/ui.xml twres/portrait.xml twres/splash.xml twres/images etc/recovery.fstab \
	| tee cpiodiff.txt | grep -vE "^(ADDED|REPLACED)" || true
grep -E "^(ADDED|REPLACED)" cpiodiff.txt
if tail -1 cpiodiff.txt | grep -q "problems 0"; then ok "stock entries unchanged except the theme's twres files; additions only"; else bad "cpio diff"; fi
rm -rf rdx && mkdir rdx && (cd rdx && cpio -id --quiet < ../new/ramdisk.cpio 2>/dev/null) || true
# The replaced theme files are exactly what theme.py makes from the stock ones.
rm -rf theme-check && mkdir theme-check
python3 "$HERE/scripts/theme.py" apply stock/rd/twres theme-check "$HERE/theme" >/dev/null
if diff -r theme-check rdx/twres | grep -v '^Only in rdx/twres' | grep -q .; then bad "twres differs from a fresh theme.py run"; else ok "twres theme files are exactly theme.py's output"; fi
grep -E "^REPLACED +twres/" cpiodiff.txt | awk '{print $2}' | sed 's|^twres/||' | while read -r f; do [ -f "theme-check/$f" ] || echo "replaced but not made by theme.py: $f"; done | grep . && bad "replaced files" || true
if python3 "$HERE/scripts/theme.py" lint rdx/twres; then ok "theme lint (pages, styles, templates, resources, variables)"; else bad "theme lint"; fi
# Stock's own integrity list must still check out on the new ramdisk for every
# file but the replaced theme files and fstab (TWRP uses it only for its A/B "repack
# ramdisk" feature, which the S9 does not have).
# The write policy: TWRP's fstab agrees with it, and is exactly fstab.py's output.
if python3 "$HERE/scripts/fstab.py" check rdx/etc/scion-partitions.conf rdx/etc/recovery.fstab; then ok "TWRP's fstab agrees with the write policy (no never-list partition, only write-list images flashable)"; else bad "fstab vs policy"; fi
python3 "$HERE/scripts/fstab.py" apply "$HERE/overlay/etc/scion-partitions.conf" stock/rd/etc/recovery.fstab fstab-check
if cmp -s fstab-check rdx/etc/recovery.fstab && cmp -s "$HERE/overlay/etc/scion-partitions.conf" rdx/etc/scion-partitions.conf; then ok "fstab and policy in the image are fstab.py's output and the committed policy"; else bad "fstab/policy differ"; fi
if (cd rdx && grep -vE '  \./(twres/(ui\.xml|portrait\.xml|splash\.xml|images/)|etc/recovery\.fstab)' ramdisk-files.sha256sum | sha256sum -c --quiet -); then ok "TWRP's ramdisk-files.sha256sum verifies except for the replaced theme files and fstab"; else bad "ramdisk-files.sha256sum"; fi

echo "== 4. size"
size=$(stat -c %s "$NEW")
if [ "$size" -le "$RECOVERY_SIZE" ]; then ok "size $size <= RECOVERY $RECOVERY_SIZE ($((RECOVERY_SIZE - size)) bytes spare)"; else bad "size $size > $RECOVERY_SIZE"; fi

echo "== 5. binaries and scripts"
for f in hfsfuse hfsdump apfs-fuse apfs-extract apfsutil mkapfs apfsck apfs-label apfs-snap; do
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
