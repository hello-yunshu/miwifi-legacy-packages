#!/bin/sh
# S8 compatibility hook for /etc/init.d/samba (version v1).
#
# Drives one Samba 4.x instance through recipes/samba/xiaomi-smb-adapter.sh:
#   start  : render config from UCI, start on 139/445, register with TaskMonitor
#   stop   : unregister from TaskMonitor, stop by PID file only
#   reload : re-render and reload-config (falls back to restart via rc.common)
#   status : adapter status exit codes (0 running, 1 degraded, 3 stopped, 4/5 anomalies)
#
# The hook never edits /tmp/taskmonitor/taskmonitor.conf and never signals the
# vendor smbd by name.  All vendor user data in /etc/config/samba is read-only.

set -u

S8DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd -P) || S8DIR=$(dirname "$0")
ADAPTER=$S8DIR/xiaomi-smb-adapter.sh
[ -x "$ADAPTER" ] || ADAPTER=/userdisk/data/.dev/live/samba/xiaomi-smb-adapter.sh
SMBROOT=${S8_SMB_ROOT:-/userdisk/data/.dev/live/samba/current}
PORTS=${S8_PORTS:-139 445}

log() {
	logger -t s8compat "$*" 2>/dev/null || true
}

usable() {
	[ -x "$ADAPTER" ] && [ -x "$SMBROOT/sbin/smbd" ]
}

case "${1:-}" in
start)
	if ! usable; then
		log "compat tree unavailable; falling back to vendor supervisord"
		/usr/sbin/supervisord start
		exit $?
	fi
	S5_ACCEPT_CONFIG=1 S5_ROOT="$SMBROOT" \
		"$ADAPTER" -r "$SMBROOT" -p "$PORTS" -P start
	rc=$?
	if [ $rc -ne 0 ]; then
		log "new smbd start failed rc=$rc"
		exit $rc
	fi
	if ! S5_ROOT="$SMBROOT" \
		"$ADAPTER" -r "$SMBROOT" -p "$PORTS" -P tm-register; then
		log "TaskMonitor registration failed; instance runs unsupervised"
	fi
	log "new smbd listening on $PORTS"
	exit 0
	;;
stop)
	if usable; then
		S5_ROOT="$SMBROOT" \
			"$ADAPTER" -r "$SMBROOT" -p "$PORTS" -P stop
		exit $?
	fi
	log "compat tree unavailable; falling back to vendor supervisord stop"
	/usr/sbin/supervisord stop
	exit $?
	;;
reload)
	if usable; then
		S5_ACCEPT_CONFIG=1 S5_ROOT="$SMBROOT" \
			"$ADAPTER" -r "$SMBROOT" -p "$PORTS" -P reload
		exit $?
	fi
	exit 0
	;;
status)
	if usable; then
		S5_ROOT="$SMBROOT" \
			"$ADAPTER" -r "$SMBROOT" -p "$PORTS" -P status
		exit $?
	fi
	/usr/sbin/supervisord status
	exit $?
	;;
*)
	echo "usage: $0 {start|stop|reload|status}" >&2
	exit 2
	;;
esac
