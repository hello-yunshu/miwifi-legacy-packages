#!/bin/sh
# netwatch 控制入口。删除本目录 + /etc/init.d/netwatch + /etc/rc.d/S98netwatch 即为卸载。
BASE=/userdisk/data/.yunshu/live/netwatch
PIDF=$BASE/netwatch.pid
STOPF=$BASE/netwatch.stop
ENVF=$BASE/netwatch.env

running() {
	[ -f "$PIDF" ] || return 1
	p=$(cat "$PIDF" 2>/dev/null)
	[ -n "$p" ] || return 1
	kill -0 "$p" 2>/dev/null
}

case "$1" in
start)
	running && { echo "already running pid $(cat "$PIDF")"; exit 0; }
	[ -f "$ENVF" ] && . "$ENVF" 2>/dev/null
	[ "${NETWATCH_ENABLED:-1}" = "1" ] || { echo "disabled (netwatch.env NETWATCH_ENABLED=0)"; exit 0; }
	# 开机时 /userdisk/data 可能还没挂上，最多等 180 秒
	i=0
	while [ ! -x "$BASE/netwatch.sh" ] && [ "$i" -lt 180 ]; do sleep 1; i=$((i+1)); done
	[ -x "$BASE/netwatch.sh" ] || { echo "netwatch.sh not found, give up"; exit 1; }
	mkdir -p /userdisk/data/.yunshu/evidence/netwatch
	rm -f "$STOPF"
	nohup "$BASE/netwatch.sh" >> "$BASE/netwatch.log" 2>&1 &
	echo $! > "$PIDF"
	echo "started pid $(cat "$PIDF")"
	;;
stop)
	echo 1 > "$STOPF"
	if running; then kill "$(cat "$PIDF")" 2>/dev/null; echo "stopped pid $(cat "$PIDF")"; else echo "not running"; fi
	rm -f "$PIDF"
	;;
status)
	if running; then echo "running pid $(cat "$PIDF")"; else echo "not running"; fi
	[ -f "$ENVF" ] && grep -E '^NETWATCH_(ENABLED|INTERVAL|KEEP)=' "$ENVF"
	echo "snapshots: $(ls -1 /userdisk/data/.yunshu/evidence/netwatch/*.snap 2>/dev/null | wc -l)"
	echo "bytes:     $(du -sk /userdisk/data/.yunshu/evidence/netwatch 2>/dev/null | awk '{print $1}')KB"
	;;
uninstall)
	echo 1 > "$STOPF"
	running && kill "$(cat "$PIDF")" 2>/dev/null
	rm -f "$PIDF" /etc/rc.d/S98netwatch /etc/init.d/netwatch
	echo "uninstalled (evidence kept at /userdisk/data/.yunshu/evidence/netwatch)"
	;;
*)
	echo "usage: $0 {start|stop|status|uninstall}"
	exit 1
	;;
esac
