#!/bin/sh
# 演练"起得来但验证不过"：新实例在 2223 运行，但永不写成功标记；
# 由同一个 watchdog-22.sh（改 ROOT/ROLLBACK 指向演练）在 deadline 后清掉它。
ROOT=/userdisk/data/dropbear-2026.94
D=$ROOT/run/drill
PIDFILE=/var/run/dropbear.drill.pid
LOG=$ROOT/log/drill.log
exec >>"$LOG" 2>&1
echo "[$(date)] drill-fail start"
mkdir -p "$D/log"
rm -f "$D/takeover.ok"
if [ -f "$PIDFILE" ]; then kill "$(cat "$PIDFILE")" 2>/dev/null; sleep 1; rm -f "$PIDFILE"; fi
DROPBEAR_RELAX_AUTHKEYS=1 "$ROOT/sbin/dropbear" -P "$PIDFILE" -p 2223 -r /etc/dropbear/dropbear_rsa_host_key -D /etc/dropbear
sleep 1
echo "drill-fail instance up on 2223, intentionally no marker"
B1_ROOT="$D" B1_ROLLBACK="$ROOT/bin/drill-rollback-2223.sh" \
  nohup sh "$ROOT/bin/watchdog-22.sh" 15 >/dev/null 2>&1 &
echo "drill-fail watchdog armed (deadline 15s)"
