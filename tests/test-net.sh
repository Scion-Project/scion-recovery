#!/bin/sh
# SPDX-License-Identifier: MIT-0
# Host test of scion-net's update side (no Wi-Fi, no phone): the manifest
# parser, update-check's refusals, update-download from a local HTTP server
# with Range (resume, a damaged download, a complete one), update-install's
# refusals (test update, low battery) and that it writes only through
# /sbin/scion (a fake one here, which records its arguments). And the scrub
# that takes a passphrase back out of TWRP's log.
#
#   tests/test-net.sh [SHELL]     (default: mksh, TWRP's /sbin/sh)
set -u
SH=${1:-mksh}
HERE=$(cd "$(dirname "$0")/.." && pwd)
W=$(mktemp -d "${TMPDIR:-/tmp}/scion-net.XXXXXX")
PORT=$((20000 + $$ % 20000))
cleanup() { [ -n "${SRV:-}" ] && kill "$SRV" 2>/dev/null; rm -rf "$W"; }
trap cleanup EXIT
pass=0; failn=0
# The output of the last command is in $W/out ("  and ..." checks read it).
t() { if "$@" >"$W/new" 2>&1; then pass=$((pass + 1)); echo "  ok: $T"; else failn=$((failn + 1)); echo "  FAIL: $T"; sed 's/^/      /' "$W/new"; fi; keep "$@"; }
nt() { if "$@" >"$W/new" 2>&1; then failn=$((failn + 1)); echo "  FAIL (it succeeded): $T"; sed 's/^/      /' "$W/new"; else pass=$((pass + 1)); echo "  ok: $T"; fi; keep "$@"; }
keep() { case $* in *scion-net*) mv "$W/new" "$W/out" ;; esac; }
N="$SH $HERE/overlay/sbin/scion-net"
echo "== $SH: scion-net"

# --- the manifest parser
cat > "$W/m.json" <<'EOF'
{ "name": "Scion iOS 27", "version": "27.1 (b9)", "test": false,
  "notes": "a \"quoted\" note, with: commas, {braces} and [brackets]",
  "root": { "url": "https://h.example/r.img", "sha256": "ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef0123456789", "size": 34359738368 },
  "boot": {"url":"https://h.example/b.img","sha256":"00","size":1},
  "list": [ {"a": 1}, {"a": 2} ] }
EOF
$N json-flat < "$W/m.json" > "$W/flat"
T="json: name"; t grep -qx 'name=Scion iOS 27' "$W/flat"
T="json: nested root.size (a number past 2^32)"; t grep -qx 'root.size=34359738368' "$W/flat"
T="json: escaped quotes and punctuation in a string"; t grep -qx 'notes=a "quoted" note, with: commas, {braces} and \[brackets\]' "$W/flat"
T="json: compact object"; t grep -qx 'boot.url=https://h.example/b.img' "$W/flat"
T="json: arrays by index"; t grep -qx 'list.1.a=2' "$W/flat"
T="json: booleans"; t grep -qx 'test=false' "$W/flat"

# --- a local server with Range (Python's own has none)
mkdir -p "$W/www" "$W/sd" "$W/cache" "$W/bat"
cat > "$W/srv.py" <<'EOF'
import http.server, os, re, sys
class H(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        p = self.translate_path(self.path)
        if not os.path.isfile(p):
            return self.send_error(404)
        data = open(p, "rb").read()
        m = re.match(r"bytes=(\d+)-$", self.headers.get("Range", ""))
        if m:
            o = int(m.group(1))
            if o >= len(data):
                self.send_response(416); self.send_header("Content-Range", "bytes */%d" % len(data)); self.end_headers(); return
            self.send_response(206); self.send_header("Content-Range", "bytes %d-%d/%d" % (o, len(data) - 1, len(data)))
            data = data[o:]
        else:
            self.send_response(200)
        self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0)); body = self.rfile.read(n)
        if self.path == "/report" and self.headers.get("Content-Type") == "application/json":
            open(os.path.join(sys.argv[2], "posted.json"), "ab").write(body)
            self.send_response(200); self.send_header("Content-Length", "0"); self.end_headers()
        else:
            self.send_error(500)
