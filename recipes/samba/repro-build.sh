#!/bin/bash
# Clean-room reproducibility build: dependencies + Samba 4.25.1 + all 7 patches.
# Usage: repro-build.sh <A|B>
#
# Both runs build inside the SAME absolute path (/work/repro-work) so that
# embedded source paths are identical; only the report and key artifacts are
# copied to /work/repro-<ID> afterwards.
set -uo pipefail
ID=${1:?usage: repro-build.sh A|B}
BASE=/work/repro-$ID
WORK=/work/repro-work
SRC=$WORK/sources
PREFIX=$WORK/prefix
ROOTFS=$WORK/rootfs
LOGS=$WORK/logs
export PATH=/toolchain/bin:$PATH
TARGET=arm-xiaomi-linux-uclibcgnueabi
export CC=$TARGET-gcc AR=$TARGET-ar RANLIB=$TARGET-ranlib STRIP=$TARGET-strip
# -fdebug-prefix-map keeps debug paths stable even if the work dir changes.
export CFLAGS="-Os -fPIC -march=armv7-a -mfloat-abi=soft -fdebug-prefix-map=$WORK=/build"
export CXXFLAGS="$CFLAGS"
export CPPFLAGS="-I$PREFIX/opt/samba-next/include"
export LDFLAGS="-L$PREFIX/opt/samba-next/lib -L$PREFIX/opt/samba-next/lib64"
export PKG_CONFIG_PATH=$PREFIX/opt/samba-next/lib/pkgconfig
export PKG_CONFIG_LIBDIR=$PREFIX/opt/samba-next/lib/pkgconfig
export PKG_CONFIG_SYSROOT_DIR=$PREFIX

rm -rf "$WORK" "$BASE"
mkdir -p "$SRC" "$PREFIX" "$ROOTFS" "$LOGS" "$BASE"
START=$(date +%s)
echo "BUILD_START $(date -u +%FT%TZ) id=$ID work=$WORK" > "$LOGS/REPORT.txt"
{
  echo "TOOLCHAIN: $($TARGET-gcc --version | head -1)"
  echo "HOST: $(uname -sr) $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")"
  echo "CFLAGS: $CFLAGS"
} >> "$LOGS/REPORT.txt"

cp /work/sources/gmp-6.3.0.tar.xz /work/sources/nettle-3.10.2.tar.gz \
   /work/sources/gnutls-3.8.13.tar.xz /work/sources/zlib-1.4.tar.xz \
   /work/samba-4.25.1.tar.gz "$SRC"/
cd "$SRC" || exit 1
tar xf gmp-6.3.0.tar.xz && tar xf nettle-3.10.2.tar.gz && \
tar xf gnutls-3.8.13.tar.xz && tar xf zlib-1.4.tar.xz && \
tar xf samba-4.25.1.tar.gz
echo "EXTRACT_RC=$?" >> "$LOGS/REPORT.txt"

# zlib
cd "$SRC/zlib-1.4" || exit 1
CHOST=$TARGET ./configure --prefix=/opt/samba-next --static > "$LOGS/zlib-configure.log" 2>&1 && \
make -j"$(nproc)" > "$LOGS/zlib-build.log" 2>&1 && \
make DESTDIR="$PREFIX" install > "$LOGS/zlib-install.log" 2>&1
echo "ZLIB_RC=$?" >> "$LOGS/REPORT.txt"

# gmp
cd "$SRC/gmp-6.3.0" || exit 1
./configure --host=$TARGET --build=x86_64-linux-gnu --prefix=/opt/samba-next \
  --disable-static --enable-shared --disable-assembly > "$LOGS/gmp-configure.log" 2>&1 && \
make -j"$(nproc)" > "$LOGS/gmp-build.log" 2>&1 && \
make DESTDIR="$PREFIX" install > "$LOGS/gmp-install.log" 2>&1
echo "GMP_RC=$?" >> "$LOGS/REPORT.txt"

# nettle (CPPFLAGS/LDFLAGS above point at the staged gmp)
cd "$SRC/nettle-3.10.2" || exit 1
./configure --host=$TARGET --build=x86_64-linux-gnu --prefix=/opt/samba-next \
  --disable-static --enable-shared --disable-assembler --disable-documentation \
  > "$LOGS/nettle-configure.log" 2>&1 && \
make -j"$(nproc)" > "$LOGS/nettle-build.log" 2>&1 && \
make DESTDIR="$PREFIX" install > "$LOGS/nettle-install.log" 2>&1
echo "NETTLE_RC=$?" >> "$LOGS/REPORT.txt"
grep -q 'Using mini-gmp:    no' "$LOGS/nettle-configure.log" && \
  echo "NETTLE_MINI_GMP=no(gmp linked)" >> "$LOGS/REPORT.txt" || \
  echo "NETTLE_MINI_GMP=YES(unexpected)" >> "$LOGS/REPORT.txt"
