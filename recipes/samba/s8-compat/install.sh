#!/bin/sh
# S8 compat installer: versioned install / verify / rollback of the SMB
# service entry owned by /etc/init.d/samba.
#
#   /userdisk/data/.dev/live/s8compat/versions/v1/hook.sh      active compat driver
#   /userdisk/data/.dev/live/s8compat/versions/v1/xiaomi-smb-adapter.sh
#   /userdisk/data/.dev/live/s8compat/versions/v1/samba.init.wrapper
#   /userdisk/data/.dev/live/s8compat/versions/v0-vendor/samba.init   pristine vendor init
#   /userdisk/data/.dev/live/s8compat/current -> versions/v1 | versions/v0-vendor
#   /etc/init.d/samba         stable wrapper (falls back to vendor)
#   /etc/init.d/samba.vendor  byte-identical vendor copy
set -u

BASE=/userdisk/data/.dev/live/s8compat
VERS=$BASE/versions
CUR=$BASE/current
INIT=/etc/init.d/samba
VENDOR=/etc/init.d/samba.vendor
SMBROOT=/userdisk/data/.dev/live/samba/current
ADAPTER_SRC=/userdisk/data/.dev/live/samba/xiaomi-smb-adapter.sh
S2_LINK=/userdisk/data/samba-s2/root
HOTPLUG=/etc/hotplug.d/block/90-s8-mounts
CRON=/etc/crontabs/root
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
	# The new tree was built with prefix /userdisk/data/samba-s2/root.  The
	# adapter refuses to start unless that prefix resolves to this real tree,
	# so this symlink is part of the install, not test debris.
	real=$(readlink -f "$SMBROOT" 2>/dev/null || echo "$SMBROOT")
	mkdir -p "$(dirname "$S2_LINK")" || die "mkdir $(dirname "$S2_LINK")"
	ln -sfn "$real" "$S2_LINK" || die "prefix symlink $S2_LINK"
	# One-shot md5 watcher: 'lan=no -> yes' does not restart samba, so the
	# DROP has to be removed by a short-lived cron job, not a daemon.  It
	# points at the concrete v1 path (stable across 'current' switches) and
	# exits immediately unless current -> versions/v1.
	CRON_ENTRY="* * * * * $VERS/v1/diskacl-sync.sh >/dev/null 2>&1 # s8-diskacl"
	mkdir -p "$(dirname "$CRON")" || die "mkdir $(dirname "$CRON")"
	if [ -f "$CRON" ]; then
		grep -q "diskacl-sync.sh" "$CRON" ||
			printf '%s\n' "$CRON_ENTRY" >>"$CRON" ||
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
	real=$(readlink -f "$SMBROOT" 2>/dev/null || echo "$SMBROOT")
	linked=$(readlink -f "$S2_LINK" 2>/dev/null)
	[ "$linked" = "$real" ] ||
		die "prefix symlink mismatch ($S2_LINK -> ${linked:-missing}, want $real)"
	echo "== version manifest =="
	cat "$VERS/v1/MANIFEST"
	(cd "$VERS/v1" && md5sum -c MANIFEST) || die "manifest mismatch"
	[ -x "$HOTPLUG" ] || die "hotplug script missing"
	sh -n "$HOTPLUG" || die "hotplug syntax"
	[ -x "$VERS/v1/diskacl-sync.sh" ] || die "diskacl sync missing"
	sh -n "$VERS/v1/diskacl-sync.sh" || die "diskacl sync syntax"
	[ -f "$CRON" ] && grep -q "diskacl-sync.sh" "$CRON" ||
		die "diskacl cron entry missing"
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
