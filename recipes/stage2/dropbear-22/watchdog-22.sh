#!/bin/sh
# 独立看护：接管期间若 deadline 内没有成功标记，自动回退原厂。
# 只依赖 BusyBox；不依赖新 dropbear 可执行。
ROOT=${B1_ROOT:-/userdisk/data/dropbear-2026.94}
MARK=$ROOT/run/takeover.ok
LOG=$ROOT/log/watchdog.log
ROLLBACK=${B1_ROLLBACK:-$ROOT/bin/rollback-22.sh}
DEADLINE=${1:-90}
mkdir -p "${LOG%/*}"
exec >>"$LOG" 2>&1
echo "[$(date)] watchdog armed deadline=${DEADLINE}s pid=$$"
i=0
while [ "$i" -lt "$DEADLINE" ]; do
  if [ -f "$MARK" ]; then
    echo "[$(date)] watchdog sees marker, exit 0"
    exit 0
  fi
  sleep 5
  i=$((i + 5))
done
echo "[$(date)] watchdog deadline reached without marker -> rollback"
"$ROLLBACK"
echo "[$(date)] watchdog rollback rc=$?"
