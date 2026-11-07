#!/bin/bash
set -euo pipefail
export PATH=/toolchain/bin:$PATH
cd /work/sources
tar xf zlib-1.4.tar.xz
cd zlib-1.4
CC=arm-xiaomi-linux-uclibcgnueabi-gcc AR=arm-xiaomi-linux-uclibcgnueabi-ar RANLIB=arm-xiaomi-linux-uclibcgnueabi-ranlib CFLAGS='-Os -fPIC' ./configure --prefix=/opt/samba-next > /work/logs/zlib-configure.log 2>&1
make -j2 > /work/logs/zlib-build.log 2>&1
make DESTDIR=/work/prefix install > /work/logs/zlib-install.log 2>&1
