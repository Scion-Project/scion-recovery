/*
	apfs-extract: read-only APFS file extractor built on ApfsLib (apfs-fuse).
	No FUSE, no kernel support needed. Intended for Android recovery (TWRP).

	Copyright (C) 2017 Simon Gander (ApfsLib)
	This file: GPL-2.0-or-later, same licence as apfs-fuse.

	Usage:
	  apfs-extract [opts] DEVICE vols
	  apfs-extract [opts] DEVICE ls   [PATH]
	  apfs-extract [opts] DEVICE stat PATH
	  apfs-extract [opts] DEVICE cat  PATH            > out
	  apfs-extract [opts] DEVICE get  PATH DESTDIR    (recursive copy)
	  apfs-extract [opts] DEVICE tar  PATH            > out.tar  (ustar/GNU, to stdout)
	opts: -v VOLID   volume index (default 0)
	      -s OFFSET  container byte offset inside DEVICE
	      -r PASS    passphrase for an encrypted volume
	      -q         quiet (no per-file progress on stderr)
*/

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cerrno>
#include <cinttypes>
#include <string>
#include <vector>

#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/types.h>

#include <ApfsLib/ApfsContainer.h>
#include <ApfsLib/ApfsVolume.h>
#include <ApfsLib/ApfsDir.h>
#include <ApfsLib/Decmpfs.h>
#include <ApfsLib/Device.h>
#include <ApfsLib/GptPartitionMap.h>

static ApfsVolume *g_vol;
static bool g_quiet = false;
static int g_errors = 0;

static void usage(const char *p)
{
	fprintf(stderr,
		"Usage: %s [-v vol] [-s offset] [-r pass] [-q] DEVICE CMD [args]\n"
		"  vols                 list volumes in the container\n"
		"  ls   [PATH]          long listing of a directory (default /)\n"
		"  stat PATH            show one inode\n"
		"  cat  PATH            write file contents to stdout\n"
		"  get  PATH DESTDIR    copy file or tree into DESTDIR (keeps mode, mtime, symlinks)\n"
		"  tar  PATH            write a tar stream of file or tree to stdout\n", p);
}

static bool lookup(ApfsDir &dir, const std::string &path, uint64_t &ino)
{
	ino = ROOT_DIR_INO_NUM;
	size_t pos = 0;
	while (pos < path.size()) {
		while (pos < path.size() && path[pos] == '/') pos++;
		if (pos >= path.size()) break;
		size_t e = path.find('/', pos);
		std::string comp = path.substr(pos, e == std::string::npos ? std::string::npos : e - pos);
		pos = (e == std::string::npos) ? path.size() : e;
		if (comp == ".") continue;
		ApfsDir::DirRec rec;
		if (!dir.LookupName(rec, ino, comp.c_str())) return false;
		ino = rec.file_id;
	}
	return true;
}

/* Fills data with the full (decompressed) file contents. Fine for logs etc;
   large uncompressed files go through streamFile instead. */
static bool isCompressed(const ApfsDir::Inode &in) { return (in.bsd_flags & APFS_UF_COMPRESSED) != 0; }

static uint64_t fileSize(ApfsDir &dir, uint64_t ino, const ApfsDir::Inode &in)
{
	if (S_ISREG(in.mode) && isCompressed(in)) {
		if (in.internal_flags & INODE_HAS_UNCOMPRESSED_SIZE) return in.uncompressed_size;
		std::vector<uint8_t> a;
		if (dir.GetAttribute(a, ino, "com.apple.decmpfs") && a.size() >= sizeof(CompressionHeader))
			return reinterpret_cast<const CompressionHeader *>(a.data())->size;
		return 0;
	}
	if (in.optional_present_flags & ApfsDir::Inode::INO_HAS_DSTREAM) return in.ds_size;
	return 0;
}

/* Calls sink(buf, len) over the file contents. */
template <typename F>
static bool streamFile(ApfsDir &dir, uint64_t ino, const ApfsDir::Inode &in, F sink)
{
	if (isCompressed(in)) {
		std::vector<uint8_t> attr, out;
		if (!dir.GetAttribute(attr, ino, "com.apple.decmpfs")) return false;
		if (!DecompressFile(dir, ino, out, attr)) return false;
		return sink(out.data(), out.size());
	}
	uint64_t size = (in.optional_present_flags & ApfsDir::Inode::INO_HAS_DSTREAM) ? in.ds_size : 0;
	const size_t chunk = 1 << 20;
	std::vector<uint8_t> buf(chunk);
	for (uint64_t off = 0; off < size; ) {
		size_t n = (size - off) < chunk ? (size_t)(size - off) : chunk;
		if (!dir.ReadFile(buf.data(), in.private_id, off, n)) return false;
		if (!sink(buf.data(), n)) return false;
		off += n;
	}
	return true;
}

