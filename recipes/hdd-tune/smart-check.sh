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
#   smart-check.sh nand      append the UBI erase counters (NAND wear) to the
#                            same log; collect calls it in the same window
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
	echo "$out" | awk '/Reallocated_Sector_Ct|Current_Pending_Sector|Offline_Uncorrectable|UDMA_CRC_Error_Count|Start_Stop_Count|Power_On_Hours|Power_Cycle_Count|Load_Cycle_Count|Temperature_Celsius|Airflow_Temperature_Cel/ {print}' >>"$LOG"

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

# NAND wear record (D-S28-17).  UBI keeps a per-eraseblock erase counter;
# max_ec is the number of program/erase cycles the most-worn physical
# eraseblock has seen, i.e. a direct read of P/E consumption.  ubi2 (mtd10
# "overlay") carries /data, /userdisk and /etc; ubi1 is the read-only rootfs
# and must stay near zero.
nand_record() {
	[ -d /sys/class/ubi/ubi2 ] || return 0
	printf '=== %s nand\n' "$(date '+%F %T')" >>"$LOG"
	for u in ubi1 ubi2; do
		[ -d "/sys/class/ubi/$u" ] || continue
		printf 'nand %s max_ec=%s bad_peb=%s pebs=%s avail=%s\n' "$u" \
			"$(cat /sys/class/ubi/$u/max_ec 2>/dev/null)" \
			"$(cat /sys/class/ubi/$u/bad_peb_count 2>/dev/null)" \
			"$(cat /sys/class/ubi/$u/total_eraseblocks 2>/dev/null)" \
			"$(cat /sys/class/ubi/$u/avail_eraseblocks 2>/dev/null)" >>"$LOG"
	done
	df -k /data 2>/dev/null |
		awk 'NR==2 {printf "nand /data used=%dK avail=%dK (%s)\n", $3, $4, $5}' >>"$LOG"

	m=$(cat /sys/class/ubi/ubi2/max_ec 2>/dev/null)
	case "$m" in '' | *[!0-9]*) ;; *)
		[ "$m" -ge "${NAND_MAX_EC_WARN:-30000}" ] &&
			logger -t nand "ubi2 max_ec=$m reached ${NAND_MAX_EC_WARN:-30000}"
		;;
	esac
	b=$(cat /sys/class/ubi/ubi2/bad_peb_count 2>/dev/null)
	case "$b" in '' | *[!0-9]*) ;; *)
		[ "$b" -ge "${NAND_BAD_WARN:-8}" ] &&
			logger -t nand "ubi2 bad_peb_count=$b reached ${NAND_BAD_WARN:-8}"
		;;
	esac
	return 0
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
	nand_record
	;;
nand)
	nand_record
	;;
*)
	echo "usage: $0 start|short|long|collect|nand" >&2
	exit 2
	;;
esac
