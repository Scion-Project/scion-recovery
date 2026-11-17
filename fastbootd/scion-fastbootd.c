// SPDX-License-Identifier: MIT-0
/*
 * scion-fastbootd: a userspace fastboot device for Scion recovery on the
 * Galaxy S9 (starlte). The S9's boot loader has no fastboot (it has Odin's
 * Download mode), so this gives a computer `fastboot flash boot|userdata`,
 * `fastboot getvar`, `fastboot erase` and `fastboot reboot [bootloader]` while
 * the phone is in Scion recovery.
 *
 * Written from scratch for Scion from the fastboot protocol as AOSP documents
 * it (system/core/fastboot/README.md: commands, OKAY/FAIL/INFO/DATA replies,
 * the "FB01" TCP handshake and 8-byte length prefixes) and the Android sparse
 * image format (libsparse's documented header and chunk layout). No AOSP code.
 *
 * Writes obey Scion's write policy (/etc/scion-partitions.conf), exactly as
 * /sbin/scion does: the partition must be on a "write" line and on no "never"
 * line, its by-name link must resolve to a device whose kernel PARTNAME is that
 * name, and no "never" partition may resolve to the same device. Every write
 * is read back and compared, and takes Scion's write lock
 * (/tmp/scion-write.lock), so a write from the GUI and one from fastboot
 * cannot overlap.
 *
 * Transports:
 *   --ffs DIR    USB through FunctionFS: DIR/ep0 gets fastboot's descriptors
 *                (interface class 0xff, subclass 0x42, protocol 3), DIR/ep1
 *                is bulk OUT, DIR/ep2 bulk IN. /sbin/scion fastboot start
 *                sets up the gadget around it.
 *   --tcp PORT   fastboot over TCP on 127.0.0.1 (the host tests: the real
 *                fastboot client against fake partitions).
 *
 * NOT run on a phone. Tested on a computer over TCP only
 * (tests/test-fastbootd.sh).
 */
#define _GNU_SOURCE
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <time.h>
#include <unistd.h>
#include <linux/fs.h>
#include <linux/reboot.h>
#ifndef NO_FFS
#include <linux/usb/ch9.h>
#include <linux/usb/functionfs.h>
#endif

#define VERSION "1"
#define MAX_NAMES 64
#define NAME_LEN 32

/* ---- configuration ------------------------------------------------------ */

static const char *policy_path = "/etc/scion-partitions.conf";
static const char *blockdirs = "/dev/block/by-name /dev/block/platform/11120000.ufs/by-name /dev/block/bootdevice/by-name";
static const char *sysblock = "/sys/class/block";
static const char *lock_dir = "/tmp/scion-write.lock";
static const char *actlog = "/tmp/scion-actions.log";
static const char *ready_file = NULL;
static uint32_t max_download = 256u << 20;
static int no_reboot = 0;