static bool writeAll(int fd, const void *p, size_t n)
{
	const uint8_t *b = (const uint8_t *)p;
	while (n) {
		ssize_t w = write(fd, b, n);
		if (w < 0) { if (errno == EINTR) continue; return false; }
		b += w; n -= w;
	}
	return true;
}

static std::string readSymlink(ApfsDir &dir, uint64_t ino)
{
	std::vector<uint8_t> d;
	if (!dir.GetAttribute(d, ino, "com.apple.fs.symlink")) return std::string();
	return std::string(reinterpret_cast<const char *>(d.data()), strnlen(reinterpret_cast<const char *>(d.data()), d.size()));
}

static char typeChar(uint16_t m)
{
	if (S_ISDIR(m)) return 'd';
	if (S_ISLNK(m)) return 'l';
	if (S_ISCHR(m)) return 'c';
	if (S_ISBLK(m)) return 'b';
	if (S_ISFIFO(m)) return 'p';
	if (S_ISSOCK(m)) return 's';
	return '-';
}

static void printLong(ApfsDir &dir, uint64_t ino, const ApfsDir::Inode &in, const std::string &name)
{
	char perm[11];
	perm[0] = typeChar(in.mode);
	const char *rwx = "rwxrwxrwx";
	for (int i = 0; i < 9; i++) perm[1 + i] = (in.mode & (0400 >> i)) ? rwx[i] : '-';
	perm[10] = 0;
	time_t t = (time_t)(in.mod_time / 1000000000ULL);
	struct tm tm; gmtime_r(&t, &tm);
	char ts[32]; strftime(ts, sizeof ts, "%Y-%m-%d %H:%M", &tm);
	printf("%s %5u %5u %12" PRIu64 " %s %s", perm, in.owner, in.group, fileSize(dir, ino, in), ts, name.c_str());
	if (S_ISLNK(in.mode)) printf(" -> %s", readSymlink(dir, ino).c_str());
	if (isCompressed(in)) printf("  [compressed]");
	printf("\n");
}

static void setMeta(const std::string &p, const ApfsDir::Inode &in, bool isLink)
{
	struct timespec ts[2];
	ts[0].tv_sec = in.access_time / 1000000000ULL; ts[0].tv_nsec = in.access_time % 1000000000ULL;
	ts[1].tv_sec = in.mod_time / 1000000000ULL; ts[1].tv_nsec = in.mod_time % 1000000000ULL;
	utimensat(AT_FDCWD, p.c_str(), ts, isLink ? AT_SYMLINK_NOFOLLOW : 0);
	if (!isLink) chmod(p.c_str(), in.mode & 07777);
}

static void getTree(ApfsDir &dir, uint64_t ino, const std::string &dst, int depth)
{
	ApfsDir::Inode in;
	if (!dir.GetInode(in, ino)) { fprintf(stderr, "error: inode %" PRIu64 " unreadable (%s)\n", ino, dst.c_str()); g_errors++; return; }
	if (S_ISDIR(in.mode)) {
		if (mkdir(dst.c_str(), 0755) != 0 && errno != EEXIST) { perror(dst.c_str()); g_errors++; return; }
		std::vector<ApfsDir::DirRec> ents;
		if (!dir.ListDirectory(ents, ino)) { fprintf(stderr, "error: cannot list %s\n", dst.c_str()); g_errors++; return; }
		for (auto &e : ents) getTree(dir, e.file_id, dst + "/" + e.name, depth + 1);
		setMeta(dst, in, false);
	} else if (S_ISLNK(in.mode)) {
		std::string tgt = readSymlink(dir, ino);
		unlink(dst.c_str());
		if (symlink(tgt.c_str(), dst.c_str()) != 0) { perror(dst.c_str()); g_errors++; return; }
		setMeta(dst, in, true);
	} else if (S_ISREG(in.mode)) {
		if (!g_quiet) fprintf(stderr, "%s\n", dst.c_str());
		int fd = open(dst.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0644);
		if (fd < 0) { perror(dst.c_str()); g_errors++; return; }
		bool ok = streamFile(dir, ino, in, [&](const uint8_t *b, size_t n) { return writeAll(fd, b, n); });
		close(fd);
		if (!ok) { fprintf(stderr, "error: read failed: %s\n", dst.c_str()); g_errors++; }
		setMeta(dst, in, false);
	} else {
		if (!g_quiet) fprintf(stderr, "skip special file %s\n", dst.c_str());
	}
}

