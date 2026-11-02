#!/bin/sh
# Runs inside alpine:latest (x86_64). Builds static x86_64 natively and static
# aarch64 by cross compiling with clang against an aarch64 Alpine sysroot.
set -eux
SRC=/w/src/apfs-fuse
OUT=/w/bin
apk add --no-cache build-base cmake clang lld samurai fuse3-dev fuse3-static zlib-dev zlib-static bzip2-dev bzip2-static linux-headers qemu-aarch64 fuse3 >/dev/null

# --- x86_64 native static ---
rm -rf /tmp/b64 && mkdir -p /tmp/b64 && cd /tmp/b64
cmake -G Ninja -DUSE_FUSE3=ON -DCMAKE_EXE_LINKER_FLAGS="-static" $SRC
ninja apfs-fuse apfsutil apfs-dump apfs-dump-quick apfs-extract
mkdir -p $OUT/x86_64 && cp apfs-fuse apfsutil apfs-dump apfs-dump-quick apfs-extract $OUT/x86_64/ && strip $OUT/x86_64/*

# --- aarch64 sysroot ---
SR=/sysroot-a64
if [ ! -e $SR/lib/ld-musl-aarch64.so.1 ]; then
  mkdir -p $SR/etc/apk && cp -r /etc/apk/keys $SR/etc/apk/ && cp /etc/apk/repositories $SR/etc/apk/
  apk --arch aarch64 --root $SR --initdb --no-scripts --allow-untrusted add musl-dev gcc g++ libstdc++-dev fuse3-dev fuse3-static zlib-dev zlib-static bzip2-dev bzip2-static linux-headers >/dev/null
fi
GCCV=$(ls $SR/usr/lib/gcc/aarch64-alpine-linux-musl/)
cat > /tmp/a64.cmake <<EOT
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)
set(CMAKE_SYSROOT $SR)
set(CMAKE_C_COMPILER clang)
set(CMAKE_CXX_COMPILER clang++)
set(CMAKE_C_COMPILER_TARGET aarch64-alpine-linux-musl)
set(CMAKE_CXX_COMPILER_TARGET aarch64-alpine-linux-musl)
set(CMAKE_EXE_LINKER_FLAGS_INIT "-fuse-ld=lld -static --rtlib=libgcc -L$SR/usr/lib/gcc/aarch64-alpine-linux-musl/$GCCV")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
EOT
rm -rf /tmp/ba && mkdir -p /tmp/ba && cd /tmp/ba
cmake -G Ninja -DUSE_FUSE3=ON -DCMAKE_TOOLCHAIN_FILE=/tmp/a64.cmake $SRC
ninja apfs-fuse apfsutil apfs-dump apfs-dump-quick apfs-extract
mkdir -p $OUT/aarch64 && cp apfs-fuse apfsutil apfs-dump apfs-dump-quick apfs-extract $OUT/aarch64/
llvm-strip $OUT/aarch64/* 2>/dev/null || strip $OUT/aarch64/* || true
file $OUT/*/* 2>/dev/null || true
ls -l $OUT/*/
qemu-aarch64 $OUT/aarch64/apfs-extract 2>&1 | head -3 || true
qemu-aarch64 $OUT/aarch64/apfs-fuse 2>&1 | head -3 || true
