#!/bin/bash
set -euo pipefail
cd /work/sources/samba-4.23.13
for name in samba-sdk-reflink-guard samba-cross-codegen-executor samba-cross-asn1-rule samba-sdk-generic-selection samba-sdk-spawn; do
  patch -p1 < "/work/patches/$name.patch"
done
