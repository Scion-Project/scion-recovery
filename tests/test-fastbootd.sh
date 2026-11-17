#!/bin/sh
# SPDX-License-Identifier: MIT-0
# Host test of scion-fastbootd with the real fastboot client (Android
# platform-tools: Debian/Ubuntu's "fastboot" package) over TCP, against fake
# partitions laid out like the S9's (plain files, a fake /sys/class/block with
# each one's PARTNAME). No root, no USB, no phone: the USB (FunctionFS) side
# is NOT exercised here.
#
#   tests/test-fastbootd.sh [path/to/scion-fastbootd]   (default: builds one with cc)
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
W=$(mktemp -d "${TMPDIR:-/tmp}/scion-fastbootd.XXXXXX")
D=""
trap '[ -n "$D" ] && kill "$D" 2>/dev/null; rm -rf "$W"' EXIT
command -v fastboot >/dev/null || { echo "no fastboot client (apt-get install fastboot)"; exit 1; }
command -v img2simg >/dev/null || { echo "no img2simg (apt-get install android-sdk-libsparse-utils)"; exit 1; }
B=${1:-}
if [ -z "$B" ]; then
	B=$W/scion-fastbootd
	cc -O2 -Wall -Wextra -Wno-format-truncation -o "$B" "$HERE/fastbootd/scion-fastbootd.c" -lpthread || exit 1
fi
pass=0; failn=0
t() { if "$@" >"$W/out" 2>&1; then pass=$((pass + 1)); echo "  ok: $T"; else failn=$((failn + 1)); echo "  FAIL: $T"; sed 's/^/      /' "$W/out"; fi; }
nt() { if "$@" >"$W/out" 2>&1; then failn=$((failn + 1)); echo "  FAIL (it succeeded): $T"; sed 's/^/      /' "$W/out"; else pass=$((pass + 1)); echo "  ok: $T"; fi; }
h() { sha256sum < "$1" | cut -c1-64; }
hb() { head -c "$2" "$1" | sha256sum | cut -c1-64; }

