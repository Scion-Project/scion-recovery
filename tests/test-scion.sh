#!/bin/sh
# Host-side test of overlay/sbin/scion, run inside a privileged Alpine container:
#
#   docker run --rm --privileged -v REPO:/r -v BINS:/b -v APFSIMG_DIR:/t alpine:3.20 sh /r/tests/test-scion.sh
#
# /b holds the aarch64 binaries from the ramdisk (run under qemu-aarch64),
# /t/t.raw.gz an APFS container with private/var/mobile/Library/Logs/CrashReporter.
# It makes a GPT disk on a loop device with BOOT, RECOVERY, EFS and USERDATA
# partitions (the kernel then reports PARTNAME= for each, as on the phone),
# and runs scion with mksh, TWRP's /sbin/sh.
set -u
apk add --no-cache mksh sgdisk util-linux qemu-aarch64 fuse3 >/dev/null 2>&1
pass=0; failn=0
t() { if "$@"; then pass=$((pass + 1)); echo "  ok: $T"; else failn=$((failn + 1)); echo "  FAIL: $T"; fi; }

# aarch64 tools behind qemu wrappers, in a dir ahead of the system's in PATH.
mkdir -p /sbin
for b in apfs-fuse apfs-extract apfsutil mkapfs apfsck; do
	printf '#!/bin/sh\nexec qemu-aarch64 /b/%s "$@"\n' "$b" > "/sbin/$b"; chmod +x "/sbin/$b"
done

