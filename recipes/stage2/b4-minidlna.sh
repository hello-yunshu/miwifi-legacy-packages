#!/bin/bash
set -uo pipefail
. /work/stage2-build/env.sh
NAME=b4-dlna
setup_prefix "$NAME"
TIME=$LOG/$NAME-timing.txt
: > "$TIME"
step() { echo "=== $* ==="; }
fail() { echo "$1"; tail -30 "$2"; exit 1; }

# ---- zlib (libid3tag / minidlna need -lz) ----
step zlib
W=$STAGE/work/$NAME-zlib; rm -rf "$W"; mkdir -p "$W"
tar xf /work/sources/zlib-1.4.tar.xz -C "$W" || exit 1
cd "$W/zlib-1.4" || exit 1
CHOST=$TARGET CC="$CC" ./configure --prefix="$PREFIX" --shared > "$LOG/$NAME-zlib-configure.log" 2>&1 || fail zlib_configure_failed "$LOG/$NAME-zlib-configure.log"
t0=$(date +%s); make -j10 > "$LOG/$NAME-zlib-cold.log" 2>&1; rc=$?; t1=$(date +%s)
echo "zlib cold_rc=$rc cold_seconds=$((t1-t0))" >> "$TIME"
make install DESTDIR="$DEST" >> "$LOG/$NAME-zlib-install.log" 2>&1 || fail zlib_install_failed "$LOG/$NAME-zlib-install.log"

# ---- libjpeg-turbo (cmake) ----
step libjpeg-turbo
W=$STAGE/work/$NAME-libjpeg; rm -rf "$W"; mkdir -p "$W"
tar xf "$SRC/libjpeg-turbo-3.0.4.tar.gz" -C "$W" || exit 1
cd "$W/libjpeg-turbo-3.0.4" || exit 1
cmake -S . -B build \
  -DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=arm \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_AR="$AR" -DCMAKE_RANLIB="$RANLIB" \
  -DCMAKE_C_FLAGS="$CFLAGS" \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_INSTALL_LIBDIR=lib \
  -DENABLE_SHARED=TRUE -DENABLE_STATIC=TRUE -DWITH_SIMD=0 -DWITH_TURBOJPEG=TRUE \
  > "$LOG/$NAME-libjpeg-configure.log" 2>&1 || fail libjpeg_configure_failed "$LOG/$NAME-libjpeg-configure.log"
t0=$(date +%s); make -C build -j10 > "$LOG/$NAME-libjpeg-cold.log" 2>&1; rc=$?; t1=$(date +%s)
echo "libjpeg-turbo cold_rc=$rc cold_seconds=$((t1-t0))" >> "$TIME"
make -C build install DESTDIR="$DEST" >> "$LOG/$NAME-libjpeg-install.log" 2>&1 || fail libjpeg_install_failed "$LOG/$NAME-libjpeg-install.log"

# ---- libexif ----
step libexif
W=$STAGE/work/$NAME-libexif; rm -rf "$W"; mkdir -p "$W"
tar xf "$SRC/libexif-0.6.24.tar.bz2" -C "$W" || exit 1
cd "$W/libexif-0.6.24" || exit 1
./configure --host=$TARGET --build=x86_64-linux-gnu --prefix="$PREFIX" --disable-static --disable-nls \
  > "$LOG/$NAME-libexif-configure.log" 2>&1 || fail libexif_configure_failed "$LOG/$NAME-libexif-configure.log"
t0=$(date +%s); make -j10 > "$LOG/$NAME-libexif-cold.log" 2>&1; rc=$?; t1=$(date +%s)
echo "libexif cold_rc=$rc cold_seconds=$((t1-t0))" >> "$TIME"
make install DESTDIR="$DEST" >> "$LOG/$NAME-libexif-install.log" 2>&1 || fail libexif_install_failed "$LOG/$NAME-libexif-install.log"

