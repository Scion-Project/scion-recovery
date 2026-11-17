#!/bin/bash
# SPDX-License-Identifier: MIT-0
# Build scion-fastbootd (fastbootd/scion-fastbootd.c) as a static aarch64 musl
# executable with zig cc, the same pinned zig as scripts/build-apfsprogs.sh.
#   scripts/build-fastbootd.sh [OUTDIR]     (default ./work/fastbootd-aarch64)
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(realpath -m "${WORK:-$HERE/work}")
OUT=${1:-$WORK/fastbootd-aarch64}
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
export ZIG_GLOBAL_CACHE_DIR=$WORK/.zigcache ZIG_LOCAL_CACHE_DIR=$WORK/.zigcache
"$ZIG" cc -target aarch64-linux-musl -O2 -static -s -Wall -Wextra -Wno-format-truncation \
	-o "$OUT/scion-fastbootd" "$HERE/fastbootd/scion-fastbootd.c"
(cd "$OUT" && sha256sum scion-fastbootd > SHA256SUMS && cat SHA256SUMS)
file "$OUT/scion-fastbootd" 2>/dev/null || true