os.chdir(sys.argv[2])
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
EOF
python3 -I "$W/srv.py" "$PORT" "$W/www" &
SRV=$!
head -c 3000000 /dev/urandom > "$W/www/root.img"
head -c 70000 /dev/urandom > "$W/www/boot.img"
rs=$(sha256sum < "$W/www/root.img" | cut -c1-64); bs=$(sha256sum < "$W/www/boot.img" | cut -c1-64)
U=http://127.0.0.1:$PORT
mk() { # mk FILE TEST [ROOT_SHA]
	printf '{"name":"Scion test","version":"1","test":%s,"root":{"url":"%s/root.img","sha256":"%s","size":3000000},"boot":{"url":"%s/boot.img","sha256":"%s","size":70000}}\n' \
		"$2" "$U" "${3:-$rs}" "$U" "$bs" > "$W/www/$1"
}
mk m.json false; mk t.json true; mk bad.json false 0000000000000000000000000000000000000000000000000000000000000000
printf '{"name":"x","version":"1","root":{"url":"http://h.example/r.img","sha256":"%s","size":1}}\n' "$rs" > "$W/www/nothttps.json"
cat > "$W/scion" <<EOF
#!/bin/sh
echo "\$*" >> "$W/scion.calls"
EOF
chmod +x "$W/scion"
echo 80 > "$W/bat/capacity"; echo Discharging > "$W/bat/status"
export NET_NOCHECK=1 CURL=curl CACERT=/etc/ssl/certs/ca-certificates.crt UPD_URL_FILE="$W/cache/update-url" \
	UPD_TMP="$W/tmp" UPD_STATE="$W/cache/staged" UPD_STORAGE="$W/sd" UPD_ANYDIR=1 UPD_SMALL="$W/cache" \
	SCION="$W/scion" BATTERY="$W/bat" WIFI_TMP="$W/wifi"
n=0; while ! curl -s -o /dev/null "$U/m.json"; do n=$((n + 1)); [ $n -gt 50 ] && break; sleep 0.1; done

T="no address set: refuses, and writes the placeholder"; nt $N update-check
T="  the placeholder is there"; t grep -q example.invalid "$W/cache/update-url"
T="update-url refuses http://"; nt $N update-url "http://h.example/m.json"
echo "$U/nothttps.json" > "$W/cache/update-url"
T="an image address that is not https is refused"; nt $N update-check
echo "$U/missing.json" > "$W/cache/update-url"
T="a missing manifest fails plainly"; nt $N update-check
T="download before check refuses"; nt $N update-download

echo "$U/bad.json" > "$W/cache/update-url"
T="check (a manifest whose root sha256 is wrong)"; t $N update-check
T="download of a damaged root fails"; nt $N update-download
T="  and says it is damaged"; t grep -q "damaged" "$W/out"
T="  and deletes it"; nt sh -c "ls '$W/sd/scion/update/' | grep -q 'root.*part'"

echo "$U/m.json" > "$W/cache/update-url"
T="check"; t $N update-check
T="  says the sizes"; t grep -q "root image: 2.9 MiB" "$W/out"
head -c 1000000 "$W/www/root.img" > "$W/sd/scion/update/root-$(echo "$rs" | cut -c1-12).img.part"
T="download resumes a partial root and checks both"; t $N update-download
T="  it resumed"; t grep -q "resuming the root image at 976.6 KiB" "$W/out"
T="  root staged on the SD card, with its .sha256"; t sh -c "cd '$W/sd/scion/update' && sha256sum -c root-*.img.sha256"
T="  boot staged on the SD card too (it is there)"; t sh -c "cd '$W/sd/scion/update' && sha256sum -c boot-*.img.sha256"
T="a second download finds both done"; t $N update-download
T="  and does not fetch again"; t grep -q "already downloaded and checked" "$W/out"