# ---- libid3tag (CMake-only source tree) ----
step libid3tag
W=$STAGE/work/$NAME-libid3tag; rm -rf "$W"; mkdir -p "$W"
tar xf "$SRC/libid3tag-0.16.3.tar.gz" -C "$W" || exit 1
cd "$W/libid3tag" || exit 1
cmake -S . -B build \
  -DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=arm \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_AR="$AR" -DCMAKE_RANLIB="$RANLIB" \
  -DCMAKE_C_FLAGS="$CFLAGS" \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_INSTALL_LIBDIR=lib \
  -DBUILD_SHARED_LIBS=ON \
  -DZLIB_LIBRARY="$DEST$PREFIX/lib/libz.so" -DZLIB_INCLUDE_DIR="$DEST$PREFIX/include" \
  > "$LOG/$NAME-libid3tag-configure.log" 2>&1 || fail libid3tag_configure_failed "$LOG/$NAME-libid3tag-configure.log"
t0=$(date +%s); make -C build -j10 > "$LOG/$NAME-libid3tag-cold.log" 2>&1; rc=$?; t1=$(date +%s)
echo "libid3tag cold_rc=$rc cold_seconds=$((t1-t0))" >> "$TIME"
make -C build install DESTDIR="$DEST" >> "$LOG/$NAME-libid3tag-install.log" 2>&1 || fail libid3tag_install_failed "$LOG/$NAME-libid3tag-install.log"

# ---- libogg ----
step libogg
W=$STAGE/work/$NAME-libogg; rm -rf "$W"; mkdir -p "$W"
tar xf "$SRC/libogg-1.3.5.tar.gz" -C "$W" || exit 1
cd "$W/libogg-1.3.5" || exit 1
./configure --host=$TARGET --build=x86_64-linux-gnu --prefix="$PREFIX" --disable-static \
  > "$LOG/$NAME-libogg-configure.log" 2>&1 || fail libogg_configure_failed "$LOG/$NAME-libogg-configure.log"
t0=$(date +%s); make -j10 > "$LOG/$NAME-libogg-cold.log" 2>&1; rc=$?; t1=$(date +%s)
echo "libogg cold_rc=$rc cold_seconds=$((t1-t0))" >> "$TIME"
make install DESTDIR="$DEST" >> "$LOG/$NAME-libogg-install.log" 2>&1 || fail libogg_install_failed "$LOG/$NAME-libogg-install.log"

# ---- libvorbis ----
step libvorbis
W=$STAGE/work/$NAME-libvorbis; rm -rf "$W"; mkdir -p "$W"
tar xf "$SRC/libvorbis-1.3.7.tar.gz" -C "$W" || exit 1
cd "$W/libvorbis-1.3.7" || exit 1
OGG_CFLAGS="-I$DEST$PREFIX/include" OGG_LIBS="-L$DEST$PREFIX/lib -logg" \
./configure --host=$TARGET --build=x86_64-linux-gnu --prefix="$PREFIX" --disable-static \
  > "$LOG/$NAME-libvorbis-configure.log" 2>&1 || fail libvorbis_configure_failed "$LOG/$NAME-libvorbis-configure.log"
t0=$(date +%s); make -j10 > "$LOG/$NAME-libvorbis-cold.log" 2>&1; rc=$?; t1=$(date +%s)
echo "libvorbis cold_rc=$rc cold_seconds=$((t1-t0))" >> "$TIME"
make install DESTDIR="$DEST" >> "$LOG/$NAME-libvorbis-install.log" 2>&1 || fail libvorbis_install_failed "$LOG/$NAME-libvorbis-install.log"

# ---- flac ----
step flac
W=$STAGE/work/$NAME-flac; rm -rf "$W"; mkdir -p "$W"
tar xf "$SRC/flac-1.4.3.tar.xz" -C "$W" || exit 1
cd "$W/flac-1.4.3" || exit 1
./configure --host=$TARGET --build=x86_64-linux-gnu --prefix="$PREFIX" \
  --disable-shared --enable-static --disable-ogg --disable-doxygen-docs --disable-examples \
  --disable-cpplibs --without-libiconv-prefix \
  > "$LOG/$NAME-flac-configure.log" 2>&1 || fail flac_configure_failed "$LOG/$NAME-flac-configure.log"
t0=$(date +%s); make -j10 > "$LOG/$NAME-flac-cold.log" 2>&1; rc=$?; t1=$(date +%s)
echo "flac cold_rc=$rc cold_seconds=$((t1-t0))" >> "$TIME"
make install DESTDIR="$DEST" >> "$LOG/$NAME-flac-install.log" 2>&1 || fail flac_install_failed "$LOG/$NAME-flac-install.log"

