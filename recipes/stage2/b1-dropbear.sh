#!/bin/bash
set -uo pipefail
. /work/stage2-build/env.sh
NAME=b1-dropbear
setup_prefix "$NAME"
W=$STAGE/work/$NAME
rm -rf "$W"; mkdir -p "$W"
tar xf "$SRC/dropbear-2026.94.tar.bz2" -C "$W" || exit 1
cd "$W/dropbear-2026.94" || exit 1

./configure --host=$TARGET --build=x86_64-linux-gnu --prefix="$PREFIX" \
  --disable-zlib --disable-lastlog --disable-utmp --disable-wtmp --disable-utmpx --disable-wtmpx \
  > "$LOG/$NAME-configure.log" 2>&1 || { echo "configure_failed"; tail -30 "$LOG/$NAME-configure.log"; exit 1; }

t0=$(date +%s)
make -j10 > "$LOG/$NAME-cold.log" 2>&1; rc=$?
t1=$(date +%s)
echo "build=dropbear-2026.94 cold_rc=$rc cold_seconds=$((t1-t0))" > "$LOG/$NAME-timing.txt"

make install DESTDIR="$DEST" > "$LOG/$NAME-install.log" 2>&1
echo "install_rc=$?" >> "$LOG/$NAME-timing.txt"

make clean >/dev/null 2>&1
t0=$(date +%s)
make -j10 > "$LOG/$NAME-warm.log" 2>&1; rc=$?
t1=$(date +%s)
echo "warm_rc=$rc warm_seconds=$((t1-t0))" >> "$LOG/$NAME-timing.txt"

echo "--- installed ---"
find "$DEST" -type f | sort
echo "--- timing ---"
cat "$LOG/$NAME-timing.txt"
