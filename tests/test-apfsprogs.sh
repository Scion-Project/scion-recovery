#!/bin/sh
# Runs inside alpine (docker). Tests the aarch64 apfsprogs under qemu-user.
set -u
apk add --no-cache qemu-aarch64 >/dev/null 2>&1
Q=qemu-aarch64; B=${B:-/w/build/apfsprogs-aarch64}; A=/apfs/bin/aarch64
truncate -s 256M /tmp/t.img
$Q $B/mkapfs -L ScionTest /tmp/t.img; echo mkapfs rc=$?
$Q $B/apfsck /tmp/t.img; echo apfsck rc=$?
$Q $B/apfs-label /tmp/t.img; echo label rc=$?
if [ -x $A/apfs-extract ]; then $Q $A/apfs-extract /tmp/t.img vols; echo extract rc=$?; fi
# corrupt a block in the middle and make sure fsck notices
printf 'garbagegarbage' | dd of=/tmp/t.img bs=1 seek=$((4096*1+64)) conv=notrunc 2>/dev/null
$Q $B/apfsck /tmp/t.img >/dev/null 2>&1; echo apfsck-after-corruption rc=$? '(expect nonzero)'
