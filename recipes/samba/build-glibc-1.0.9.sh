#!/bin/bash
# Build Samba 4.25.1 (version 1.0.9-r2d) against a private glibc 2.23 runtime
# configured for kernel >= 2.6.32, for the Xiaomi R2D (brcm4709, kernel 2.6.36).
#
# Same pipeline as recipes/samba/repro-build.sh; the only differences are the
# toolchain (arm-linux-gnueabi, glibc 2.23) and that the produced tree carries
# its own loader + glibc under lib/glibc.  System /lib is never touched.
#
# Prerequisites (Ubuntu 16.04 container, arm64 host):
#   - gcc-arm-linux-gnueabi 5.4 + libc6-dev-armel-cross
#   - glibc 2.23 built for arm-linux-gnueabi with --enable-kernel=2.6.32
#     and installed at /work/glibc-root/opt/glibc23 (kernel headers from the
#     device SDK sysroot; Ubuntu's stock armel glibc dies with "kernel too old")
#   - python3.7 at /opt/py37 (Samba's waf needs f-strings and _ssl)
#   - qemu-arm-static as the waf --cross-execute runner (run-arm.sh)
#   - /userdisk/.../runtime/lib/glibc present inside the container while
#     configuring: waf test programs carry the final PT_INTERP, so the loader
#     and libc must exist at that path for the run-based checks to pass.
set -uo pipefail
WORK=${WORK:-/work/build-1.0.9}
SRC=$WORK/sources
PREFIX=$WORK/prefix
ROOTFS=$WORK/rootfs
LOGS=$WORK/logs
TARGET=arm-linux-gnueabi
GLIBC=/work/glibc-root/opt/glibc23
RT=/userdisk/data/.yunshu/live/samba/runtime
export CC=$TARGET-gcc AR=$TARGET-ar RANLIB=$TARGET-ranlib STRIP=$TARGET-strip
export CFLAGS="-Os -fPIC -march=armv7-a -mfloat-abi=soft -fdebug-prefix-map=$WORK=/build"
export CXXFLAGS="$CFLAGS"
export CPPFLAGS="-I$PREFIX/opt/samba-next/include"
export LDFLAGS="-L$PREFIX/opt/samba-next/lib -L$PREFIX/opt/samba-next/lib64"
export PKG_CONFIG_PATH=$PREFIX/opt/samba-next/lib/pkgconfig
export PKG_CONFIG_LIBDIR=$PREFIX/opt/samba-next/lib/pkgconfig
export PKG_CONFIG_SYSROOT_DIR=$PREFIX

rm -rf "$WORK"
mkdir -p "$SRC" "$PREFIX" "$ROOTFS" "$LOGS"
START=$(date +%s)
{
  echo "BUILD_START $(date -u +%FT%TZ) work=$WORK"
  echo "TOOLCHAIN: $($TARGET-gcc --version | head -1)"
  echo "GLIBC: $("$GLIBC/lib/libc.so.6" 2>/dev/null | head -1)"
  echo "CFLAGS: $CFLAGS"
} > "$LOGS/REPORT.txt"

cp /work/sources/gmp-6.3.0.tar.xz /work/sources/nettle-3.10.2.tar.gz \
   /work/sources/gnutls-3.8.13.tar.xz /work/sources/zlib-1.4.tar.xz \
   /work/sources/samba-4.25.1.tar.gz "$SRC"/
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
./configure --host=$TARGET --build=aarch64-linux-gnu --prefix=/opt/samba-next \
  --disable-static --enable-shared --disable-assembly > "$LOGS/gmp-configure.log" 2>&1 && \
make -j"$(nproc)" > "$LOGS/gmp-build.log" 2>&1 && \
make DESTDIR="$PREFIX" install > "$LOGS/gmp-install.log" 2>&1
echo "GMP_RC=$?" >> "$LOGS/REPORT.txt"

# nettle
cd "$SRC/nettle-3.10.2" || exit 1
./configure --host=$TARGET --build=aarch64-linux-gnu --prefix=/opt/samba-next \
  --disable-static --enable-shared --disable-assembler --disable-documentation \
  > "$LOGS/nettle-configure.log" 2>&1 && \
make -j"$(nproc)" > "$LOGS/nettle-build.log" 2>&1 && \
make DESTDIR="$PREFIX" install > "$LOGS/nettle-install.log" 2>&1
echo "NETTLE_RC=$?" >> "$LOGS/REPORT.txt"

# gnutls
cd "$SRC/gnutls-3.8.13" || exit 1
./configure --host=$TARGET --build=aarch64-linux-gnu --prefix=/opt/samba-next \
  --disable-static --enable-shared --with-included-libtasn1 --with-included-unistring \
  --without-p11-kit --disable-guile --disable-cxx --disable-doc --disable-tests --disable-tools \
  --disable-nls --disable-hardware-acceleration --disable-libdane --without-tpm --without-tpm2 \
  --disable-libidn --disable-zlib --disable-brotli --disable-zstd \
  > "$LOGS/gnutls-configure.log" 2>&1
