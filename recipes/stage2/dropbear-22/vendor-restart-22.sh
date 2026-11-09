#!/bin/sh
# 演练原厂 stop/start 链：验证回退时 /etc/init.d/dropbear start 能把 22 拉回原厂。
# 若 start 失败，脚本自行用原厂二进制兜底，避免把维护者关在门外。
LOG=/userdisk/data/dropbear-2026.94/log/vendor-restart.log
V=/usr/sbin/dropbear
exec >>"$LOG" 2>&1
echo "[$(date)] vendor stop/start dry-run start"
/etc/init.d/dropbear stop
sleep 2
if netstat -ltn 2>/dev/null | grep -q ':22 '; then
  echo "WARN: 22 still listening after stop"
fi
/etc/init.d/dropbear start
sleep 2
pid=$(cat /var/run/dropbear.1.pid 2>/dev/null)
exe=$(readlink "/proc/$pid/exe" 2>/dev/null)
if netstat -ltn 2>/dev/null | grep -q ':22 ' && [ "$exe" = "$V" ]; then
  echo "[$(date)] vendor restart OK pid=$pid exe=$exe"
  exit 0
fi
echo "[$(date)] vendor init start FAILED pid=$pid exe=$exe; manual fallback"
nohup "$V" -P /var/run/dropbear.1.pid -p 22 >/dev/null 2>&1 &
sleep 2
pid=$(cat /var/run/dropbear.1.pid 2>/dev/null)
exe=$(readlink "/proc/$pid/exe" 2>/dev/null)
if netstat -ltn 2>/dev/null | grep -q ':22 ' && [ "$exe" = "$V" ]; then
  echo "[$(date)] manual fallback OK pid=$pid"
  exit 0
fi
echo "[$(date)] manual fallback FAILED"
exit 1
