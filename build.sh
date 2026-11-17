#!/bin/bash
# SPDX-License-Identifier: MIT-0
# Build Scion recovery: stock TWRP 3.7.0_9-0 for starlte (Galaxy S9, SM-G960F)
# with the HFS Plus and APFS tools and the scion helper added to its ramdisk.
#
# Only the ramdisk changes. The kernel, the Exynos DT table, the second stage
# slot and every header field except ramdisk_size and the id (its SHA-1) are
# copied byte for byte from the stock image. The ramdisk is the stock cpio with
# entries added (no stock entry is touched), recompressed as LZMA like stock.
#
#   HFS_BIN=dir APFS_BIN=dir APFSPROGS_BIN=dir ./build.sh
#
#   HFS_BIN        static aarch64 hfsfuse, hfsdump
#                  (third_party/hfsfuse/build-in-alpine.sh)
#   APFS_BIN       static aarch64 apfs-fuse, apfs-extract, apfsutil
#                  (see third_party/apfs-fuse/; built in Alpine/musl)
#   APFSPROGS_BIN  static aarch64 mkapfs, apfsck, apfs-label, apfs-snap
#                  (scripts/build-apfsprogs.sh)
#   WORK, OUT      scratch and output directories (default ./work, ./out)
#   MAGISKBOOT     an x86_64 magiskboot; downloaded from Magisk v31.1 if unset
#
# Then run ./verify.sh.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$(realpath -m "${WORK:-$HERE/work}")
OUT=$(realpath -m "${OUT:-$HERE/out}")
HFS_BIN=${HFS_BIN:?set HFS_BIN to the dir with hfsfuse, hfsdump}
HFS_BIN=$(realpath "$HFS_BIN")
APFS_BIN=${APFS_BIN:?set APFS_BIN to the dir with apfs-fuse, apfs-extract, apfsutil}
APFSPROGS_BIN=${APFSPROGS_BIN:?set APFSPROGS_BIN to the dir with mkapfs, apfsck, apfs-label, apfs-snap}
APFS_BIN=$(realpath "$APFS_BIN")
APFSPROGS_BIN=$(realpath "$APFSPROGS_BIN")

TWRP_NAME=twrp-3.7.0_9-0-starlte.img
TWRP_URL=https://dl.twrp.me/starlte/$TWRP_NAME
TWRP_SHA256=905f81903849a5b981fe8915c91d2ba025358f79324e2427c2b704a4f9e46a4e
MAGISK_URL=https://github.com/topjohnwu/Magisk/releases/download/v31.1/Magisk-v31.1.apk
# Samsung S9 (G960F) RECOVERY partition, from LineageOS universal9810-common
# BoardConfigCommon.mk: BOARD_RECOVERYIMAGE_PARTITION_SIZE := 68149248.
RECOVERY_SIZE=68149248

mkdir -p "$WORK" "$OUT"
cd "$WORK"

# 1. Stock TWRP, verified.
if [ ! -f "$TWRP_NAME" ]; then
	curl -fsSL -H "Referer: https://dl.twrp.me/starlte/$TWRP_NAME.html" -o "$TWRP_NAME.part" "$TWRP_URL"
	mv "$TWRP_NAME.part" "$TWRP_NAME"
fi
echo "$TWRP_SHA256  $TWRP_NAME" | sha256sum -c -

# 2. magiskboot (used only for LZMA and cpio editing).
if [ -n "${MAGISKBOOT:-}" ]; then MAGISKBOOT=$(realpath "$MAGISKBOOT"); fi
if [ -z "${MAGISKBOOT:-}" ]; then
	MAGISKBOOT=$WORK/magiskboot
	if [ ! -x "$MAGISKBOOT" ]; then
		curl -fsSL -o magisk.apk "$MAGISK_URL"
		unzip -o -q -j magisk.apk lib/x86_64/libmagiskboot.so -d .
		mv libmagiskboot.so "$MAGISKBOOT"
		chmod +x "$MAGISKBOOT"
		rm -f magisk.apk
	fi
fi

