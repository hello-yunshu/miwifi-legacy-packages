#!/bin/sh
# netwatch - read-only network snapshot ring buffer.
# Writes only under /userdisk/data/.dev/evidence/netwatch/. Never touches config,
# never reloads/restarts any service.
BASE=/userdisk/data/.dev/live/netwatch
OUT=/userdisk/data/.dev/evidence/netwatch
ENVF=$BASE/netwatch.env
LOG=$BASE/netwatch.log

log() { echo "$(date '+%F %T') [$$] $*" >> "$LOG" 2>/dev/null; }

mkdir -p "$OUT" 2>/dev/null
log "start pid=$$"

while :; do
	# 每个周期重新读取开关，改 env 文件 5 秒内生效
	[ -f "$ENVF" ] && . "$ENVF" 2>/dev/null
	: "${NETWATCH_ENABLED:=1}"
	: "${NETWATCH_INTERVAL:=5}"
	: "${NETWATCH_KEEP:=200}"
	: "${NETWATCH_MINKB:=2097152}"

	if [ "$NETWATCH_ENABLED" != "1" ]; then
		log "disabled via netwatch.env, exit"
		exit 0
	fi
	if [ -f "$BASE/netwatch.stop" ]; then
		log "stop file present, exit"
		exit 0
	fi

	avail=$(df -k /userdisk/data 2>/dev/null | awk 'NR==2{print $4}')
	if [ -n "$avail" ] && [ "$avail" -lt "$NETWATCH_MINKB" ] 2>/dev/null; then
		log "low space (${avail}KB), skip"
		sleep "$NETWATCH_INTERVAL"
		continue
	fi

	ts=$(date +%s 2>/dev/null)
	[ -n "$ts" ] || ts=0
	f=$(printf '%s/%010d.snap' "$OUT" "$ts")
	tmp="$f.tmp"

	{
		echo "### ts $ts  date $(date '+%F %T %z')  uptime $(cut -d. -f1 /proc/uptime 2>/dev/null)"
		echo "### ip addr"
		ip addr 2>/dev/null || ifconfig -a 2>/dev/null
		echo "### brctl"
		brctl show 2>/dev/null
		echo "### ip route"
		ip route 2>/dev/null || route -n 2>/dev/null
		echo "### iptables"
		iptables-save 2>/dev/null
	} > "$tmp" 2>&1

	# 原子落盘：先写 .tmp 再改名，避免掉线时留下半份
	mv -f "$tmp" "$f" 2>/dev/null

	# 环形裁剪：按 mtime 排序（开机时钟回跳到 2018 时不会误删新快照）
	n=$(ls -1 "$OUT"/*.snap 2>/dev/null | wc -l)
	if [ "$n" -gt "$NETWATCH_KEEP" ]; then
		ls -1t "$OUT"/*.snap 2>/dev/null | tail -n +$((NETWATCH_KEEP + 1)) | while read -r x; do
			rm -f "$x"
		done
	fi

	sleep "$NETWATCH_INTERVAL"
done