echo "GNUTLS_CONFIGURE_RC=$?" >> "$LOGS/REPORT.txt"
patch -p1 < /work/patches/gnutls-sdk-thread-local.patch > "$LOGS/gnutls-patch.log" 2>&1
echo "GNUTLS_PATCH_RC=$?" >> "$LOGS/REPORT.txt"
make -j"$(nproc)" > "$LOGS/gnutls-build.log" 2>&1
echo "GNUTLS_BUILD_RC=$?" >> "$LOGS/REPORT.txt"
make install DESTDIR="$PREFIX" > "$LOGS/gnutls-install.log" 2>&1
echo "GNUTLS_INSTALL_RC=$?" >> "$LOGS/REPORT.txt"
if ! ls "$PREFIX/opt/samba-next/lib/libgnutls.so.30" >/dev/null 2>&1; then
  echo "GNUTLS_MISSING: aborting before Samba" >> "$LOGS/REPORT.txt"
  exit 1
fi

# Samba's waf needs Python >= 3.6 (xenial ships 3.5); use the local 3.7 build.
export PATH=/opt/py37/bin:$PATH
export PYTHON=/opt/py37/bin/python3

# cross runner for codegen (host side only; the device never runs this)
cat > "$WORK/run-arm.sh" <<EOF
#!/bin/sh
exec /usr/bin/qemu-arm-static -L /usr/arm-linux-gnueabi -E LD_LIBRARY_PATH=$PREFIX/opt/samba-next/lib64:$PREFIX/opt/samba-next/lib:$PREFIX/opt/samba-next/lib/private "\$@"
EOF
chmod +x "$WORK/run-arm.sh"

# Samba: fresh tree + all eight patches
cd "$SRC/samba-4.25.1" || exit 1
: > "$LOGS/samba-patch.log"
for p in samba-cross-asn1-rule samba-cross-codegen-executor samba-sdk-generic-selection \
         samba-sdk-reflink-guard samba-sdk-spawn samba-s3-mac-policy samba-s4-readonly-timewindow \
         samba-sock-reuseport-eopnotsupp; do
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
export LDFLAGS="-L$PREFIX/opt/samba-next/lib -L$PREFIX/opt/samba-next/lib64 \
  -Wl,-rpath,$RT/lib -Wl,-rpath,$RT/lib/glibc \
  -Wl,--dynamic-linker=$RT/lib/glibc/ld-linux.so.3 \
  -Wl,-rpath-link,$PREFIX/opt/samba-next/lib -Wl,-rpath-link,$PREFIX/opt/samba-next/lib64"

./configure --prefix=$RT \
  --libdir=$RT/lib \
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

R=$ROOTFS$RT
[ -x "$R/sbin/smbd" ] || { echo "NO_SMBD" >> "$LOGS/REPORT.txt"; exit 1; }

# dependency libs into the tree (same set as 1.0.8)
for pat in 'libgnutls.so.30*' 'libnettle.so.8*' 'libhogweed.so.6*' 'libgmp.so.10*'; do
  for f in "$PREFIX/opt/samba-next/lib/"$pat; do
    [ -e "$f" ] || continue
    cp -a "$f" "$R/lib/" || echo "DEP_LIB_FAIL=$f" >> "$LOGS/REPORT.txt"
  done
done

# private glibc 2.23 runtime (kernel 2.6.32 build), used only by this tree
mkdir -p "$R/lib/glibc"
for f in ld-2.23.so ld-linux.so.3 libc-2.23.so libc.so.6 \
         libpthread-2.23.so libpthread.so.0 libdl-2.23.so libdl.so.2 \
         libm-2.23.so libm.so.6 librt-2.23.so librt.so.1 \
         libutil-2.23.so libutil.so.1 libcrypt-2.23.so libcrypt.so.1 \
         libnsl-2.23.so libnsl.so.1 libresolv-2.23.so libresolv.so.2 \
         libanl-2.23.so libanl.so.1; do
  cp -f "$GLIBC/lib/$f" "$R/lib/glibc/" 2>/dev/null || echo "GLIBC_LIB_ABSENT=$f" >> "$LOGS/REPORT.txt"
done
cp -f /usr/arm-linux-gnueabi/lib/libgcc_s.so.1 "$R/lib/glibc/" 2>/dev/null
# NSS modules must be reachable from the LD_LIBRARY_PATH the adapter exports
cp -f "$GLIBC/lib/libnss_files.so.2" "$GLIBC/lib/libnss_dns.so.2" "$R/lib/" 2>/dev/null
# charset modules for glibc iconv (kept next to the private loader)
cp -a "$GLIBC/lib/gconv" "$R/lib/glibc/gconv" 2>/dev/null || true

cp -f "$R/sbin/smbd" "$R/sbin/samba-s5d"
{
  echo "HASHES"
  md5sum "$R/sbin/smbd" "$R/sbin/samba-s5d" "$R/bin/smbclient" \
         "$R/lib/private/libsmbd-base-private-samba.so" 2>/dev/null
  echo "== smbd ELF =="
  $TARGET-readelf -l "$R/sbin/smbd" 2>/dev/null | grep -A1 INTERP
  $TARGET-readelf -d "$R/sbin/smbd" 2>/dev/null | grep -E "NEEDED|RPATH|RUNPATH"
  echo "== uclibc refs =="
  $TARGET-readelf -d "$R/sbin/smbd" 2>/dev/null | grep -c "libc.so.0" || true
} >> "$LOGS/REPORT.txt"
END=$(date +%s)
echo "ELAPSED_SEC=$((END-START))" >> "$LOGS/REPORT.txt"
echo "BUILD_END $(date -u +%FT%TZ)" >> "$LOGS/REPORT.txt"
echo DONE
if grep -qE '_RC=[1-9]' "$LOGS/REPORT.txt"; then
  echo "BUILD FAILED (see $LOGS/REPORT.txt)"; exit 1
fi
exit 0
