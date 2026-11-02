#!/bin/sh
# Build hfsfuse and hfsdump (github.com/0x09/hfsfuse, tag 0.469) as
# static-pie aarch64 musl executables: clang cross compiling against an
# aarch64 Alpine sysroot, like apfs-fuse (third_party/apfs-fuse/).
#
#   docker run --rm --platform linux/amd64 -v $PWD:/w alpine:3.20 sh /w/build-in-alpine.sh
#
# with $PWD holding this script and hfsfuse-0.469.tar.gz (git archive of the
# tag plus src/version.h, as shipped in out/sources/). Writes $PWD/bin/aarch64/.
# FUSE 3 (libfuse 3.16.2 from Alpine, LGPL-2.1) and zlib are linked in
# statically; hfsfuse's bundled ublio, utf8proc, LZVN and LZFSE are used.
# hfstar is not built: it needs libarchive, and Alpine's static liblz4 (which
# that pulls in) holds GCC LTO objects that clang/lld cannot link.
set -eux
W=${W:-/w}
SRC=$W/hfsfuse-0.469.tar.gz
OUT=$W/bin/aarch64
apk add --no-cache clang lld llvm make file >/dev/null

SR=/sysroot-a64
if [ ! -e $SR/lib/ld-musl-aarch64.so.1 ]; then
	mkdir -p $SR/etc/apk && cp -r /etc/apk/keys $SR/etc/apk/ && cp /etc/apk/repositories $SR/etc/apk/
	apk --arch aarch64 --root $SR --initdb --no-scripts --allow-untrusted add \
		musl-dev gcc linux-headers fuse3-dev fuse3-static zlib-dev zlib-static >/dev/null
fi
GCCV=$(ls $SR/usr/lib/gcc/aarch64-alpine-linux-musl/)
# Linker choice and libgcc in CC itself: the bundled libraries' Makefiles link
# a shared utf8proc and an lzfse command line tool of their own.
CC="clang --target=aarch64-alpine-linux-musl --sysroot=$SR -Qunused-arguments -fuse-ld=lld --rtlib=libgcc -L$SR/usr/lib/gcc/aarch64-alpine-linux-musl/$GCCV"
LDF="-static-pie"

rm -rf /tmp/hb && mkdir -p /tmp/hb && cd /tmp/hb
tar xzf "$SRC" && cd hfsfuse-0.469
# The bundled libraries first, without the static link flags (utf8proc's
# Makefile also links a shared object); LZFSE's Makefile runs a bare "ld -r".
MK="make -j$(nproc) CC=\"$CC\" AR=llvm-ar RANLIB=llvm-ranlib LD=ld.lld CONFIG_CFLAGS=\"-O2 -fPIE\""
eval "$MK lib"
eval "$MK LDFLAGS=\"$LDF\" FUSE_LIB=\"-lfuse3 -lpthread\" HAVE_LIBARCHIVE=0 hfsfuse hfsdump"
mkdir -p "$OUT"
cp hfsfuse hfsdump "$OUT/"
llvm-strip "$OUT"/hfsfuse "$OUT"/hfsdump
file "$OUT"/*
(cd "$OUT" && sha256sum hfsfuse hfsdump > SHA256SUMS && cat SHA256SUMS)