mkdir -p "$W/dev" "$W/sys" "$W/byname"
n=0
for p in BOOT:4096 RECOVERY:4096 EFS:1024 RADIO:2048 PARAM:512 BOTA0:256 SYSTEM:8192 VENDOR:2048 USERDATA:40960; do
	n=$((n + 1)); name=${p%%:*}; kib=${p#*:}
	head -c $((kib * 1024)) /dev/urandom > "$W/dev/sda$n"
	mkdir -p "$W/sys/sda$n"
	printf 'DEVNAME=sda%d\nPARTNAME=%s\n' "$n" "$name" > "$W/sys/sda$n/uevent"
	ln -s "$W/dev/sda$n" "$W/byname/$name"
done
protected="RECOVERY EFS RADIO PARAM BOTA0 SYSTEM VENDOR"
for p in $protected; do h "$W/byname/$p" > "$W/before-$p"; done

PORT=$((20000 + $$ % 20000))
SCION_POLICY="$HERE/overlay/etc/scion-partitions.conf" SCION_BLOCKDIRS="$W/byname" SCION_SYSBLOCK="$W/sys" \
	SCION_LOCK="$W/lock" SCION_ACTLOG="$W/actions.log" SCION_MAX_DOWNLOAD=2097152 \
	"$B" --tcp "$PORT" --no-reboot --ready "$W/ready" > "$W/daemon.log" 2>&1 &
D=$!
i=0; while [ ! -f "$W/ready" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
F="fastboot -s tcp:127.0.0.1:$PORT"
echo "== getvar"
T="getvar product"; t sh -c "$F getvar product 2>&1 | grep -q 'product: '"
T="getvar is-userspace: yes"; t sh -c "$F getvar is-userspace 2>&1 | grep -q 'is-userspace: yes'"
T="getvar max-download-size: 0x200000"; t sh -c "$F getvar max-download-size 2>&1 | grep -q 'max-download-size: 0x200000'"
T="getvar partition-size:boot: 0x400000"; t sh -c "$F getvar partition-size:boot 2>&1 | grep -q 'partition-size:boot: 0x400000'"
T="getvar scion-writable:efs: no"; t sh -c "$F getvar scion-writable:efs 2>&1 | grep -q 'scion-writable:efs: no'"
T="getvar scion-writable:userdata: yes"; t sh -c "$F getvar scion-writable:userdata 2>&1 | grep -q 'scion-writable:userdata: yes'"
T="getvar all"; t sh -c "$F getvar all 2>&1 | grep -q 'scion-version'"
T="oem scion-policy"; t sh -c "$F oem scion-policy 2>&1 | grep -q 'may write: BOOT USERDATA'"

echo "== flash boot"
{ printf 'ANDROID!'; head -c 1048568 /dev/urandom; } > "$W/boot.img"
head -c 1048576 /dev/urandom > "$W/rnd.img"
T="flash boot"; t $F flash boot "$W/boot.img"
T="BOOT holds the image"; t test "$(hb "$W/byname/BOOT" 1048576)" = "$(h "$W/boot.img")"
T="the write is in Scion's action log"; t grep -q "fastboot write BOOT" "$W/actions.log"
T="flash boot refuses an image without ANDROID!"; nt $F flash boot "$W/rnd.img"
for p in recovery efs radio param bota0 bota1 sboot rpmb keystorage system vendor odm cache "../boot"; do
	T="flash $p refused"; nt $F flash "$p" "$W/rnd.img"
done
T="refusal names the policy"; t sh -c "$F flash efs $W/rnd.img 2>&1 | grep -q 'never written'"
for p in efs recovery system; do T="erase $p refused"; nt $F erase "$p"; done

echo "== flash userdata (bigger than max-download-size: the client sends sparse pieces)"
# 6 MiB of data with zero and repeated regions, as a raw file and as img2simg's sparse.
python3 - "$W/root.img" <<'PY'
import os, sys
with open(sys.argv[1], "wb") as f:
    f.write(os.urandom(3 << 20)); f.write(b"\0" * (1 << 20)); f.write(b"\xab\xcd\xef\x01" * (1 << 18)); f.write(os.urandom(1 << 20))
PY
T="flash userdata (raw, 6 MiB, max-download 2 MiB)"; t $F flash userdata "$W/root.img"
T="USERDATA holds it"; t test "$(hb "$W/byname/USERDATA" 6291456)" = "$(h "$W/root.img")"
head -c 6291456 /dev/urandom > "$W/root2.raw"
python3 - "$W/root2.raw" <<'PY'
import sys
with open(sys.argv[1], "r+b") as f:
    f.seek(1 << 20); f.write(b"\0" * (2 << 20))
PY
img2simg "$W/root2.raw" "$W/root2.simg"
T="flash userdata (img2simg sparse)"; t $F flash userdata "$W/root2.simg"
T="USERDATA holds it"; t test "$(hb "$W/byname/USERDATA" 6291456)" = "$(h "$W/root2.raw")"
T="sparse pieces were read back"; t grep -q "sparse: .* written and read back" "$W/daemon.log"

echo "== erase"
T="erase boot"; t $F erase boot
T="BOOT is zeros"; t sh -c "[ \"\$(tr -d '\\0' < $W/byname/BOOT | wc -c)\" -eq 0 ]"

echo "== lock and lying links"
sleep 30 & sp=$!
mkdir "$W/lock"; echo $sp > "$W/lock/pid"
T="flash refused while another write holds the lock"; nt $F flash boot "$W/boot.img"
kill $sp; wait $sp 2>/dev/null
T="a stale lock is taken over"; t $F flash boot "$W/boot.img"
T="lock released"; t test ! -e "$W/lock"
ln -sf "$W/dev/sda3" "$W/byname/BOOT"
T="BOOT linked to EFS's device: refused"; nt $F flash boot "$W/boot.img"
ln -sf "$W/dev/sda1" "$W/byname/BOOT"
ln -sf "$W/dev/sda1" "$W/byname/EFS"
T="EFS linked to BOOT's device: BOOT refused"; nt $F flash boot "$W/boot.img"
ln -sf "$W/dev/sda3" "$W/byname/EFS"

echo "== the rest"
T="flashing unlock refused"; nt $F flashing unlock
T="boot refused"; nt $F boot "$W/boot.img"
T="reboot (--no-reboot: answered, logged)"; t $F reboot
T="reboot bootloader (Download mode)"; t sh -c "$F reboot bootloader 2>&1; grep -q 'reboot download' $W/daemon.log"
for p in $protected; do T="$p unchanged"; t test "$(h "$W/byname/$p")" = "$(cat "$W/before-$p")"; done

echo "passed $pass, failed $failn"
[ $failn -eq 0 ] || { echo "--- daemon log"; tail -40 "$W/daemon.log"; }
[ $failn -eq 0 ]