T="install without --yes refuses"; nt $N update-install
echo 20 > "$W/bat/capacity"
T="install at 20 % battery, not charging, refuses"; nt $N update-install --yes
T="  and says why"; t grep -q "battery at 20%" "$W/out"
echo Charging > "$W/bat/status"
T="install at 20 % while charging"; t $N update-install --yes
T="  writes the root first, through scion write-root with its sidecar"; t sh -c "head -1 '$W/scion.calls' | grep -q '^write-root .*/root-.*\.img --yes --need-sidecar$'"
T="  then BOOT through scion flash"; t sh -c "sed -n 2p '$W/scion.calls' | grep -q '^flash .*/boot-.*\.img BOOT$'"
T="  and nothing else"; t test "$(wc -l < "$W/scion.calls")" -eq 2

rm -f "$W/scion.calls"
echo "$U/t.json" > "$W/cache/update-url"
T="a test update: check"; t $N update-check
T="a test update: download"; t $N update-download
T="a test update is never installed"; nt $N update-install --yes
T="  and scion was not called"; t test ! -e "$W/scion.calls"

# --- crash and boot reports: only with consent
mkdir -p "$W/boot/pstore"
printf 'reason: KPON\n' > "$W/boot/proc-reset_reason.txt"
printf '[  1.0] CRASH: panic(cpu 0): test wlan0 c4:eb:43:95:45:a3 at 192.168.0.101\n[  1.1] nothing\n' > "$W/boot/last_kmsg.txt"
printf '#!/bin/sh\nexec sh %s "$@"\n' "$HERE/overlay/sbin/scion-report" > "$W/scion-report"; chmod +x "$W/scion-report"
RQ="REPORT_Q=$W/cache/rq REPORT_TMP=$W/rt BOOTLOGS=$W/boot CONSENT=$W/cache/consent SCION_REPORT=$W/scion-report SCION_CACHE_DIR=$W/cache"
T="report-send without an answer refuses"; nt env $RQ REPORT_URL="$U/report" $N report-send
T="  and sends nothing"; t test ! -e "$W/www/posted.json"
T="consent no"; t env $RQ $N report-consent no
T="report-send after no refuses"; nt env $RQ REPORT_URL="$U/report" $N report-send
T="consent yes (no Wi-Fi here: nothing sent yet)"; t env $RQ $N report-consent yes
T="report-send with a failing server keeps the report"; nt env $RQ REPORT_URL="$U/nope" $N report-send
T="  one queued"; t test "$(ls "$W/cache/rq" | wc -l)" -eq 1
T="report-send sends the queued report"; t env $RQ REPORT_URL="$U/report" $N report-send
T="  the queue is empty"; t test "$(ls "$W/cache/rq" | wc -l)" -eq 0
T="  the server got the crash line"; t grep -q 'CRASH: panic' "$W/www/posted.json"
T="  scrubbed: no MAC, no IP"; nt grep -qE 'c4:eb:43|192\.168\.0\.101' "$W/www/posted.json"
T="consent no empties the queue"; t sh -c "mkdir -p '$W/cache/rq' && : > '$W/cache/rq/x.json' && env $RQ $N report-consent no && test ! -e '$W/cache/rq/x.json'"

# --- the passphrase scrub
mkdir -p "$W/wifi"
printf 'I:Running command: %s\nline two\nagain: %s and %s\n' "/sbin/scion-net wifi-join 'x' 'p@ss w\\rd%1'" "p@ss w\\rd%1" "p@ss w\\rd%1" > "$W/rlog"
sz=$(wc -c < "$W/rlog")
T="scrub: wifi-join takes the passphrase out of the log (it then fails: no Wi-Fi here)"; nt env SCRUB_LOG="$W/rlog" $N wifi-join /nonexistent 'p@ss w\rd%1'
T="  the passphrase is gone"; nt grep -qF 'p@ss' "$W/rlog"
T="  three times starred"; t test "$(grep -o '[*]\{11\}' "$W/rlog" | wc -l)" -eq 3
T="  the log is the same size"; t test "$(wc -c < "$W/rlog")" -eq "$sz"

echo "== $SH: $pass passed, $failn failed"
[ "$failn" -eq 0 ]
