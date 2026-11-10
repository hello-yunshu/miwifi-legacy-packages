#!/bin/sh
# Rewrite the baked DT_RPATH of a deployed lighttpd tree so it never points at
# a path outside the .yunshu tree (the build prefix lived at the data-disk root).
#
# The build produced a two-entry RPATH string:
#   /work/stage2/b6-webdav/root/userdisk/data/r2d-cand/b6-webdav/root/lib
#   :/userdisk/data/r2d-cand/b6-webdav/root/lib                      (112 bytes)
# The /work/stage2 entry is a build-host artifact and never exists on the
# device; only the second entry matters.  This script replaces the whole
# 112-byte string (or the 43/42-byte single-entry variants) with
#   /userdisk/data/.yunshu/live/webdav/lib                          (38 bytes)
# followed by NUL padding, so the file size and every .dynstr offset stay
# unchanged.  Padding is safe: the string ends at the first NUL and no other
# dynstr entry starts inside the replaced region.
#
# Replacement length must be identical to the matched region, otherwise ELF
# offsets shift and lighttpd dies with SIGILL on startup.  The replacement is
# a plain string and must not be quoted inside s{}{}: quotes become literals.
#
# Without it, mod_webdav.so / mod_auth.so / ... resolve libxml2.so.16 and
# libsqlite3.so from a path outside .yunshu, which forces a visible development
# symlink to stay at the data root.  LD_LIBRARY_PATH does not help: uClibc
# searches the loading object's own DT_RPATH first.
#
# Usage: patch-rpath.sh [tree-root]   (default: live/webdav/current)
set -u
TARGET=${1:-/userdisk/data/.yunshu/live/webdav/current}
ROOT=$(cd "$TARGET" && pwd -P) || exit 1
changed=0
for f in $(find "$ROOT" -type f); do
	head -c 4 "$f" 2>/dev/null | grep -q ELF || continue
	strings "$f" 2>/dev/null | grep -q -E "r2d-cand/b6-webdav|\.dev/live/webdav/currentlib" || continue
	before=$(wc -c <"$f")
	perl -0777 -i -pe '
		my $n = "/userdisk/data/.yunshu/live/webdav/lib";
		my $old = qr{(?:\.dev/live/webdav/currentlib|r2d-cand/b6-webdav/root/lib)};
		s{/work/stage2/b6-webdav/root/userdisk/data/$old:/userdisk/data/$old}{$n . ("\0" x 74)}ge;
		s{:/userdisk/data/$old}{$n . ("\0" x 5)}ge;
		s{/userdisk/data/$old}{$n . ("\0" x 4)}ge;
	' "$f" || {
		echo "FAILED: $f"
		continue
	}
	after=$(wc -c <"$f")
	if [ "$before" != "$after" ]; then
		echo "SIZE MISMATCH: $f $before -> $after"
		continue
	fi
	if strings "$f" 2>/dev/null | grep -q -E "stage2/b6-webdav|r2d-cand|\.dev/live/webdav"; then
		echo "LEFTOVER: $f"
	fi
	echo "patched ${f#$ROOT/}"
	changed=$((changed + 1))
done
echo "total patched: $changed"