ls "$PREFIX/opt/samba-next/lib" | grep -q libhogweed && \
  echo "HOGWEED=present" >> "$LOGS/REPORT.txt" || echo "HOGWEED=MISSING" >> "$LOGS/REPORT.txt"

# gnutls (patch applied after configure, matching the verified S1 procedure)
cd "$SRC/gnutls-3.8.13" || exit 1
./configure --host=$TARGET --build=x86_64-linux-gnu --prefix=/opt/samba-next \
  --disable-static --enable-shared --with-included-libtasn1 --with-included-unistring \
  --without-p11-kit --disable-guile --disable-cxx --disable-doc --disable-tests --disable-tools \
  --disable-nls --disable-hardware-acceleration --disable-libdane --without-tpm --without-tpm2 \
  --disable-libidn --disable-zlib --disable-brotli --disable-zstd \
  > "$LOGS/gnutls-configure.log" 2>&1
echo "GNUTLS_CONFIGURE_RC=$?" >> "$LOGS/REPORT.txt"
patch -p1 < /work/patches/gnutls-sdk-thread-local.patch > "$LOGS/gnutls-patch.log" 2>&1
echo "GNUTLS_PATCH_RC=$?" >> "$LOGS/REPORT.txt"
# GCC 4.8 / uClibc sysroot has no C11 static_assert; gnutls' gnulib provides a
# replacement assert.h that must be generated before compiling lib/.
make -C gl -j"$(nproc)" > "$LOGS/gnutls-gl-build.log" 2>&1
echo "GNUTLS_GL_RC=$?" >> "$LOGS/REPORT.txt"
make -C lib -j"$(nproc)" > "$LOGS/gnutls-build.log" 2>&1
echo "GNUTLS_BUILD_RC=$?" >> "$LOGS/REPORT.txt"
make -C lib DESTDIR="$PREFIX" install > "$LOGS/gnutls-install.log" 2>&1
echo "GNUTLS_INSTALL_RC=$?" >> "$LOGS/REPORT.txt"
if ! ls "$PREFIX/opt/samba-next/lib/libgnutls.so.30.42.0" >/dev/null 2>&1; then
  echo "GNUTLS_MISSING: aborting before Samba" >> "$LOGS/REPORT.txt"
  cp "$LOGS/REPORT.txt" "$BASE/REPORT.txt"
  echo "DONE id=$ID (failed at gnutls)"
  exit 1
fi
# allow glibc layout for gnutls libdir
for d in "$PREFIX/opt/samba-next/lib" "$PREFIX/opt/samba-next/lib64"; do
  [ -d "$d" ] || mkdir -p "$d"
done
ln -sf ../lib/libgnutls.so.30.42.0 "$PREFIX/opt/samba-next/lib64/libgnutls.so.30.42.0" 2>/dev/null || true

# per-build cross runner with this build's libraries
cat > "$WORK/run-arm.sh" <<EOF
#!/bin/sh
exec /usr/bin/qemu-arm-static -L /toolchain/arm-xiaomi-linux-uclibcgnueabi/sysroot -E LD_LIBRARY_PATH=$PREFIX/opt/samba-next/lib64:$PREFIX/opt/samba-next/lib:$PREFIX/opt/samba-next/lib/private "\$@"
EOF
chmod +x "$WORK/run-arm.sh"

# Samba: fresh tree + all seven patches
cd "$SRC/samba-4.25.1" || exit 1
: > "$LOGS/samba-patch.log"
for p in samba-cross-asn1-rule samba-cross-codegen-executor samba-sdk-generic-selection \
         samba-sdk-reflink-guard samba-sdk-spawn samba-s3-mac-policy samba-s4-readonly-timewindow; do
  echo "== $p" >> "$LOGS/samba-patch.log"
  prc=0
  patch -p1 < "/work/patches/$p.patch" >> "$LOGS/samba-patch.log" 2>&1 || prc=$?
  echo "rc=$prc" >> "$LOGS/samba-patch.log"
  [ "$prc" -ne 0 ] && { echo "SAMBA_PATCH_RC=$prc" >> "$LOGS/REPORT.txt"; exit 1; }
done
echo "SAMBA_PATCH_RC=0" >> "$LOGS/REPORT.txt"

export SAMBA_CODEGEN_EXECUTOR="$WORK/run-arm.sh"
export PYTHONHASHSEED=1 WAF_MAKE=1
export CC=$TARGET-gcc AR=$TARGET-ar RANLIB=$TARGET-ranlib LINK_CC=$TARGET-gcc
export CPPFLAGS="-I$PREFIX/opt/samba-next/include"
export LDFLAGS="-L$PREFIX/opt/samba-next/lib -L$PREFIX/opt/samba-next/lib64 -Wl,-rpath,/userdisk/data/.yunshu/live/samba/runtime/lib -Wl,-rpath-link,$PREFIX/opt/samba-next/lib -Wl,-rpath-link,$PREFIX/opt/samba-next/lib64"