/* ---- minimal tar writer (ustar + GNU longname) ---- */
static void tarOct(char *f, size_t len, uint64_t v) { snprintf(f, len, "%0*" PRIo64, (int)len - 1, v); }
static bool tarHeader(const std::string &name, char type, uint64_t size, const ApfsDir::Inode &in, const std::string &link)
{
	if (name.size() > 99) {
		std::string ln = name; ln.push_back('\0');
		ApfsDir::Inode dummy = in;
		if (!tarHeader("././@LongLink", 'L', ln.size(), dummy, "")) return false;
		std::vector<char> pad((ln.size() + 511) & ~511ULL, 0);
		memcpy(pad.data(), ln.data(), ln.size());
		if (!writeAll(1, pad.data(), pad.size())) return false;
	}
	char h[512]; memset(h, 0, sizeof h);
	strncpy(h, name.c_str(), 99);
	tarOct(h + 100, 8, in.mode & 07777);
	tarOct(h + 108, 8, in.owner);
	tarOct(h + 116, 8, in.group);
	tarOct(h + 124, 12, size);
	tarOct(h + 136, 12, in.mod_time / 1000000000ULL);
	h[156] = type;
	strncpy(h + 157, link.c_str(), 99);
	memcpy(h + 257, "ustar  ", 8);
	memset(h + 148, ' ', 8);
	unsigned sum = 0; for (int i = 0; i < 512; i++) sum += (unsigned char)h[i];
	snprintf(h + 148, 8, "%06o", sum); h[155] = ' ';
	return writeAll(1, h, 512);
}

static void tarTree(ApfsDir &dir, uint64_t ino, const std::string &name)
{
	ApfsDir::Inode in;
	if (!dir.GetInode(in, ino)) { fprintf(stderr, "error: inode %" PRIu64 " unreadable (%s)\n", ino, name.c_str()); g_errors++; return; }
	if (S_ISDIR(in.mode)) {
		tarHeader(name + "/", '5', 0, in, "");
		std::vector<ApfsDir::DirRec> ents;
		if (!dir.ListDirectory(ents, ino)) { g_errors++; return; }
		for (auto &e : ents) tarTree(dir, e.file_id, name + "/" + e.name);
	} else if (S_ISLNK(in.mode)) {
		tarHeader(name, '2', 0, in, readSymlink(dir, ino));
	} else if (S_ISREG(in.mode)) {
		if (!g_quiet) fprintf(stderr, "%s\n", name.c_str());
		uint64_t size = fileSize(dir, ino, in);
		/* Decompress first for compressed files so the header size is exact. */
		std::vector<uint8_t> data;
		bool ok;
		if (isCompressed(in)) {
			ok = streamFile(dir, ino, in, [&](const uint8_t *b, size_t n) { data.insert(data.end(), b, b + n); return true; });
			size = ok ? data.size() : 0;
			tarHeader(name, '0', size, in, "");
			if (ok) writeAll(1, data.data(), data.size());
		} else {
			tarHeader(name, '0', size, in, "");
			uint64_t written = 0;
			ok = streamFile(dir, ino, in, [&](const uint8_t *b, size_t n) { written += n; return writeAll(1, b, n); });
			if (!ok) { /* keep the stream consistent: pad with zeros */
				std::vector<uint8_t> z(65536, 0);
				while (written < size) { size_t n = (size - written) < z.size() ? (size_t)(size - written) : z.size(); writeAll(1, z.data(), n); written += n; }
			}
		}
		if (!ok) { fprintf(stderr, "error: read failed: %s\n", name.c_str()); g_errors++; }
		static const char zero[512] = {0};
		if (size % 512) writeAll(1, zero, 512 - size % 512);
	}
}

