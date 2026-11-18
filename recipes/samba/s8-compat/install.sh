#!/bin/sh
# S8 compat installer: versioned install / verify / rollback of the SMB
# service entry owned by /etc/init.d/samba.
#
#   /userdisk/data/.yunshu/live/s8compat/versions/v1/hook.sh      active compat driver
#   /userdisk/data/.yunshu/live/s8compat/versions/v1/xiaomi-smb-adapter.sh
#   /userdisk/data/.yunshu/live/s8compat/versions/v1/samba.init.wrapper
#   /userdisk/data/.yunshu/live/s8compat/versions/v0-vendor/samba.init   pristine vendor init
#   /userdisk/data/.yunshu/live/s8compat/current -> versions/v1 | versions/v0-vendor
#   /etc/init.d/samba         stable wrapper (falls back to vendor)
#   /etc/init.d/samba.vendor  byte-identical vendor copy
set -u

BASE=/userdisk/data/.yunshu/live/s8compat
VERS=$BASE/versions
CUR=$BASE/current
INIT=/etc/init.d/samba
VENDOR=/etc/init.d/samba.vendor
SMBROOT=/userdisk/data/.yunshu/live/samba/current
ADAPTER_SRC=/userdisk/data/.yunshu/live/samba/xiaomi-smb-adapter.sh
HOTPLUG=/etc/hotplug.d/block/90-s8-mounts
CRON=/etc/crontabs/root
# The once-a-minute reconciler must not live on the internal HDD: crond forks a
# shell that reads the script from sda every minute, which is exactly the
# periodic read that keeps noflushd from letting the disk spin down.  Keep the
# authoritative copy in the version tree and run a tmpfs copy (D-S28-04).
RT=${S8_RUNTIME_DIR:-/tmp/samba-runtime}
RT_BIN=$RT/bin
STAGE=$(dirname "$0")

die() { echo "ERROR: $*" >&2; exit 1; }
is_wrapper() { grep -q "S8 SMB compatibility init" "$INIT" 2>/dev/null; }

