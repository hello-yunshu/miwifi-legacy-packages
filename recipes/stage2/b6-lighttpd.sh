#!/bin/bash
set -uo pipefail
. /work/stage2-build/env.sh
NAME=b6-webdav
setup_prefix "$NAME"

step() { echo "=== $* ==="; }

# ---- sqlite3 ----
step sqlite
W=$STAGE/work/$NAME-sqlite; rm -rf "$W"; mkdir -p "$W"
tar xf "$SRC/sqlite-autoconf-3540100.tar.gz" -C "$W" || exit 1
cd "$W/sqlite-autoconf-3540100" || exit 1
./configure --host=$TARGET --build=x86_64-linux-gnu --prefix="$PREFIX" \
  --disable-readline > "$LOG/$NAME-sqlite-configure.log" 2>&1 || { echo "sqlite_configure_failed"; tail -30 "$LOG/$NAME-sqlite-configure.log"; exit 1; }
t0=$(date +%s); make -j10 > "$LOG/$NAME-sqlite-cold.log" 2>&1; rc=$?; t1=$(date +%s)
echo "sqlite cold_rc=$rc cold_seconds=$((t1-t0))" >> "$LOG/$NAME-timing.txt"
make install DESTDIR="$DEST" >> "$LOG/$NAME-sqlite-install.log" 2>&1 || { echo "sqlite_install_failed"; tail -20 "$LOG/$NAME-sqlite-install.log"; exit 1; }

# ---- libxml2 ----
step libxml2
W=$STAGE/work/$NAME-libxml2; rm -rf "$W"; mkdir -p "$W"
tar xf "$SRC/libxml2-2.15.4.tar.xz" -C "$W" || exit 1
cd "$W/libxml2-2.15.4" || exit 1
./configure --host=$TARGET --build=x86_64-linux-gnu --prefix="$PREFIX" \
  --without-python --without-lzma --without-zlib --without-iconv --without-http --without-ftp \
  --disable-static > "$LOG/$NAME-libxml2-configure.log" 2>&1 || { echo "libxml2_configure_failed"; tail -30 "$LOG/$NAME-libxml2-configure.log"; exit 1; }
t0=$(date +%s); make -j10 > "$LOG/$NAME-libxml2-cold.log" 2>&1; rc=$?; t1=$(date +%s)
echo "libxml2 cold_rc=$rc cold_seconds=$((t1-t0))" >> "$LOG/$NAME-timing.txt"
make install DESTDIR="$DEST" >> "$LOG/$NAME-libxml2-install.log" 2>&1 || { echo "libxml2_install_failed"; tail -20 "$LOG/$NAME-libxml2-install.log"; exit 1; }

# ---- lighttpd ----
step lighttpd
W=$STAGE/work/$NAME-lighttpd; rm -rf "$W"; mkdir -p "$W"
tar xf "$SRC/lighttpd-1.4.85.tar.xz" -C "$W" || exit 1
cd "$W/lighttpd-1.4.85" || exit 1
./autogen.sh > "$LOG/$NAME-lighttpd-autogen.log" 2>&1 || { echo "lighttpd_autogen_failed"; tail -20 "$LOG/$NAME-lighttpd-autogen.log"; exit 1; }
./configure --host=$TARGET --build=x86_64-linux-gnu --prefix="$PREFIX" \
  --without-pcre2 --without-pcre --without-zlib --without-bzip2 --without-openssl \
  --with-webdav-props --with-webdav-locks \
  > "$LOG/$NAME-lighttpd-configure.log" 2>&1 || { echo "lighttpd_configure_failed"; tail -40 "$LOG/$NAME-lighttpd-configure.log"; exit 1; }
t0=$(date +%s); make -j10 > "$LOG/$NAME-lighttpd-cold.log" 2>&1; rc=$?; t1=$(date +%s)
echo "lighttpd cold_rc=$rc cold_seconds=$((t1-t0))" >> "$LOG/$NAME-timing.txt"
make install DESTDIR="$DEST" >> "$LOG/$NAME-lighttpd-install.log" 2>&1 || { echo "lighttpd_install_failed"; tail -20 "$LOG/$NAME-lighttpd-install.log"; exit 1; }

echo "--- installed files ---"
find "$DEST" -type f | sort
echo "--- timing ---"
cat "$LOG/$NAME-timing.txt"
