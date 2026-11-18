#!/bin/sh
# SPDX-License-Identifier: MIT-0
# Host test of overlay/sbin/scion-report: the scrubber, and the report builder,
# against tests/data/scion-report-fixture.log (fake values only).
#
#   tests/test-report-scrub.sh [SHELL]     (default: sh; CI runs mksh, busybox sh, dash)
#
# The scrubber is run with each awk the host has (awk, mawk, gawk, and busybox
# awk, which is what the phone's TWRP has). python3 checks the JSON: test host only.
set -u
SH=${1:-sh}
HERE=$(cd "$(dirname "$0")/.." && pwd)
S=$HERE/overlay/sbin/scion-report
FIX=$HERE/tests/data/scion-report-fixture.log
W=$(mktemp -d "${TMPDIR:-/tmp}/scion-report.XXXXXX")
trap 'rm -rf "$W"' EXIT
pass=0
failn=0
ok() { pass=$((pass + 1)); echo "  ok: $1"; }
bad() { failn=$((failn + 1)); echo "  FAIL: $1"; }
# absent TEXT FILE LABEL: TEXT (a fake secret) is not in FILE, any case.
absent() { if grep -qiF -- "$1" "$2"; then bad "$3 still has: $1"; else ok "$3 has no: $1"; fi; }
# present TEXT FILE LABEL: TEXT is in FILE, exactly as written.
present() { if grep -qF -- "$1" "$2"; then ok "$3 keeps: $1"; else bad "$3 lost: $1"; fi; }

# The fake secrets: none may survive the scrubber, nor the report.
SECRETS='AA:BB:CC:DD:EE:FF
00:11:22:33:44:55
192.168.1.23
fe80::1234:abcd:5678
R58M12ABCDE
490154203237518
358240051111110
7f3c9e1a-2b4d-4e5f-8a9b-0c1d2e3f4a5b
1A2B3C4D-1111-2222-3333-444455556666
/Users/dylan
0123456789abcdef0123456789abcdef
dylan@example.com
353871234567
53.349805
6.260310
HomeNet-5G
Cafe Guest
ZZ99QQ
C02XX1234567
C02MLB987654
XAA-FAKE
MKT12ZD
ABCDEF0123
1234ABCD5678
5a5a5a5a'
# The lines and tokens that must survive.
KEPT='CRASH: pid 812 (recovery) signal 11 at 0x00000000 reason=null deref
CRASH: bt #0 0xc0a1b2c3 /Users/<user>/Library/Scion/recovery.log
CRASH: bt #1 /var/mobile/Containers/Data/Application/<uuid>/Documents/x.db
SWEET EXIT: code 0 after 3.2 s
panic(): not syncing: Attempted to kill init
STARLTE TOP   PID  COMMAND  CPU%  S
STARLTE MEM   total 3.6G free 412M
decmpfs: refused key in /private/var
MTL2 driver: Unsupported format 0x42
cpufreq_gov: stat cpu0 0 0 1 2
serialno=<redacted>
imei=<redacted>
sn=<redacted>
<mac>
<ip>
<ip6>
<email>
<phone>
<geo>
<ssid>
<num15>
<hex>
<uuid>'

# Each awk the host has. busybox awk goes through a wrapper: scion-report runs "$AWK".
mkdir -p "$W/bin"
printf '#!/bin/sh\nexec busybox awk "$@"\n' > "$W/bin/busybox-awk"
chmod +x "$W/bin/busybox-awk"
AWKS=
for a in "$(command -v awk)" "$(command -v mawk)" "$(command -v gawk)"; do
	[ -n "$a" ] && AWKS="$AWKS $a"
done
command -v busybox >/dev/null 2>&1 && AWKS="$AWKS $W/bin/busybox-awk"

