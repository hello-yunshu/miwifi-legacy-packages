#!/bin/sh
# Xiaomi MiWiFi Samba install / upgrade / rollback / uninstall helper (S7).
#
# Installs packaged Samba trees side by side, activates a version by atomically
# repointing the prefix that smbd was *built* for (SBINDIR from `smbd -b`), and
# never writes to vendor paths (/usr/sbin, /etc/config, /var/etc, 139/445).
#
# Layout:
#   $BASE/versions/<name>/root/...   unpacked tree
#   $BASE/current -> versions/<name>/root
#   $BASE/state/previous             name to roll back to
#   $BASE/state/vendor.md5           baseline of vendor files (first install)
#   $BASE/state/<name>.sha256        payload digest
#   $BASE/state/install.log          install / activate audit trail
#
# Retention:
#   Keep at least one complete previous tree (N-1) plus the state/previous
#   pointer, so rollback never depends on re-downloading a package.  Deleting a
#   tree without clearing the pointer leaves a dangling rollback target; install
#   then refuses to upgrade (exit 6) and only re-installing that exact missing
#   tree is allowed.  Activation verifies the rollback tree without starting it
#   and records the result in state/install.log.
#
# Exit codes:
#   0 ok
#   1 runtime failure (stop/start/health)
#   2 bad invocation or missing prerequisite
#   3 payload rejected (missing binaries / prefix cannot be parsed)
#   4 prefix conflict (target exists and is not our symlink)
#   5 vendor file drift against recorded baseline
#   6 no previous version / version not installed / rollback target tree missing

set -u

BASE=${S7_BASE:-/userdisk/data/s7root}
ADAPTER=${S7_ADAPTER:-$BASE/xiaomi-smb-adapter.sh}
PORT=${S7_PORT:-1445}
BIND=${S7_BIND:-192.168.3.2}
VENDOR_BIN=${S7_VENDOR_BIN:-/usr/sbin/samba_multicall}
VENDOR_CONF=${S7_VENDOR_CONF:-/etc/config/samba}
BASELINE=${S7_BASELINE:-$BASE/state/vendor.md5}
CONFIG_BASELINE=${S7_CONFIG_BASELINE:-$BASE/state/vendor-config.md5}
CRONTAB=${S7_CRONTAB:-/etc/crontabs/root}
LOG=${S7_INSTALL_LOG:-$BASE/state/install.log}

die() { echo "install: $1" >&2; exit "${2:-1}"; }

log() {
	mkdir -p "$BASE/state" 2>/dev/null
	printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG" 2>/dev/null || true
}

sha() { md5sum "$1" 2>/dev/null | awk '{print $1}'; }

tree_root() { echo "$BASE/versions/$1/root"; }

previous_name() { cat "$BASE/state/previous" 2>/dev/null || true; }

# Inspect the recorded rollback target without starting it.  Sets RB_STATUS,
# RB_NAME and RB_PREFIX; returns 1 when the pointer names an unusable tree.
check_rollback() {
	RB_STATUS=none
	RB_NAME=
	RB_PREFIX=
	rb=$(previous_name)
	[ -n "$rb" ] || return 0
	RB_NAME=$rb
	rb_tree=$(tree_root "$rb")
	[ -d "$rb_tree" ] || { RB_STATUS=missing-tree; return 1; }
	[ -x "$rb_tree/sbin/smbd" ] || { RB_STATUS=missing-smbd; return 1; }
	RB_PREFIX=$(baked_prefix "$rb_tree") || { RB_STATUS=bad-prefix; return 1; }
	RB_STATUS=ok
	return 0
}

report_rollback() {
	if check_rollback; then
		case $RB_STATUS in
		none)
			echo "  rollback: none"
			log "rollback-target: none"
			;;
		ok)
			echo "  rollback: $RB_NAME (tree ok, not started)"
			log "rollback-target: $RB_NAME verified tree+baked-prefix, not started"
			;;
		esac
		return 0
	fi
	echo "  rollback: UNUSABLE $RB_NAME ($RB_STATUS)" >&2
	log "rollback-target: $RB_NAME UNUSABLE:$RB_STATUS"
	return 1
}

current_name() {
	[ -L "$BASE/current" ] || return 1
	readlink "$BASE/current" | sed -n 's#^versions/\([^/]*\)/root$#\1#p'
}

baked_prefix() {
	smbd=$1/sbin/smbd
	[ -x "$smbd" ] || return 1
	sb=$(LD_LIBRARY_PATH="$1/lib:$1/lib/private" "$smbd" -b 2>/dev/null |
		sed -n 's/^[[:space:]]*SBINDIR:[[:space:]]*//p')
	[ -n "$sb" ] || return 1
	dirname "$sb"
}

