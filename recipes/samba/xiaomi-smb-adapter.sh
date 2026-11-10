#!/bin/sh
# Xiaomi MiWiFi Samba 4.x isolated lifecycle/config adapter (S5).
#
# Generates a Samba 4.x smb.conf from the stock UCI model without touching
# /etc/config/samba, validates it with the matching testparm, keeps the
# previous valid file, and controls exactly one instance through its own PID
# file.  It never calls /etc/init.d/samba, shareUpdate, killall or pkill.
#
# Exit codes:
#   0 ok
#   1 runtime failure (start/stop/reload)
#   2 bad invocation / missing tree
#   3 configuration rejected (previous config kept)
#   4 stale PID file or PID does not belong to this tree (nothing killed)
#   5 port already in use
#   6 reload channel failed (configuration kept, restart required)
#   7 configuration source drifted from the accepted baseline
#   8 disk access policy refused (mode.lan is not blacklist, or malformed;
#     nothing changed)

set -u

ROOT=${S5_ROOT:-/userdisk/data/.yunshu/live/samba/current}
CONF_SRC=${S5_UCI_DIR:-/etc/config}
PORT=${S5_PORT:-1445}
BIND=${S5_BIND:-}
PROC_NAME=${S5_PROC_NAME:-samba-s5d}
SNAPSHOT=${S5_CONFIG_SNAPSHOT:-}
# Mount table used by the mount-derived share layer.  Tests point this at a
# fixture; production reads the live kernel table.
MOUNTS_FILE=${S8_MOUNTS_FILE:-/proc/mounts}
EXTDISK_ROOT=${S8_EXTDISK_ROOT:-/extdisks}
TM_TOOL=${S5_TM_TOOL:-/usr/sbin/taskmonitorTool}
TM_NAME=${S5_TM_NAME:-samba-s5d}
ALLOW_STOCK=0
NO_GENERATE=0
PIDFILE=
ACTION=

# Per-device disk access control (vendor "全盘访问" intent).
# The vendor keeps the intent in /etc/config/macfilter:
#   config mode 'mode'   option lan 'blacklist'|'whitelist'
#   config mac           option mac 'aa:bb:..'  option lan 'yes'|'no'
# 'lan=no' means the device must not reach the SMB service.  Only the
# blacklist mode is enforced (DROP explicit 'no', RETURN everyone else);
# any other or malformed mode is refused without touching the firewall, so a
# parsing surprise can never take the whole LAN off SMB.  The vendor's own
# apply_firewall does not program this intent, so this chain is the only
# enforcement point for the isolated Samba 4.x instance.  We own exactly one
# chain and two INPUT jumps, and never read, flush or rebuild the rest of
# INPUT.  The old 's8-pridisk' chain is only ever removed, never created.
#
# Guest network: a guest device must never reach SMB by default, and it is
# NOT part of the per-device list.  Guest clients randomise their MAC
# (iOS/Android private Wi-Fi addresses), so macfilter never contains them and
# a blacklist would default-allow them: the list is structurally unable to
# cover guests.  Guest access is therefore refused unconditionally by one
# INPUT rule scoped to br-guest, inserted before the vendor's any-interface
# ACCEPT for 22,80,135:139,445.  It is a DROP, not a jump to s8-diskacl,
# because the chain tail RETURN would fall through to that ACCEPT.
MACFILTER=${S8_MACFILTER:-/etc/config/macfilter}
IPT=${S8_IPTABLES:-iptables}
DISKACL_CHAIN=${S8_DISKACL_CHAIN:-s8-diskacl}
LEGACY_CHAIN=${S8_LEGACY_CHAIN:-s8-pridisk}
DISKACL_IFACE=${S8_DISKACL_IFACE:-br-lan}
DISKACL_TCP_PORTS=${S8_DISKACL_TCP_PORTS:-139,445}
DISKACL_UDP_PORTS=${S8_DISKACL_UDP_PORTS:-137,138}
GUEST_IFACE=${S8_GUEST_IFACE:-br-guest}
NET_DIR=${S8_NET_DIR:-/sys/class/net}
DISKACL_PRINT=0
DA_MODE=
DA_MODE_SRC=
DA_NO=
DA_DENIED=0
DA_ALLOWED=0
DA_ENTRIES=0
DA_UNSET=0
DA_BAD=0

usage() {
	cat <<EOF
Usage: $0 [-r root] [-c uci-dir] [-p port] [-b bind-address] [-B baseline] [-P] <command>

Commands:
  generate   render UCI -> smb.conf, validate, keep last-good
  start      generate (unless --no-generate) and start the instance
  stop       stop the instance using its PID file only
  restart    stop then start
  reload     generate then 'smbcontrol smbd reload-config'
  status     report running / degraded / stale / stopped (0 / 1 / 4 / 3)
  check      print isolation and configuration facts
  tm-register    register this running instance with TaskMonitor (own alias)
  tm-unregister  remove this instance from TaskMonitor (before a planned stop)
  vendor-stop    ask TaskMonitor to stop and unregister the factory smbd entry
  vendor-start   restore the factory service via /etc/init.d/samba start
  diskacl-apply  rebuild the per-device SMB access chain from macfilter.lan
                 (blacklist only: DROP explicit 'lan=no', RETURN the rest)
  diskacl-clear  remove our INPUT jumps and chains (incl. legacy s8-pridisk)
  diskacl-status report mode/chain/jump state
  pridisk-*      deprecated aliases for the three commands above

Options:
  -r root    installation tree (default $ROOT)
  -c dir     alternate UCI config dir (default $CONF_SRC, read-only use)
  -p port    TCP port(s) for this instance, e.g. '139 445' (default $PORT)
  -b addr    bind address (default: network.lan.ipaddr, else all)
  -n name    process name used to start the binary (default $PROC_NAME)
  -B file    accepted-config baseline (default <root>/var/state/config-baseline)
  -P         allow stock ports 139/445 for an authorised takeover
  -N         start without regenerating the configuration
  -R         dry run: print the iptables commands instead of executing them

Environment:
  S5_ACCEPT_CONFIG=1  record the current samba/misc hashes as accepted
  S8_MACFILTER        macfilter path (default /etc/config/macfilter)
  S8_IPTABLES         iptables binary (default iptables)
  S8_DISKACL_CHAIN    our chain name (default s8-diskacl)
  S8_LEGACY_CHAIN     old chain removed on sight (default s8-pridisk)
  S8_DISKACL_IFACE    LAN interface for the INPUT jumps (default br-lan)
  S8_GUEST_IFACE      guest interface refused unconditionally (default br-guest)
  S8_NET_DIR          sysfs net directory used to detect interfaces (default /sys/class/net)
EOF
}

die() {
	echo "$0: $1" >&2
	exit "${2:-1}"
}

log() {
	[ -d "$ROOT/var/log" ] || mkdir -p "$ROOT/var/log" || return 0
	printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$ROOT/var/log/adapter.log"
}

uci_get() {
	uci -c "$CONF_SRC" -q get "$1" 2>/dev/null
}

uci_bool() {
	case "$(uci_get "$1")" in
	1|on|true|yes|enabled) echo 1 ;;
	*) echo 0 ;;
	esac
}

share_sections() {
	uci -c "$CONF_SRC" -q show samba 2>/dev/null |
		sed -n 's/^samba\.\([^=]*\)=sambashare$/\1/p'
}

