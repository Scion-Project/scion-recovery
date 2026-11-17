#!/bin/sh
# SPDX-License-Identifier: MIT-0
# Host test of /sbin/scion's write actions and its write policy, against fake
# partitions: plain files under a temporary directory, by-name links to them
# and a fake /sys/class/block with each one's PARTNAME, as the S9's kernel
# reports it. No root, no loop devices, no phone.
#
#   tests/test-actions.sh [SHELL]     (default: mksh, TWRP's /sbin/sh)
#
# What it proves: only BOOT and USERDATA are ever written, whatever name is
# asked for; a by-name link that resolves to another partition (or to a
# "never" partition's device) is refused; hashes are checked before and after
# every write and a mismatch is refused before anything is written; two writes
# cannot overlap; EFS and RADIO are byte for byte the same at the end.
set -u
SH=${1:-mksh}
HERE=$(cd "$(dirname "$0")/.." && pwd)
W=$(mktemp -d "${TMPDIR:-/tmp}/scion-actions.XXXXXX")
trap 'rm -rf "$W"' EXIT
pass=0; failn=0
t() { if "$@" >"$W/out" 2>&1; then pass=$((pass + 1)); echo "  ok: $T"; else failn=$((failn + 1)); echo "  FAIL: $T"; sed 's/^/      /' "$W/out"; fi; }
nt() { if "$@" >"$W/out" 2>&1; then failn=$((failn + 1)); echo "  FAIL (it succeeded): $T"; sed 's/^/      /' "$W/out"; else pass=$((pass + 1)); echo "  ok: $T"; fi; }

