#!/bin/sh
# SPDX-License-Identifier: MIT-0
# Runs inside alpine:3.20 (x86_64). Cross compiles static aarch64 wpa_supplicant,
# wpa_cli (hostap) and curl (OpenSSL) with clang against an aarch64 Alpine sysroot,
# and copies Alpine's CA bundle and static busybox (for udhcpc). Sources: /w/src/wpa_supplicant-*.tar.gz, /w/src/curl-*.tar.xz
# (fetched and hash-checked by the workflow, versions in SOURCE). Output: /w/bin/aarch64.
set -eux
OUT=/w/bin/aarch64
apk add --no-cache build-base clang lld llvm pkgconf perl linux-headers ca-certificates >/dev/null
SR=/sysroot-a64
if [ ! -e $SR/lib/ld-musl-aarch64.so.1 ]; then
  mkdir -p $SR/etc/apk && cp -r /etc/apk/keys $SR/etc/apk/ && cp /etc/apk/repositories $SR/etc/apk/
  apk --arch aarch64 --root $SR --initdb --no-scripts --allow-untrusted add musl-dev gcc linux-headers \
    libnl3-dev libnl3-static openssl-dev openssl-libs-static zlib-dev zlib-static busybox-static >/dev/null
fi
GCCV=$(ls $SR/usr/lib/gcc/aarch64-alpine-linux-musl/)
T=aarch64-alpine-linux-musl
CC="clang --target=$T --sysroot=$SR"
LDF="-fuse-ld=lld -static --rtlib=libgcc -L$SR/usr/lib/gcc/$T/$GCCV"
export PKG_CONFIG_SYSROOT_DIR=$SR PKG_CONFIG_LIBDIR=$SR/usr/lib/pkgconfig
mkdir -p $OUT /tmp/b

# --- wpa_supplicant, wpa_cli: nl80211, WPA/WPA2/WPA3-Personal, control socket ---
cd /tmp/b && rm -rf wpa_supplicant-* && tar xzf /w/src/wpa_supplicant-*.tar.gz && cd wpa_supplicant-*/wpa_supplicant
cat > .config <<EOC
CONFIG_DRIVER_NL80211=y
CONFIG_LIBNL32=y
CONFIG_CTRL_IFACE=y
CONFIG_BACKEND=file
CONFIG_TLS=openssl
CONFIG_SAE=y
CONFIG_IEEE80211W=y
CONFIG_IEEE80211N=y
CONFIG_IEEE80211AC=y
CONFIG_NO_RANDOM_POOL=y
CONFIG_GETRANDOM=y
CONFIG_ELOOP_POLL=y
EOC
make -j"$(nproc)" CC="$CC" LDFLAGS="$LDF" PKG_CONFIG=pkg-config \
  EXTRA_CFLAGS="-Os -I$SR/usr/include/libnl3" wpa_supplicant wpa_cli
cp wpa_supplicant wpa_cli $OUT/

# --- curl: HTTPS (OpenSSL), resume (-C -), no other protocols ---
cd /tmp/b && rm -rf curl-* && tar xJf /w/src/curl-*.tar.xz && cd curl-*/
./configure --host=$T CC="$CC" LDFLAGS="$LDF" CFLAGS="-Os" --disable-shared --enable-static \
  --with-openssl="$SR/usr" --with-zlib="$SR/usr" --without-libpsl --without-brotli --without-zstd \
  --without-nghttp2 --without-libidn2 --disable-ldap --disable-rtsp --disable-dict --disable-telnet \
  --disable-tftp --disable-pop3 --disable-imap --disable-smtp --disable-gopher --disable-mqtt \
  --disable-smb --disable-manual --disable-docs --with-ca-bundle=/etc/scion/cacert.pem >/dev/null
make -j"$(nproc)" LDFLAGS="$LDF -all-static" >/dev/null
cp src/curl $OUT/
llvm-strip $OUT/wpa_supplicant $OUT/wpa_cli $OUT/curl
cp /etc/ssl/certs/ca-certificates.crt $OUT/cacert.pem
# udhcpc (TWRP's busybox has none): Alpine's static aarch64 busybox, used only as udhcpc
cp $SR/bin/busybox.static $OUT/scion-busybox
file $OUT/* || true
ls -l $OUT