need_root() {
	[ -d "$ROOT" ] || die "installation tree missing: $ROOT" 2
	[ -x "$ROOT/sbin/smbd" ] || die "smbd missing under $ROOT" 2
	[ -x "$ROOT/bin/testparm" ] || die "testparm missing under $ROOT" 2
	# Samba bakes SBINDIR/MODULESDIR at build time.  A tree copied to a
	# different prefix still starts for simple shares but silently fails to
	# load VFS/auth modules, so refuse the mismatch instead of half-working.
	built=$(LD_LIBRARY_PATH="$ROOT/lib:$ROOT/lib/private" "$ROOT/sbin/smbd" -b 2>/dev/null |
		sed -n 's/^[[:space:]]*SBINDIR:[[:space:]]*//p')
	if [ -n "$built" ]; then
		built_prefix=$(dirname "$built")
		root_real=$(readlink -f "$ROOT" 2>/dev/null || echo "$ROOT")
		built_real=$(readlink -f "$built_prefix" 2>/dev/null || echo "$built_prefix")
		if [ "$built_real" != "$root_real" ]; then
			die "tree prefix mismatch: built for $built_prefix, installed at $ROOT" 2
		fi
	fi
}

prepare_dirs() {
	for d in etc var/lock var/locks var/state var/cache var/private \
		var/log var/run var/run/ncalrpc; do
		mkdir -p "$ROOT/$d" || die "cannot create $ROOT/$d" 1
	done
}

bind_address() {
	if [ -n "$BIND" ]; then
		echo "$BIND"
		return
	fi
	uci -c "$CONF_SRC" -q get network.lan.ipaddr 2>/dev/null || echo 0.0.0.0
}

run_env() {
	LD_LIBRARY_PATH="$ROOT/lib:$ROOT/lib/private"
	export LD_LIBRARY_PATH
	if [ -r /etc/TZ ]; then
		TZ=$(cat /etc/TZ)
		export TZ
	fi
	# Test seam from the S3 MAC-policy patch: pass it through when the
	# operator explicitly set it, otherwise keep the built-in default.
	if [ -n "${XIAOMI_MAC_FILTER:-}" ]; then
		export XIAOMI_MAC_FILTER
	fi
	if [ -n "${XIAOMI_READONLY_NOW:-}" ]; then
		export XIAOMI_READONLY_NOW
	fi
}

config_is_isolated() {
	conf=$1
	# Any of the stock runtime paths in the generated file means the new
	# instance would share state with the vendor daemon.  Reject outright.
	if grep -Eq '^[[:space:]]*(lock|pid|state|cache|private|ncalrpc)[[:space:]]*directory[[:space:]]*=[[:space:]]*(/tmp/(lock|run)|/var/(etc|lock|run|state|cache|lib/samba))' "$conf"; then
		return 1
	fi
	if [ "$ALLOW_STOCK" = 0 ] &&
		grep -Eq '^[[:space:]]*smb ports[[:space:]]*=[[:space:]]*(139|445)([[:space:]]|$)' "$conf"; then
		return 1
	fi
	return 0
}

config_snapshot() {
	if [ -n "$SNAPSHOT" ]; then
		echo "$SNAPSHOT"
	else
		echo "$ROOT/var/state/config-baseline"
	fi
}

config_facts() {
	for f in samba misc; do
		p="$CONF_SRC/$f"
		if [ -r "$p" ]; then
			sum=$(md5sum "$p" 2>/dev/null | awk '{print $1}')
			set -- $(stat -c '%s %Y %i' "$p" 2>/dev/null || echo "0 0 0")
			echo "$f md5=$sum size=$1 mtime=$2 inode=$3"
		else
			echo "$f missing"
		fi
	done
}

# The vendor management stack can rewrite /etc/config/samba and
# /etc/config/misc at arbitrary times (S7 forensics: 2026-11-08 05:05:48).
# Refuse to render a new smb.conf from a source that no longer matches the
# accepted snapshot; an operator who has reviewed the change can opt in with
# S5_ACCEPT_CONFIG=1, which records the new hashes and keeps a readable copy.
config_guard() {
	snap=$(config_snapshot)
	dir=$(dirname "$snap")
	now=$(config_facts)
	if [ ! -f "$snap" ]; then
		mkdir -p "$dir" || return 1
		printf '%s\n' "$now" >"$snap" || return 1
		[ -r "$CONF_SRC/samba" ] && cp -p "$CONF_SRC/samba" "$dir/samba.accepted" 2>/dev/null
		[ -r "$CONF_SRC/misc" ] && cp -p "$CONF_SRC/misc" "$dir/misc.accepted" 2>/dev/null
		log "config baseline adopted: $(printf '%s' "$now" | tr '\n' ';')"
		return 0
	fi
	old=$(cat "$snap" 2>/dev/null)
	[ "$old" = "$now" ] && return 0
	if [ "${S5_ACCEPT_CONFIG:-0}" = 1 ]; then
		printf '%s\n' "$now" >"$snap" || return 1
		[ -r "$CONF_SRC/samba" ] && cp -p "$CONF_SRC/samba" "$dir/samba.accepted" 2>/dev/null
		[ -r "$CONF_SRC/misc" ] && cp -p "$CONF_SRC/misc" "$dir/misc.accepted" 2>/dev/null
		log "config drift accepted explicitly"
		echo "adapter: configuration drift accepted (S5_ACCEPT_CONFIG=1)" >&2
		return 0
	fi
	echo "adapter: configuration source changed unexpectedly" >&2
	echo "  baseline: $snap" >&2
	echo "  accepted:" >&2
	printf '%s\n' "$old" | sed 's/^/    /' >&2
	echo "  current:" >&2
	printf '%s\n' "$now" | sed 's/^/    /' >&2
	echo "  refusing to regenerate; review and rerun with S5_ACCEPT_CONFIG=1" >&2
	log "config drift rejected"
	return 7
}

