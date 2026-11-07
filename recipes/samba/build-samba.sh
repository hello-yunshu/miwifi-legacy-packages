#!/bin/bash
set -euo pipefail
export SAMBA_CODEGEN_EXECUTOR=/work/run-arm.sh
export PYTHONHASHSEED=1 WAF_MAKE=1
export PATH=/toolchain/bin:$PATH
cd /work/sources/samba-4.23.13
python3 buildtools/bin/waf build -j2 --targets=smbd/smbd,client/smbclient,smbpasswd,smbcontrol,testparm,smbstatus,nmbd,vfs_readonly > /work/logs/samba-build.log 2>&1
python3 buildtools/bin/waf install -j2 --destdir=/work/prefix > /work/logs/samba-install.log 2>&1
printf 'SAMBA_BUILD_INSTALL_COMPLETE\n'
