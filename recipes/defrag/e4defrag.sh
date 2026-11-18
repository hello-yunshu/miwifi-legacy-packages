#!/bin/sh
# Online ext4 defragmentation for the internal HDD (sda1).
#
#   e4defrag.sh check  <path>...   report fragmentation scores, change nothing
#   e4defrag.sh defrag <path>...   defragment in place (EXT4_IOC_MOVE_EXT)
#
# The binary is the static ARM e4defrag 1.45.6 built by this recipe.
# Verified on the device 2026-11-18: 150-extent test file -> 1 extent, no
# kernel errors.
#
# Caveats:
#  - e4defrag does not lock writers.  Never point it at a file that is being
#    written (camera recordings, SMB/webdav uploads).
#  - A device-wide run ('defrag /dev/sda1' or '/userdisk/data') rewrites every
#    fragmented file and is slow on this CPU; prefer one directory at a time.
#  - Scores: 0-30 no problem, 31-55 slightly fragmented, 56+ needs defrag.
set -eu

BIN=${E4DEFRAG_BIN:-/userdisk/data/.yunshu/live/tools/bin/e4defrag}
cmd=${1:-}
[ -n "$cmd" ] || { echo "usage: $0 check|defrag <path>..." >&2; exit 2; }
shift

case "$cmd" in
check) exec "$BIN" -c "$@" ;;
defrag) exec "$BIN" -v "$@" ;;
*)
	echo "usage: $0 check|defrag <path>..." >&2
	exit 2
	;;
esac