render() {
	out=$1
	addr=$(bind_address)
	name=$(uci_get samba.@samba[0].name)
	workgroup=$(uci_get samba.@samba[0].workgroup)
	desc=$(uci_get samba.@samba[0].description)
	charset=$(uci_get samba.@samba[0].charset)
	[ -n "$name" ] || name=$(uci -c "$CONF_SRC" -q get system.@system[0].hostname 2>/dev/null)
	[ -n "$name" ] || name=MiWiFi
	[ -n "$workgroup" ] || workgroup=WORKGROUP
	[ -n "$desc" ] || desc="Samba on $name"
	[ -n "$charset" ] || charset=UTF8

	{
		echo '[global]'
		echo "	netbios name = $name"
		echo "	server string = $desc"
		echo "	workgroup = $workgroup"
		echo "	unix charset = $charset"
		echo '	server role = standalone server'
		echo '	security = user'
		echo '	map to guest = Bad User'
		echo '	guest account = nobody'
		echo '	passdb backend = smbpasswd'
		echo "	smb passwd file = $ROOT/var/private/smbpasswd"
		echo "	interfaces = $addr"
		echo '	bind interfaces only = yes'
		echo "	smb ports = $PORT"
		echo "	pid directory = $ROOT/var/run"
		echo "	lock directory = $ROOT/var/lock"
		echo "	state directory = $ROOT/var/state"
		echo "	cache directory = $ROOT/var/cache"
		echo "	private dir = $ROOT/var/private"
		echo "	ncalrpc dir = $ROOT/var/run/ncalrpc"
		echo "	log file = $ROOT/var/log/samba.log"
		echo '	max log size = 500'
		echo '	log level = 1'
		echo '	load printers = no'
		echo '	printable = no'
		echo '	server min protocol = NT1'
		# Samba 4.25 advertises SMB3 multi-channel by default.  macOS
		# clients negotiate it, then stall for ~18 s after a successful
		# session setup because no second channel can be established on
		# this single-interface router; smbutil view never enumerates.
		# SMB2_10 works and so does SMB3 with this switch off, so the
		# extra channel support is not worth the client regression.
		echo '	server multi channel support = no'
		echo '	deadtime = 30'
		echo '	enable core files = no'
		echo '	null passwords = yes'
		echo '	obey pam restrictions = yes'
		echo '	min receivefile size = 16384'
		echo '	use sendfile = yes'
		echo '	smb encrypt = disabled'
		echo '	server signing = default'

		if [ "$(uci_bool misc.samba.smb_tune)" = 1 ]; then
			maxbuf=$(uci_get misc.samba.smb2_max_buf)
			[ -n "$maxbuf" ] && {
				echo "	smb2 max read = $maxbuf"
				echo "	smb2 max write = $maxbuf"
				echo "	smb2 max trans = $maxbuf"
			}
			# 'socket options', 'write cache size' and 'default cpumask'
			# exist in 4.0.21 but are unknown/obsolete in this 4.25.1 build
			# (SO_SNDBUFFORCE/SO_RCVBUFFORCE are rejected by uClibc), so
			# they are intentionally dropped instead of being echoed as
			# no-op parameters.
		fi

		if [ "$(uci_bool samba.@samba[0].homes)" = 1 ]; then
			echo
			echo '[homes]'
			echo '	comment = Home Directories'
			echo '	browseable = no'
			echo '	read only = no'
			echo '	create mode = 0750'
		fi

		seen=" "
		uci_paths=" "
		fail=0
		for sec in $(share_sections); do
			sname=$(uci_get "samba.$sec.name")
			spath=$(uci_get "samba.$sec.path")
			[ -n "$sname" ] && [ -n "$spath" ] || continue
			case "$sname" in
			*'['*|*']'*)
				echo "adapter: reject share name: $sname" >&2
				fail=1
				break
				;;
			esac
			case "$seen" in
			*" [$sname] "*)
				echo "adapter: reject duplicate share: $sname" >&2
				fail=1
				break
				;;
			esac
			seen="${seen} [$sname] "
			case "$spath" in
			/*) ;;
			*)
				echo "adapter: reject share path (not absolute): $sname -> $spath" >&2
				fail=1
				break
				;;
			esac
			case "/$spath/" in
			*/../*)
				echo "adapter: reject share path (parent traversal): $sname -> $spath" >&2
				fail=1
				break
				;;
			esac
			pnorm=${spath%/}
			uci_paths="${uci_paths}${pnorm} "

			echo
			echo "[$sname]"
			echo "	path = $spath"
			preexec=$(uci_get "samba.$sec.preexec")
			[ -n "$preexec" ] && echo "	preexec = $preexec"
			users=$(uci_get "samba.$sec.users")
			[ -n "$users" ] && echo "	valid users = $users"
			ro=$(uci_get "samba.$sec.read_only")
			[ -n "$ro" ] && echo "	read only = $ro"
			gok=$(uci_get "samba.$sec.guest_ok")
			[ -n "$gok" ] && echo "	guest ok = $gok"
			cm=$(uci_get "samba.$sec.create_mask")
			[ -n "$cm" ] && echo "	create mask = $cm"
			dm=$(uci_get "samba.$sec.dir_mask")
			[ -n "$dm" ] && echo "	directory mask = $dm"
			br=$(uci_get "samba.$sec.browseable")
			[ -n "$br" ] && echo "	browseable = $br"
			fu=$(uci_get "samba.$sec.force_user")
			[ -n "$fu" ] && echo "	force user = $fu"

			# S8: keep the private .yunshu tree out of the whole-disk
			# share.  File permissions cannot do this: the share is
			# guest ok + force user = root, so mode bits are bypassed.
			# veto files hides and denies the name; dont descend stops
			# directory scans before they read it.
			case "$pnorm" in
			/userdisk/data)
				echo '	veto files = /.yunshu/'
				echo '	dont descend = .yunshu'
				;;
			esac

			case "$sname" in
			*摄像机*)
				limit=$(uci_get misc.smb_ctl.limit)
				if [ -z "$limit" ] || [ "$limit" = 1 ]; then
					st=$(uci_get misc.smb_ctl.start_time)
					et=$(uci_get misc.smb_ctl.end_time)
					[ -n "$st" ] || st="today 06:00:00"
					[ -n "$et" ] || et="tomorrow 02:00:00"
					echo '	vfs object = readonly'
					echo "	readonly:period = \"$st\",\"$et\""
				fi
				;;
			esac
		done

		# Mount-derived shares.  The vendor stack creates a UCI
		# 'sambashare' for every /extdisks/<dev> when the disk is
		# mounted (shareUpdate -a).  Do not depend on that: synthesize
		# a share for any active mount that UCI does not already cover.
		# UCI wins and nothing is written back to /etc/config/samba.
		if [ -r "$MOUNTS_FILE" ]; then
			mlist="$out.mounts"
			if ! awk '$1 !~ /^#/ && NF >= 2 {print $2 " " $1}' "$MOUNTS_FILE" 2>/dev/null |
				sort > "$mlist" 2>/dev/null; then
				: > "$mlist"
			fi
			seen_mounts=" "
			while read mpoint mdev mrest; do
				case "$mdev" in
				/dev/*) ;;
				*) continue ;;
				esac
				case "$mpoint" in
				"${EXTDISK_ROOT:-/extdisks}"/*) ;;
				*) continue ;;
				esac
				case "$mpoint" in
				"${EXTDISK_ROOT:-/extdisks}"/*/*) continue ;;
				esac
				[ -d "$mpoint" ] || continue
				pnorm=${mpoint%/}
				case "$uci_paths" in
				*" $pnorm "*) continue ;;
				esac
				case "$seen_mounts" in
				*" $pnorm "*) continue ;;
				esac
				seen_mounts="${seen_mounts}${pnorm} "
				n=0
				while :; do
					case "$seen" in
					*" [XiaoMi-usb$n] "*) n=$((n + 1)) ;;
					*) break ;;
					esac
				done
				sname="XiaoMi-usb$n"
				seen="${seen} [$sname] "
				echo
				echo "[$sname]"
				echo "	path = $mpoint"
				echo "	read only = no"
				echo "	guest ok = yes"
				echo "	create mask = 0777"
				echo "	directory mask = 0777"
				echo "	browseable = no"
				echo "	force user = root"
			done < "$mlist"
			rm -f "$mlist"
		fi
	} >"$out" 2>"$out.err"

	rc=$?
	if [ $rc -ne 0 ] || [ "$fail" != 0 ]; then
		msg=$(cat "$out.err" 2>/dev/null)
		rm -f "$out" "$out.err"
		echo "adapter: render failed: $msg" >&2
		log "render failed: $msg"
		return 3
	fi
	rm -f "$out.err"
	return 0
}

