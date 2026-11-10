#!/bin/sh
# 演练用回退：只清 2223 上的新实例，并确认 22 仍是原厂。不启动/停止 22。
ROOT=/userdisk/data/.yunshu/live/dropbear
PIDFILE=/var/run/dropbear.drill.pid
LOG=$ROOT/log/drill.log
exec >>"$LOG" 2>&1
echo "[$(date)] drill rollback start"
pid=$(cat "$PIDFILE" 2>/dev/null)
if [ -n "$pid" ]; then
  exe=$(readlink "/proc/$pid/exe" 2>/dev/null)
  echo "drill rollback kill pid=$pid exe=$exe"
  kill -TERM "$pid" 2>/dev/null
fi
rm -f "$PIDFILE"
sleep 1
vpid=$(cat /var/run/dropbear.1.pid 2>/dev/null)
vex=$(readlink "/proc/$vpid/exe" 2>/dev/null)
if netstat -ltn 2>/dev/null | grep ':2223 '; then
  echo "[$(date)] drill rollback FAILED: 2223 still listening"; exit 1
fi
if [ "$vex" = "/usr/sbin/dropbear" ]; then
  echo "[$(date)] drill rollback OK: 22 still vendor pid=$vpid"
  exit 0
fi
echo "[$(date)] drill rollback FAILED: 22 owner exe=$vex"
exit 1