record_vendor_baseline() {
	[ -f "$BASELINE" ] || {
		mkdir -p "$BASE/state" || die "cannot create $BASE/state" 1
		[ -f "$VENDOR_BIN" ] &&
			echo "$(md5sum "$VENDOR_BIN" | awk '{print $1}')  $VENDOR_BIN" >"$BASELINE"
	}
	# The management stack rewrites these UCI files on its own schedule, so
	# they are recorded separately and reported as configuration drift rather
	# than treated as a firmware overwrite.  The adapter's config guard is the
	# gate that decides whether a changed source may be rendered.
	[ -f "$CONFIG_BASELINE" ] || {
		mkdir -p "$BASE/state" || die "cannot create $BASE/state" 1
		{
			[ -f "$VENDOR_CONF" ] && echo "$(md5sum "$VENDOR_CONF" | awk '{print $1}')  $VENDOR_CONF"
			[ -f /etc/config/misc ] && echo "$(md5sum /etc/config/misc | awk '{print $1}')  /etc/config/misc"
		} >"$CONFIG_BASELINE"
	}
}

cmd_install() {
	[ $# -ge 1 ] || die "install <tarball> [name]" 2
	tar=$1
	name=${2:-$(basename "$tar" | sed 's/\.tar\.gz$//')}
	[ -f "$tar" ] || die "payload missing: $tar" 2
	record_vendor_baseline
	case $name in ''|*/*|.|..) die "bad version name: $name" 2 ;; esac

	dst=$(tree_root "$name")
	if [ -d "$dst" ]; then
		old=$(cat "$BASE/state/$name.md5" 2>/dev/null)
		now=$(sha "$tar")
		if [ -n "$old" ] && [ "$old" = "$now" ]; then
			echo "already-installed $name"
			return 0
		fi
		die "version $name exists with different payload" 3
	fi

	# A rollback pointer naming a missing tree means the last cleanup left no
	# usable fallback.  Refuse to upgrade on top of that instead of silently
	# carrying a broken chain forward; re-installing that exact tree is allowed,
	# because that is how the pointer is repaired.
	prev=$(previous_name)
	if [ -n "$prev" ] && [ "$prev" != "$name" ] && [ ! -d "$(tree_root "$prev")" ]; then
		die "rollback target $prev has no tree; reinstall $prev or clear state/previous first" 6
	fi

	mkdir -p "$BASE/versions" || die "cannot create $BASE/versions" 1
	tmp="$BASE/versions/.$name.tmp"
	rm -rf "$tmp"
	mkdir -p "$tmp/root" || die "cannot create $tmp" 1
	tar -xzf "$tar" -C "$tmp/root" || { rm -rf "$tmp"; die "extract failed" 3; }

	[ -x "$tmp/root/sbin/smbd" ] || { rm -rf "$tmp"; die "no sbin/smbd in payload" 3; }
	[ -x "$tmp/root/bin/testparm" ] || { rm -rf "$tmp"; die "no bin/testparm in payload" 3; }
	baked=$(baked_prefix "$tmp/root") || { rm -rf "$tmp"; die "smbd -b gave no SBINDIR" 3; }

	mv "$tmp" "$BASE/versions/$name" || die "cannot publish $name" 1
	sha "$tar" >"$BASE/state/$name.md5"
	echo "installed $name"
	echo "  tree:   $dst"
	echo "  baked:  $baked"
	echo "  smbd:   $(md5sum "$dst/sbin/smbd" | awk '{print $1}')"
	log "install $name tar_md5=$(sha "$tar") tree=$dst"
	report_rollback || true
}

cmd_activate() {
	[ $# -ge 1 ] || die "activate <name>" 2
	name=$1
	tree=$(tree_root "$name")
	[ -d "$tree" ] || die "version not installed: $name" 6
	baked=$(baked_prefix "$tree") || die "cannot parse SBINDIR for $name" 3

	if [ -e "$baked" ] && [ ! -L "$baked" ]; then
		die "prefix is a real directory, refusing to replace: $baked" 4
	fi
	mkdir -p "$(dirname "$baked")" || die "cannot create $(dirname "$baked")" 1

	prev=$(current_name 2>/dev/null || true)
	# A running smbd keeps its PID file inside the tree it was started from;
	# switching the prefix under it would leave it unstoppable.  Require a
	# clean stop before any version switch.
	if [ -n "$prev" ] && [ "$prev" != "$name" ] && [ -f "$ADAPTER" ]; then
		if sh "$ADAPTER" -r "$(tree_root "$prev")" -p "$PORT" status >/dev/null 2>&1; then
			die "instance for $prev is running; stop it before switching versions" 1
		fi
	fi
	ln -sfn "versions/$name/root" "$BASE/current" || die "cannot update current" 1
	# busybox mv treats an existing symlink-to-directory as a directory and
	# would move the new link inside the old tree; replace it in place.
	ln -sfn "$tree" "$baked" || die "cannot repoint $baked" 1
	[ "$(readlink -f "$baked")" = "$(readlink -f "$tree")" ] ||
		die "prefix switch did not take effect: $baked" 1
	if [ -n "$prev" ] && [ "$prev" != "$name" ]; then
		echo "$prev" >"$BASE/state/previous"
	fi
	echo "activated $name"
	echo "  prefix: $baked -> $(readlink -f "$baked")"
	log "activate $name previous=$(previous_name)"
	report_rollback || true
}

cmd_rollback() {
	[ -f "$BASE/state/previous" ] || die "no previous version recorded" 6
	# cmd_activate assigns its own `prev`; keep the rollback target under a
	# distinct name or the final message reports the version we came from.
	target=$(cat "$BASE/state/previous")
	cur=$(current_name 2>/dev/null || true)
	[ -n "$target" ] || die "empty previous marker" 6
	[ -d "$(tree_root "$target")" ] || die "previous tree missing: $target" 6
	cmd_activate "$target" || exit $?
	[ -n "$cur" ] && echo "$cur" >"$BASE/state/previous"
	echo "rolled-back-to $target"
}

cmd_stop() {
	baked=${1:-}
	[ -n "$baked" ] && [ -d "$baked" ] || baked=$(baked_prefix "$(tree_root "$(current_name)")") || die "no active tree" 2
	[ -f "$ADAPTER" ] || die "adapter missing: $ADAPTER" 2
	sh "$ADAPTER" -r "$baked" -p "$PORT" stop
}

cmd_uninstall() {
	cur=$(current_name 2>/dev/null || true)
	if [ -n "$cur" ]; then
		baked=$(baked_prefix "$(tree_root "$cur")" 2>/dev/null || true)
		cmd_stop "$baked" || die "cannot stop instance before uninstall" 1
		if [ -n "$baked" ] && [ -L "$baked" ]; then
			case $(readlink -f "$baked") in
				"$BASE"/*) rm -f "$baked" ;;
				*) echo "leaving foreign symlink $baked" >&2 ;;
			esac
		fi
	fi

	# The md5 watcher lives in /etc/crontabs (outside $BASE); remove its line
	# so an uninstalled tree is not probed every minute.
	if [ -f "$CRONTAB" ]; then
		tmp=$CRONTAB.s8tmp.$$
		grep -v 'diskacl-sync.sh' "$CRONTAB" >"$tmp" 2>/dev/null &&
			mv "$tmp" "$CRONTAB" || rm -f "$tmp"
	fi
	rm -f "$BASE/current"
	rm -rf "$BASE/versions" "$BASE/state" "$BASE"/drill-*
	echo "uninstalled"
}

cmd_verify() {
	[ -f "$BASELINE" ] || { record_vendor_baseline; echo "baseline-created $BASELINE"; }
	rc=0
	while read -r sum path; do
		[ -f "$path" ] || { echo "MISSING $path"; rc=5; continue; }
		now=$(md5sum "$path" | awk '{print $1}')
		if [ "$now" != "$sum" ]; then
			echo "DRIFT $path expected=$sum now=$now"
			rc=5
		else
			echo "ok $path"
		fi
	done <"$BASELINE"

	if [ -f "$CONFIG_BASELINE" ]; then
		while read -r sum path; do
			[ -f "$path" ] || { echo "CONFIG-MISSING $path"; continue; }
			now=$(md5sum "$path" | awk '{print $1}')
			if [ "$now" != "$sum" ]; then
				echo "CONFIG-DRIFT $path expected=$sum now=$now"
				echo "  source changed by the management stack; adapter config guard decides reuse"
			fi
		done <"$CONFIG_BASELINE"
	fi

	if cur=$(current_name 2>/dev/null); then
		baked=$(baked_prefix "$(tree_root "$cur")") || { echo "BAD current $cur"; rc=3; }
		[ -L "$baked" ] || { echo "BAD prefix not a symlink: $baked"; rc=3; }
		case $(readlink -f "$baked") in
			"$BASE"/*) echo "ok prefix $baked -> $cur" ;;
			*) echo "BAD prefix outside base: $baked"; rc=3 ;;
		esac
	else
		echo "no-active-version"
	fi
	[ -f "$ADAPTER" ] || echo "warn adapter missing: $ADAPTER"
	echo "port=$PORT"
	return $rc
}

cmd_status() {
	cur=$(current_name 2>/dev/null || echo none)
	prev=$(cat "$BASE/state/previous" 2>/dev/null || echo none)
	echo "current=$cur previous=$prev port=$PORT"
	[ "$cur" = none ] && return 0
	sh "$ADAPTER" -r "$(tree_root "$cur")" -p "$PORT" status
}

case ${1:-} in
	install) shift; cmd_install "$@" ;;
	activate) shift; cmd_activate "$@" ;;
	rollback) shift; cmd_rollback "$@" ;;
	uninstall) shift; cmd_uninstall "$@" ;;
	verify) shift; cmd_verify ;;
	status) shift; cmd_status ;;
	*) echo "usage: $0 {install <tar> [name]|activate <name>|rollback|uninstall [--all]|verify|status}" >&2; exit 2 ;;
esac