# ---- sqlite3 ----
step sqlite3
W=$STAGE/work/$NAME-sqlite; rm -rf "$W"; mkdir -p "$W"
tar xf "$SRC/sqlite-autoconf-3540100.tar.gz" -C "$W" || exit 1
cd "$W/sqlite-autoconf-3540100" || exit 1
./configure --host=$TARGET --build=x86_64-linux-gnu --prefix="$PREFIX" --disable-readline \
  > "$LOG/$NAME-sqlite-configure.log" 2>&1 || fail sqlite_configure_failed "$LOG/$NAME-sqlite-configure.log"
t0=$(date +%s); make -j10 > "$LOG/$NAME-sqlite-cold.log" 2>&1; rc=$?; t1=$(date +%s)
echo "sqlite cold_rc=$rc cold_seconds=$((t1-t0))" >> "$TIME"
make install DESTDIR="$DEST" >> "$LOG/$NAME-sqlite-install.log" 2>&1 || fail sqlite_install_failed "$LOG/$NAME-sqlite-install.log"

# ---- ffmpeg (minidlna 1.3.3 hard-requires libavutil/libavcodec/libavformat) ----
step ffmpeg
W=$STAGE/work/$NAME-ffmpeg; rm -rf "$W"; mkdir -p "$W"
tar xf "$SRC/ffmpeg-6.1.2.tar.xz" -C "$W" || exit 1
cd "$W/ffmpeg-6.1.2" || exit 1
./configure --enable-cross-compile --cross-prefix=$TARGET- --arch=arm --target-os=linux --cc="$CC" \
  --prefix="$PREFIX" --disable-shared --enable-static --disable-programs --disable-doc --disable-network \
  --disable-autodetect --disable-avdevice --disable-swresample --disable-swscale --disable-postproc \
  --disable-avfilter --disable-everything --enable-protocol=file --enable-demuxer=image2 \
  --enable-decoder=mjpeg,png \
  > "$LOG/$NAME-ffmpeg-configure.log" 2>&1 || fail ffmpeg_configure_failed "$LOG/$NAME-ffmpeg-configure.log"
t0=$(date +%s); make -j10 > "$LOG/$NAME-ffmpeg-cold.log" 2>&1; rc=$?; t1=$(date +%s)
echo "ffmpeg cold_rc=$rc cold_seconds=$((t1-t0))" >> "$TIME"
make install DESTDIR="$DEST" >> "$LOG/$NAME-ffmpeg-install.log" 2>&1 || fail ffmpeg_install_failed "$LOG/$NAME-ffmpeg-install.log"

# ---- minidlna ----
step minidlna
W=$STAGE/work/$NAME-minidlna; rm -rf "$W"; mkdir -p "$W"
tar xf "$SRC/minidlna-1.3.3.tar.gz" -C "$W" || exit 1
cd "$W/minidlna-1.3.3" || exit 1
LIBS="-lm -lpthread" ./configure --host=$TARGET --build=x86_64-linux-gnu --prefix="$PREFIX" --disable-nls \
  > "$LOG/$NAME-minidlna-configure.log" 2>&1 || fail minidlna_configure_failed "$LOG/$NAME-minidlna-configure.log"
t0=$(date +%s); make -j10 > "$LOG/$NAME-minidlna-cold.log" 2>&1; rc=$?; t1=$(date +%s)
echo "minidlna cold_rc=$rc cold_seconds=$((t1-t0))" >> "$TIME"
make install DESTDIR="$DEST" >> "$LOG/$NAME-minidlna-install.log" 2>&1 || fail minidlna_install_failed "$LOG/$NAME-minidlna-install.log"
# warm rebuild of the final binary
make clean >/dev/null 2>&1
t0=$(date +%s); make -j10 > "$LOG/$NAME-minidlna-warm.log" 2>&1; rc=$?; t1=$(date +%s)
echo "minidlna warm_rc=$rc warm_seconds=$((t1-t0))" >> "$TIME"

echo "--- installed files ---"
find "$DEST" -type f | sort
echo "--- timing ---"
cat "$TIME"
