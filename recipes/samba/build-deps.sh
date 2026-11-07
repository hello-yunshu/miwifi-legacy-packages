#!/bin/bash
set -euo pipefail
export PATH=/toolchain/bin:$PATH
export TARGET=arm-xiaomi-linux-uclibcgnueabi
export CC=$TARGET-gcc AR=$TARGET-ar RANLIB=$TARGET-ranlib STRIP=$TARGET-strip
export CFLAGS='-Os -fPIC -march=armv7-a -mfloat-abi=soft'
export CPPFLAGS=-I/work/prefix/opt/samba-next/include
export LDFLAGS='-L/work/prefix/opt/samba-next/lib -Wl,-rpath,/opt/samba-next/lib'
export PKG_CONFIG_LIBDIR=/work/prefix/opt/samba-next/lib/pkgconfig
export PKG_CONFIG_SYSROOT_DIR=/work/prefix
cd /work/sources
for t in gmp-6.3.0.tar.xz nettle-3.10.2.tar.gz gnutls-3.8.13.tar.xz; do tar xf "$t"; done
cd gmp-6.3.0
./configure --host=$TARGET --build=x86_64-linux-gnu --prefix=/opt/samba-next --disable-static --enable-shared --disable-assembly > /work/logs/gmp-configure.log 2>&1
make -j2 > /work/logs/gmp-build.log 2>&1
make DESTDIR=/work/prefix install > /work/logs/gmp-install.log 2>&1
cd ../nettle-3.10.2
./configure --host=$TARGET --build=x86_64-linux-gnu --prefix=/opt/samba-next --disable-static --enable-shared --disable-assembler --disable-documentation > /work/logs/nettle-configure.log 2>&1
make -j2 > /work/logs/nettle-build.log 2>&1
make DESTDIR=/work/prefix install > /work/logs/nettle-install.log 2>&1
cd ../gnutls-3.8.13
./configure --host=$TARGET --build=x86_64-linux-gnu --prefix=/opt/samba-next --disable-static --enable-shared --with-included-libtasn1 --with-included-unistring --without-p11-kit --disable-guile --disable-cxx --disable-doc --disable-tests --disable-tools --disable-nls --disable-hardware-acceleration --disable-libdane --without-tpm --without-tpm2 --disable-libidn --disable-zlib --disable-brotli --disable-zstd > /work/logs/gnutls-configure.log 2>&1
patch -p1 < /work/patches/gnutls-sdk-thread-local.patch
make -C lib -j2 > /work/logs/gnutls-build.log 2>&1
make -C lib DESTDIR=/work/prefix install > /work/logs/gnutls-install.log 2>&1
printf 'DEPENDENCIES_COMPLETE\n'