# The partition table: name, kernel device name, size in KiB.
mkdir -p "$W/dev" "$W/sys" "$W/byname" "$W/sd" "$W/bin" "$W/proc/sys/vm"
n=0
for p in BOOT:4096 RECOVERY:4096 EFS:1024 SEC_EFS:256 CPEFS:256 RADIO:2048 PARAM:512 BOTA0:256 SYSTEM:8192 VENDOR:2048 USERDATA:16384; do
	n=$((n + 1)); name=${p%%:*}; kib=${p#*:}
	head -c $((kib * 1024)) /dev/urandom > "$W/dev/sda$n"
	mkdir -p "$W/sys/sda$n"
	printf 'MAJOR=8\nMINOR=%d\nDEVNAME=sda%d\nDEVTYPE=partition\nPARTN=%d\nPARTNAME=%s\n' "$n" "$n" "$n" "$name" > "$W/sys/sda$n/uevent"
	ln -s "$W/dev/sda$n" "$W/byname/$name"
done
cp "$HERE/overlay/etc/scion-partitions.conf" "$W/policy"
# A fake hfsdump: "stat PATH" succeeds for the paths listed in $W/hfs-paths.
cat > "$W/bin/hfsdump" <<EOF
#!/bin/sh
[ "\$2" = stat ] && grep -qx "\$3" "$W/hfs-paths" 2>/dev/null
EOF
chmod +x "$W/bin/hfsdump"
: > "$W/hfs-paths"

export SCION_BLOCKDIRS="$W/byname" SCION_SYSBLOCK="$W/sys" SCION_POLICY="$W/policy" \
	SCION_LOCK="$W/lock" SCION_ACTLOG="$W/actions.log" SCION_STORAGE="$W/sd" SCION_STORAGE_ANYDIR=1 \
	SCION_MNT="$W/mnt" SCION_LOGDIR="$W/logs" SCION_PROC="$W/proc" SCION_CHUNK_MB=1
PATH="$W/bin:$PATH"
S="$SH $HERE/overlay/sbin/scion"
h() { sha256sum < "$1" | cut -c1-64; }
hb() { head -c "$2" "$1" | sha256sum | cut -c1-64; }
protected="EFS SEC_EFS CPEFS RADIO PARAM BOTA0 RECOVERY SYSTEM VENDOR"
for p in $protected; do h "$W/byname/$p" > "$W/before-$p"; done
echo "== $SH: policy"

for p in BOOT boot USERDATA; do T="may write $p"; t $S check "$p"; done
for p in EFS efs SEC_EFS CPEFS RADIO PARAM BOTA0 BOTA1 SBOOT CM UP_PARAM KEYSTORAGE STEADY PERSISTENT RPMB RECOVERY SYSTEM VENDOR ODM CACHE "" "../BOOT" "BOOT/../EFS" "BO OT"; do
	T="refuses '$p'"; nt $S check "$p"
done
T="refuses EFS with the 'never' reason"; t sh -c "$S check EFS 2>&1 | grep -q \"on the 'never' list\""
T="refuses SYSTEM with the 'write only' reason"; t sh -c "$S check SYSTEM 2>&1 | grep -q 'Scion writes only: BOOT USERDATA'"
T="ends with RESULT: FAILED"; t sh -c "$S check EFS 2>&1 | tail -1 | grep -q 'RESULT: FAILED'"
T="ends with RESULT: OK"; t sh -c "$S check BOOT | tail -1 | grep -q 'RESULT: OK'"
# A 'never' name wins over a 'write' name.
cp "$W/policy" "$W/policy.save"; echo "write EFS" >> "$W/policy"
T="'never' wins over 'write' (EFS put on a write line)"; nt $S check EFS
cp "$W/policy.save" "$W/policy"
# By-name links that lie.
ln -sf "$W/dev/sda3" "$W/byname/BOOT"
T="refuses BOOT when its link resolves to EFS's device"; nt $S check BOOT
T="... saying PARTNAME is EFS"; t sh -c "$S check BOOT 2>&1 | grep -q \"named 'EFS', not BOOT\""
ln -sf "$W/dev/sda1" "$W/byname/BOOT"
# A device whose PARTNAME says BOOT but that EFS's link also resolves to.
ln -sf "$W/dev/sda1" "$W/byname/EFS"
T="refuses BOOT when EFS's link resolves to the same device"; nt $S check BOOT
ln -sf "$W/dev/sda3" "$W/byname/EFS"
mv "$W/policy" "$W/policy.off"
T="no policy file: every write refused"; nt $S check BOOT
mv "$W/policy.off" "$W/policy"

echo "== $SH: flash (BOOT)"
{ printf 'ANDROID!'; head -c 1048568 /dev/urandom; } > "$W/good.img"
head -c 1048576 /dev/urandom > "$W/rnd.img"
{ printf 'ANDROID!'; head -c 5000000 /dev/zero; } > "$W/big.img"
for p in RECOVERY EFS USERDATA SYSTEM; do T="flash refuses target $p"; nt $S flash "$W/good.img" "$p"; done
T="refuses a file without ANDROID! magic"; nt $S flash "$W/rnd.img"
T="refuses an image larger than BOOT"; nt $S flash "$W/big.img"
echo "0000000000000000000000000000000000000000000000000000000000000000  good.img" > "$W/good.img.sha256"
bootbefore=$(h "$W/byname/BOOT"); bootbefore1=$(hb "$W/byname/BOOT" 1048576)
T="refuses an image whose .sha256 does not match"; nt $S flash "$W/good.img"
T="... and BOOT is unchanged"; t test "$(h "$W/byname/BOOT")" = "$bootbefore"
sha256sum "$W/good.img" | sed "s|$W/||" > "$W/good.img.sha256"
T="writes BOOT when the .sha256 matches"; t sh -c "$S flash $W/good.img | grep -q 'read-back OK'"
T="BOOT holds the image"; t test "$(hb "$W/byname/BOOT" 1048576)" = "$(h "$W/good.img")"
T="BOOT beyond the image untouched"; t test "$(tail -c 3145728 "$W/byname/BOOT" | sha256sum | cut -c1-64)" = "$(tail -c 3145728 "$W/dev/sda1" | sha256sum | cut -c1-64)"
T="the write is in the action log with the old contents' hash"; t grep -q "write BOOT .*before=$bootbefore1" "$W/actions.log"

echo "== $SH: the write lock"
sleep 30 & sp=$!
mkdir "$W/lock"; echo $sp > "$W/lock/pid"; echo "a test write" > "$W/lock/what"
T="refuses while another write holds the lock"; nt $S flash "$W/good.img"
T="... and says which"; t sh -c "$S flash $W/good.img 2>&1 | grep -q 'another write is running (pid $sp: a test write)'"
kill $sp; wait $sp 2>/dev/null
T="takes over a stale lock (its pid is gone)"; t sh -c "$S flash $W/good.img > $W/o2; grep -q 'stale write lock' $W/o2"
T="the lock is gone after a write"; t test ! -e "$W/lock"
T="the lock is gone after a refused write"; t sh -c "! $S flash $W/rnd.img >/dev/null 2>&1; test ! -e $W/lock"

echo "== $SH: write-root (USERDATA)"
head -c 5242880 /dev/urandom > "$W/root.img"            # 5 pieces of 1 MiB
head -c 20000000 /dev/urandom > "$W/huge.img"           # bigger than USERDATA
head -c 1000 /dev/urandom > "$W/odd.img"                # not whole 4 KiB blocks
T="refuses without --yes"; nt $S write-root "$W/root.img"
T="refuses an image bigger than USERDATA"; nt $S write-root "$W/huge.img" --yes
T="refuses an image that is not whole 4096-byte blocks"; nt $S write-root "$W/odd.img" --yes
echo "1111111111111111111111111111111111111111111111111111111111111111  root.img" > "$W/root.img.sha256"
ud=$(h "$W/byname/USERDATA")
T="refuses an image whose .sha256 does not match"; nt $S write-root "$W/root.img" --yes
T="... and USERDATA is unchanged"; t test "$(h "$W/byname/USERDATA")" = "$ud"
rm "$W/root.img.sha256"
T="restore-root refuses an image without .sha256"; nt $S restore-root "$W/root.img" --yes
T="writes USERDATA piece by piece"; t sh -c "$S write-root $W/root.img --yes | grep -q '5 of 5 pieces'"
T="USERDATA holds the image"; t test "$(hb "$W/byname/USERDATA" 5242880)" = "$(h "$W/root.img")"
T="USERDATA past the image untouched"; t test "$(tail -c 11534336 "$W/byname/USERDATA" | sha256sum | cut -c1-64)" = "$(tail -c 11534336 "$W/dev/sda11" | sha256sum | cut -c1-64)"
head -c 3145728 /dev/urandom > "$W/root2.img"
T="--from 2 writes only pieces 2 and on"; t sh -c "$S write-root $W/root2.img --yes --from 2 | grep -q '3 of 3 pieces'"
T="... pieces 0-1 still the first image, 2 the second"; t sh -c "[ \"\$(head -c 2097152 $W/byname/USERDATA | sha256sum)\" = \"\$(head -c 2097152 $W/root.img | sha256sum)\" ] && [ \"\$(dd if=$W/byname/USERDATA bs=1048576 skip=2 count=1 2>/dev/null | sha256sum)\" = \"\$(dd if=$W/root2.img bs=1048576 skip=2 count=1 2>/dev/null | sha256sum)\" ]"

echo "== $SH: backup-root / restore-root"
# An HFS Plus header at byte 1024 ("H+", version 4): block size 4096, 768
# blocks = 3 MiB, the volume the backup must cover.
python3 - "$W/byname/USERDATA" <<'EOF'
import struct, sys
with open(sys.argv[1], "r+b") as f:
    f.seek(1024); f.write(b"H+" + struct.pack(">H", 4) + struct.pack(">I", 1 << 13))
    f.seek(1024 + 40); f.write(struct.pack(">III", 4096, 768, 100))
EOF
vol=$(hb "$W/byname/USERDATA" 3145728)
T="backs up USERDATA's volume (3 MiB by its header)"; t sh -c "$S backup-root | grep -q 'hfsplus covering 3.0 MiB'"
bk=$(ls "$W"/sd/scion/scion-root-*.img | head -1)
T="the backup is the volume, byte for byte"; t test "$(h "$bk")" = "$vol"
T="the backup has a matching .sha256"; t sh -c "cd $W/sd/scion && sha256sum -c ${bk##*/}.sha256"
dd if=/dev/urandom of="$W/byname/USERDATA" bs=1048576 count=3 conv=notrunc 2>/dev/null
T="restore-root puts it back"; t $S restore-root "$bk" --yes
T="USERDATA's volume is the backup again"; t test "$(hb "$W/byname/USERDATA" 3145728)" = "$vol"
dd if=/dev/zero of="$W/byname/USERDATA" bs=4096 count=1 conv=notrunc 2>/dev/null
T="backup-root refuses USERDATA without HFS Plus or APFS"; nt $S backup-root

echo "== $SH: backup-boot, copy-efs (read only)"
T="backup-boot"; t $S backup-boot
bb=$(ls "$W"/sd/scion/boot-2*.img | head -1)
T="the BOOT copy matches BOOT"; t test "$(h "$bb")" = "$(h "$W/byname/BOOT")"
T="copy-efs"; t $S copy-efs
T="EFS copy matches EFS"; t sh -c "[ \"\$(cat $W/sd/scion/EFS-*.img | sha256sum)\" = \"\$(sha256sum < $W/byname/EFS)\" ]"
T="SEC_EFS and CPEFS copied too"; t sh -c "ls $W/sd/scion/SEC_EFS-*.img $W/sd/scion/CPEFS-*.img"

echo "== $SH: switch"
mkdir -p "$W/sd/scion"
for os in android ios165 ios27; do
	{ printf 'ANDROID!'; printf '%s' "$os"; head -c 65536 /dev/urandom; } > "$W/sd/scion/boot-$os.img"
	(cd "$W/sd/scion" && sha256sum "boot-$os.img" > "boot-$os.img.sha256")
done
# USERDATA: HFS Plus with iOS 27's root.
python3 - "$W/byname/USERDATA" <<'EOF'
import struct, sys
with open(sys.argv[1], "r+b") as f:
    f.seek(1024); f.write(b"H+" + struct.pack(">H", 4))
EOF
echo /System/Library/CoreServices/SystemVersion.plist > "$W/hfs-paths"
T="bootlib lists the three"; t sh -c "$S bootlib | grep -c 'with .sha256' | grep -qx 3"
T="switch ios27 with iOS 27's root on USERDATA"; t sh -c "$S switch ios27 | grep -q 'next boot: iOS 27'"
T="BOOT holds boot-ios27.img"; t test "$(hb "$W/byname/BOOT" "$(wc -c < "$W/sd/scion/boot-ios27.img")")" = "$(h "$W/sd/scion/boot-ios27.img")"
T="switch android refused: USERDATA holds iOS"; nt $S switch android
T="... with the reason"; t sh -c "$S switch android 2>&1 | grep -q 'USERDATA holds ios27-root'"
T="switch android --anyway"; t $S switch android --anyway
T="BOOT holds boot-android.img"; t test "$(hb "$W/byname/BOOT" "$(wc -c < "$W/sd/scion/boot-android.img")")" = "$(h "$W/sd/scion/boot-android.img")"
T="switch ios165 refused: SYSTEM holds no iOS"; nt $S switch ios165
rm "$W/sd/scion/boot-ios27.img.sha256"
T="switch refuses a library image without .sha256"; nt $S switch ios27
printf '0%.0s' $(seq 64) > "$W/sd/scion/boot-ios27.img.sha256"
T="switch refuses a library image whose .sha256 differs"; nt $S switch ios27
T="switch refuses an unknown system"; nt $S switch windows

echo "== $SH: looking"
T="facts"; t $S facts
T="inspect"; t sh -c "$S inspect | grep -q 'USERDATA .*hfsplus'"
T="policy lists BOOT and USERDATA"; t sh -c "$S policy | grep -q 'Scion may write: BOOT USERDATA'"
T="help"; t sh -c "$S help | grep -q 'scion write-root IMG'"
T="unknown command exits 2"; t sh -c "$S frobnicate >/dev/null 2>&1; [ \$? -eq 2 ]"

echo "== $SH: nothing protected was written"
for p in $protected; do T="$p unchanged"; t test "$(h "$W/byname/$p")" = "$(cat "$W/before-$p")"; done

echo "$SH: passed $pass, failed $failn"
[ $failn -eq 0 ]