int main(int argc, char **argv)
{
	unsigned vol = 0;
	uint64_t offset = 0;
	std::string pass;
	int c;
	while ((c = getopt(argc, argv, "v:s:r:qh")) != -1) {
		switch (c) {
		case 'v': vol = strtoul(optarg, nullptr, 0); break;
		case 's': offset = strtoull(optarg, nullptr, 0); break;
		case 'r': pass = optarg; break;
		case 'q': g_quiet = true; break;
		default: usage(argv[0]); return 2;
		}
	}
	if (argc - optind < 2) { usage(argv[0]); return 2; }
	const char *devpath = argv[optind];
	std::string cmd = argv[optind + 1];
	std::vector<std::string> args(argv + optind + 2, argv + argc);

	Device *dev = Device::OpenDevice(devpath);
	if (!dev) { fprintf(stderr, "cannot open %s\n", devpath); return 1; }
	uint64_t size = dev->GetSize();
	if (offset == 0) {
		GptPartitionMap gpt;
		if (gpt.LoadAndVerify(*dev)) {
			int p = gpt.FindFirstAPFSPartition();
			if (p != -1) gpt.GetPartitionOffsetAndSize(p, offset, size);
		}
	} else {
		if (offset >= size) { fprintf(stderr, "offset beyond device\n"); return 1; }
		size -= offset;
	}
	ApfsContainer *ct = new ApfsContainer(dev, offset, size);
	if (!ct->Init()) { fprintf(stderr, "not an APFS container (or unreadable)\n"); return 1; }

	if (cmd == "vols") {
		for (unsigned k = 0; k < 100; k++) {
			apfs_superblock_t sb;
			if (!ct->GetVolumeInfo(k, sb)) break;
			printf("vol %u: name=\"%s\" role=0x%x used=%" PRIu64 " bytes%s%s\n", k,
				reinterpret_cast<const char *>(sb.apfs_volname), (unsigned)sb.apfs_role,
				(uint64_t)sb.apfs_fs_alloc_count * ct->GetBlocksize(),
				(sb.apfs_incompatible_features & APFS_INCOMPAT_SEALED_VOLUME) ? " sealed" : "",
				(sb.apfs_fs_flags & APFS_FS_UNENCRYPTED) ? "" : " encrypted");
		}
		return 0;
	}

	g_vol = ct->GetVolume(vol, pass);
	if (!g_vol) { fprintf(stderr, "cannot open volume %u\n", vol); return 1; }
	ApfsDir dir(*g_vol);

	std::string path = args.empty() ? "/" : args[0];
	uint64_t ino;
	if (!lookup(dir, path, ino)) { fprintf(stderr, "%s: not found\n", path.c_str()); return 1; }
	ApfsDir::Inode in;
	if (!dir.GetInode(in, ino)) { fprintf(stderr, "%s: inode unreadable\n", path.c_str()); return 1; }

	if (cmd == "ls") {
		if (!S_ISDIR(in.mode)) { printLong(dir, ino, in, path); return 0; }
		std::vector<ApfsDir::DirRec> ents;
		if (!dir.ListDirectory(ents, ino)) { fprintf(stderr, "cannot list %s\n", path.c_str()); return 1; }
		for (auto &e : ents) {
			ApfsDir::Inode ci;
			if (dir.GetInode(ci, e.file_id)) printLong(dir, e.file_id, ci, e.name);
			else printf("?????????? %s (inode %" PRIu64 " unreadable)\n", e.name.c_str(), e.file_id);
		}
	} else if (cmd == "stat") {
		printf("inode=%" PRIu64 " private_id=%" PRIu64 " mode=0%o uid=%u gid=%u size=%" PRIu64 " bsd_flags=0x%x compressed=%d mtime=%" PRIu64 "\n",
			ino, in.private_id, in.mode, in.owner, in.group, fileSize(dir, ino, in), in.bsd_flags, isCompressed(in) ? 1 : 0, in.mod_time / 1000000000ULL);
	} else if (cmd == "cat") {
		if (!S_ISREG(in.mode)) { fprintf(stderr, "%s: not a regular file\n", path.c_str()); return 1; }
		if (!streamFile(dir, ino, in, [](const uint8_t *b, size_t n) { return writeAll(1, b, n); })) { fprintf(stderr, "read failed\n"); return 1; }
	} else if (cmd == "get") {
		if (args.size() < 2) { usage(argv[0]); return 2; }
		std::string base = path;
		while (base.size() > 1 && base.back() == '/') base.pop_back();
		size_t sl = base.rfind('/');
		std::string leaf = (base == "/") ? "root" : base.substr(sl + 1);
		mkdir(args[1].c_str(), 0755);
		getTree(dir, ino, args[1] + "/" + leaf, 0);
	} else if (cmd == "tar") {
		std::string base = path;
		while (base.size() > 1 && base.back() == '/') base.pop_back();
		std::string leaf = (base == "/") ? "root" : base.substr(base.rfind('/') + 1);
		tarTree(dir, ino, leaf);
		static const char zero[1024] = {0};
		writeAll(1, zero, sizeof zero);
	} else {
		usage(argv[0]); return 2;
	}
	if (g_errors) fprintf(stderr, "%d error(s)\n", g_errors);
	return g_errors ? 3 : 0;
}