cmd_install() {
	mkdir -p "$VERS/v0-vendor" "$VERS/v1" || die "mkdir $VERS"
	if is_wrapper; then
		[ -f "$VERS/v0-vendor/samba.init" ] ||
			die "wrapper already installed but vendor copy is missing"
	else
		cp "$INIT" "$VERS/v0-vendor/samba.init" || die "backup vendor init"
		md5sum "$VERS/v0-vendor/samba.init" | awk '{print $1}' \
			> "$VERS/v0-vendor/vendor.md5"
	fi
	cp "$ADAPTER_SRC" "$VERS/v1/xiaomi-smb-adapter.sh" || die "copy adapter"
	cp "$STAGE/hook.sh" "$VERS/v1/hook.sh" || die "copy hook"
	cp "$STAGE/samba.init.wrapper" "$VERS/v1/samba.init.wrapper" ||
		die "copy wrapper"
	cp "$STAGE/diskacl-sync.sh" "$VERS/v1/diskacl-sync.sh" ||
		die "copy diskacl sync"
	chmod 755 "$VERS/v1/hook.sh" "$VERS/v1/xiaomi-smb-adapter.sh" \
		"$VERS/v1/diskacl-sync.sh"
	mkdir -p "$RT_BIN" || die "mkdir $RT_BIN"
	cp "$STAGE/diskacl-sync.sh" "$RT_BIN/diskacl-sync.sh.tmp" &&
		mv "$RT_BIN/diskacl-sync.sh.tmp" "$RT_BIN/diskacl-sync.sh" &&
		chmod 755 "$RT_BIN/diskacl-sync.sh" ||
		die "stage diskacl sync on tmpfs"
	for f in "$VERS/v1/hook.sh" "$VERS/v1/samba.init.wrapper" \
		"$VERS/v1/diskacl-sync.sh"; do
		sh -n "$f" || die "syntax error: $f"
	done
	cp "$VERS/v0-vendor/samba.init" "$VENDOR.tmp" &&
		mv "$VENDOR.tmp" "$VENDOR" && chmod 755 "$VENDOR" ||
		die "install vendor copy"
	cp "$VERS/v1/samba.init.wrapper" "$INIT.tmp" &&
		mv "$INIT.tmp" "$INIT" && chmod 755 "$INIT" ||
		die "install wrapper"
	[ -f "$STAGE/90-s8-mounts" ] || die "hotplug script missing in $STAGE"
	mkdir -p "$(dirname "$HOTPLUG")" || die "mkdir $(dirname "$HOTPLUG")"
	cp "$STAGE/90-s8-mounts" "$HOTPLUG.tmp" &&
		mv "$HOTPLUG.tmp" "$HOTPLUG" && chmod 755 "$HOTPLUG" ||
		die "install hotplug script"
	sh -n "$HOTPLUG" || die "hotplug syntax"
	md5sum "$HOTPLUG" | awk '{print $1}' > "$VERS/v1/hotplug.md5"
	ln -sfn versions/v1 "$CUR"
	# No /userdisk/data/samba-s2 compatibility link: 1.0.9 and later are built
	# with the runtime prefix inside .yunshu, so nothing outside that tree is
	# referenced.  Re-creating the link would violate S20 of the device contract.
	# One-shot md5 watcher: 'lan=no -> yes' does not restart samba, so the
	# DROP has to be removed by a short-lived cron job, not a daemon.  It
	# points at the tmpfs copy (refreshed by hook.sh on every start) and
	# exits immediately unless current -> versions/v1.  Rewrite the line
	# instead of only appending, so a tree installed before D-S28-04 is
	# migrated off the HDD path.
	CRON_ENTRY="* * * * * $RT_BIN/diskacl-sync.sh >/dev/null 2>&1 # s8-diskacl"
	mkdir -p "$(dirname "$CRON")" || die "mkdir $(dirname "$CRON")"
	if [ -f "$CRON" ]; then
		grep -v 'diskacl-sync\.sh' "$CRON" >"$CRON.tmp" 2>/dev/null ||
			die "rewrite cron"
		printf '%s\n' "$CRON_ENTRY" >>"$CRON.tmp" || die "install cron entry"
		cat "$CRON.tmp" >"$CRON" && rm -f "$CRON.tmp" ||
			die "install cron entry"
	else
		printf '%s\n' "$CRON_ENTRY" >"$CRON" || die "install cron entry"
	fi
	# The crond shipped in 2.25.209 keeps the table it loaded at startup and
	# does not notice an edited /etc/crontabs/root (observed: the appended
	# line stayed dormant for several minutes until crond was restarted).
	# Restart the vendor cron service so the watcher is live immediately;
	# rc.common's restart is a clean stop/start, never a SIGHUP (a HUP makes
	# this crond exit instead of reloading).
	if [ -x /etc/init.d/cron ]; then
		/etc/init.d/cron restart >/dev/null 2>&1 ||
			echo "warn: cron restart failed; diskacl watcher starts on next reboot" >&2
	fi
	(cd "$VERS/v1" &&
		md5sum hook.sh xiaomi-smb-adapter.sh samba.init.wrapper \
			diskacl-sync.sh > MANIFEST)
	echo "installed v1; current -> $(readlink "$CUR")"
	cmd_verify
}