D=/tmp/disk.img
truncate -s 160M $D
sgdisk -n1:0:+16M -c1:BOOT -n2:0:+16M -c2:RECOVERY -n3:0:+4M -c3:EFS -n4:0:+8M -c4:SYSTEM -n5:0:0 -c5:USERDATA $D >/dev/null
L=$(losetup -fP --show $D)
for i in 1 2 3 4 5; do
	n=${L##*/}p$i
	[ -b /dev/$n ] || mknod /dev/$n b $(tr ':' ' ' < /sys/class/block/$n/dev)
done
mkdir -p /dev/block /tmp/byname
for i in 1 2 3 4 5; do ln -sf /dev/${L##*/}p$i /dev/block/${L##*/}p$i; done
for p in 1:BOOT 2:RECOVERY 3:EFS 4:SYSTEM 5:USERDATA; do ln -sf "/dev/block/${L##*/}p${p%%:*}" "/tmp/byname/${p#*:}"; done
grep -h PARTNAME /sys/class/block/${L##*/}p*/uevent
zcat /t/t.raw.gz | dd of=/tmp/byname/USERDATA bs=1M conv=fsync 2>/dev/null

export SCION_BLOCKDIRS=/tmp/byname SCION_MNT=/tmp/scion SCION_LOGDIR=/tmp/scion-logs
S="mksh /r/overlay/sbin/scion"

echo "== info"; $S info
echo "== flash refusals"
head -c 1048576 /dev/urandom > /tmp/rnd.bin
{ printf 'ANDROID!'; head -c 2097144 /dev/urandom; } > /tmp/good.img
{ printf 'ANDROID!'; head -c 20000000 /dev/zero; } > /tmp/big.img
dd if=/dev/zero of=/tmp/byname/RECOVERY bs=1M count=16 2>/dev/null
for p in RECOVERY recovery EFS USERDATA BOTA PARAM "BOOT2" "../BOOT"; do
	T="refuses partition '$p'"; t sh -c "! $S flash /tmp/good.img '$p' 2>/dev/null"
done
T="RECOVERY still all zero after the refusals"; t sh -c '[ "$(head -c 16777216 /tmp/byname/RECOVERY | tr -d "\0" | wc -c)" -eq 0 ]'
T="refuses a file that is not an Android boot image"; t sh -c "! $S flash /tmp/rnd.bin 2>/dev/null"
T="refuses an image larger than BOOT"; t sh -c "! $S flash /tmp/big.img 2>/dev/null"
T="refuses a missing file"; t sh -c "! $S flash /tmp/nonexistent.img 2>/dev/null"
# A BOOT link that really points at RECOVERY must be refused by the PARTNAME check.
ln -sf "/dev/block/${L##*/}p2" /tmp/byname/BOOT
T="refuses when by-name/BOOT resolves to the RECOVERY partition"; t sh -c "! $S flash /tmp/good.img"
T="RECOVERY still all zero"; t sh -c '[ "$(head -c 16777216 /tmp/byname/RECOVERY | tr -d "\0" | wc -c)" -eq 0 ]'
ln -sf "/dev/block/${L##*/}p1" /tmp/byname/BOOT
echo "== flash BOOT"
T="flashes BOOT with matching read-back"; t sh -c "$S flash /tmp/good.img | tee /dev/stderr | grep -q 'read-back OK'"
T="BOOT holds the image"; t sh -c "[ \"\$(head -c $(wc -c < /tmp/good.img) /tmp/byname/BOOT | sha256sum | cut -c1-64)\" = \"\$(sha256sum < /tmp/good.img | cut -c1-64)\" ]"
T="RECOVERY untouched by the flash"; t sh -c '[ "$(head -c 16777216 /tmp/byname/RECOVERY | tr -d "\0" | wc -c)" -eq 0 ]'

echo "== mountvar / pull"
T="mountvar mounts USERDATA and links /scion/var"; t sh -c "$S mountvar"
T="/scion/var has the CrashReporter dir"; t test -d /tmp/scion/var/mobile/Library/Logs/CrashReporter
grep fuse /proc/mounts
T="mountvar again is idempotent"; t sh -c "$S mountvar"
T="pull makes a tarball with the .ips files"; t sh -c "$S pull && tar -tzf /tmp/scion-logs/crashreporter-*.tar.gz | grep -q '\.ips$'"
T="umountvar"; t sh -c "$S umountvar && ! grep -q /tmp/scion/apfs /proc/mounts"
rm -f /tmp/scion-logs/crashreporter-*.tar.gz
mv /sbin/apfs-fuse /sbin/apfs-fuse.off
T="pull without FUSE falls back to apfs-extract"; t sh -c "$S pull && tar -tzf /tmp/scion-logs/crashreporter-*.tar.gz | grep -q '\.ips$'"
mv /sbin/apfs-fuse.off /sbin/apfs-fuse
tar -tzf /tmp/scion-logs/crashreporter-*.tar.gz | head -5

echo "== var on SYSTEM (HakiOS mkapfs.py image: System vol 0, Data vol 1), USERDATA not APFS"
dd if=/dev/zero of=/tmp/byname/USERDATA bs=1M count=8 conv=fsync 2>/dev/null
zcat /t/hak.apfs.gz | dd of=/tmp/byname/SYSTEM bs=1M conv=fsync 2>/dev/null
rm -f /tmp/scion-logs/crashreporter-*.tar.gz
T="mountvar finds the Data volume on SYSTEM"; t sh -c "$S mountvar | tee /dev/stderr | grep -q 'SYSTEM .* volume 1 mounted'"
T="/scion/var/mobile/.../CrashReporter/test-1.ips readable (decompressed)"; t sh -c "cat /tmp/scion/var/mobile/Library/Logs/CrashReporter/test-1.ips | tee /dev/stderr | grep -q ."
T="pull from it"; t sh -c "$S pull >/dev/null && tar -tzf /tmp/scion-logs/crashreporter-*.tar.gz | grep -q test-2.ips"
$S umountvar >/dev/null

echo "== logs"
# A fake device tree with the reserved-memory log regions as on the S9.
DT=/tmp/dt/reserved-memory; mkdir -p $DT/log_pstore@fed10000 $DT/log_kernel@f9000000 $DT/modem_if
printf '\0\0\0\2' > "$DT/#address-cells"; printf '\0\0\0\1' > "$DT/#size-cells"
printf '\0\0\0\0\376\321\0\0\0\0\200\0' > $DT/log_pstore@fed10000/reg
printf '\0\0\0\0\371\0\0\0\0\40\0\0' > $DT/log_kernel@f9000000/reg
printf '\0\0\0\0\361\0\0\0\0\200\0\0' > $DT/modem_if/reg
T="logs writes a dir and a tarball"; t sh -c "SCION_DT=/tmp/dt $S logs | tee /dev/stderr | grep -q 'archive:'"
cat /tmp/scion-logs/*/reserved-log-regions.txt
T="log regions parsed (pstore at 0xfed10000, 32 KB)"; t grep -q 'log_pstore@fed10000 addr=0x00000000fed10000 size=0x00008000' /tmp/scion-logs/*/reserved-log-regions.txt
T="non-log regions skipped"; t sh -c '! grep -q modem /tmp/scion-logs/*/reserved-log-regions.txt'
T="boot mode writes /tmp/scion-boot"; t sh -c "mksh /r/overlay/sbin/scion logs --boot /tmp/scion-boot >/dev/null && [ -d /tmp/scion-boot ]"
T="help"; t sh -c "$S help | grep -q 'scion flash IMG'"
T="unknown command exits 2"; t sh -c "$S frobnicate >/dev/null 2>&1; [ \$? -eq 2 ]"
T="also runs under busybox ash"; t sh -c "sh /r/overlay/sbin/scion version | grep -q 'scion 1'"

losetup -d "$L"
echo "passed $pass, failed $failn"
[ $failn -eq 0 ]
