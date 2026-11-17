# Licensing

This file is a plain-English map of who may use what under which licence. It does not replace the licence files.

The repository-level `LICENSE` is GPL-2.0 (the recovery is built on TeamWin's TWRP) and is not changed.

## Original work: MIT-0

Files that the Scion project wrote entirely from scratch (every commit by the project's authors, no third-party notice, nothing ported or derived from another codebase) are licensed **MIT-0** (MIT No Attribution, SPDX `MIT-0`; text in `LICENSES/MIT-0.txt`). Each such file carries `SPDX-License-Identifier: MIT-0` in its first lines, except the files listed in the table below, which cannot hold a comment.

MIT-0 paths (top-level location, number of files, 17 November 2026):

- `(top level)`: 7 files (README.md, RESTORE.md, TESTING.md, CHANGELOG.md, build.sh, verify.sh, .gitignore)
- `.github`: 1 file (the build workflow)
- `fastbootd`: 1 file (scion-fastbootd.c, written from scratch from the fastboot protocol's documentation)
- `overlay`: 4 files (scion, scion-bootlogs, init.recovery.samsungexynos9810.rc, etc/scion-partitions.conf)
- `scripts`: 8 files
- `tests`: 6 files
- `theme`: 2 files (scion.xml, splash.xml)

The full per-file list is in the pull request that introduced this file, and every file's own first lines are authoritative.

`theme/art/scion-logo.svg` is the Scion project's logo, copied from the website repository, which keeps its logo
images under their own terms (`theme/art/SOURCE`).

What the build makes from TeamWin's files (the theme's ui.xml, portrait.xml and recoloured PNGs, TWRP's fstab)
stays under TWRP's licence; `scripts/theme.py` and `scripts/fstab.py`, which make them, are MIT-0.

## Files that keep their existing licence

- Anything not listed above, and any file that has no explicit `SPDX-License-Identifier: MIT-0` tag, stays under the repository's existing licence, as before.
- `third_party/*`: apfs-fuse and `third_party/apfs-fuse/apfs-extract/apfs-extract.cpp` (GPL-2.0-or-later), apfsprogs (GPL-2.0), hfsfuse (MIT, with BSD-licensed libraries), each under its own terms.
- Everything TWRP ships in the stock image this builds on (not in this repository).