cmd_generate() {
	need_root
	prepare_dirs
	config_guard
	grc=$?
	[ $grc -eq 0 ] || return $grc
	out="$ROOT/etc/smb.conf.new"
	render "$out" || { rm -f "$out"; return 3; }

	run_env
	if ! "$ROOT/bin/testparm" -s --suppress-prompt "$out" \
		>"$ROOT/var/log/testparm.out" 2>&1; then
		msg=$(tail -3 "$ROOT/var/log/testparm.out" | tr '\n' ' ')
		rm -f "$out"
		echo "adapter: testparm rejected configuration: $msg" >&2
		log "testparm rejected: $msg"
		return 3
	fi

	if ! config_is_isolated "$out"; then
		rm -f "$out"
		echo "adapter: generated configuration is not isolated" >&2
		log "rejected: non-isolated runtime path or stock port"
		return 3
	fi

	# A camera share references the readonly VFS module.  testparm does not
	# load modules, so a missing .so would pass validation and then silently
	# behave as a plain writable share.  Refuse that combination.
	if grep -Eq '^[[:space:]]*vfs object[[:space:]]*=[[:space:]]*readonly' "$out" &&
		[ ! -f "$ROOT/lib/vfs/readonly.so" ]; then
		rm -f "$out"
		echo "adapter: readonly VFS module missing under $ROOT/lib/vfs" >&2
		log "rejected: readonly module missing"
		return 3
	fi

	if [ -f "$ROOT/etc/smb.conf" ]; then
		cp -p "$ROOT/etc/smb.conf" "$ROOT/etc/smb.conf.last-good" || true
	fi
	mv "$out" "$ROOT/etc/smb.conf" || { rm -f "$out"; return 1; }
	log "generated from $CONF_SRC md5=$(md5sum "$ROOT/etc/smb.conf" | cut -d' ' -f1)"
	echo "$ROOT/etc/smb.conf"
	return 0
}

pid_from_file() {
	[ -f "$PIDFILE" ] || return 1
	pid=$(cat "$PIDFILE" 2>/dev/null | tr -dc '0-9')
	[ -n "$pid" ] || return 1
	echo "$pid"
}

# Remove the pidfile only when it still names the pid we just handled.  A
# TaskMonitor revival or a concurrent start may already have written a newer
# pid into the same path; deleting it then leaves a live instance without a
# pidfile, which status reports as "port in use by another process".
remove_pidfile_if() {
	[ -f "$PIDFILE" ] || return 0
	cur=$(cat "$PIDFILE" 2>/dev/null | tr -dc '0-9')
	[ "$cur" = "$1" ] && rm -f "$PIDFILE"
	return 0
}

