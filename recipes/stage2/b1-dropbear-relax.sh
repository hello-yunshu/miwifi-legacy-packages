#!/bin/bash
# Build Dropbear 2026.94 with the R2D local relaxation patch.
# The relaxation only takes effect when DROPBEAR_RELAX_AUTHKEYS is set in the
# environment of the spare instance (port 2222).
set -uo pipefail
. /work/stage2-build/env.sh
NAME=b1-dropbear-relax
setup_prefix "$NAME"
W=$STAGE/work/$NAME
rm -rf "$W"; mkdir -p "$W"
tar xf "$SRC/dropbear-2026.94.tar.bz2" -C "$W" || exit 1
cd "$W/dropbear-2026.94" || exit 1

patch -p1 < /work/stage2-build/dropbear-relax-authkeys.patch > "$LOG/$NAME-patch.log" 2>&1 || {
  echo "patch_failed"; cat "$LOG/$NAME-patch.log"; exit 1;
}
echo "patch_rc=0"

./configure --host=$TARGET --build=x86_64-linux-gnu --prefix="$PREFIX" \
  --disable-zlib --disable-lastlog --disable-utmp --disable-wtmp --disable-utmpx --disable-wtmpx \
  > "$LOG/$NAME-configure.log" 2>&1 || { echo "configure_failed"; tail -30 "$LOG/$NAME-configure.log"; exit 1; }

t0=$(date +%s)
make -j10 > "$LOG/$NAME-build.log" 2>&1; rc=$?
t1=$(date +%s)
echo "build=dropbear-2026.94-relax rc=$rc seconds=$((t1-t0))" > "$LOG/$NAME-timing.txt"
[ "$rc" -eq 0 ] || { echo "build_failed"; tail -40 "$LOG/$NAME-build.log"; exit 1; }

make install DESTDIR="$DEST" > "$LOG/$NAME-install.log" 2>&1
echo "install_rc=$?" >> "$LOG/$NAME-timing.txt"

echo "--- installed ---"
find "$DEST" -type f | sort
echo "--- timing ---"
cat "$LOG/$NAME-timing.txt"