static void logf_(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void logf_(const char *fmt, ...)
{
	char ts[32];
	time_t t = time(NULL);
	strftime(ts, sizeof ts, "%H:%M:%S", localtime(&t));
	fprintf(stderr, "%s scion-fastbootd: ", ts);
	va_list ap;
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	fputc('\n', stderr);
	fflush(stderr);
}

static void action_log(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void action_log(const char *fmt, ...)
{
	FILE *f = fopen(actlog, "a");
	if (!f)
		return;
	char ts[32];
	time_t t = time(NULL);
	strftime(ts, sizeof ts, "%Y%m%d-%H%M%S", localtime(&t));
	fprintf(f, "%s fastboot ", ts);
	va_list ap;
	va_start(ap, fmt);
	vfprintf(f, fmt, ap);
	va_end(ap);
	fputc('\n', f);
	fclose(f);
}

/* ---- SHA-256 (FIPS 180-4), for the log and INFO lines --------------------- */

typedef struct {
	uint32_t h[8];
	uint64_t len;
	uint8_t buf[64];
	size_t n;
} sha256_t;

static const uint32_t K256[64] = {
	0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
	0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
	0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
	0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
	0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
	0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
	0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
	0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
};

#define ROR(x, n) (((x) >> (n)) | ((x) << (32 - (n))))

static void sha256_block(sha256_t *s, const uint8_t *p)
{
	uint32_t w[64], a, b, c, d, e, f, g, h;
	for (int i = 0; i < 16; i++)
		w[i] = (uint32_t)p[4 * i] << 24 | (uint32_t)p[4 * i + 1] << 16 | (uint32_t)p[4 * i + 2] << 8 | p[4 * i + 3];
	for (int i = 16; i < 64; i++) {
		uint32_t s0 = ROR(w[i - 15], 7) ^ ROR(w[i - 15], 18) ^ (w[i - 15] >> 3);
		uint32_t s1 = ROR(w[i - 2], 17) ^ ROR(w[i - 2], 19) ^ (w[i - 2] >> 10);
		w[i] = w[i - 16] + s0 + w[i - 7] + s1;
	}
	a = s->h[0]; b = s->h[1]; c = s->h[2]; d = s->h[3];
	e = s->h[4]; f = s->h[5]; g = s->h[6]; h = s->h[7];
	for (int i = 0; i < 64; i++) {
		uint32_t t1 = h + (ROR(e, 6) ^ ROR(e, 11) ^ ROR(e, 25)) + ((e & f) ^ (~e & g)) + K256[i] + w[i];
		uint32_t t2 = (ROR(a, 2) ^ ROR(a, 13) ^ ROR(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
		h = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
	}
	s->h[0] += a; s->h[1] += b; s->h[2] += c; s->h[3] += d;
	s->h[4] += e; s->h[5] += f; s->h[6] += g; s->h[7] += h;
}

static void sha256_init(sha256_t *s)
{
	static const uint32_t iv[8] = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
					0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 };
	memcpy(s->h, iv, sizeof iv);
	s->len = 0;
	s->n = 0;
}

static void sha256_update(sha256_t *s, const void *data, size_t len)
{
	const uint8_t *p = data;
	s->len += len;
	while (len) {
		size_t k = 64 - s->n < len ? 64 - s->n : len;
		memcpy(s->buf + s->n, p, k);
		s->n += k; p += k; len -= k;
		if (s->n == 64) {
			sha256_block(s, s->buf);
			s->n = 0;
		}
	}
}

static void sha256_hex(sha256_t *s, char out[65])
{
	uint64_t bits = s->len * 8;
	uint8_t pad = 0x80, z = 0, l[8];
	sha256_update(s, &pad, 1);
	while (s->n != 56)
		sha256_update(s, &z, 1);
	for (int i = 0; i < 8; i++)
		l[i] = (uint8_t)(bits >> (56 - 8 * i));
	sha256_update(s, l, 8);
	for (int i = 0; i < 8; i++)
		sprintf(out + 8 * i, "%08x", s->h[i]);
}

static void sha256_of(const void *data, size_t len, char out[65])
{
	sha256_t s;
	sha256_init(&s);
	sha256_update(&s, data, len);
	sha256_hex(&s, out);
}

/* ---- transport ----------------------------------------------------------- */

static int t_tcp = 0;           /* 1: TCP, 0: FunctionFS */
static int fd_in = -1, fd_out = -1;
static uint64_t tcp_left = 0;   /* bytes left in the current TCP message */

static int read_full(int fd, void *buf, size_t len)
{
	uint8_t *p = buf;
	while (len) {
		ssize_t r = read(fd, p, len);
		if (r < 0 && errno == EINTR)
			continue;
		if (r <= 0)
			return -1;
		p += r;
		len -= (size_t)r;
	}
	return 0;
}

static int write_full(int fd, const void *buf, size_t len)
{
	const uint8_t *p = buf;
	while (len) {
		ssize_t r = write(fd, p, len);
		if (r < 0 && errno == EINTR)
			continue;
		if (r <= 0)
			return -1;
		p += r;
		len -= (size_t)r;
	}
	return 0;
}

static int tcp_next_header(void)
{
	uint8_t h[8];
	if (read_full(fd_in, h, 8))
		return -1;
	tcp_left = 0;
	for (int i = 0; i < 8; i++)
		tcp_left = tcp_left << 8 | h[i];
	return 0;
}

/* One command packet into buf (NUL-terminated); its length, or -1. */
static ssize_t t_read_cmd(char *buf, size_t max)
{
	if (t_tcp) {
		while (tcp_left == 0)
			if (tcp_next_header())
				return -1;
		if (tcp_left > max - 1)
			return -1;
		size_t n = (size_t)tcp_left;
		if (read_full(fd_in, buf, n))
			return -1;
		tcp_left = 0;
		buf[n] = 0;
		return (ssize_t)n;
	}
	for (;;) {
		ssize_t r = read(fd_in, buf, max - 1);
		if (r < 0 && errno == EINTR)
			continue;
		if (r < 0)
			return -1;
		if (r == 0)
			continue; /* a zero-length packet: wait for the command */
		buf[r] = 0;
		return r;
	}
}

/* Exactly len bytes of download data. */
static int t_read_data(uint8_t *buf, size_t len)
{
	if (t_tcp) {
		while (len) {
			while (tcp_left == 0)
				if (tcp_next_header())
					return -1;
			size_t k = tcp_left < len ? (size_t)tcp_left : len;
			if (read_full(fd_in, buf, k))
				return -1;
			buf += k; len -= k; tcp_left -= k;
		}
		return 0;
	}
	while (len) {
		size_t k = len > (1u << 20) ? (1u << 20) : len;
		ssize_t r = read(fd_in, buf, k);
		if (r < 0 && errno == EINTR)
			continue;
		if (r < 0)
			return -1;
		buf += r;
		len -= (size_t)r;
	}
	return 0;
}

static int t_write(const char *buf, size_t len)
{
	if (t_tcp) {
		uint8_t h[8];
		for (int i = 0; i < 8; i++)
			h[i] = (uint8_t)((uint64_t)len >> (56 - 8 * i));
		if (write_full(fd_out, h, 8))
			return -1;
	}
	return write_full(fd_out, buf, len);
}

static int reply(const char *kind, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
static int reply(const char *kind, const char *fmt, ...)
{
	char msg[256];
	int n = snprintf(msg, sizeof msg, "%s", kind);
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(msg + n, sizeof msg - (size_t)n, fmt, ap);
	va_end(ap);
	/* Up to 256 bytes, what fastboot clients since platform-tools 28 read. */
	size_t len = strlen(msg);
	if (strcmp(kind, "FAIL") == 0)
		logf_("FAIL %s", msg + 4);
	return t_write(msg, len);
}

#define OKAY(...) reply("OKAY", __VA_ARGS__)
#define FAIL(...) reply("FAIL", __VA_ARGS__)
#define INFO(...) reply("INFO", __VA_ARGS__)

#ifndef NO_FFS
/* FunctionFS: fastboot's interface on two bulk endpoints, full, high and
 * super speed, like every fastboot device. */
struct ffs_fs_hs {
	struct usb_interface_descriptor intf;
	struct usb_endpoint_descriptor_no_audio sink, source;
} __attribute__((packed));

struct ffs_ss {
	struct usb_interface_descriptor intf;
	struct usb_endpoint_descriptor_no_audio sink;
	struct usb_ss_ep_comp_descriptor sink_comp;
	struct usb_endpoint_descriptor_no_audio source;
	struct usb_ss_ep_comp_descriptor source_comp;
} __attribute__((packed));

static const struct {
	struct usb_functionfs_descs_head_v2 header;
	__le32 fs_count, hs_count, ss_count;
	struct ffs_fs_hs fs, hs;
	struct ffs_ss ss;
} __attribute__((packed)) descriptors = {
	.header = {
		.magic = FUNCTIONFS_DESCRIPTORS_MAGIC_V2,
		.length = sizeof(descriptors),
		.flags = FUNCTIONFS_HAS_FS_DESC | FUNCTIONFS_HAS_HS_DESC | FUNCTIONFS_HAS_SS_DESC,
	},
	.fs_count = 3, .hs_count = 3, .ss_count = 5,
#define INTF { .bLength = sizeof(struct usb_interface_descriptor), .bDescriptorType = USB_DT_INTERFACE, \
	.bInterfaceNumber = 0, .bNumEndpoints = 2, .bInterfaceClass = 0xff, .bInterfaceSubClass = 0x42, \
	.bInterfaceProtocol = 3, .iInterface = 1 }
#define EP(addr, mps) { .bLength = USB_DT_ENDPOINT_SIZE, .bDescriptorType = USB_DT_ENDPOINT, \
	.bEndpointAddress = (addr), .bmAttributes = USB_ENDPOINT_XFER_BULK, .wMaxPacketSize = (mps) }
#define COMP { .bLength = sizeof(struct usb_ss_ep_comp_descriptor), .bDescriptorType = USB_DT_SS_ENDPOINT_COMP, \
	.bMaxBurst = 15 }
	.fs = { .intf = INTF, .sink = EP(1 | USB_DIR_OUT, 64), .source = EP(2 | USB_DIR_IN, 64) },
	.hs = { .intf = INTF, .sink = EP(1 | USB_DIR_OUT, 512), .source = EP(2 | USB_DIR_IN, 512) },
	.ss = { .intf = INTF, .sink = EP(1 | USB_DIR_OUT, 1024), .sink_comp = COMP,
		.source = EP(2 | USB_DIR_IN, 1024), .source_comp = COMP },
};

static const struct {
	struct usb_functionfs_strings_head header;
	struct {
		__le16 code;
		const char str1[sizeof("fastboot")];
	} __attribute__((packed)) lang0;
} __attribute__((packed)) strings = {
	.header = { .magic = FUNCTIONFS_STRINGS_MAGIC, .length = sizeof(strings), .str_count = 1, .lang_count = 1 },
	.lang0 = { 0x0409, "fastboot" },
};

static int ep0 = -1;

static void *ep0_events(void *arg)
{
	(void)arg;
	struct usb_functionfs_event ev[4];
	static const char *names[] = { "BIND", "UNBIND", "ENABLE", "DISABLE", "SETUP", "SUSPEND", "RESUME" };
	for (;;) {
		ssize_t r = read(ep0, ev, sizeof ev);
		if (r < 0 && errno == EINTR)
			continue;
		if (r <= 0) {
			logf_("ep0: read: %s", r < 0 ? strerror(errno) : "end");
			return NULL;
		}
		for (size_t i = 0; i < (size_t)r / sizeof ev[0]; i++) {
			unsigned ty = ev[i].type;
			logf_("usb: %s", ty < 7 ? names[ty] : "?");
			if (ty == FUNCTIONFS_SETUP) {
				/* No control requests of our own: stall them. */
				if (ev[i].u.setup.bRequestType & USB_DIR_IN) {
					if (write(ep0, NULL, 0) < 0) { /* a stall is the expected error */ }
				} else {
					if (read(ep0, NULL, 0) < 0) { /* likewise */ }
				}
			}
		}
	}
}

static int ffs_open(const char *dir)
{
	char p[PATH_MAX];
	snprintf(p, sizeof p, "%s/ep0", dir);
	ep0 = open(p, O_RDWR);
	if (ep0 < 0) {
		logf_("%s: %s", p, strerror(errno));
		return -1;
	}
	if (write(ep0, &descriptors, sizeof descriptors) != (ssize_t)sizeof descriptors ||
	    write(ep0, &strings, sizeof strings) != (ssize_t)sizeof strings) {
		logf_("%s: writing descriptors: %s", p, strerror(errno));
		return -1;
	}
	snprintf(p, sizeof p, "%s/ep1", dir);
	fd_in = open(p, O_RDONLY);
	snprintf(p, sizeof p, "%s/ep2", dir);
	fd_out = open(p, O_WRONLY);
	if (fd_in < 0 || fd_out < 0) {
		logf_("%s/ep1, ep2: %s", dir, strerror(errno));
		return -1;
	}
	pthread_t th;
	pthread_create(&th, NULL, ep0_events, NULL);
	pthread_detach(th);
	return 0;
}
#endif

static int tcp_listen(int port)
{
	int s = socket(AF_INET, SOCK_STREAM, 0), one = 1;
	struct sockaddr_in a = { .sin_family = AF_INET, .sin_port = htons((uint16_t)port) };
	a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
	if (s < 0 || bind(s, (struct sockaddr *)&a, sizeof a) || listen(s, 1)) {
		logf_("tcp %d: %s", port, strerror(errno));
		return -1;
	}
	return s;
}

static int tcp_accept(int s)
{
	int c = accept(s, NULL, NULL);
	if (c < 0)
		return -1;
	char hs[4];
	if (read_full(c, hs, 4) || memcmp(hs, "FB", 2) || write_full(c, "FB01", 4)) {
		close(c);
		return -1;
	}
	fd_in = fd_out = c;
	tcp_left = 0;
	return 0;
}

/* ---- the write policy ------------------------------------------------------ */

static char write_names[MAX_NAMES][NAME_LEN], never_names[MAX_NAMES][NAME_LEN];
static int n_write, n_never;

static int load_policy(char *why, size_t whylen)
{
	FILE *f = fopen(policy_path, "r");
	n_write = n_never = 0;
	if (!f) {
		snprintf(why, whylen, "no write policy at %s: every write is refused", policy_path);
		return -1;
	}
	char line[1024];
	while (fgets(line, sizeof line, f)) {
		char *save = NULL, *w = strtok_r(line, " \t\r\n", &save);
		if (!w || *w == '#')
			continue;
		int kind = !strcmp(w, "write") ? 1 : !strcmp(w, "never") ? 2 : 0;
		if (!kind)
			continue;
		while ((w = strtok_r(NULL, " \t\r\n", &save)) && *w != '#') {
			char (*list)[NAME_LEN] = kind == 1 ? write_names : never_names;
			int *n = kind == 1 ? &n_write : &n_never;
			if (*n < MAX_NAMES && strlen(w) < NAME_LEN) {
				for (char *c = w; *c; c++)
					*c = (char)toupper((unsigned char)*c);
				strcpy(list[(*n)++], w);
			}
		}
	}
	fclose(f);
	if (!n_write || !n_never) {
		snprintf(why, whylen, "%s has no write or no never line: every write is refused", policy_path);
		return -1;
	}
	return 0;
}

static int in_list(char (*list)[NAME_LEN], int n, const char *name)
{
	for (int i = 0; i < n; i++)
		if (!strcmp(list[i], name))
			return 1;
	return 0;
}

/* The by-name link of NAME, or -1. */
static int find_part(const char *name, char *out, size_t outlen)
{
	char dirs[1024];
	snprintf(dirs, sizeof dirs, "%s", blockdirs);
	char *save = NULL;
	for (char *d = strtok_r(dirs, " ", &save); d; d = strtok_r(NULL, " ", &save)) {
		snprintf(out, outlen, "%s/%s", d, name);
		if (access(out, F_OK) == 0)
			return 0;
	}
	return -1;
}

/* The kernel's PARTNAME of the device PATH resolves to. */
static int partname_of(const char *path, char *out, size_t outlen)
{
	char real[PATH_MAX], ue[PATH_MAX], line[256];
	if (!realpath(path, real))
		return -1;
	const char *base = strrchr(real, '/');
	base = base ? base + 1 : real;
	snprintf(ue, sizeof ue, "%s/%s/uevent", sysblock, base);
	FILE *f = fopen(ue, "r");
	if (!f)
		return -1;
	int found = -1;
	while (fgets(line, sizeof line, f))
		if (!strncmp(line, "PARTNAME=", 9)) {
			line[strcspn(line, "\r\n")] = 0;
			snprintf(out, outlen, "%s", line + 9);
			found = 0;
		}
	fclose(f);
	return found;
}

/* Upper-case NAME into OUT; 0 if it is a plain partition name. */
static int norm_name(const char *name, char *out)
{
	size_t n = strlen(name);
	if (!n || n >= NAME_LEN)
		return -1;
	for (size_t i = 0; i <= n; i++) {
		char c = (char)toupper((unsigned char)name[i]);
		if (i < n && !(isupper((unsigned char)c) || isdigit((unsigned char)c) || c == '_'))
			return -1;
		out[i] = c;
	}
	return 0;
}

/* The device to write for NAME, or -1 with the reason in WHY. */
static int writable_dev(const char *name, char *dev, size_t devlen, char *why, size_t whylen)
{
	char up[NAME_LEN], pn[64], real[PATH_MAX], other[PATH_MAX], oreal[PATH_MAX];
	if (norm_name(name, up)) {
		snprintf(why, whylen, "'%s' is not a partition name", name);
		return -1;
	}
	if (load_policy(why, whylen))
		return -1;
	if (in_list(never_names, n_never, up)) {
		snprintf(why, whylen, "%s is never written (Scion's policy: identity, modem, boot loader, secure storage)", up);
		return -1;
	}
	if (!in_list(write_names, n_write, up)) {
		snprintf(why, whylen, "Scion writes only BOOT and USERDATA, not %s", up);
		return -1;
	}
	if (find_part(up, dev, devlen) || !realpath(dev, real)) {
		snprintf(why, whylen, "%s partition not found", up);
		return -1;
	}
	if (partname_of(dev, pn, sizeof pn) || strcmp(pn, up)) {
		snprintf(why, whylen, "%s resolves to a partition named '%s', not %s", up, pn, up);
		return -1;
	}
	for (int i = 0; i < n_never; i++)
		if (!find_part(never_names[i], other, sizeof other) && realpath(other, oreal) && !strcmp(oreal, real)) {
			snprintf(why, whylen, "%s is the same device as %s", up, never_names[i]);
			return -1;
		}
	return 0;
}

/* ---- the write lock ------------------------------------------------------- */

static int lock_take(const char *what, char *why, size_t whylen)
{
	char p[PATH_MAX];
	for (int tries = 0; tries < 2; tries++) {
		if (mkdir(lock_dir, 0700) == 0) {
			FILE *f;
			snprintf(p, sizeof p, "%s/pid", lock_dir);
			if ((f = fopen(p, "w"))) { fprintf(f, "%d\n", (int)getpid()); fclose(f); }
			snprintf(p, sizeof p, "%s/what", lock_dir);
			if ((f = fopen(p, "w"))) { fprintf(f, "fastboot: %s\n", what); fclose(f); }
			return 0;
		}
		int pid = 0;
		snprintf(p, sizeof p, "%s/pid", lock_dir);
		FILE *f = fopen(p, "r");
		if (f) { if (fscanf(f, "%d", &pid) != 1) pid = 0; fclose(f); }
		if (pid > 0 && kill(pid, 0) == 0) {
			snprintf(why, whylen, "another write is running (pid %d): wait for it", pid);
			return -1;
		}
		logf_("taking over a stale write lock (pid %d is gone)", pid);
		snprintf(p, sizeof p, "%s/pid", lock_dir); unlink(p);
		snprintf(p, sizeof p, "%s/what", lock_dir); unlink(p);
		rmdir(lock_dir);
	}
	snprintf(why, whylen, "cannot take the write lock %s", lock_dir);
	return -1;
}

static void lock_drop(void)
{
	char p[PATH_MAX];
	snprintf(p, sizeof p, "%s/pid", lock_dir); unlink(p);
	snprintf(p, sizeof p, "%s/what", lock_dir); unlink(p);
	rmdir(lock_dir);
}

/* ---- block device I/O ---------------------------------------------------- */

static int dev_size(int fd, uint64_t *size)
{
	struct stat st;
	if (fstat(fd, &st))
		return -1;
	if (S_ISBLK(st.st_mode))
		return ioctl(fd, BLKGETSIZE64, size);
	*size = (uint64_t)st.st_size;
	return 0;
}

static int pwrite_full(int fd, const void *buf, size_t len, uint64_t off)
{
	const uint8_t *p = buf;
	while (len) {
		ssize_t r = pwrite(fd, p, len, (off_t)off);
		if (r < 0 && errno == EINTR)
			continue;
		if (r <= 0)
			return -1;
		p += r; len -= (size_t)r; off += (uint64_t)r;
	}
	return 0;
}

static int pread_full(int fd, void *buf, size_t len, uint64_t off)
{
	uint8_t *p = buf;
	while (len) {
		ssize_t r = pread(fd, p, len, (off_t)off);
		if (r < 0 && errno == EINTR)
			continue;
		if (r <= 0)
			return -1;
		p += r; len -= (size_t)r; off += (uint64_t)r;
	}
	return 0;
}

/* What was written is on the device, and the next read comes from it. */
static void flush_dev(int fd)
{
	fsync(fd);
	ioctl(fd, BLKFLSBUF, 0);
	posix_fadvise(fd, 0, 0, POSIX_FADV_DONTNEED);
	int dc = open("/proc/sys/vm/drop_caches", O_WRONLY);
	if (dc >= 0) {
		if (write(dc, "3", 1) < 0) { /* not root (tests) */ }
		close(dc);
	}
}

static uint8_t *scratch;          /* 1 MiB, for read-back and fill */
#define SCRATCH (1u << 20)

/* Compare LEN bytes at OFF with BUF (or, BUF NULL, with the 32-bit FILL). */
static int verify_range(int fd, uint64_t off, const uint8_t *buf, uint64_t len, uint32_t fill)
{
	while (len) {
		size_t k = len > SCRATCH ? SCRATCH : (size_t)len;
		if (pread_full(fd, scratch, k, off))
			return -1;
		if (buf) {
			if (memcmp(scratch, buf, k))
				return -1;
			buf += k;
		} else {
			for (size_t i = 0; i < k; i += 4)
				if (memcmp(scratch + i, &fill, 4))
					return -1;
		}
		off += k; len -= k;
	}
	return 0;
}

static int fill_range(int fd, uint64_t off, uint64_t len, uint32_t fill)
{
	static uint8_t pat[SCRATCH];
	for (size_t i = 0; i < SCRATCH; i += 4)
		memcpy(pat + i, &fill, 4);
	while (len) {
		size_t k = len > SCRATCH ? SCRATCH : (size_t)len;
		if (pwrite_full(fd, pat, k, off))
			return -1;
		off += k; len -= k;
	}
	return 0;
}

/* ---- Android sparse images -------------------------------------------------- */

#define SPARSE_MAGIC 0xed26ff3au
#define CHUNK_RAW 0xcac1
#define CHUNK_FILL 0xcac2
#define CHUNK_DONT_CARE 0xcac3
#define CHUNK_CRC32 0xcac4

static uint32_t le32(const uint8_t *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }
static uint16_t le16(const uint8_t *p) { return (uint16_t)(p[0] | p[1] << 8); }

/* Check (WRITE 0) or write and read back (WRITE 1) a sparse image. */
static int sparse_pass(int fd, const uint8_t *img, size_t len, uint64_t psize, int write, char *why, size_t whylen)
{
	if (len < 28) { snprintf(why, whylen, "sparse header truncated"); return -1; }
	uint16_t major = le16(img + 4), fhs = le16(img + 8), chs = le16(img + 10);
	uint32_t blk = le32(img + 12), nchunks = le32(img + 20);
	if (major != 1 || fhs < 28 || chs < 12 || blk == 0 || blk % 4) {
		snprintf(why, whylen, "unsupported sparse image (version %u, block %u)", major, blk);
		return -1;
	}
	size_t pos = fhs;
	uint64_t out = 0, written = 0;
	for (uint32_t i = 0; i < nchunks; i++) {
		if (pos + chs > len) { snprintf(why, whylen, "sparse chunk %u header truncated", i); return -1; }
		const uint8_t *c = img + pos;
		uint16_t type = le16(c);
		uint32_t nblk = le32(c + 4), total = le32(c + 8);
		uint64_t bytes = (uint64_t)nblk * blk;
		if (total < chs || pos + total > len) { snprintf(why, whylen, "sparse chunk %u truncated", i); return -1; }
		const uint8_t *data = c + chs;
		uint64_t dlen = total - chs;
		if (type != CHUNK_DONT_CARE && type != CHUNK_CRC32 && out + bytes > psize) {
			snprintf(why, whylen, "sparse image reaches past the partition's end");
			return -1;
		}
		switch (type) {
		case CHUNK_RAW:
			if (dlen != bytes) { snprintf(why, whylen, "sparse raw chunk %u size", i); return -1; }
			if (write && (pwrite_full(fd, data, (size_t)bytes, out) ||
				      (flush_dev(fd), verify_range(fd, out, data, bytes, 0)))) {
				snprintf(why, whylen, "write or read-back failed at byte %llu", (unsigned long long)out);
				return -1;
			}
			written += bytes;
			break;
		case CHUNK_FILL:
			if (dlen != 4) { snprintf(why, whylen, "sparse fill chunk %u size", i); return -1; }
			if (write && (fill_range(fd, out, bytes, le32(data)) ||
				      (flush_dev(fd), verify_range(fd, out, NULL, bytes, le32(data))))) {
				snprintf(why, whylen, "fill or read-back failed at byte %llu", (unsigned long long)out);
				return -1;
			}
			written += bytes;
			break;
		case CHUNK_DONT_CARE:
			break;
		case CHUNK_CRC32:
			bytes = 0;
			break;
		default:
			snprintf(why, whylen, "unknown sparse chunk type 0x%x", type);
			return -1;
		}
		out += bytes;
		pos += total;
	}
	if (write)
		logf_("sparse: %llu bytes written and read back", (unsigned long long)written);
	return 0;
}

/* ---- commands --------------------------------------------------------------- */

static uint8_t *dl;              /* the download buffer */
static size_t dl_len;

static void prop(const char *name, char *out, size_t outlen)
{
	char cmd[128];
	out[0] = 0;
	snprintf(cmd, sizeof cmd, "getprop %s 2>/dev/null", name);
	FILE *p = popen(cmd, "r");
	if (!p)
		return;
	if (!fgets(out, (int)outlen, p))
		out[0] = 0;
	pclose(p);
	out[strcspn(out, "\r\n")] = 0;
}

static int getvar(const char *v, char *val, size_t vlen)
{
	char name[NAME_LEN], dev[PATH_MAX], why[256];
	if (!strcmp(v, "version")) snprintf(val, vlen, "0.4");
	else if (!strcmp(v, "version-bootloader")) prop("ro.boot.bootloader", val, vlen);
	else if (!strcmp(v, "product")) { prop("ro.product.device", val, vlen); if (!*val) snprintf(val, vlen, "starlte"); }
	else if (!strcmp(v, "serialno")) prop("ro.serialno", val, vlen);
	else if (!strcmp(v, "max-download-size")) snprintf(val, vlen, "0x%x", max_download);
	else if (!strcmp(v, "is-userspace")) snprintf(val, vlen, "yes");
	else if (!strcmp(v, "slot-count")) snprintf(val, vlen, "0");
	else if (!strcmp(v, "secure")) snprintf(val, vlen, "no");
	else if (!strcmp(v, "scion-version")) snprintf(val, vlen, "scion-fastbootd %s", VERSION);
	else if (!strncmp(v, "has-slot:", 9) || !strncmp(v, "is-logical:", 11)) snprintf(val, vlen, "no");
	else if (!strncmp(v, "partition-type:", 15)) snprintf(val, vlen, "raw");
	else if (!strncmp(v, "partition-size:", 15)) {
		uint64_t sz = 0;
		if (norm_name(v + 15, name) || find_part(name, dev, sizeof dev))
			return -1;
		int fd = open(dev, O_RDONLY);
		if (fd < 0 || dev_size(fd, &sz)) { if (fd >= 0) close(fd); return -1; }
		close(fd);
		snprintf(val, vlen, "0x%llx", (unsigned long long)sz);
	} else if (!strncmp(v, "scion-writable:", 15))
		snprintf(val, vlen, "%s", writable_dev(v + 15, dev, sizeof dev, why, sizeof why) ? "no" : "yes");
	else
		return -1;
	return 0;
}

static void cmd_getvar(const char *v)
{
	char val[256];
	if (!strcmp(v, "all")) {
		static const char *all[] = { "version", "version-bootloader", "product", "max-download-size",
					     "is-userspace", "slot-count", "secure", "scion-version", NULL };
		for (int i = 0; all[i]; i++)
			if (!getvar(all[i], val, sizeof val))
				INFO("%s: %s", all[i], val);
		static const char *parts[] = { "BOOT", "USERDATA", NULL };
		for (int i = 0; parts[i]; i++) {
			char q[64];
			snprintf(q, sizeof q, "partition-size:%s", parts[i]);
			if (!getvar(q, val, sizeof val))
				INFO("%s: %s", q, val);
		}
		OKAY("%s", "");
		return;
	}
	if (getvar(v, val, sizeof val))
		FAIL("unknown variable %s", v);
	else
		OKAY("%s", val);
}

static void cmd_download(const char *arg)
{
	char *end;
	unsigned long n = strtoul(arg, &end, 16);
	if (*arg == 0 || *end || n == 0) { FAIL("bad download size"); return; }
	if (n > max_download) { FAIL("too big: max-download-size is 0x%x", max_download); return; }
	if (reply("DATA", "%08lx", n))
		return;
	if (t_read_data(dl, n)) {
		logf_("download: transfer failed");
		dl_len = 0;
		return;
	}
	dl_len = n;
	char h[65];
	sha256_of(dl, dl_len, h);
	logf_("download: %zu bytes, sha256 %s", dl_len, h);
	OKAY("%s", "");
}

static void cmd_flash(const char *part)
{
	char dev[PATH_MAX], why[256], up[NAME_LEN], h[65];
	if (writable_dev(part, dev, sizeof dev, why, sizeof why)) { FAIL("refused: %s", why); return; }
	norm_name(part, up);
	if (!dl_len) { FAIL("nothing downloaded"); return; }
	int sparse = dl_len >= 28 && le32(dl) == SPARSE_MAGIC;
	if (!sparse && !strcmp(up, "BOOT") && (dl_len < 8 || memcmp(dl, "ANDROID!", 8))) {
		FAIL("refused: not an Android boot image (no ANDROID! magic)");
		return;
	}
	int fd = open(dev, O_RDWR);
	uint64_t psize = 0;
	if (fd < 0 || dev_size(fd, &psize)) { FAIL("cannot open %s", up); if (fd >= 0) close(fd); return; }
	if (sparse ? sparse_pass(fd, dl, dl_len, psize, 0, why, sizeof why) : (dl_len > psize ? -1 : 0)) {
		if (!sparse)
			snprintf(why, sizeof why, "%zu bytes do not fit in %s (%llu)", dl_len, up, (unsigned long long)psize);
		FAIL("refused: %s", why);
		close(fd);
		return;
	}
	if (lock_take(up, why, sizeof why)) { FAIL("%s", why); close(fd); return; }
	sha256_of(dl, dl_len, h);
	INFO("writing %s (%zu bytes%s, sha256 %.16s...)", up, dl_len, sparse ? ", sparse" : "", h);
	action_log("write %s dev=%s size=%zu sparse=%d sha256=%s", up, dev, dl_len, sparse, h);
	int bad;
	if (sparse) {
		bad = sparse_pass(fd, dl, dl_len, psize, 1, why, sizeof why);
	} else {
		bad = pwrite_full(fd, dl, dl_len, 0);
		if (bad)
			snprintf(why, sizeof why, "write failed: %s", strerror(errno));
		else {
			flush_dev(fd);
			if ((bad = verify_range(fd, 0, dl, dl_len, 0)))
				snprintf(why, sizeof why, "read-back MISMATCH: do not boot it, flash again");
		}
	}
	close(fd);
	lock_drop();
	if (bad) {
		action_log("write %s FAILED: %s", up, why);
		FAIL("%s", why);
		return;
	}
	action_log("write %s ok, read back", up);
	INFO("%s written and read back", up);
	OKAY("%s", "");
}

static void cmd_erase(const char *part)
{
	char dev[PATH_MAX], why[256], up[NAME_LEN];
	if (writable_dev(part, dev, sizeof dev, why, sizeof why)) { FAIL("refused: %s", why); return; }
	norm_name(part, up);
	int fd = open(dev, O_RDWR);
	uint64_t psize = 0;
	if (fd < 0 || dev_size(fd, &psize)) { FAIL("cannot open %s", up); if (fd >= 0) close(fd); return; }
	if (lock_take(up, why, sizeof why)) { FAIL("%s", why); close(fd); return; }
	/* BOOT: all of it. USERDATA: its first and last 16 MiB, where file
	 * systems keep their headers, so nothing mounts it as before. */
	uint64_t edge = 16u << 20, ranges[2][2] = { { 0, psize }, { 0, 0 } };
	if (strcmp(up, "BOOT") && psize > 2 * edge) {
		ranges[0][1] = edge;
		ranges[1][0] = psize - edge;
		ranges[1][1] = edge;
	}
	int bad = 0;
	for (int i = 0; i < 2 && !bad; i++)
		if (ranges[i][1])
			bad = fill_range(fd, ranges[i][0], ranges[i][1], 0) ||
			      (flush_dev(fd), verify_range(fd, ranges[i][0], NULL, ranges[i][1], 0));
	close(fd);
	lock_drop();
	action_log("erase %s %s", up, bad ? "FAILED" : "ok");
	if (bad)
		FAIL("erase of %s failed", up);
	else
		OKAY("%s", "");
}

static void do_reboot(const char *target)
{
	logf_("reboot %s", *target ? target : "(system)");
	if (no_reboot) {
		logf_("--no-reboot: not rebooting");
		return;
	}
	char arg[64];
	snprintf(arg, sizeof arg, "reboot,%s", target);
	pid_t pid = fork();
	if (pid == 0) {
		execl("/sbin/setprop", "setprop", "sys.powerctl", arg, (char *)NULL);
		execlp("setprop", "setprop", "sys.powerctl", arg, (char *)NULL);
		_exit(127);
	}
	if (pid > 0)
		waitpid(pid, NULL, 0);
	sleep(5);
	/* init did not take it: ask the kernel. */
	sync();
	syscall(SYS_reboot, LINUX_REBOOT_MAGIC1, LINUX_REBOOT_MAGIC2, LINUX_REBOOT_CMD_RESTART2, target);
}

static int handle(char *cmd)
{
	logf_("> %s", cmd);
	if (!strncmp(cmd, "getvar:", 7)) cmd_getvar(cmd + 7);
	else if (!strncmp(cmd, "download:", 9)) cmd_download(cmd + 9);
	else if (!strncmp(cmd, "flash:", 6)) cmd_flash(cmd + 6);
	else if (!strncmp(cmd, "erase:", 6)) cmd_erase(cmd + 6);
	else if (!strcmp(cmd, "reboot") || !strcmp(cmd, "continue")) { OKAY("%s", ""); do_reboot(""); return 1; }
	else if (!strcmp(cmd, "reboot-bootloader")) {
		/* The S9's boot loader has Download mode, not fastboot. */
		INFO("rebooting to Download mode (Odin/heimdall): the S9's boot loader has no fastboot");
		OKAY("%s", ""); do_reboot("download"); return 1;
	} else if (!strcmp(cmd, "reboot-recovery")) { OKAY("%s", ""); do_reboot("recovery"); return 1; }
	else if (!strcmp(cmd, "reboot-fastboot")) { INFO("already in Scion recovery's fastboot"); OKAY("%s", ""); }
	else if (!strcmp(cmd, "oem scion-policy")) {
		char why[256];
		if (load_policy(why, sizeof why)) FAIL("%s", why);
		else {
			char line[200] = "";
			for (int i = 0; i < n_write; i++) { strcat(line, " "); strcat(line, write_names[i]); }
			INFO("may write:%s", line);
			line[0] = 0;
			for (int i = 0; i < n_never && strlen(line) < 150; i++) { strcat(line, " "); strcat(line, never_names[i]); }
			INFO("never:%s", line);
			OKAY("%s", "");
		}
	} else if (!strncmp(cmd, "flashing", 8) || !strncmp(cmd, "oem", 3))
		FAIL("not in Scion's fastbootd (no locking, no OEM commands)");
	else if (!strcmp(cmd, "boot"))
		FAIL("fastboot boot is not possible here: flash boot, then reboot");
	else
		FAIL("unknown command");
	return 0;
}

static void usage(void)
{
	fprintf(stderr, "usage: scion-fastbootd (--ffs DIR | --tcp PORT) [--no-reboot] [--ready FILE]\n"
			"  environment: SCION_POLICY, SCION_BLOCKDIRS, SCION_SYSBLOCK, SCION_LOCK, SCION_ACTLOG,\n"
			"  SCION_MAX_DOWNLOAD (bytes)\n");
	exit(2);
}

int main(int argc, char **argv)
{
	const char *ffs = NULL;
	int port = 0;
	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--ffs") && i + 1 < argc) ffs = argv[++i];
		else if (!strcmp(argv[i], "--tcp") && i + 1 < argc) port = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--no-reboot")) no_reboot = 1;
		else if (!strcmp(argv[i], "--ready") && i + 1 < argc) ready_file = argv[++i];
		else if (!strcmp(argv[i], "--version")) { printf("scion-fastbootd %s\n", VERSION); return 0; }
		else usage();
	}
	if (!ffs == !port)
		usage();
	const char *e;
	if ((e = getenv("SCION_POLICY"))) policy_path = e;
	if ((e = getenv("SCION_BLOCKDIRS"))) blockdirs = e;
	if ((e = getenv("SCION_SYSBLOCK"))) sysblock = e;
	if ((e = getenv("SCION_LOCK"))) lock_dir = e;
	if ((e = getenv("SCION_ACTLOG"))) actlog = e;
	if ((e = getenv("SCION_MAX_DOWNLOAD"))) max_download = (uint32_t)strtoul(e, NULL, 0);
	signal(SIGPIPE, SIG_IGN);
	dl = malloc(max_download);
	scratch = malloc(SCRATCH);
	if (!dl || !scratch) {
		logf_("cannot allocate %u bytes for downloads", max_download);
		return 1;
	}
	char why[256];
	if (load_policy(why, sizeof why))
		logf_("%s", why);
	else
		logf_("policy %s: %d names to write, %d never", policy_path, n_write, n_never);
	int ls = -1;
	if (port) {
		t_tcp = 1;
		if ((ls = tcp_listen(port)) < 0)
			return 1;
		logf_("listening on 127.0.0.1:%d", port);
	} else {
#ifdef NO_FFS
		logf_("built without FunctionFS");
		return 1;
#else
		if (ffs_open(ffs))
			return 1;
		logf_("fastboot on %s", ffs);
#endif
	}
	if (ready_file) {
		FILE *f = fopen(ready_file, "w");
		if (f) { fprintf(f, "%d\n", (int)getpid()); fclose(f); }
	}
	char cmd[4097];
	for (;;) {
		if (t_tcp && fd_in < 0 && tcp_accept(ls))
			continue;
		ssize_t n = t_read_cmd(cmd, sizeof cmd);
		if (n < 0) {
			if (t_tcp) {
				close(fd_in);
				fd_in = fd_out = -1;
				continue;
			}
			logf_("USB read failed: %s; waiting", strerror(errno));
			sleep(1);
			continue;
		}
		if (handle(cmd) && !no_reboot)
			break;
	}
	return 0;
}