# 3. Split the stock image.
rm -rf stock && mkdir stock
python3 "$HERE/scripts/bootimg.py" extract "$TWRP_NAME" stock
python3 "$HERE/scripts/bootimg.py" info "$TWRP_NAME" > stock/info.txt
fmt=$("$MAGISKBOOT" decompress stock/ramdisk stock/ramdisk.cpio 2>&1)
case $fmt in *"[lzma]"*|*": lzma"*) ;; *) echo "stock ramdisk is not LZMA ($fmt): stop" >&2; exit 1 ;; esac

# 4. Stock cpio plus our entries. magiskboot edits the archive in place, so
#    every stock entry keeps its mode, owner and content.
cp stock/ramdisk.cpio ramdisk.cpio
O=$HERE/overlay
for f in "$O/sbin/scion" "$O/sbin/scion-bootlogs" "$O/init.recovery.samsungexynos9810.rc"; do
	[ -f "$f" ] || { echo "missing $f" >&2; exit 1; }
done
for b in hfsfuse hfsdump; do [ -f "$HFS_BIN/$b" ] || { echo "missing $HFS_BIN/$b" >&2; exit 1; }; done
for b in apfs-fuse apfs-extract apfsutil; do [ -f "$APFS_BIN/$b" ] || { echo "missing $APFS_BIN/$b" >&2; exit 1; }; done
for b in mkapfs apfsck apfs-label apfs-snap; do [ -f "$APFSPROGS_BIN/$b" ] || { echo "missing $APFSPROGS_BIN/$b" >&2; exit 1; }; done

"$MAGISKBOOT" cpio ramdisk.cpio \
	"add 0750 init.recovery.samsungexynos9810.rc $O/init.recovery.samsungexynos9810.rc" \
	"add 0755 sbin/scion $O/sbin/scion" \
	"add 0755 sbin/scion-bootlogs $O/sbin/scion-bootlogs" \
	"add 0755 sbin/hfsfuse $HFS_BIN/hfsfuse" \
	"add 0755 sbin/hfsdump $HFS_BIN/hfsdump" \
	"add 0755 sbin/apfs-fuse $APFS_BIN/apfs-fuse" \
	"add 0755 sbin/apfs-extract $APFS_BIN/apfs-extract" \
	"add 0755 sbin/apfsutil $APFS_BIN/apfsutil" \
	"add 0755 sbin/mkapfs $APFSPROGS_BIN/mkapfs" \
	"add 0755 sbin/apfsck $APFSPROGS_BIN/apfsck" \
	"add 0755 sbin/apfs-label $APFSPROGS_BIN/apfs-label" \
	"add 0755 sbin/apfs-snap $APFSPROGS_BIN/apfs-snap" \
	"ln apfsck sbin/fsck.apfs" \
	"ln mkapfs sbin/mkfs.apfs" \
	"mkdir 0755 scion" \
	"mkdir 0755 scion/apfs" \
	"mkdir 0755 scion/hfs"

# 5. Same compression as stock (legacy LZMA), then splice into the stock image.
rm -f ramdisk.cpio.lzma
"$MAGISKBOOT" compress=lzma ramdisk.cpio ramdisk.cpio.lzma
python3 "$HERE/scripts/bootimg.py" replace-ramdisk "$TWRP_NAME" ramdisk.cpio.lzma scion-recovery.img

size=$(stat -c %s scion-recovery.img)
if [ "$size" -gt "$RECOVERY_SIZE" ]; then
	echo "scion-recovery.img is $size bytes, RECOVERY is $RECOVERY_SIZE: too big" >&2
	exit 1
fi

cp scion-recovery.img "$OUT/scion-recovery.img"
cp "$TWRP_NAME" "$OUT/$TWRP_NAME"
(cd "$OUT" && sha256sum scion-recovery.img "$TWRP_NAME" > SHA256SUMS && cat SHA256SUMS)
# Odin/heimdall-friendly tar too (Odin wants recovery.img inside a .tar).
(cd "$WORK" && rm -rf odin && mkdir odin && cp scion-recovery.img odin/recovery.img &&
	tar -C odin -cf "$OUT/scion-recovery.tar" recovery.img)
echo "built $OUT/scion-recovery.img ($size bytes, RECOVERY holds $RECOVERY_SIZE)"
