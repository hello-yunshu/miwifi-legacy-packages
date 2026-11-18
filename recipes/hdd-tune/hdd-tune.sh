#!/bin/sh
# HDD tuning for the R2D.
#
# The vendor leaves both disks on the cfq scheduler (2.6.36 default) and the
# internal disk at a 128 KB read-ahead.  On a single-disk NAS deadline is a
# better fit: it guarantees a latency budget for reads instead of letting
# queued writes delay a video seek.  512 KB read-ahead only affects sequential
# reads (media streaming); random metadata access is unchanged because ext4
# reads inode/bitmap blocks directly.
#
# sysfs values are lost on every boot, so apply is driven by
# /etc/init.d/hdd-tune (boot) and /etc/hotplug.d/block/85-hdd-tune (USB attach).
set -u

SDA=${SDA:-sda}
SDB=${SDB:-sdb}

sched() {
	cat "/sys/block/$1/queue/scheduler" 2>/dev/null
}

set_sched() {
	[ -d "/sys/block/$1/queue" ] || return 0
	case "$2" in
	deadline | cfq | noop)
		echo "$2" >"/sys/block/$1/queue/scheduler" || return 1
		;;
	*)
		return 1
		;;
	esac
	return 0
}

set_ra() {
	[ -e "/sys/block/$1/queue/read_ahead_kb" ] || return 0
	echo "$2" >"/sys/block/$1/queue/read_ahead_kb" || return 1
}

apply() {
	set_sched "$SDA" deadline
	set_sched "$SDB" deadline
	set_ra "$SDA" 512
	return 0
}

revert() {
	set_sched "$SDA" cfq
	set_sched "$SDB" cfq
	set_ra "$SDA" 128
	return 0
}

status() {
	for d in "$SDA" "$SDB"; do
		[ -d "/sys/block/$d/queue" ] || continue
		printf '%s scheduler=%s read_ahead_kb=%s\n' "$d" \
			"$(sched "$d")" \
			"$(cat "/sys/block/$d/queue/read_ahead_kb" 2>/dev/null)"
	done
}

case "${1:-}" in
apply) apply ;;
revert) revert ;;
status) status ;;
*)
	echo "usage: $0 apply|status|revert" >&2
	exit 2
	;;
esac
