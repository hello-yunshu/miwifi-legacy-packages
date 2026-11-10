#!/bin/sh
# 将 22 端口还原为原厂 dropbear 2011.54。
# 只依赖 BusyBox + 原厂二进制，不依赖新 dropbear。
ROOT=/userdisk/data/.yunshu/live/dropbear
B=/userdisk/data/.yunshu/backups/dropbear-state/backup-dropbear-v2011.54
LOG=$ROOT/log/rollback.log
exec >>"$LOG" 2>&1
echo "[$(date)] rollback start"

# 1) 清掉所有非原厂 pidfile 实例
for pf in /var/run/dropbear.*.pid; do
  [ -f "$pf" ] || continue
  pid=$(cat "$pf" 2>/dev/null)
  [ -n "$pid" ] || continue
  exe=$(readlink "/proc/$pid/exe" 2>/dev/null)
  if [ "$exe" != "/usr/sbin/dropbear" ]; then
    echo "kill non-vendor pid=$pid exe=$exe"
    kill -TERM "$pid" 2>/dev/null
  fi
  rm -f "$pf"
done

# 2) 兜底：按 22 端口所有者清理
for pid in $(netstat -ltnp 2>/dev/null | awk '$4 ~ /:22$/ {print $NF}' | cut -d/ -f1); do
  exe=$(readlink "/proc/$pid/exe" 2>/dev/null)
  [ "$exe" = "/usr/sbin/dropbear" ] && continue
  echo "kill port22 owner pid=$pid exe=$exe"
  kill -TERM "$pid" 2>/dev/null
  sleep 1
  kill -KILL "$pid" 2>/dev/null
done
sleep 1

# 3) 还原原厂 init/config（原厂二进制在只读 /usr 原位，无需还原）
cp -p "$B/files/etc/init.d/dropbear" /etc/init.d/dropbear
cp -p "$B/files/etc/config/dropbear" /etc/config/dropbear
chmod 755 /etc/init.d/dropbear
rm -f /var/run/dropbear.2026.pid

# 4) 启动原厂
/etc/init.d/dropbear start
sleep 2

# 5) 验证 22 已归原厂
pid=$(cat /var/run/dropbear.1.pid 2>/dev/null)
exe=$(readlink "/proc/$pid/exe" 2>/dev/null)
if netstat -ltn 2>/dev/null | grep -q ':22 ' && [ "$exe" = "/usr/sbin/dropbear" ]; then
  echo "[$(date)] rollback OK pid=$pid exe=$exe"
  exit 0
fi
echo "[$(date)] rollback FAILED pid=$pid exe=$exe"
netstat -ltnp 2>/dev/null | grep ':22 '
exit 1
