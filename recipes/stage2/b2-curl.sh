#!/bin/bash
set -uo pipefail
. /work/stage2-build/env.sh
NAME=b2-curl
setup_prefix "$NAME"
W=$STAGE/work/$NAME
rm -rf "$W"; mkdir -p "$W"
tar xf "$SRC/curl-8.23.0.tar.xz" -C "$W" || exit 1
cd "$W/curl-8.23.0" || exit 1

./configure --host=$TARGET --build=x86_64-linux-gnu --prefix="$PREFIX" \
  --disable-shared --enable-static \
  --without-ssl --without-libpsl --without-zlib --without-brotli --without-zstd \
  --without-libidn2 --without-nghttp2 --without-ngtcp2 --without-nghttp3 \
  --disable-ldap --disable-ldaps --disable-rtsp --disable-dict --disable-telnet \
  --disable-tftp --disable-pop3 --disable-imap --disable-smtp --disable-gopher \
  --disable-mqtt --disable-ftp --disable-file --disable-ipfs --disable-websockets \
  --disable-threaded-resolver --disable-manual --disable-docs \
  > "$LOG/$NAME-configure.log" 2>&1 || { echo "configure_failed"; tail -30 "$LOG/$NAME-configure.log"; exit 1; }

t0=$(date +%s)
make -j10 > "$LOG/$NAME-cold.log" 2>&1; rc=$?
t1=$(date +%s)
echo "build=curl-8.23.0 cold_rc=$rc cold_seconds=$((t1-t0))" > "$LOG/$NAME-timing.txt"

make install DESTDIR="$DEST" > "$LOG/$NAME-install.log" 2>&1
echo "install_rc=$?" >> "$LOG/$NAME-timing.txt"

make clean >/dev/null 2>&1
t0=$(date +%s)
make -j10 > "$LOG/$NAME-warm.log" 2>&1; rc=$?
t1=$(date +%s)
echo "warm_rc=$rc warm_seconds=$((t1-t0))" >> "$LOG/$NAME-timing.txt"

$STRIP "$DEST$PREFIX/bin/curl"
echo "--- installed ---"
find "$DEST" -type f | sort
echo "--- timing ---"
cat "$LOG/$NAME-timing.txt"
