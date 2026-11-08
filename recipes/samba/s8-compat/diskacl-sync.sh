#!/bin/sh
# One-shot reconciler for the per-device SMB access chain.
#
# Why this exists: the vendor only restarts Samba when a device goes
# 'lan=yes -> no'.  Re-enabling a device ('no -> yes') does not restart
# anything, so the DROP would otherwise stay until the next restart.  This
# script is run by busybox crond once a minute; it is NOT a resident daemon.
#
# It is deliberately conservative:
#   * no-op unless /userdisk/data/s8compat/current really points at v1
#     (after rollback to the vendor tree the job stays quiet);
#   * no-op when macfilter is missing/unreadable or its md5 cannot be read;
#   * only rebuilds when the macfilter md5 changed, or when the chain/jumps
#     disappeared, or when the legacy all-DROP chain came back;
#   * a refused policy (mode.lan != blacklist) is cached too, so it is not
#     re-evaluated every minute.
#
# TaskMonitor risk: crond is a vendor service and this job is a short-lived
# shell process that is never registered in /tmp/taskmonitor/taskmonitor.conf.
# TaskMonitor only acts on the PIDs/command lines it owns, so there is nothing
# for it to kill or revive here.  If the adapter itself is restarted by
# TaskMonitor it re-applies the same blacklist chain, which is safe by design.

PATH=/usr/sbin:/usr/bin:/sbin:/bin
BASE=${S8_BASE:-/userdisk/data/s8compat}
S8DIR=$BASE/versions/v1
ADAPTER=$S8DIR/xiaomi-smb-adapter.sh
[ -x "$ADAPTER" ] || ADAPTER=/userdisk/data/s7root/xiaomi-smb-adapter.sh
SMBROOT=${S8_SMB_ROOT:-/userdisk/data/s7root/current}
MACFILTER=${S8_MACFILTER:-/etc/config/macfilter}
IPT=${S8_IPTABLES:-iptables}
CHAIN=${S8_DISKACL_CHAIN:-s8-diskacl}
LEGACY=${S8_LEGACY_CHAIN:-s8-pridisk}
STATE=${S8_SYNC_STATE:-$BASE/state}
LOG=$STATE/sync.log

cur=$(readlink "$BASE/current" 2>/dev/null || true)
[ "$cur" = versions/v1 ] || exit 0
[ -x "$ADAPTER" ] || exit 0
[ -f "$MACFILTER" ] && [ -r "$MACFILTER" ] || exit 0

sum=$(md5sum "$MACFILTER" 2>/dev/null | awk '{print $1}')
[ -n "$sum" ] || exit 0

mkdir -p "$STATE" 2>/dev/null || exit 0
old=$(cat "$STATE/macfilter.md5" 2>/dev/null || true)
need=0
[ "$sum" = "$old" ] || need=1

# Cheap self-heal when the file itself did not change.
if [ "$need" -eq 0 ]; then
	statef=$SMBROOT/var/state/diskacl.state
	decision=$(sed -n 's/^decision=//p' "$statef" 2>/dev/null)
	denied=$(sed -n 's/^denied=//p' "$statef" 2>/dev/null)
	if [ "$decision" = applied ] && [ "${denied:-0}" -gt 0 ] 2>/dev/null; then
		"$IPT" -S "$CHAIN" >/dev/null 2>&1 || need=1
		jumps=$("$IPT" -S INPUT 2>/dev/null | grep -cF -- "-j $CHAIN")
		[ "$jumps" = 2 ] || need=1
	fi
	# A returning legacy chain is always urgent, even under a refused policy.
	"$IPT" -S "$LEGACY" >/dev/null 2>&1 && need=1
fi

[ "$need" -eq 1 ] || exit 0

rc=0
"$ADAPTER" -r "$SMBROOT" diskacl-apply >>"$LOG" 2>&1 || rc=$?
# 0 = applied, 8 = deliberately refused/unavailable (deterministic until the
# file changes); both mean there is nothing to retry this minute.
case $rc in
0|8)
	tmp=$STATE/.macfilter.md5.$$
	if printf '%s\n' "$sum" >"$tmp" 2>/dev/null; then
		mv "$tmp" "$STATE/macfilter.md5" 2>/dev/null || rm -f "$tmp"
	fi
	;;
esac
exit 0
