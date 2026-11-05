#!/bin/sh
# Make tests/data/hfsx-var.img.gz on macOS: a 64 MB journaled, case-sensitive
# HFS Plus (HFSX) volume made with newfs_hfs as tools/mkdatavol.py does
# (Scion-Project/scion-kernel), laid out like HakiOS' /private/var on the
# S9's USERDATA: the volume root is /private/var, with hakios-runs and
# mobile/Library/Logs/CrashReporter. One file is HFS-compressed (decmpfs) and
# one name has a space. Unmounted cleanly, so its journal is clean;
# tests/test-scion.sh dirties it itself.
#   tests/mkhfsimg-macos.sh OUTDIR
set -eu
D=${1:?usage: mkhfsimg-macos.sh OUTDIR}
mkdir -p "$D/mnt"
cd "$D"
rm -f var.img var.img.gz
mkfile -n 64m var.img
dev=$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage var.img | awk 'NR==1{print $1}')
newfs_hfs -s -J -b 4096 -v Data "/dev/r${dev#/dev/}"
hdiutil detach "$dev" >/dev/null
dev=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -mountpoint "$D/mnt" var.img | awk 'NR==1{print $1}')
M=$D/mnt
CR=$M/mobile/Library/Logs/CrashReporter
mkdir -p "$CR/Retired" "$M/tmp" "$M/db"
printf 'Incident Identifier: HFS-1\nCrashReporter Key: scion-test\nProcess: SpringBoard\n' > "$CR/x.ips"
printf 'Incident Identifier: HFS-2\n' > "$CR/Retired/backboardd 2026-11-02.ips"
echo 7 > "$M/hakios-runs"
yes 'compressible line of a jetsam report' | head -n 4000 > "$D/big.txt"
ditto --hfsCompression "$D/big.txt" "$CR/JetsamEvent-compressed.ips"
ln -s mobile/Library/Logs/CrashReporter "$M/crashes"
(cd "$M" && find . -type f ! -path './.*' -exec shasum -a 256 {} \;) > sums.txt
hdiutil detach "$dev" >/dev/null
gzip -9 var.img
cat sums.txt