for AWK in $AWKS; do
	export SCION_AWK=$AWK
	cache=$W/cache-$(basename "$AWK")
	export SCION_CACHE_DIR=$cache
	echo "== $SH with $(basename "$AWK")"

	# The scrubber, on the fixture.
	if $SH "$S" scrub < "$FIX" > "$W/scrubbed"; then ok "scrub exits 0"; else bad "scrub failed"; fi
	echo "$SECRETS" | while IFS= read -r s; do absent "$s" "$W/scrubbed" scrub; done > "$W/absent.out"
	grep -q FAIL "$W/absent.out" && { cat "$W/absent.out"; failn=$((failn + 1)); } || pass=$((pass + 1))
	echo "$KEPT" | while IFS= read -r s; do present "$s" "$W/scrubbed" scrub; done > "$W/kept.out"
	grep -q FAIL "$W/kept.out" && { cat "$W/kept.out"; failn=$((failn + 1)); } || pass=$((pass + 1))

	# Each non-ASCII byte becomes '?' (the two bytes of e-acute: '??').
	printf 'CRASH caf\303\251 ok\n' | $SH "$S" scrub > "$W/utf"
	present 'CRASH caf?? ok' "$W/utf" "scrub (non-ASCII)"

	# The report.
	if $SH "$S" build "$FIX" "$W/report.json"; then ok "build exits 0"; else bad "build failed"; fi
	echo "$SECRETS" | while IFS= read -r s; do absent "$s" "$W/report.json" report; done > "$W/absent.out"
	grep -q FAIL "$W/absent.out" && { cat "$W/absent.out"; failn=$((failn + 1)); } || pass=$((pass + 1))
	echo "$KEPT" | while IFS= read -r s; do present "$s" "$W/report.json" report; done > "$W/kept.out"
	grep -q FAIL "$W/kept.out" && { cat "$W/kept.out"; failn=$((failn + 1)); } || pass=$((pass + 1))
	grep -Eq '"install_id": "[0-9a-f]{32}"' "$W/report.json" && ok "install_id is 32 hex" || bad "install_id is not 32 hex"
	grep -Fq '"model": "unknown"' "$W/report.json" && ok "model falls back to unknown" || bad "model"
	grep -Fq '"builds": {"recovery": "unknown"}' "$W/report.json" && ok "recovery build falls back to unknown" || bad "builds"
	grep -Eq '"ts": [0-9]+,' "$W/report.json" && ok "ts is epoch seconds" || bad "ts"
	grep -q '^    "' "$W/report.json" && ok "lines has entries" || bad "lines empty"
	[ "$(grep -c '^    "' "$W/report.json")" -eq 17 ] && ok "17 report lines: 10 CRASH, SWEET, panic, 2 STARLTE, decmpfs, MTL2, cpufreq" || bad "wrong count of report lines"
	absent 'noise: this line' "$W/report.json" report
	[ -s "$SCION_CACHE_DIR/install-id" ] && ok "install-id stored" || bad "install-id not stored"
	$SH "$S" build "$FIX" "$W/report2.json" && grep -F "$(sed -n 's/.*"install_id": "\(.*\)".*/\1/p' "$W/report.json")" "$W/report2.json" >/dev/null &&
		ok "install-id is kept across runs" || bad "install-id changed"
	python3 -I -m json.tool "$W/report.json" >/dev/null && ok "report is valid JSON (json.tool)" || bad "report JSON invalid"

	# JSON escaping: quote, backslash, tab, control byte, and a drop line that must not be kept.
	printf 'CRASH: quote "x" back\\slash tab\there ctl\001end\n' > "$W/esc.log"
	$SH "$S" build "$W/esc.log" "$W/esc.json" && ok "escaping build exits 0" || bad "escaping build"
	present 'quote \"x\" back\\slash tab\there ctl\u0001end' "$W/esc.json" "report (escapes)"
	python3 -I -m json.tool "$W/esc.json" >/dev/null && ok "escaped report is valid JSON" || bad "escaped report JSON invalid"

	# Empty report: no lines at all, still valid JSON.
	echo 'noise only' > "$W/empty.log"
	$SH "$S" build "$W/empty.log" "$W/empty.json" && python3 -I -m json.tool "$W/empty.json" >/dev/null &&
		ok "empty report is valid JSON" || bad "empty report"

	# The cap: 2100 CRASH lines, 2000 kept.
	i=0
	: > "$W/many.log"
	while [ "$i" -lt 2100 ]; do echo "CRASH: filler $i" >> "$W/many.log"; i=$((i + 1)); done
	$SH "$S" build "$W/many.log" "$W/many.json" && [ "$(grep -c '^    "' "$W/many.json")" -eq 2000 ] &&
		ok "capped at 2000 lines" || bad "cap"

	# Usage errors.
	if $SH "$S" bogus >/dev/null 2>&1; then bad "unknown command accepted"; else ok "unknown command refused"; fi
	if $SH "$S" scrub extra < /dev/null >/dev/null 2>&1; then bad "scrub with an argument accepted"; else ok "scrub with an argument refused"; fi
	if $SH "$S" build "$W/nope.log" "$W/x.json" >/dev/null 2>&1; then bad "missing log accepted"; else ok "missing log refused"; fi
	rm -rf "$SCION_CACHE_DIR"
done

echo "== $SH: $pass passed, $failn failed"
[ "$failn" -eq 0 ]
