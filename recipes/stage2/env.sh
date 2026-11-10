#!/bin/bash
# Shared cross-build environment for R2D stage 2 (container miwifi-s1)
export PATH=/toolchain/bin:$PATH
export TARGET=arm-xiaomi-linux-uclibcgnueabi
export CC=$TARGET-gcc
export CXX=$TARGET-g++
export AR=$TARGET-ar
export RANLIB=$TARGET-ranlib
export STRIP=$TARGET-strip
export CFLAGS="-Os -fPIC -march=armv7-a -mfloat-abi=soft"
export CXXFLAGS="$CFLAGS"
export SRC=/work/sources/stage0-1-20261109
export STAGE=/work/stage2
export LOG=$STAGE/logs
mkdir -p "$LOG" "$STAGE/work"

# usage: setup_prefix <name>  -> sets PREFIX (device path) and DEST (staging root)
setup_prefix() {
  local name=$1
  PREFIX=/userdisk/data/.yunshu/candidates/$name/root
  DEST=$STAGE/$name/root
  mkdir -p "$DEST"
  export CPPFLAGS="-I$DEST$PREFIX/include"
  export LDFLAGS="-L$DEST$PREFIX/lib -Wl,-rpath,$PREFIX/lib -Wl,-rpath-link,$DEST$PREFIX/lib"
  export PKG_CONFIG_LIBDIR="$DEST$PREFIX/lib/pkgconfig:$DEST$PREFIX/share/pkgconfig"
  export PKG_CONFIG_SYSROOT_DIR="$DEST"
  export PATH="$DEST$PREFIX/bin:/toolchain/bin:$PATH"
}

# usage: timeit <logfile> <cmd...>
timeit() {
  local logf=$1; shift
  local t0 t1 rc
  t0=$(date +%s)
  "$@" > "$logf" 2>&1; rc=$?
  t1=$(date +%s)
  echo "rc=$rc seconds=$((t1-t0))"
  return $rc
}
