#!/bin/sh
# R2D WebDAV lifecycle (lighttpd 1.4.85 + mod_webdav, port 5005 on br-lan).
#
# Layout under /userdisk/data/.yunshu/live/webdav:
#   current -> versions/<ver>/root   binaries, modules and private libs
#   conf/lighttpd.conf               config
#   conf/users.basic                 basic credentials (0600 nobody)
#   state/                           pid, error.log, upload tmp, webdav.db
#   webroot/本机储存/                 bind mounts of every visible top-level dir of /userdisk/data
#   webroot/外接盘/                   bind mount of the first mounted /extdisks/*
#
# Two roots mirror the SMB entries XiaoMi (/userdisk/data) and XiaoMi-usb0
# (/extdisks/sdb1). Dot entries (.yunshu, .systemconfig, ...) and the top-level
# compatibility symlinks are never mounted, so they cannot be listed or fetched.
#
# Usage: run.sh start|stop|restart|status|watch|heal
set -u

BASE=/userdisk/data/.yunshu/live/webdav
ROOT=$BASE/current
CONF=$BASE/conf/lighttpd.conf
STATE=$BASE/state
WEBROOT=$BASE/webroot
LOCAL_ROOT=$WEBROOT/本机储存
USB_ROOT=$WEBROOT/外接盘
DATA_ROOT=/userdisk/data
USB_BASE=/extdisks
PIDF=$STATE/lighttpd.pid
LOG=$BASE/webdav.log

BOOT_WAIT=${WEBDAV_BOOT_WAIT:-180}
WATCH_INTERVAL=${WEBDAV_WATCH_INTERVAL:-30}

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >>"$LOG" 2>/dev/null; }

data_mounted() { grep -q ' /userdisk/data ' /proc/mounts 2>/dev/null; }
is_mounted() { grep -q " $1 " /proc/mounts 2>/dev/null; }

running_pid() {
	[ -f "$PIDF" ] || return 1
	p=$(cat "$PIDF" 2>/dev/null)
	[ -n "$p" ] && kill -0 "$p" 2>/dev/null && { echo "$p"; return 0; }
	return 1
}

mount_one() {
	src=$1
	dst=$2
	[ -d "$src" ] || return 1
	mkdir -p "$dst" 2>/dev/null || return 1
	is_mounted "$dst" && return 0
	mount --bind "$src" "$dst" || return 1
	return 0
}

umount_one() {
	is_mounted "$1" || return 0
	umount "$1" 2>/dev/null || umount -l "$1" 2>/dev/null
	return 0
}

