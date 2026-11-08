#!/bin/sh
# S8 compat installer: versioned install / verify / rollback of the SMB
# service entry owned by /etc/init.d/samba.
#
#   /userdisk/data/s8compat/versions/v1/hook.sh      active compat driver
#   /userdisk/data/s8compat/versions/v1/xiaomi-smb-adapter.sh
#   /userdisk/data/s8compat/versions/v1/samba.init.wrapper
#   /userdisk/data/s8compat/versions/v0-vendor/samba.init   pristine vendor init
#   /userdisk/data/s8compat/current -> versions/v1 | versions/v0-vendor
#   /etc/init.d/samba         stable wrapper (falls back to vendor)
#   /etc/init.d/samba.vendor  byte-identical vendor copy
set -u

BASE=/userdisk/data/s8compat
VERS=$BASE/versions
CUR=$BASE/current
INIT=/etc/init.d/samba
VENDOR=/etc/init.d/samba.vendor
SMBROOT=/userdisk/data/s7root/current
ADAPTER_SRC=/userdisk/data/s7root/xiaomi-smb-adapter.sh
S2_LINK=/userdisk/data/samba-s2/root
HOTPLUG=/etc/hotplug.d/block/90-s8-mounts
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
	chmod 755 "$VERS/v1/hook.sh" "$VERS/v1/xiaomi-smb-adapter.sh"
	for f in "$VERS/v1/hook.sh" "$VERS/v1/samba.init.wrapper"; do
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
	(cd "$VERS/v1" &&
		md5sum hook.sh xiaomi-smb-adapter.sh samba.init.wrapper > MANIFEST)
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
