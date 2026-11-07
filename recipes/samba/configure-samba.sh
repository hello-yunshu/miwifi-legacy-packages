#!/bin/bash
set -euo pipefail
export PATH=/toolchain/bin:$PATH
export CC=arm-xiaomi-linux-uclibcgnueabi-gcc
export AR=arm-xiaomi-linux-uclibcgnueabi-ar
export RANLIB=arm-xiaomi-linux-uclibcgnueabi-ranlib
export LINK_CC=$CC
export CFLAGS='-Os -fPIC -march=armv7-a -mfloat-abi=soft'
export CPPFLAGS=-I/work/prefix/opt/samba-next/include
export LDFLAGS='-L/work/prefix/opt/samba-next/lib -Wl,-rpath,/opt/samba-next/lib -Wl,-rpath-link,/work/prefix/opt/samba-next/lib'
export PKG_CONFIG_LIBDIR=/work/prefix/opt/samba-next/lib/pkgconfig
export PKG_CONFIG_SYSROOT_DIR=/work/prefix
cd /work/sources/samba-4.23.13
./configure --prefix=/opt/samba-next --cross-compile --hostcc=gcc --cross-execute=/work/run-arm.sh --disable-python --without-ad-dc --without-ads --without-ldap --without-pam --without-winbind --without-gpgme --without-regedit --without-winexe --without-systemd --without-systemd-userdb --without-json --without-acl-support --without-quotas --disable-cups --disable-iprint --disable-avahi --disable-spotlight --disable-wsp --without-libarchive --without-libunwind --without-automount --without-dmapi --without-fam --without-cluster-support --disable-glusterfs --disable-cephfs --with-shared-modules='!vfs_snapper' --bundled-libraries=ALL --disable-warnings-as-errors > /work/logs/samba-configure.log 2>&1
printf 'SAMBA_CONFIGURE_COMPLETE\n'
