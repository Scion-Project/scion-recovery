<!-- SPDX-License-Identifier: MIT-0 -->
# Wi-Fi and "Install over Wi-Fi"

Scion recovery can join a Wi-Fi network and download, check and install an iOS update by itself:
**Install iOS > Over Wi-Fi** (or **Scion settings > Wi-Fi**). Everything is `/sbin/scion-net`; the GUI runs it.

## How Wi-Fi works here

- The S9's Broadcom driver (`bcmdhd`, BCM4361) is built into the recovery kernel (`wlan0` is there at start).
  Its firmware is on VENDOR: `scion-net` mounts VENDOR **read only** for a moment and copies
  `firmware/bcmdhd_sta.bin_b0/_b2`, `firmware/nvram.txt_*` to the ramdisk's `/vendor/firmware` and
  `firmware/bcmdhd_clm.blob` to `/vendor/etc/wifi` (where the driver looks for the CLM blob), then points
  `/sys/module/dhd/parameters/firmware_path` and `nvram_path` at them. The driver adds the chip revision
  (`_b2`) and module type (`_r02a_b2`) itself. `ip link set wlan0 up` loads it.
- `wpa_supplicant` and `wpa_cli` (2.11, nl80211; WPA2/WPA3-Personal), `curl` (8.11.1, OpenSSL) and a busybox
  (Alpine's static one, used only for `udhcpc` and `ntpd`) are static aarch64 builds in `/scion/bin`
  (`third_party/wifi/`); Mozilla's CA list is `/etc/scion/cacert.pem`.
- After joining: `udhcpc` (`/sbin/scion-udhcpc` applies the lease and `/etc/resolv.conf`), then `ntpd` sets the
  clock (recovery starts in 2018, and TLS refuses certificates "not yet valid" without it).
- Saved networks: `/cache/scion/wifi/wpa_supplicant.conf`, mode 600 (directory 700). The passphrase is typed
  on a masked field; TWRP logs the command line that carries it, so `scion-net` overwrites it with `*` in
  `/tmp/recovery.log` before anything else. `'` and `%` cannot be typed there (they would break TWRP's
  command line); over adb: `scion-net wifi-join NAME 'PASSPHRASE'`. `scion-net wifi-forget` forgets them all.

## The update

`/cache/scion/update-url` holds the address of the update list (a manifest). Until it is set it holds a
placeholder (`https://updates.example.invalid/...`) and Check refuses. Set it with
`adb shell scion-net update-url https://...` (https only). The manifest:

```json
{
  "name": "Scion iOS 27", "version": "27.1 (b9)", "test": false, "notes": "optional",
  "root": { "url": "https://...", "sha256": "<64 hex>", "size": 34359738368 },
  "boot": { "url": "https://...", "sha256": "<64 hex>", "size": 33554432 }
}
```

Either image may be left out. `"test": true` makes an update that can be downloaded and checked but never
installed (`tests/data/update-test/manifest.json` is one: LICENSE as a stand-in BOOT image).

1. **Check**: fetches the manifest (joining the saved network first if needed), refuses image addresses that
   are not https, sha256 that are not 64 hex digits, missing sizes.
2. **Download**: to `scion/update/` on the SD card or a USB drive (`/external_sd`, `/usb-otg`); a BOOT image
   may go to `/cache` when there is neither. **Never USERDATA** (`/data`, `/sdcard`): that is what gets
   written. Free space is checked first; FAT32 refuses files of 4 GiB or more. A stopped download is kept as
   `.part` and resumed (HTTP Range). The size and sha256 are checked; a damaged file is deleted. A checked
   file gets its `.sha256` beside it.
3. **Install** (after a swipe): refused below 30 % battery unless charging, refused for a test update. The root
   goes first, through `scion write-root IMG --yes --need-sidecar` (64 MiB pieces, each read back), then BOOT
   through `scion flash IMG BOOT`: both are held to the write policy (BOOT and USERDATA only).

**Not done yet**: a real update host (the manifest and images); signing the manifest (today it is trusted for
coming over https from the configured address); hidden networks; enterprise (802.1X) Wi-Fi.

## Tested on a phone (18 November 2026, phone 2, image 8fd3eef: sha256 fa72a3e4...)

- Over adb: firmware loaded (`Firmware version = wl0: ... 13.50.37 (B2 Network/rsdb)`, CLM `Samsung.R7`),
  joined WPA2 networks on 5 GHz and 2.4 GHz, DHCP lease, clock set by NTP, `ping 1.1.1.1` 0 % loss,
  `curl https://api.ipsw.me/v4/device/iPhone12,1?type=ipsw` HTTP 200 (57 KB). The passphrase scrub leaves
  `I:Running command: test '**********'` in the log.
- In the GUI (taps): Scion settings > Wi-Fi > a network > Join (saved network, empty field) > the result page
  ("Joined ..., address ..."), status line "Connected: ..., 192.168.0.101". Install iOS > Over Wi-Fi >
  Check (the test manifest) > Download and check (LICENSE as BOOT, to /cache, sha256 OK). A secure network
  with no saved passphrase and an empty field says "... needs its passphrase". Install refuses a test update.
- Not tried on a phone: typing a new passphrase on the keyboard (the same command path as above, tested
  over adb), a real install (USERDATA/BOOT), a resumed download over Wi-Fi (tested on a computer,
  tests/test-net.sh), the start-up MTP fix with a stale `tw_mtp_enabled=0` (it would cut adb if it failed).
