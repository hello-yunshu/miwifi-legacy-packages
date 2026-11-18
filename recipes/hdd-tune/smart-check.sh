#!/bin/sh
# SMART self-test scheduling for the internal disk and the USB disk.
#
#   smart-check.sh start     cron: 1st of month 03:30 -- long in Jan/Apr/Jul/Oct,
#                            short otherwise
#   smart-check.sh short     run a short test now
#   smart-check.sh long      run a long test now
#   smart-check.sh collect   cron: 1st of month 06:00 -- append results to the
#                            log and raise a syslog warning when a test failed
#                            or a defect counter is non-zero
#
# A long test reads every sector (about 2 h on the 1 TB internal disk) and keeps
# the platter spinning for that time; short takes about 2 min.  The USB disk
# needs '-d sat' and may be absent, in which case it is skipped silently.
set -u

LOG=${SMART_LOG:-/userdisk/data/.yunshu/live/tools/smart.log}
CTL=${SMARTCTL:-/usr/sbin/smartctl}
TAG=smart

args_for() {
	case "$1" in
	sdb) echo "-d sat" ;;
	*) echo "" ;;
	esac
}

devices() {
	echo sda
	[ -e /dev/sdb ] && echo sdb
}

run_test() {
	mode=$1
	for dev in $(devices); do
		a=$(args_for "$dev")
		out=$($CTL $a -t "$mode" "/dev/$dev" 2>&1)
		rc=$?
		printf '%s start %s %s rc=%s\n' "$(date '+%F %T')" \
			"$mode" "$dev" "$rc" >>"$LOG"
		logger -t "$TAG" "start $mode on $dev rc=$rc"
	done
}

collect_one() {
	dev=$1
	a=$(args_for "$dev")
	[ -e "/dev/$dev" ] || return 0
	out=$($CTL $a -A "/dev/$dev" 2>/dev/null)
	st=$($CTL $a -l selftest "/dev/$dev" 2>/dev/null)

	printf '=== %s %s\n' "$(date '+%F %T')" "$dev" >>"$LOG"
	echo "$st" | sed -n '/Self-test log/,$p' | sed -n '3,4p' >>"$LOG"
	echo "$out" | awk '/Reallocated_Sector_Ct|Current_Pending_Sector|Offline_Uncorrectable|UDMA_CRC_Error_Count/ {print}' >>"$LOG"

	bad=$(echo "$out" | awk '$2 ~ /Reallocated_Sector_Ct|Current_Pending_Sector|Offline_Uncorrectable/ && $10 + 0 > 0 {printf "%s=%s ", $2, $10}')
	fail=$(echo "$st" | awk '/^# 1/ && $0 !~ /Completed without error/ {print; exit}')
	[ -n "$bad" ] && logger -t "$TAG" "$dev defect counters: $bad"
	[ -n "$fail" ] && logger -t "$TAG" "$dev last self-test not clean: $fail"
	return 0
}

# The vendor collects the same SMART data one extra time every Monday 18:00
# (/sbin/hdd_stat.sh) and ships it as statistics.  Rebuilding that record here
# from data the monthly collect already reads removes one weekly disk wake; the
# only loss is that the App's disk panel refreshes monthly instead of weekly.
stat_record() {
	[ -e /dev/sda ] || return 0
	info=$($CTL -i /dev/sda 2>/dev/null)
	family=$(echo "$info" | sed -n 's/^Model Family:[[:space:]]*//p' | xargs | tr ' ' '_')
	dmodel=$(echo "$info" | sed -n 's/^Device Model:[[:space:]]*//p' | xargs | tr ' ' '_')
	[ -z "$family" ] && [ -z "$dmodel" ] && return 0
	attrs=$($CTL -A /dev/sda 2>/dev/null |
		awk '/^[[:space:]]*[0-9]+[[:space:]]/ {printf "%d:%d,%d,%d,%s,%d;", $1, $4, $5, $6, $9, $10}')
	model=$(cat /proc/xiaoqiang/model 2>/dev/null)
	logger stat_points_none \
		"hdd_stat_v2_${model}=Version:1;Family:${family};Model:${dmodel};${attrs}END;"
}

case "${1:-}" in
start)
	case "$(date +%m)" in
	01 | 04 | 07 | 10) run_test long ;;
	*) run_test short ;;
	esac
	;;
short | long)
	run_test "$1"
	;;
collect)
	for dev in $(devices); do
		collect_one "$dev"
	done
	stat_record
	;;
*)
	echo "usage: $0 start|short|long|collect" >&2
	exit 2
	;;
esac
