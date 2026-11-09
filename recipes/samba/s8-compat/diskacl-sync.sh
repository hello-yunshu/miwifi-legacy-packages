#!/bin/sh
# One-shot reconciler for the per-device SMB access chain.
#
# Why this exists: the vendor only restarts Samba when a device goes
# 'lan=yes -> no'.  Re-enabling a device ('no -> yes') does not restart
# anything, so the DROP would otherwise stay until the next restart.  This
# script is run by busybox crond once a minute; it is NOT a resident daemon.
#
# It is deliberately conservative:
#   * no-op unless /userdisk/data/.dev/live/s8compat/current really points at v1
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
BASE=${S8_BASE:-/userdisk/data/.dev/live/s8compat}
S8DIR=$BASE/versions/v1
ADAPTER=$S8DIR/xiaomi-smb-adapter.sh
[ -x "$ADAPTER" ] || ADAPTER=/userdisk/data/.dev/live/samba/xiaomi-smb-adapter.sh
SMBROOT=${S8_SMB_ROOT:-/userdisk/data/.dev/live/samba/current}
MACFILTER=${S8_MACFILTER:-/etc/config/macfilter}
IPT=${S8_IPTABLES:-iptables}
CHAIN=${S8_DISKACL_CHAIN:-s8-diskacl}
LEGACY=${S8_LEGACY_CHAIN:-s8-pridisk}
GUEST_IFACE=${S8_GUEST_IFACE:-br-guest}
GUEST_PORTS=${S8_DISKACL_TCP_PORTS:-139,445}
NET_DIR=${S8_NET_DIR:-/sys/class/net}
STATE=${S8_SYNC_STATE:-$BASE/state}
LOG=$STATE/sync.log

cur=$(readlink "$BASE/current" 2>/dev/null || true)
[ "$cur" = versions/v1 ] || exit 0
[ -x "$ADAPTER" ] || exit 0

mkdir -p "$STATE" 2>/dev/null || exit 0

# macfilter drives the per-device chain; it is optional here so that the
# guest refusal below is still health-checked when the file is missing.
sum=""
if [ -f "$MACFILTER" ] && [ -r "$MACFILTER" ]; then
	sum=$(md5sum "$MACFILTER" 2>/dev/null | awk '{print $1}')
fi

need=0
if [ -n "$sum" ]; then
	old=$(cat "$STATE/macfilter.md5" 2>/dev/null || true)
	[ "$sum" = "$old" ] || need=1
fi

# Guest refusal must exist exactly once and stay above the vendor's
# any-interface ACCEPT for 139/445.  A rule that slipped below it is as
# useless as a missing one, so both trigger a rebuild.
if [ -d "$NET_DIR/$GUEST_IFACE" ] && [ "$need" -eq 0 ]; then
	gspec="-i $GUEST_IFACE -p tcp -m multiport --dports $GUEST_PORTS -j DROP"
	n=$("$IPT" -S INPUT 2>/dev/null | grep -cF -- "$gspec")
	[ "$n" = 1 ] || need=1
	if [ "$need" -eq 0 ]; then
		gi=$("$IPT" -S INPUT 2>/dev/null |
			awk -v s="$gspec" '
				/^-A INPUT / { n++; if (index($0, s)) { print n; exit } }')
		vi=$("$IPT" -S INPUT 2>/dev/null |
			awk '
				/^-A INPUT / { n++ }
				/-j ACCEPT/ && /--dports / && /445/ && !/-i / { print n; exit }')
		[ -n "$gi" ] || need=1
		[ "$need" -eq 0 ] && [ -n "$vi" ] && [ "$gi" -ge "$vi" ] && need=1
	fi
fi

# Cheap self-heal when the file itself did not change.
if [ "$need" -eq 0 ] && [ -n "$sum" ]; then
	statef=$SMBROOT/var/state/diskacl.state
	decision=$(sed -n 's/^decision=//p' "$statef" 2>/dev/null)
	denied=$(sed -n 's/^denied=//p' "$statef" 2>/dev/null)
	if [ "$decision" = applied ] && [ "${denied:-0}" -gt 0 ] 2>/dev/null; then
		"$IPT" -S "$CHAIN" >/dev/null 2>&1 || need=1
		jumps=$("$IPT" -S INPUT 2>/dev/null | grep -cF -- "-j $CHAIN")
		[ "$jumps" = 2 ] || need=1
	fi
fi

# A returning legacy chain is always urgent, even under a refused policy.
if [ "$need" -eq 0 ]; then
	"$IPT" -S "$LEGACY" >/dev/null 2>&1 && need=1
fi

[ "$need" -eq 1 ] || exit 0

rc=0
"$ADAPTER" -r "$SMBROOT" diskacl-apply >>"$LOG" 2>&1 || rc=$?
# 0 = applied, 8 = deliberately refused/unavailable (deterministic until the
# file changes); both mean there is nothing to retry this minute.
case $rc in
0|8)
	[ -n "$sum" ] || exit 0
	tmp=$STATE/.macfilter.md5.$$
	if printf '%s\n' "$sum" >"$tmp" 2>/dev/null; then
		mv "$tmp" "$STATE/macfilter.md5" 2>/dev/null || rm -f "$tmp"
	fi
	;;
esac
exit 0
