#!/bin/sh
# Release installer/orchestrator for the Xiaomi R2D Samba package.
#
#   ./install-release.sh verify      check payload + compat hashes only
#   ./install-release.sh install     unpack, activate, install compat, start
#   ./install-release.sh upgrade     same as install (previous version recorded)
#   ./install-release.sh rollback    stop, activate previous, start
#   ./install-release.sh uninstall   stop, restore vendor init, remove trees
#   ./install-release.sh status      service + version state
#
# The package is self-contained: payload/samba-tree.tar.gz, compat/*, VERSION.
# It never writes to /etc/config/samba or /usr/sbin.

set -u

PKG=$(cd "$(dirname "$0")" && pwd -P) || exit 2
BASE=${S7_BASE:-/userdisk/data/.dev/live/samba}
S8=${S8_BASE:-/userdisk/data/.dev/live/s8compat}
INIT=/etc/init.d/samba
VENDOR=/etc/init.d/samba.vendor
PORTS="139 445"

die() { echo "ERROR: $*" >&2; exit "${2:-1}"; }
say() { echo "== $*"; }

version() { cat "$PKG/VERSION" 2>/dev/null | tr -d ' \r\n'; }

payload_md5() { md5sum "$PKG/payload/samba-tree.tar.gz" | awk '{print $1}'; }

check_payload() {
	[ -f "$PKG/VERSION" ] || die "VERSION missing" 2
	[ -f "$PKG/payload/samba-tree.tar.gz" ] || die "payload missing" 2
	[ -f "$PKG/MANIFEST.md5" ] || die "MANIFEST.md5 missing" 2
	[ -f "$PKG/xiaomi-smb-install.sh" ] || die "tree installer missing" 2
	[ -f "$PKG/compat/install.sh" ] || die "compat installer missing" 2
	(cd "$PKG" && md5sum -c MANIFEST.md5 >/dev/null 2>&1) ||
		die "MANIFEST.md5 mismatch (run 'verify' for detail)" 3
}

listener_owner() {
	netstat -ltnp 2>/dev/null | grep -E ':(139|445) ' | head -5
}

ports_up() {
	netstat -ltn 2>/dev/null | grep -qE ':139 ' &&
		netstat -ltn 2>/dev/null | grep -qE ':445 '
}

wait_ports() {
	i=0
	while [ $i -lt 30 ]; do
		ports_up && return 0
		sleep 1
		i=$((i + 1))
	done
	return 1
}

svc_stop() {
	"$INIT" stop >/dev/null 2>&1 || true
	sleep 1
}

svc_start() {
	svc_stop
	"$INIT" start || die "service start failed" 1
	wait_ports || die "139/445 did not come up" 1
	"$INIT" status || die "service status failed after start" 1
	say "listeners"
	listener_owner
}

cmd_verify() {
	check_payload
	say "payload"
	echo "version=$(version)"
	echo "tree_md5=$(payload_md5)"
	(cd "$PKG" && md5sum -c MANIFEST.md5)
	echo "OK"
}

cmd_install() {
	v=$(version)
	check_payload
	say "stop current service"
	svc_stop
	say "install tree $v"
	sh "$PKG/xiaomi-smb-install.sh" install "$PKG/payload/samba-tree.tar.gz" "$v" ||
		die "tree install failed" $?
	say "activate $v"
	sh "$PKG/xiaomi-smb-install.sh" activate "$v" || die "activate failed" $?
	say "install adapter + compat layer"
	cp "$PKG/compat/xiaomi-smb-adapter.sh" "$BASE/xiaomi-smb-adapter.sh" || die "adapter copy"
	chmod 755 "$BASE/xiaomi-smb-adapter.sh"
	sh "$PKG/compat/install.sh" install || die "compat install failed" $?
	say "start"
	svc_start
	say "installed $v"
	"$INIT" status
}

cmd_rollback() {
	check_payload
	say "stop current service"
	svc_stop
	say "activate previous tree"
	sh "$PKG/xiaomi-smb-install.sh" rollback || die "rollback failed" $?
	say "start"
	svc_start
	"$INIT" status
}

cmd_uninstall() {
	say "stop service"
	svc_stop
	say "restore vendor init"
	if [ -f "$S8/versions/v0-vendor/samba.init" ]; then
		cp "$S8/versions/v0-vendor/samba.init" "$INIT.tmp" &&
			mv "$INIT.tmp" "$INIT" && chmod 755 "$INIT" ||
			die "restore vendor init failed" 1
		rm -f "$VENDOR"
	else
		die "vendor backup missing: $S8/versions/v0-vendor/samba.init" 2
	fi
	say "remove per-device access chain"
	# svc_stop already asked the hook to clear it; repeat explicitly while the
	# adapter still exists so a failed stop cannot leave our chain behind.
	if [ -x "$BASE/xiaomi-smb-adapter.sh" ]; then
		# 1.0.6 uses diskacl-clear; fall back to the old name so an
		# uninstall still removes the chain after a binary rollback.
		"$BASE/xiaomi-smb-adapter.sh" -r "$BASE" diskacl-clear >/dev/null 2>&1 ||
			"$BASE/xiaomi-smb-adapter.sh" -r "$BASE" pridisk-clear >/dev/null 2>&1 ||
			echo "note: diskacl-clear/pridisk-clear returned nonzero" >&2
	fi
	say "remove prefix symlink and trees"
	p="$BASE/current"
	real=$(readlink -f "$p" 2>/dev/null || true)
	case $real in
		"$BASE"/*) ;;
		*) real= ;;
	esac
	if [ -L /userdisk/data/samba-s2/root ]; then
		case $(readlink -f /userdisk/data/samba-s2/root) in
			"$BASE"/*) rm -f /userdisk/data/samba-s2/root ;;
		esac
	fi
	rm -f "$BASE/current"
	rm -rf "$BASE/versions" "$BASE/state"
	rm -f "$BASE/xiaomi-smb-adapter.sh" "$BASE/xiaomi-smb-install.sh"
	rm -f /etc/hotplug.d/block/90-s8-mounts
	say "start vendor service"
	"$INIT" start || echo "note: vendor start returned nonzero" >&2
	i=0
	while [ $i -lt 20 ]; do ports_up && break; sleep 1; i=$((i + 1)); done
	listener_owner
	echo "uninstalled (vendor restored)"
}

cmd_status() {
	v=$(version)
	echo "package=$v"
	echo "current=$(readlink "$BASE/current" 2>/dev/null || echo none)"
	[ -f "$S8/current/hook.sh" ] && echo "compat=$(readlink "$S8/current" 2>/dev/null)"
	"$INIT" status || echo "status rc=$?"
	listener_owner
}

case "${1:-}" in
	verify) cmd_verify ;;
	install|upgrade) cmd_install ;;
	rollback) cmd_rollback ;;
	uninstall) cmd_uninstall ;;
	status) cmd_status ;;
	*) echo "usage: $0 {verify|install|upgrade|rollback|uninstall|status}" >&2; exit 2 ;;
esac