pid_is_ours() {
	pid=$1
	[ -d "/proc/$pid" ] || return 1
	exe=$(readlink "/proc/$pid/exe" 2>/dev/null) || return 1
	# S7 activates versions through a symlink, so compare the resolved tree
	# as well; otherwise an instance started via the link looks foreign and
	# stop/status would refuse to touch a process they actually own.
	real=$(readlink -f "$ROOT" 2>/dev/null || echo "$ROOT")
	case "$exe" in
	"$ROOT"/sbin/*|"$real"/sbin/*) return 0 ;;
	esac
	return 1
}

port_listening() {
	for p in $PORT; do
		netstat -ltn 2>/dev/null | awk '{print $4}' | grep -q ":$p\$" || return 1
	done
	return 0
}

cmd_status() {
	if pid=$(pid_from_file); then
		if pid_is_ours "$pid"; then
			if port_listening; then
				echo "running pid=$pid port=$PORT"
				return 0
			fi
			echo "degraded pid=$pid port=$PORT not listening"
			return 1
		fi
		echo "stale pidfile: $PIDFILE -> $pid (not this tree)"
		return 4
	fi
	if port_listening; then
		echo "port $PORT in use by another process"
		return 5
	fi
	echo "stopped"
	return 3
}

cmd_start() {
	if [ "$NO_GENERATE" = 1 ]; then
		:
	else
		cmd_generate >/dev/null
		grc=$?
		[ $grc -eq 0 ] || return $grc
	fi
	need_root
	prepare_dirs
	if pid=$(pid_from_file); then
		if pid_is_ours "$pid"; then
			if port_listening; then
				# Re-assert the access rules.  diskacl_apply can only build
				# the blacklist chain (explicit 'lan=no' -> DROP, tail
				# RETURN) or refuse without touching the firewall; it can
				# never turn a restart into an all-LAN DROP.
				diskacl_apply >/dev/null || diskacl_log "apply failed rc=$?"
				echo "already running pid=$pid"
				return 0
			fi
			echo "pid=$pid is alive but port $PORT is not listening; stop first" >&2
			return 1
		fi
		if [ -d "/proc/$pid" ]; then
			echo "refusing to start: pidfile refers to live foreign pid $pid" >&2
			return 4
		fi
		echo "clearing stale pidfile for dead pid $pid"
		remove_pidfile_if "$pid"
	fi
	if port_listening; then
		echo "refusing to start: port $PORT already in use" >&2
		return 5
	fi

	# Start from a real copy, not a symlink: busybox pidof matches the
	# resolved /proc/<pid>/exe basename, so a symlink named samba-s5d would
	# still make 'pidof smbd' return this instance and let stock scripts
	# treat it as their own smbd.
	if [ ! -x "$ROOT/sbin/$PROC_NAME" ] || [ -L "$ROOT/sbin/$PROC_NAME" ]; then
		rm -f "$ROOT/sbin/$PROC_NAME"
		cp "$ROOT/sbin/smbd" "$ROOT/sbin/$PROC_NAME" || return 1
		chmod 755 "$ROOT/sbin/$PROC_NAME"
	fi

	run_env
	(
		umask 077
		cd "$ROOT" || exit 1
		nohup "./sbin/$PROC_NAME" -D -s "$ROOT/etc/smb.conf" \
			-l "$ROOT/var/log" >"$ROOT/var/log/start.out" 2>&1
	) || true

	i=0
	while [ $i -lt 20 ]; do
		if pid=$(pid_from_file) && pid_is_ours "$pid" && port_listening; then
			log "started pid=$pid port=$PORT via sbin/$PROC_NAME"
			diskacl_apply >/dev/null || diskacl_log "apply failed rc=$?"
			echo "started pid=$pid port=$PORT"
			return 0
		fi
		sleep 1
		i=$((i + 1))
	done

	echo "start failed; see $ROOT/var/log/samba.log" >&2
	log "start failed"
	if pid=$(pid_from_file) && pid_is_ours "$pid"; then
		kill -TERM "$pid" 2>/dev/null || true
	fi
	return 1
}

cmd_stop() {
	# A registered instance would be revived by the 5 s check right after the
	# kill, so unregister first.  Absence of the tool is not an error here.
	if [ -x "$TM_TOOL" ] && tm_entry_present "$(tm_procline)"; then
		cmd_tm_unregister >/dev/null 2>&1 || true
	fi
	if ! pid=$(pid_from_file); then
		# tm-unregister may kill the process asynchronously; give it a moment,
		# then require the port to be free.  Reporting success while another
		# process still owns the port would let start collide with it.
		i=0
		while port_listening && [ $i -lt 20 ]; do
			usleep 100000 2>/dev/null || sleep 1
			i=$((i + 1))
		done
		if port_listening; then
			echo "stop failed: port $PORT still listening (no live pidfile)" >&2
			return 5
		fi
		diskacl_clear >/dev/null || diskacl_log "clear failed rc=$?"
		echo "stopped (no live pidfile)"
		return 0
	fi
	if ! pid_is_ours "$pid"; then
		if [ -d "/proc/$pid" ]; then
			echo "refusing to kill $pid: not a process of $ROOT" >&2
			return 4
		fi
		remove_pidfile_if "$pid"
		if port_listening; then
			echo "stop failed: port $PORT still listening after removing stale pidfile" >&2
			return 5
		fi
		diskacl_clear >/dev/null || diskacl_log "clear failed rc=$?"
		echo "stopped (removed stale pidfile for dead pid $pid)"
		return 0
	fi

	kill -TERM "$pid" 2>/dev/null || true
	i=0
	while [ $i -lt 15 ]; do
		[ -d "/proc/$pid" ] || break
		sleep 1
		i=$((i + 1))
	done
	if [ -d "/proc/$pid" ]; then
		if pid_is_ours "$pid"; then
			kill -KILL "$pid" 2>/dev/null || true
			sleep 1
		fi
	fi
	remove_pidfile_if "$pid"
	# The process is gone, but a child or a foreign listener could still own
	# the port.  Do not report success until the port is actually free.
	i=0
	while port_listening && [ $i -lt 20 ]; do
		usleep 100000 2>/dev/null || sleep 1
		i=$((i + 1))
	done
	if port_listening; then
		echo "stop failed: port $PORT still listening after killing pid $pid" >&2
		return 5
	fi
	log "stopped pid=$pid"
	diskacl_clear >/dev/null || diskacl_log "clear failed rc=$?"
	echo "stopped pid=$pid"
	return 0
}

cmd_reload() {
	cmd_generate >/dev/null
	grc=$?
	[ $grc -eq 0 ] || return $grc
	if ! pid=$(pid_from_file) || ! pid_is_ours "$pid"; then
		echo "not running" >&2
		return 3
	fi
	run_env
	if "$ROOT/bin/smbcontrol" -s "$ROOT/etc/smb.conf" smbd reload-config \
		>"$ROOT/var/log/smbcontrol.out" 2>&1; then
		log "reload-config sent to pid=$pid"
		# macfilter may have changed on disk; rebuild the chain idempotently.
		# The blacklist-only policy cannot widen into an all-LAN DROP.
		diskacl_apply >/dev/null || diskacl_log "apply failed rc=$?"
		echo "reloaded"
		return 0
	fi
	echo "reload failed; configuration kept, restart required" >&2
	log "reload failed: $(tail -1 "$ROOT/var/log/smbcontrol.out" 2>/dev/null)"
	return 6
}

# --- per-device disk access (macfilter.lan) ------------------------------
# macfilter intent (stock firmware uses a 'mode' section):
#   config mode 'mode'      option lan 'blacklist'|'whitelist'
#   config mac  'y'         option mac 'aa:..'  option lan 'yes'|'no'
# 'config macfilter' is accepted as an alias for the mode section.
#
# Policy:
#   blacklist : DROP for every device with an explicit 'lan=no', then RETURN.
#               A device with 'lan=yes' or no value is allowed by default.
#   refused   : mode.lan missing, not blacklist, or unparsable -> nothing is
#               built and state/decision=refused (exit 8).  Guessing here can
#               take the whole LAN off SMB, so we never do.
#   unavailable: file absent/unreadable, or no 'config mac' section -> the
#               firewall is left alone and state/decision=unavailable.
#   legacy s8-pridisk: removed on every apply/clear.  It is only ever deleted,
#               never created; this removes the old all-DROP chain even when
#               the current policy is refused.
#
# start/reload call diskacl_apply so a vendor samba restart or a 'lan=no'
# change is enforced immediately.  The blacklist-only contract means the
# worst outcome of that call is the explicit 'no' set being dropped; it can
# never become an allow=0 chain.  'lan=no -> yes' does not restart samba,
# so a once-a-minute md5 watcher (compat/diskacl-sync.sh) reconciles it.

diskacl_parse() {
	awk '
	function unq(s,   c) {
		gsub(/^[ \t\r]+|[ \t\r]+$/, "", s)
		c = substr(s, 1, 1)
		if ((c == "\"" || c == "\047") && substr(s, length(s), 1) == c)
			s = substr(s, 2, length(s) - 2)
		return s
	}
	function emit() {
		if (stype == "mode" || stype == "macfilter")
			print "mode", slan
		else if (stype == "mac" && smac != "")
			print "mac", smac, slan
	}
	/^[ \t]*#/ { next }
	/^[ \t]*config[ \t]/ {
		emit()
		stype = $2
		smac = ""
		slan = ""
		next
	}
	/^[ \t]*option[ \t]/ {
		opt = $2
		rest = $0
		sub(/^[ \t]*option[ \t]+[^ \t]+[ \t]+/, "", rest)
		if (opt == "lan")
			slan = unq(rest)
		else if (opt == "mac" && stype == "mac")
			smac = unq(rest)
		next
	}
	END { emit() }
	' "$MACFILTER" 2>/dev/null
}

diskacl_load() {
	DA_MODE=
	DA_MODE_SRC=
	DA_NO=" "
	DA_DENIED=0
	DA_ALLOWED=0
	DA_ENTRIES=0
	DA_UNSET=0
	DA_BAD=0
	[ -f "$MACFILTER" ] && [ -r "$MACFILTER" ] || return 1
	if [ "$DISKACL_PRINT" = 1 ]; then
		# Dry run must not create files inside the installation tree.
		DISKACL_PARSE=/tmp/diskacl.parse.$$
	else
		mkdir -p "$ROOT/var/run" 2>/dev/null || return 1
		DISKACL_PARSE=$ROOT/var/run/diskacl.parse.$$
	fi
	if ! diskacl_parse >"$DISKACL_PARSE"; then
		rm -f "$DISKACL_PARSE"
		return 1
	fi
	da_mode_seen=0
	while read -r kind a b; do
		case "$kind" in
		mode)
			da_mode_seen=1
			case "$a" in
			""|-) ;;
			*) DA_MODE=$(printf '%s' "$a" | tr 'A-Z' 'a-z') ;;
			esac
			;;
		mac)
			DA_ENTRIES=$((DA_ENTRIES + 1))
			m=$(printf '%s' "$a" | tr 'A-Z' 'a-z')
			case "$m" in
			[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]) ;;
			*)
				DA_BAD=$((DA_BAD + 1))
				continue
				;;
			esac
			v=$(printf '%s' "$b" | tr 'A-Z' 'a-z')
			case "$v" in
			no|off|0|false) DA_NO="$DA_NO$m "; DA_DENIED=$((DA_DENIED + 1)) ;;
			yes|on|1|true) DA_ALLOWED=$((DA_ALLOWED + 1)) ;;
			*) DA_UNSET=$((DA_UNSET + 1)); DA_ALLOWED=$((DA_ALLOWED + 1)) ;;
			esac
			;;
		esac
	done <"$DISKACL_PARSE"
	rm -f "$DISKACL_PARSE"

	# A file with no device section is a parse failure, not an empty
	# blacklist: leave the firewall untouched and say so.
	[ "$DA_ENTRIES" -gt 0 ] || return 1
	[ "$da_mode_seen" = 1 ] || { DA_MODE_SRC=missing; return 2; }
	case "$DA_MODE" in
	blacklist)
		DA_MODE_SRC=explicit
		return 0
		;;
	"")
		DA_MODE_SRC=missing
		return 2
		;;
	*)
		DA_MODE_SRC=$DA_MODE
		return 3
		;;
	esac
}

diskacl_count() {
	c=0
	for m in $1; do c=$((c + 1)); done
	echo "$c"
}

diskacl_log() {
	[ "$DISKACL_PRINT" = 1 ] && return 0
	log "diskacl: $*"
}

# Print in dry-run mode, execute otherwise.  stderr from the real binary is
# kept for diagnosis but never aborts the lifecycle by itself.
ipt_run() {
	if [ "$DISKACL_PRINT" = 1 ]; then
		printf '%s' "$IPT"
		for a in "$@"; do printf ' %s' "$a"; done
		printf '\n'
		return 0
	fi
	"$IPT" "$@" 2>>"$ROOT/var/log/diskacl.err"
}

ipt_out() {
	"$IPT" "$@" 2>/dev/null
}

diskacl_chain_exists() {
	ipt_out -S "$DISKACL_CHAIN" >/dev/null 2>&1
}

# --- guest network -------------------------------------------------------
# One rule, always interface-scoped, never derived from macfilter.
guest_iface_present() {
	[ -d "$NET_DIR/$GUEST_IFACE" ]
}

guest_spec() {
	printf -- '-i %s -p tcp -m multiport --dports %s -j DROP' \
		"$GUEST_IFACE" "$DISKACL_TCP_PORTS"
}

# Index of the vendor's any-interface ACCEPT that would otherwise let a
# guest reach 139/445.  Our rule must stay strictly above it.  The rule
# counter skips the '-P INPUT ...' policy header that iptables -S prints,
# because -I index counts rules only.
guest_accept_index() {
	ipt_out -S INPUT 2>/dev/null | awk '
		/^-A INPUT / { n++ }
		/-j ACCEPT/ && /--dports / && /445/ && !/-i / { print n; exit }'
}

guest_rule_index() {
	spec=$(guest_spec)
	ipt_out -S INPUT 2>/dev/null |
		awk -v s="$spec" '
			/^-A INPUT / { n++; if (index($0, s)) { print n; exit } }'
}

guest_rule_remove() {
	spec=$(guest_spec)
	lines=$(ipt_out -S INPUT 2>/dev/null | grep -F -- "$spec")
	[ -n "$lines" ] || return 0
	printf '%s\n' "$lines" | while IFS= read -r line; do
		rest=${line#-A INPUT }
		[ "$rest" = "$line" ] && continue
		# shellcheck disable=SC2086
		set -- $rest
		ipt_run -D INPUT "$@"
	done
}

guest_rule_ok() {
	guest_iface_present || return 0
	spec=$(guest_spec)
	n=$(ipt_out -S INPUT 2>/dev/null | grep -cF -- "$spec")
	[ "$n" = 1 ] || return 1
	gi=$(guest_rule_index)
	[ -n "$gi" ] || return 1
	vi=$(guest_accept_index)
	[ -n "$vi" ] || return 0
	[ "$gi" -lt "$vi" ]
}

guest_apply() {
	guest_iface_present || return 0
	guest_rule_remove
	idx=$(guest_accept_index)
	[ -n "$idx" ] || idx=1
	ipt_run -I INPUT "$idx" -i "$GUEST_IFACE" -p tcp \
		-m multiport --dports "$DISKACL_TCP_PORTS" -j DROP
	if [ "$DISKACL_PRINT" = 0 ] && ! guest_rule_ok; then
		diskacl_log "guest rule for $GUEST_IFACE is missing or below the vendor ACCEPT"
		echo "diskacl: guest rule not in the required position" >&2
		return 1
	fi
	[ "$DISKACL_PRINT" = 1 ] ||
		diskacl_log "guest: DROP $GUEST_IFACE tcp $DISKACL_TCP_PORTS"
	return 0
}

diskacl_state() {
	[ "$DISKACL_PRINT" = 0 ] || return 0
	[ -d "$ROOT/var/state" ] || return 0
	{
		printf 'mode=%s\n' "$1"
		printf 'decision=%s\n' "$4"
		printf 'mode_source=%s\n' "${DA_MODE_SRC:-none}"
		printf 'allowed=%s\n' "$2"
		printf 'denied=%s\n' "$3"
		printf 'entries=%s\n' "${DA_ENTRIES:-0}"
		printf 'unset=%s\n' "${DA_UNSET:-0}"
		printf 'iface=%s\n' "$DISKACL_IFACE"
		printf 'chain=%s\n' "$DISKACL_CHAIN"
		printf 'macfilter=%s\n' "$MACFILTER"
		printf 'updated=%s\n' "$(date +%s)"
	} >"$ROOT/var/state/diskacl.state" 2>/dev/null || true
}

# Delete every INPUT rule that jumps to a chain.  Only those exact jumps are
# touched; the rest of INPUT keeps its original order.
diskacl_jump_remove() {
	chain=$1
	lines=$(ipt_out -S INPUT 2>/dev/null | grep -F -- "-j $chain")
	[ -n "$lines" ] || return 0
	printf '%s\n' "$lines" | while IFS= read -r line; do
		spec=${line#-A INPUT }
		[ "$spec" = "$line" ] && continue
		# shellcheck disable=SC2086
		set -- $spec
		ipt_run -D INPUT "$@"
	done
}

# The old 1.0.4 chain put an unconditional DROP at its tail.  Remove its
# jumps first (otherwise a surviving jump would still fall through to the
# DROP), then the chain.  It is never re-created.
legacy_clear() {
	diskacl_jump_remove "$LEGACY_CHAIN"
	if ipt_out -S "$LEGACY_CHAIN" >/dev/null 2>&1; then
		ipt_run -F "$LEGACY_CHAIN"
		if ! ipt_run -X "$LEGACY_CHAIN" && [ "$DISKACL_PRINT" = 0 ]; then
			diskacl_log "legacy chain $LEGACY_CHAIN still present after -X"
			echo "diskacl: legacy chain $LEGACY_CHAIN still present" >&2
			return 1
		fi
	fi
	if [ "$DISKACL_PRINT" = 0 ] &&
		ipt_out -S INPUT 2>/dev/null | grep -qF -- "-j $LEGACY_CHAIN"; then
		diskacl_log "legacy jump to $LEGACY_CHAIN survived deletion"
		echo "diskacl: legacy jump survived deletion" >&2
		return 1
	fi
	return 0
}

diskacl_apply() {
	[ "$DISKACL_PRINT" = 1 ] ||
		mkdir -p "$ROOT/var/log" "$ROOT/var/state" "$ROOT/var/run" 2>/dev/null

	# Remove the old chain before anything else: it is the only object here
	# that can block the whole LAN, and it must go even when the new policy
	# is refused or unavailable.
	if ! legacy_clear; then
		diskacl_state error 0 0 error
		return 1
	fi

	# Guest refusal is independent of macfilter: apply it on every path,
	# including refused/unavailable, so a guest network that the vendor
	# brings up later never inherits SMB access by accident.
	if ! guest_apply; then
		diskacl_state error 0 0 error
		return 1
	fi

	diskacl_load
	lrc=$?
	case $lrc in
	1)
		diskacl_log "UNAVAILABLE: $MACFILTER missing, unreadable, or has no device section; firewall untouched"
		echo "diskacl: unavailable ($MACFILTER); firewall left untouched" >&2
		diskacl_state unavailable 0 0 unavailable
		return 0
		;;
	2)
		diskacl_log "refused: mode.lan missing; firewall untouched"
		echo "diskacl: refused mode.lan=missing; firewall untouched" >&2
		diskacl_state missing 0 0 refused
		return 8
		;;
	3)
		diskacl_log "refused: mode.lan='$DA_MODE' (only blacklist is enforced); firewall untouched"
		echo "diskacl: refused mode.lan=$DA_MODE (only blacklist is enforced); firewall untouched" >&2
		diskacl_state "$DA_MODE" 0 0 refused
		return 8
		;;
	esac

	denied=$(diskacl_count "$DA_NO")
	diskacl_log "mode=blacklist source=$DA_MODE_SRC allow=$DA_ALLOWED deny=$denied entries=$DA_ENTRIES unset=$DA_UNSET"
	[ "$DA_BAD" -eq 0 ] || diskacl_log "ignored $DA_BAD macfilter entr(ies) with an invalid mac"

	# A blacklist with nothing to drop is a no-op.  If an old chain still
	# exists, rebuild it as RETURN-only so a stale DROP disappears; otherwise
	# do not create an empty chain at all.
	if [ "$denied" -eq 0 ] && ! diskacl_chain_exists; then
		diskacl_state blacklist "$DA_ALLOWED" 0 applied
		if [ "$DISKACL_PRINT" = 1 ]; then
			echo "diskacl: dry run, nothing to deny"
		else
			diskacl_log "applied chain=absent deny=0 (nothing to drop)"
			echo "diskacl: applied mode=blacklist allow=$DA_ALLOWED deny=0"
		fi
		return 0
	fi

	if ! diskacl_chain_exists; then
		if ! ipt_run -N "$DISKACL_CHAIN" && [ "$DISKACL_PRINT" = 0 ]; then
			diskacl_log "cannot create chain $DISKACL_CHAIN"
			echo "diskacl: cannot create chain $DISKACL_CHAIN" >&2
			diskacl_state error 0 0 error
			return 1
		fi
	fi
	ipt_run -F "$DISKACL_CHAIN"
	for m in $DA_NO; do
		ipt_run -A "$DISKACL_CHAIN" -m mac --mac-source "$m" -j DROP
	done
	ipt_run -A "$DISKACL_CHAIN" -j RETURN

	diskacl_jump_remove "$DISKACL_CHAIN"
	if [ "$DISKACL_PRINT" = 0 ] &&
		ipt_out -S INPUT 2>/dev/null | grep -qF -- "-j $DISKACL_CHAIN"; then
		diskacl_log "stale $DISKACL_CHAIN jump survived deletion; refusing to add duplicates"
		echo "diskacl: stale jump in INPUT; chain rebuilt but jumps not re-added" >&2
		diskacl_state error "$DA_ALLOWED" "$denied" error
		return 1
	fi

	# Position 1/2: the vendor has an any-interface ACCEPT for
	# 22,80,135:139,445 early in INPUT; our jump must precede it or the
	# per-device decision never runs.  Two rules, both scoped to the LAN.
	ipt_run -I INPUT 1 -i "$DISKACL_IFACE" -p tcp \
		-m multiport --dports "$DISKACL_TCP_PORTS" -j "$DISKACL_CHAIN"
	ipt_run -I INPUT 2 -i "$DISKACL_IFACE" -p udp \
		-m multiport --dports "$DISKACL_UDP_PORTS" -j "$DISKACL_CHAIN"

	diskacl_state blacklist "$DA_ALLOWED" "$denied" applied
	if [ "$DISKACL_PRINT" = 1 ]; then
		echo "diskacl: dry run, $denied DROP rule(s) + RETURN"
	else
		diskacl_log "applied chain=$DISKACL_CHAIN iface=$DISKACL_IFACE deny=$denied"
		echo "diskacl: applied mode=blacklist allow=$DA_ALLOWED deny=$denied"
	fi
	return 0
}

diskacl_clear() {
	[ "$DISKACL_PRINT" = 1 ] ||
		mkdir -p "$ROOT/var/log" "$ROOT/var/state" 2>/dev/null
	if ! legacy_clear; then
		return 1
	fi
	guest_rule_remove
	diskacl_jump_remove "$DISKACL_CHAIN"
	if diskacl_chain_exists; then
		ipt_run -F "$DISKACL_CHAIN"
		if ! ipt_run -X "$DISKACL_CHAIN" && [ "$DISKACL_PRINT" = 0 ]; then
			diskacl_log "chain $DISKACL_CHAIN still present after -X"
			echo "diskacl: chain $DISKACL_CHAIN still present" >&2
			return 1
		fi
	fi
	diskacl_state cleared 0 0 cleared
	if [ "$DISKACL_PRINT" = 1 ]; then
		echo "diskacl: dry run, chain removed"
	else
		diskacl_log "cleared chain=$DISKACL_CHAIN"
		echo "diskacl: cleared"
	fi
	return 0
}

diskacl_status() {
	chain=absent
	diskacl_chain_exists && chain=present
	jumps=$(ipt_out -S INPUT 2>/dev/null | grep -cF -- "-j $DISKACL_CHAIN")
	legacy=absent
	ipt_out -S "$LEGACY_CHAIN" >/dev/null 2>&1 && legacy=present
	legacy_jumps=$(ipt_out -S INPUT 2>/dev/null | grep -cF -- "-j $LEGACY_CHAIN")
	echo "diskacl_chain=$chain"
	echo "diskacl_jumps=$jumps"
	echo "diskacl_legacy_chain=$legacy"
	echo "diskacl_legacy_jumps=$legacy_jumps"
	if guest_iface_present; then
		spec=$(guest_spec)
		n=$(ipt_out -S INPUT 2>/dev/null | grep -cF -- "$spec")
		if [ "$n" = 0 ]; then
			guest=absent
		elif guest_rule_ok; then
			guest=enforced
		else
			guest=misplaced
		fi
	else
		guest=iface-absent
	fi
	echo "diskacl_guest=$guest"
	echo "diskacl_guest_iface=$GUEST_IFACE"
	if [ -f "$ROOT/var/state/diskacl.state" ]; then
		sed 's/^/diskacl_/' "$ROOT/var/state/diskacl.state"
	else
		echo "diskacl_state=absent"
	fi
}

cmd_check() {
	need_root
	echo "root=$ROOT"
	echo "uci_dir=$CONF_SRC"
	echo "port=$PORT"
	echo "bind=$(bind_address)"
	echo "config=$ROOT/etc/smb.conf"
	[ -f "$ROOT/etc/smb.conf" ] && echo "config_md5=$(md5sum "$ROOT/etc/smb.conf" | cut -d' ' -f1)"
	[ -f "$ROOT/etc/smb.conf.last-good" ] &&
		echo "last_good_md5=$(md5sum "$ROOT/etc/smb.conf.last-good" | cut -d' ' -f1)"
	cfg=$(uci_get samba.@samba[0].name)
	[ -n "$cfg" ] && echo "uci_netbios=$cfg"
	snap=$(config_snapshot)
	echo "config_baseline=$snap"
	drift=0
	if [ -f "$snap" ]; then
		if [ "$(cat "$snap" 2>/dev/null)" = "$(config_facts)" ]; then
			echo "config_drift=no"
		else
			echo "config_drift=yes"
			drift=1
		fi
	else
		echo "config_baseline=absent"
	fi
	if [ -f "$ROOT/etc/smb.conf" ] && ! config_is_isolated "$ROOT/etc/smb.conf"; then
		echo "isolation=FAIL"
		return 1
	fi
	echo "isolation=OK"
	diskacl_status
	cmd_status || true
	[ $drift -eq 1 ] && return 7
	return 0
}

# --- TaskMonitor coexistence ------------------------------------------------
# The vendor supervisor keeps a PID-keyed task table in
# /tmp/taskmonitor/taskmonitor.conf (binary, rewritten by taskmonitorServer).
# Its CLI crashes with SIGSEGV when -p or the optional flags are omitted, so
# every call below mirrors supervisord's full invocation.  We never edit that
# table and never restart taskmonitorServer/pluginTaskmonitor.

tm_tool() {
	[ -x "$TM_TOOL" ] || die "taskmonitorTool missing: $TM_TOOL" 2
}

tm_procline() {
	printf './sbin/%s -D -s %s/etc/smb.conf -l %s/var/log' \
		"$PROC_NAME" "$ROOT" "$ROOT"
}

tm_call() {
	"$TM_TOOL" -p "$2" -b "$2" -i "$3" -t "$1" \
		-C 0 -M 1 -r -1 -L "$ROOT/lib:$ROOT/lib/private" -D "$ROOT" \
		-g none -d off -v -1 --vmzdata -1 --fastreboot 0 --delay 0
}

tm_entry_present() {
	[ -r /tmp/taskmonitor/taskmonitor.conf ] || return 1
	strings -n 4 /tmp/taskmonitor/taskmonitor.conf 2>/dev/null | grep -qF "$1"
}

cmd_tm_register() {
	need_root
	tm_tool
	pid=$(pid_from_file) || die "not running: no pidfile" 1
	pid_is_ours "$pid" || die "refusing: pid $pid is not this tree" 4
	port_listening || die "refusing: port $PORT not listening" 1
	procline=$(tm_procline)
	if tm_entry_present "$procline"; then
		echo "already registered as $TM_NAME"
		return 0
	fi
	tm_call start "$procline" "$TM_NAME" || {
		echo "TaskMonitor refused registration" >&2
		log "tm-register failed"
		return 1
	}
	log "tm-registered $TM_NAME pid=$pid"
	echo "registered $TM_NAME (pid=$pid)"
}

# Must run before a planned stop: once registered, TaskMonitor restarts the
# instance within its 5 s check, so killing it first would just revive it.
cmd_tm_unregister() {
	tm_tool
	procline=$(tm_procline)
	tm_call stop "$procline" "$TM_NAME"
	rc=$?
	case $rc in
	0)
		log "tm-unregistered $TM_NAME"
		echo "unregistered $TM_NAME"
		return 0
		;;
	1)
		echo "not registered as $TM_NAME"
		return 0
		;;
	*)
		echo "TaskMonitor unregister failed rc=$rc" >&2
		log "tm-unregister rc=$rc"
		return 1
		;;
	esac
}

vendor_pid() {
	for d in /proc/[0-9]*; do
		[ -r "$d/cmdline" ] || continue
		cmd=$(tr '\0' ' ' <"$d/cmdline" 2>/dev/null)
		cmd=${cmd% }
		[ "$cmd" = "/usr/sbin/smbd -D" ] || continue
		exe=$(readlink "$d/exe" 2>/dev/null) || continue
		[ "$exe" = "/usr/sbin/samba_multicall" ] || continue
		echo "${d#/proc/}"
	done
}

stock_ports_busy() {
	netstat -ltn 2>/dev/null | awk '{print $4}' | grep -qE ':(139|445)$'
}

# Unregister the vendor task instead of signalling the process: a plain TERM
# is followed by an automatic restart within seconds.
cmd_vendor_stop() {
	tm_tool
	pids=$(vendor_pid | tr '\n' ' ')
	"$TM_TOOL" -p "/usr/sbin/smbd -D" -b "/usr/sbin/smbd -D" -i smbd -t stop \
		-C 0 -M 1 -r -1 -L none -D none -g none -d off -v -1 \
		--vmzdata -1 --fastreboot 0 --delay 0
	rc=$?
	if [ $rc -ne 0 ] && [ -n "$pids" ]; then
		echo "TaskMonitor could not stop the factory smbd (rc=$rc)" >&2
		log "vendor-stop rc=$rc"
		return 1
	fi
	i=0
	while [ $i -lt 15 ]; do
		stock_ports_busy || break
		sleep 1
		i=$((i + 1))
	done
	if stock_ports_busy; then
		echo "factory smbd still listens on 139/445 after TaskMonitor stop" >&2
		log "vendor-stop: ports still busy"
		return 1
	fi
	log "vendor smbd unregistered via TaskMonitor (was: $pids)"
	echo "factory smbd stopped and unregistered"
}

# Rollback goes through the vendor's own init script so that shareUpdate,
# updateconfig, supervisord registration and nmbd all run exactly as after a
# normal boot.  It never stops the new instance; call 'stop' first.
cmd_vendor_start() {
	[ -x /etc/init.d/samba ] || die "/etc/init.d/samba missing" 2
	/etc/init.d/samba start >/dev/null 2>&1
	i=0
	while [ $i -lt 25 ]; do
		netstat -ltn 2>/dev/null | awk '{print $4}' |
			grep -qE ':(139|445)$' && break
		sleep 1
		i=$((i + 1))
	done
	[ -n "$(vendor_pid)" ] || {
		echo "factory smbd did not come back" >&2
		log "vendor-start failed"
		return 1
	}
	log "vendor smbd restored via init.d/samba start"
	echo "factory smbd restored"
}

while getopts "r:c:p:b:n:B:PNRh" opt; do
	case "$opt" in
	r) ROOT=$OPTARG ;;
	c) CONF_SRC=$OPTARG ;;
	p) PORT=$OPTARG ;;
	b) BIND=$OPTARG ;;
	n) PROC_NAME=$OPTARG ;;
	B) SNAPSHOT=$OPTARG ;;
	P) ALLOW_STOCK=1 ;;
	N) NO_GENERATE=1 ;;
	R) DISKACL_PRINT=1 ;;
	h) usage; exit 0 ;;
	*) usage; exit 2 ;;
	esac
done
shift $((OPTIND - 1))
ACTION=${1:-}
PIDFILE="$ROOT/var/run/smbd.pid"

case "$ACTION" in
generate) cmd_generate ;;
start) cmd_start ;;
stop) cmd_stop ;;
restart) cmd_stop; cmd_start ;;
reload) cmd_reload ;;
status) cmd_status ;;
check) cmd_check ;;
tm-register) cmd_tm_register ;;
tm-unregister) cmd_tm_unregister ;;
vendor-stop) cmd_vendor_stop ;;
vendor-start) cmd_vendor_start ;;
diskacl-apply) diskacl_apply "$@" ;;
diskacl-clear) diskacl_clear ;;
diskacl-status) diskacl_status ;;
# Deprecated aliases kept for the 1.0.4 installer's uninstall path.  They no
# longer read 'pridisk' at all; every one of them maps to macfilter.lan.
pridisk-apply) diskacl_apply "$@" ;;
pridisk-clear) diskacl_clear ;;
pridisk-status) diskacl_status ;;
*) usage; exit 2 ;;
esac
