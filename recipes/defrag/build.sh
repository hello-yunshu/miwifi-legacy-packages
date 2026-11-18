#!/bin/sh
# Build a static ARM e4defrag for the R2D (uClibc 0.9.33.2, kernel 2.6.36).
#
# The stock image ships e2fsprogs 1.41 without e4defrag, and no compiler.
# e2fsprogs 1.45.6 builds cleanly with the Xiaomi SDK toolchain once the
# fallocate64 gap is patched (see e4defrag-uclibc.patch): uClibc has no
# fallocate64() and its variadic syscall() misplaces 64-bit arguments on ARM
# EABI, so the shim issues the syscall with an explicit register layout.
#
# Verified 2026-11-18 on the device: a 150-extent file collapsed to 1 extent,
# kernel 2.6.36 supports EXT4_IOC_MOVE_EXT.
#
# Usage:
#   TOOLCHAIN=/path/to/sdk_package ./build.sh [output-dir]
#
#   TOOLCHAIN  sdk_package directory (contains toolchain/bin)
#   IMAGE      build image with make/gcc (default yunwrt-build:24.04)
#   SRC_TARBALL optional local copy of e2fsprogs-<ver>.tar.gz
set -eu

here=$(cd "$(dirname "$0")" && pwd)
out=${1:-$here/dist}
: "${TOOLCHAIN:?set TOOLCHAIN to the sdk_package directory}"
IMAGE=${IMAGE:-yunwrt-build:24.04}
VER=1.45.6
SHA=2230b0469b7c0e9170ec7591728aa40caae62330543633be0960ac49d5bce310
SRC=${SRC_TARBALL:-/tmp/e2fsprogs-$VER.tar.gz}

if [ ! -f "$SRC" ]; then
	curl -fsSL -o "$SRC" \
		"https://mirrors.edge.kernel.org/pub/linux/kernel/people/tytso/e2fsprogs/v$VER/e2fsprogs-$VER.tar.gz"
fi
echo "$SHA  $SRC" | shasum -a 256 -c - >/dev/null ||
	{ echo "source checksum mismatch: $SRC" >&2; exit 1; }

mkdir -p "$out"
docker run --rm --platform linux/amd64 \
	-e VER="$VER" \
	-v "$TOOLCHAIN:/sdk:ro" \
	-v "$out:/out" \
	-v "$SRC:/src.tar.gz:ro" \
	-v "$here/e4defrag-uclibc.patch:/shim.patch:ro" \
	"$IMAGE" bash -c '
set -eu
T=arm-xiaomi-linux-uclibcgnueabi
export PATH=/sdk/toolchain/bin:$PATH
cd /tmp
tar xf /src.tar.gz
cd "e2fsprogs-$VER"
patch -p1 < /shim.patch
./configure --host=$T --build=x86_64-linux-gnu \
	--disable-nls --disable-tls --disable-elf-shlibs --enable-static \
	--prefix=/tmp/install \
	CC=$T-gcc AR=$T-ar RANLIB=$T-ranlib STRIP=$T-strip \
	CFLAGS="-Os -fPIC" LDFLAGS="-static" >/dev/null
make -j4 >/dev/null
$T-strip misc/e4defrag -o /out/e4defrag
'
ls -l "$out/e4defrag"
