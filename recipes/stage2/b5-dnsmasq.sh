#!/bin/bash
set -uo pipefail
. /work/stage2-build/env.sh
NAME=b5-dnsmasq
setup_prefix "$NAME"
W=$STAGE/work/$NAME
rm -rf "$W"; mkdir -p "$W"
tar xf "$SRC/dnsmasq-2.92rel2.tar.xz" -C "$W" || exit 1
cd "$W/dnsmasq-2.92rel2" || exit 1
make clean >/dev/null 2>&1

t0=$(date +%s)
make -j10 CC="$CC" CFLAGS="$CFLAGS" LDFLAGS="" COPTS="$CFLAGS" > "$LOG/$NAME-cold.log" 2>&1; rc=$?
t1=$(date +%s)
echo "build=dnsmasq-2.92rel2 cold_rc=$rc cold_seconds=$((t1-t0))" > "$LOG/$NAME-timing.txt"

make install DESTDIR="$DEST" PREFIX="$PREFIX" > "$LOG/$NAME-install.log" 2>&1
echo "install_rc=$?" >> "$LOG/$NAME-timing.txt"

make clean >/dev/null 2>&1
t0=$(date +%s)
make -j10 CC="$CC" CFLAGS="$CFLAGS" LDFLAGS="" COPTS="$CFLAGS" > "$LOG/$NAME-warm.log" 2>&1; rc=$?
t1=$(date +%s)
echo "warm_rc=$rc warm_seconds=$((t1-t0))" >> "$LOG/$NAME-timing.txt"

echo "--- installed ---"
find "$DEST" -type f | sort
echo "--- timing ---"
cat "$LOG/$NAME-timing.txt"