./configure --prefix=/userdisk/data/.yunshu/live/samba/runtime \
  --libdir=/userdisk/data/.yunshu/live/samba/runtime/lib \
  --cross-compile --hostcc=gcc --cross-execute="$WORK/run-arm.sh" \
  --disable-python --without-ad-dc --without-ads --without-ldap --without-pam --without-winbind \
  --without-gpgme --without-regedit --without-winexe --without-systemd --without-systemd-userdb \
  --without-json --without-acl-support --without-quotas --disable-cups --disable-iprint \
  --disable-avahi --disable-spotlight --disable-wsp --without-libarchive --without-libunwind \
  --without-automount --without-dmapi --without-fam --without-cluster-support --disable-glusterfs \
  --disable-cephfs --with-shared-modules='!vfs_snapper' --bundled-libraries=ALL \
  --disable-warnings-as-errors > "$LOGS/samba-configure.log" 2>&1
echo "SAMBA_CONFIGURE_RC=$?" >> "$LOGS/REPORT.txt"

make -j"$(nproc)" > "$LOGS/samba-build.log" 2>&1
echo "SAMBA_BUILD_RC=$?" >> "$LOGS/REPORT.txt"
make install DESTDIR="$ROOTFS" > "$LOGS/samba-install.log" 2>&1
echo "SAMBA_INSTALL_RC=$?" >> "$LOGS/REPORT.txt"

R=$ROOTFS/userdisk/data/.yunshu/live/samba/runtime
# Samba links gnutls/nettle/gmp dynamically; the device tree carries them in
# its own lib/ (uClibc resolves DT_RPATH before LD_LIBRARY_PATH), so a tree
# without them starts but cannot negotiate TLS.  Install them like 1.0.8 does.
for f in libgnutls.so.30 libgnutls.so.30.42.0 libnettle.so.8 libnettle.so.8.11 \
         libhogweed.so.6 libhogweed.so.6.11 libgmp.so.10 libgmp.so.10.5.0; do
  cp -f "$PREFIX/opt/samba-next/lib/$f" "$R/lib/" 2>/dev/null || \
    echo "DEP_LIB_MISSING=$f" >> "$LOGS/REPORT.txt"
done
# The service entry in the device tree is a copy of smbd under the instance
# name used by the adapter (S5_PROC_NAME); keep the payload identical.
cp -f "$R/sbin/smbd" "$R/sbin/samba-s5d"
{
  echo "HASHES id=$ID"
  md5sum "$R/sbin/smbd" "$R/sbin/samba-s5d" "$R/bin/smbclient" \
         "$R/lib/private/libsmbd-base-private-samba.so" 2>/dev/null
  md5sum "$PREFIX/opt/samba-next/lib/libgnutls.so.30.42.0" \
         "$PREFIX/opt/samba-next/lib/libnettle.so.8.11" \
         "$PREFIX/opt/samba-next/lib/libgmp.so.10.5.0" 2>/dev/null
} >> "$LOGS/REPORT.txt"
END=$(date +%s)
echo "ELAPSED_SEC=$((END-START))" >> "$LOGS/REPORT.txt"
echo "BUILD_END $(date -u +%FT%TZ)" >> "$LOGS/REPORT.txt"

# keep the report and the artifacts whose hashes matter
cp "$LOGS/REPORT.txt" "$BASE/REPORT.txt"
mkdir -p "$BASE/artifacts/sbin" "$BASE/artifacts/bin" "$BASE/artifacts/lib" "$BASE/artifacts/deps"
cp "$R/sbin/smbd" "$R/sbin/samba-s5d" "$BASE/artifacts/sbin/" 2>/dev/null
cp "$R/bin/smbclient" "$BASE/artifacts/bin/" 2>/dev/null
cp "$R/lib/private/libsmbd-base-private-samba.so" "$BASE/artifacts/lib/" 2>/dev/null
cp "$PREFIX/opt/samba-next/lib/libgnutls.so.30.42.0" \
   "$PREFIX/opt/samba-next/lib/libnettle.so.8.11" \
   "$PREFIX/opt/samba-next/lib/libgmp.so.10.5.0" "$BASE/artifacts/deps/" 2>/dev/null
echo "DONE id=$ID"
# A failed stage must not look like a successful run to the caller.
if grep -qE '_RC=[1-9]' "$LOGS/REPORT.txt"; then
  echo "BUILD FAILED (see $LOGS/REPORT.txt)"
  exit 1
fi
exit 0
