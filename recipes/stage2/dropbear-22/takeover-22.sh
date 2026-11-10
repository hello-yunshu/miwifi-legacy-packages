#!/bin/sh
# 在 22 端口用 dropbear 2026.94 接管；任何一步失败立即回退原厂。
# 由看护脚本 watchdog-22.sh 独立兜底。
ROOT=/userdisk/data/.yunshu/live/dropbear
MARK=$ROOT/run/takeover.ok
LOG=$ROOT/log/takeover.log
PIDFILE=/var/run/dropbear.2026.pid
NEW=$ROOT/sbin/dropbear
AK=/etc/dropbear/authorized_keys
exec >>"$LOG" 2>&1
echo "[$(date)] takeover start"

rm -f "$MARK"

# 1) 停原厂监听（已建立的 SSH 子会话不受影响）
VPID=$(cat /var/run/dropbear.1.pid 2>/dev/null)
echo "vendor pid=$VPID"
if [ -n "$VPID" ]; then
  kill -TERM "$VPID" 2>/dev/null
  i=0
  while [ -d "/proc/$VPID" ] && [ "$i" -lt 10 ]; do
    sleep 1
    i=$((i + 1))
  done
  [ -d "/proc/$VPID" ] && kill -KILL "$VPID" 2>/dev/null
fi
rm -f /var/run/dropbear.1.pid

# 1b) 若 22 上已有候选实例（例如重复执行本脚本），一并停掉后再起新实例
for pf in /var/run/dropbear.*.pid; do
  [ -f "$pf" ] || continue
  pid=$(cat "$pf" 2>/dev/null)
  [ -n "$pid" ] || continue
  exe=$(readlink "/proc/$pid/exe" 2>/dev/null)
  case "$exe" in
    "$NEW"|/usr/sbin/dropbear)
      echo "stop existing pid=$pid exe=$exe"
      kill -TERM "$pid" 2>/dev/null
      ;;
  esac
  rm -f "$pf"
done
sleep 1

# 2) 等 22 释放
i=0
while netstat -ltn 2>/dev/null | grep -q ':22 ' && [ "$i" -lt 10 ]; do
  sleep 1
  i=$((i + 1))
done

# 3) 起新实例
DROPBEAR_RELAX_AUTHKEYS=1 "$NEW" -P "$PIDFILE" -p 22 -r /etc/dropbear/dropbear_rsa_host_key -D /etc/dropbear
sleep 1

# 4) banner 检查
banner=$(timeout -t 2 nc 127.0.0.1 22 </dev/null 2>/dev/null | head -1)
echo "banner=$banner"
case "$banner" in
  *dropbear_2026.94*) ;;
  *)
    echo "banner mismatch -> rollback"
    "$ROOT/bin/rollback-22.sh"
    exit 1
    ;;
esac

# 5) 回环公钥登录实测
cp -p "$AK" "$ROOT/run/authorized_keys.before"
"$ROOT/bin/dropbearkey" -t ed25519 -f "$ROOT/run/takeover_test.key" >/dev/null 2>&1
pub=$("$ROOT/bin/dropbearkey" -y -f "$ROOT/run/takeover_test.key" 2>/dev/null | grep '^ssh-')
echo "$pub takeover-test@r2d" >> "$AK"
out=$(timeout -t 20 "$ROOT/bin/dbclient" -y -i "$ROOT/run/takeover_test.key" -p 22 127.0.0.1 'echo AUTH_OK' 2>&1)
echo "auth_out=$out"
cp -p "$ROOT/run/authorized_keys.before" "$AK"
case "$out" in
  *AUTH_OK*)
    :
    ;;
  *)
    out=""
    ;;
esac
if [ -n "$out" ]; then
  date > "$MARK"
  echo "[$(date)] takeover SUCCESS"
  exit 0
fi
echo "auth failed -> rollback"
"$ROOT/bin/rollback-22.sh"
exit 1