cmd_verify() {
	echo "== init md5 =="
	md5sum "$INIT" "$VENDOR" "$VERS/v0-vendor/samba.init"
	w=$(cat "$VERS/v0-vendor/vendor.md5" 2>/dev/null)
	v=$(md5sum "$VENDOR" 2>/dev/null | awk '{print $1}')
	[ -n "$w" ] && [ "$w" = "$v" ] || die "vendor copy mismatch ($w vs $v)"
	sh -n "$INIT" || die "init syntax"
	[ -x "$CUR/hook.sh" ] || die "active hook missing"
	sh -n "$CUR/hook.sh" || die "hook syntax"
	# S20 of the device contract: nothing of ours may live outside .yunshu.
	[ ! -e /userdisk/data/samba-s2 ] && [ ! -L /userdisk/data/samba-s2 ] ||
		die "/userdisk/data/samba-s2 present: violates contract S20"
	# Samba's directory_create_or_exist_strict() treats a symlinked msg.sock as
	# "isn't a directory" and refuses to start; the relocation must be a bind
	# mount (D-S28-07).
	[ ! -L "$SMBROOT/var/private/msg.sock" ] ||
		die "msg.sock must not be a symlink: Samba refuses to start"
	echo "== version manifest =="
	cat "$VERS/v1/MANIFEST"
	(cd "$VERS/v1" && md5sum -c MANIFEST) || die "manifest mismatch"
	[ -x "$HOTPLUG" ] || die "hotplug script missing"
	sh -n "$HOTPLUG" || die "hotplug syntax"
	[ -x "$VERS/v1/diskacl-sync.sh" ] || die "diskacl sync missing"
	sh -n "$VERS/v1/diskacl-sync.sh" || die "diskacl sync syntax"
	[ -x "$RT_BIN/diskacl-sync.sh" ] || die "diskacl sync tmpfs copy missing"
	sh -n "$RT_BIN/diskacl-sync.sh" || die "diskacl sync tmpfs syntax"
	[ -f "$CRON" ] && grep -qF "$RT_BIN/diskacl-sync.sh" "$CRON" ||
		die "diskacl cron entry missing or still on the HDD tree"
	grep -qF "$VERS/v1/diskacl-sync.sh >/dev/null" "$CRON" &&
		die "diskacl cron entry still points at the HDD tree"
	[ "$(md5sum "$HOTPLUG" | awk '{print $1}')" = \
		"$(cat "$VERS/v1/hotplug.md5" 2>/dev/null)" ] ||
		die "hotplug checksum mismatch"
	echo "== current =="
	readlink "$CUR"
	echo "== listeners =="
	netstat -ltn 2>/dev/null | grep -E ':(139|445) ' || echo "no listener"
}

cmd_state() {
	echo "current=$(readlink "$CUR")"
	ms=$SMBROOT/var/private/msg.sock
	# /proc/mounts shows the resolved path; $SMBROOT may go through current.
	if grep -q "var/private/msg.sock " /proc/mounts 2>/dev/null; then
		echo "msg.sock: tmpfs bind mounted"
	elif [ -d "$ms" ]; then
		echo "msg.sock is a directory on the data disk (adapter start relocates it)"
	else
		echo "msg.sock absent"
	fi
	echo "vendor.md5=$(cat "$VERS/v0-vendor/vendor.md5" 2>/dev/null)"
	echo "vendor.copy=$(md5sum "$VENDOR" 2>/dev/null | awk '{print $1}')"
	echo "init.md5=$(md5sum "$INIT" 2>/dev/null | awk '{print $1}')"
	echo "hotplug.md5=$(md5sum "$HOTPLUG" 2>/dev/null | awk '{print $1}')"
	ps w | grep -E "samba-s5d|/usr/sbin/smbd|nmbd|taskmonitor" | grep -v grep
	netstat -ltn 2>/dev/null | grep -E ':(139|445) '
	if [ -f /tmp/taskmonitor/taskmonitor.conf ]; then
		echo "-- task entries --"
		strings /tmp/taskmonitor/taskmonitor.conf |
			grep -E "samba-s5d|^/usr/sbin/smbd" || true
	fi
}

cmd_rollback() {
	echo "== stop new instance =="
	"$VERS/v1/xiaomi-smb-adapter.sh" -r "$SMBROOT" -p "139 445" -P stop ||
		echo "note: stop returned nonzero (already stopped?)"
	ln -sfn versions/v0-vendor "$CUR"
	echo "current -> $(readlink "$CUR")"
	echo "== restart vendor through init =="
	/etc/init.d/samba start || true
	i=0
	while [ $i -lt 25 ]; do
		netstat -ltn 2>/dev/null | grep -qE ':445 ' && break
		sleep 1
		i=$((i + 1))
	done
	netstat -ltn 2>/dev/null | grep -E ':(139|445) ' ||
		die "no listener after rollback"
	ps w | grep "/usr/sbin/smbd" | grep -v grep || true
	echo "rollback done"
}

case "${1:-}" in
install) cmd_install ;;
verify) cmd_verify ;;
state) cmd_state ;;
rollback) cmd_rollback ;;
*) echo "usage: $0 {install|verify|state|rollback}"; exit 2 ;;
esac
