#!/bin/bash
# SPDX-License-Identifier: MIT-0
# Build apfsprogs (mkapfs, apfsck = fsck.apfs, apfs-label, apfs-snap) as static
# aarch64 musl executables with zig cc. GPL-2.0, github.com/linux-apfs/apfsprogs.
#   scripts/build-apfsprogs.sh [OUTDIR]     (default ./work/apfsprogs-aarch64)
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(realpath -m "${WORK:-$HERE/work}")
OUT=${1:-$WORK/apfsprogs-aarch64}
APFSPROGS_COMMIT=${APFSPROGS_COMMIT:-1bd1c1c2140d13d1b6d2e03379316572bee70aa3}
ZIG_VER=0.13.0
ZIG_SHA256=d45312e61ebcc48032b77bc4cf7fd6915c11fa16e4aad116b66c9468211230ea
mkdir -p "$WORK" "$OUT"
cd "$WORK"
ZIG=$(realpath -m "${ZIG:-$WORK/zig-linux-x86_64-$ZIG_VER/zig}")
if [ ! -x "$ZIG" ]; then
	curl -fsSL -o zig.tar.xz "https://ziglang.org/download/$ZIG_VER/zig-linux-x86_64-$ZIG_VER.tar.xz"
	echo "$ZIG_SHA256  zig.tar.xz" | sha256sum -c -
	tar xJf zig.tar.xz && rm zig.tar.xz
fi
[ -d apfsprogs ] || git clone -q https://github.com/linux-apfs/apfsprogs
git -C apfsprogs fetch -q origin && git -C apfsprogs checkout -q "$APFSPROGS_COMMIT"
SRC=$WORK/apfsprogs
export ZIG_GLOBAL_CACHE_DIR=$WORK/.zigcache ZIG_LOCAL_CACHE_DIR=$WORK/.zigcache
cc="$ZIG cc -target aarch64-linux-musl"
for d in lib mkapfs apfsck apfs-label apfs-snap; do make -C "$SRC/$d" clean >/dev/null 2>&1 || true; done
for d in mkapfs apfsck apfs-label apfs-snap; do
	# musl has no loff_t without _GNU_SOURCE in every header; off_t is 64-bit there.
	make -C "$SRC/$d" --no-print-directory CC="$cc" AR="$ZIG ar" \
		CFLAGS="-O2 -D_GNU_SOURCE -Dloff_t=off_t" LDFLAGS="-static -s"
	cp "$SRC/$d/$d" "$OUT/"
done
git -C "$SRC" rev-parse HEAD > "$OUT/SOURCE_COMMIT"
(cd "$OUT" && sha256sum mkapfs apfsck apfs-label apfs-snap > SHA256SUMS)
file "$OUT"/mkapfs "$OUT"/apfsck "$OUT"/apfs-label "$OUT"/apfs-snap