# Bind every visible top-level directory of the data partition, then drop
# entries whose source directory disappeared (unplugged/renamed).
sync_local() {
	for src in "$DATA_ROOT"/*; do
		[ -e "$src" ] || continue
		[ -L "$src" ] && continue
		[ -d "$src" ] || continue
		case "${src##*/}" in .*|lost+found) continue ;; esac
		mount_one "$src" "$LOCAL_ROOT/${src##*/}" || log "bind failed: $src"
	done
	for dst in "$LOCAL_ROOT"/*; do
		[ -e "$dst" ] || continue
		is_mounted "$dst" || continue
		# /proc/mounts reports the backing device for bind mounts, not the source
		# path, so stale detection compares against the expected source directory.
		if [ ! -d "$DATA_ROOT/${dst##*/}" ]; then
			log "prune stale local mount: $dst"
			umount_one "$dst"
			rmdir "$dst" 2>/dev/null
		fi
	done
	for dst in "$LOCAL_ROOT"/*; do
		[ -d "$dst" ] || continue
		is_mounted "$dst" || rmdir "$dst" 2>/dev/null
	done
}

usb_source() {
	for d in "$USB_BASE"/*; do
		[ -d "$d" ] || continue
		is_mounted "$d" || continue
		echo "$d"
		return 0
	done
	return 1
}

# Follow the external disk: bind whichever partition is mounted under /extdisks.
# The bound source is remembered in state/usb.src because /proc/mounts only
# reports the backing device for bind mounts.
sync_usb() {
	src=$(usb_source)
	cur=$(cat "$STATE/usb.src" 2>/dev/null)
	if [ -n "$src" ]; then
		[ "$cur" = "$src" ] && is_mounted "$USB_ROOT" && return 0
		umount_one "$USB_ROOT"
		if mount_one "$src" "$USB_ROOT"; then
			echo "$src" >"$STATE/usb.src"
		else
			log "usb bind failed: $src"
		fi
	else
		if is_mounted "$USB_ROOT"; then
			log "prune usb mount: $cur"
			umount_one "$USB_ROOT"
		fi
		rm -f "$STATE/usb.src"
	fi
	return 0
}

prepare() {
	mkdir -p "$STATE/tmp" "$WEBROOT" "$LOCAL_ROOT" "$USB_ROOT" 2>/dev/null
	chown nobody:nogroup "$STATE" "$STATE/tmp" 2>/dev/null
	chmod 750 "$STATE" 2>/dev/null
	chmod 700 "$STATE/tmp" 2>/dev/null
	# Read-only for nobody at the two root levels so PUT/MKCOL/DELETE of the
	# roots themselves fail; children are separate bind mounts with their own modes.
	chown root:root "$WEBROOT" "$LOCAL_ROOT" "$USB_ROOT" 2>/dev/null
	chmod 755 "$WEBROOT" 2>/dev/null
	chmod 555 "$LOCAL_ROOT" "$USB_ROOT" 2>/dev/null
}

# Remove the pre-2026-11-10 flat layout (webroot/{下载,共享,图片,文档}).
cleanup_legacy() {
	for old in 下载 共享 图片 文档; do
		d=$WEBROOT/$old
		is_mounted "$d" && umount "$d" 2>/dev/null
		[ -d "$d" ] && rmdir "$d" 2>/dev/null
	done
}

lighttpd_start() {
	[ -x "$ROOT/sbin/lighttpd" ] || { log "binary missing: $ROOT/sbin/lighttpd"; return 1; }
	umask 000
	# The binary and modules are built with an absolute DT_RPATH pointing at the
	# data-disk root. patch-rpath.sh rewrites that string, with identical length,
	# to /userdisk/data/.yunshu/live/webdav/lib, so nothing outside .yunshu is
	# needed and LD_LIBRARY_PATH is not required: uClibc resolves an object's own
	# DT_RPATH before the environment variable. Re-run patch-rpath.sh on any new
	# tree (it matches the build-host DESTDIR prefix as well).
	"$ROOT/sbin/lighttpd" -m "$ROOT/lib" -f "$CONF"
	rc=$?
	[ "$rc" -eq 0 ] || { log "lighttpd failed rc=$rc"; return 1; }
	i=0
	while [ "$i" -lt 10 ]; do
		running_pid >/dev/null && return 0
		sleep 1
		i=$((i + 1))
	done
	log "lighttpd exited without pidfile"
	return 1
}

start_watch() {
	if [ -f "$STATE/watch.pid" ] && kill -0 "$(cat "$STATE/watch.pid" 2>/dev/null)" 2>/dev/null; then
		return 0
	fi
	nohup sh "$0" watch >>"$LOG" 2>&1 &
	echo $! >"$STATE/watch.pid"
}

stop_watch() {
	[ -f "$STATE/watch.pid" ] && kill "$(cat "$STATE/watch.pid" 2>/dev/null)" 2>/dev/null
	rm -f "$STATE/watch.pid"
	return 0
}

do_start() {
	i=0
	while [ "$i" -lt "$BOOT_WAIT" ]; do
		data_mounted && [ -x "$ROOT/sbin/lighttpd" ] && break
		sleep 1
		i=$((i + 1))
	done
	if ! data_mounted; then
		log "start: /userdisk/data not mounted after ${BOOT_WAIT}s"
		return 1
	fi
	prepare
	cleanup_legacy
	sync_local
	sync_usb
	if p=$(running_pid); then
		log "start: already running pid=$p"
	else
		lighttpd_start || return 1
		log "start: pid=$(running_pid) bind=192.168.3.2:5005"
	fi
	start_watch
	return 0
}

do_stop() {
	stop_watch
	if p=$(running_pid); then
		kill "$p" 2>/dev/null
		log "stop: pid=$p"
	fi
	rm -f "$PIDF"
	for dst in "$LOCAL_ROOT"/* "$USB_ROOT"; do umount_one "$dst"; done
	return 0
}

do_status() {
	echo "binary: $ROOT/sbin/lighttpd $([ -x "$ROOT/sbin/lighttpd" ] && echo ok || echo missing)"
	echo "pid: $(running_pid || echo none)"
	echo "watch_pid: $(cat "$STATE/watch.pid" 2>/dev/null || echo none)"
	echo "listen:"
	netstat -lnt 2>/dev/null | grep ':5005 ' || echo "  not listening"
	echo "本机储存:"
	for d in "$LOCAL_ROOT"/*; do
		[ -e "$d" ] || continue
		is_mounted "$d" && echo "  ${d##*/} mounted" || echo "  ${d##*/} NOT mounted"
	done
	echo "外接盘:"
	src=$(cat "$STATE/usb.src" 2>/dev/null)
	[ -n "$src" ] && is_mounted "$USB_ROOT" && echo "  mounted from $src" || echo "  no external disk"
}

do_watch() {
	while :; do
		if data_mounted; then
			sync_local
			sync_usb
			if ! running_pid >/dev/null; then
				log "watch: lighttpd absent, restarting"
				lighttpd_start
			fi
		fi
		sleep "$WATCH_INTERVAL"
	done
}

do_heal() {
	data_mounted || { log "heal: data not mounted"; return 1; }
	prepare
	cleanup_legacy
	sync_local
	sync_usb
	running_pid >/dev/null || { log "heal: restarting lighttpd"; lighttpd_start; }
	return 0
}

case "${1:-}" in
start) do_start ;;
stop) do_stop ;;
restart) do_stop; do_start ;;
status) do_status ;;
watch) do_watch ;;
heal) do_heal ;;
*) echo "usage: $0 start|stop|restart|status|watch|heal"; exit 2 ;;
esac
