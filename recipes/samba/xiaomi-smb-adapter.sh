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

set -u

ROOT=${S5_ROOT:-/userdisk/data/samba-s5/root}
CONF_SRC=${S5_UCI_DIR:-/etc/config}
PORT=${S5_PORT:-1445}
BIND=${S5_BIND:-}
PROC_NAME=${S5_PROC_NAME:-samba-s5d}
NO_GENERATE=0
PIDFILE=
ACTION=

usage() {
	cat <<EOF
Usage: $0 [-r root] [-c uci-dir] [-p port] [-b bind-address] <command>

Commands:
  generate   render UCI -> smb.conf, validate, keep last-good
  start      generate (unless --no-generate) and start the instance
  stop       stop the instance using its PID file only
  restart    stop then start
  reload     generate then 'smbcontrol smbd reload-config'
  status     report running / stale / stopped (0 / 4 / 3)
  check      print isolation and configuration facts

Options:
  -r root    installation tree (default $ROOT)
  -c dir     alternate UCI config dir (default $CONF_SRC, read-only use)
  -p port    TCP port for this instance (default $PORT)
  -b addr    bind address (default: network.lan.ipaddr, else all)
  -n name    process name used to start the binary (default $PROC_NAME)
  -N         start without regenerating the configuration
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
	if grep -Eq '^[[:space:]]*smb ports[[:space:]]*=[[:space:]]*(139|445)([[:space:]]|$)' "$conf"; then
		return 1
	fi
	return 0
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

pid_is_ours() {
	pid=$1
	[ -d "/proc/$pid" ] || return 1
	exe=$(readlink "/proc/$pid/exe" 2>/dev/null) || return 1
	case "$exe" in
	"$ROOT"/sbin/*) return 0 ;;
	esac
	return 1
}

port_listening() {
	netstat -ltn 2>/dev/null | awk '{print $4}' | grep -q ":$PORT\$"
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
		rm -f "$PIDFILE"
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
	if ! pid=$(pid_from_file); then
		echo "stopped (no pidfile)"
		return 0
	fi
	if ! pid_is_ours "$pid"; then
		if [ -d "/proc/$pid" ]; then
			echo "refusing to kill $pid: not a process of $ROOT" >&2
			return 4
		fi
		rm -f "$PIDFILE"
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
	rm -f "$PIDFILE"
	log "stopped pid=$pid"
	echo "stopped pid=$pid"
	return 0
}

cmd_reload() {
	cmd_generate >/dev/null || return 3
	if ! pid=$(pid_from_file) || ! pid_is_ours "$pid"; then
		echo "not running" >&2
		return 3
	fi
	run_env
	if "$ROOT/bin/smbcontrol" -s "$ROOT/etc/smb.conf" smbd reload-config \
		>"$ROOT/var/log/smbcontrol.out" 2>&1; then
		log "reload-config sent to pid=$pid"
		echo "reloaded"
		return 0
	fi
	echo "reload failed; configuration kept, restart required" >&2
	log "reload failed: $(tail -1 "$ROOT/var/log/smbcontrol.out" 2>/dev/null)"
	return 6
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
	if [ -f "$ROOT/etc/smb.conf" ] && ! config_is_isolated "$ROOT/etc/smb.conf"; then
		echo "isolation=FAIL"
		return 1
	fi
	echo "isolation=OK"
	cmd_status || true
	return 0
}

while getopts "r:c:p:b:n:Nh" opt; do
	case "$opt" in
	r) ROOT=$OPTARG ;;
	c) CONF_SRC=$OPTARG ;;
	p) PORT=$OPTARG ;;
	b) BIND=$OPTARG ;;
	n) PROC_NAME=$OPTARG ;;
	N) NO_GENERATE=1 ;;
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
*) usage; exit 2 ;;
esac
