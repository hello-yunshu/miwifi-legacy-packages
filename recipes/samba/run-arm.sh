#!/bin/sh
exec /qemu-arm -L /toolchain/arm-xiaomi-linux-uclibcgnueabi/sysroot -E LD_LIBRARY_PATH=/work/prefix/opt/samba-next/lib "$@"
