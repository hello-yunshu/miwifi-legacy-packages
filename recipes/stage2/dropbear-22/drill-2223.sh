#!/bin/sh
# 隔离演练：在 2223 起 dropbear 2026.94，成功则写标记。不碰 22。
ROOT=/userdisk/data/.yunshu/live/dropbear
D=$ROOT/run/drill
MARK=$D/takeover.ok
PIDFILE=/var/run/dropbear.drill.pid
LOG=$ROOT/log/drill.log
AK=/etc/dropbear/authorized_keys
exec >>"$LOG" 2>&1
echo "[$(date)] drill start"
mkdir -p "$D"
rm -f "$MARK"
if [ -f "$PIDFILE" ]; then kill "$(cat "$PIDFILE")" 2>/dev/null; sleep 1; rm -f "$PIDFILE"; fi
DROPBEAR_RELAX_AUTHKEYS=1 "$ROOT/sbin/dropbear" -P "$PIDFILE" -p 2223 -r /etc/dropbear/dropbear_rsa_host_key -D /etc/dropbear
sleep 1
banner=$(timeout -t 2 nc 127.0.0.1 2223 </dev/null 2>/dev/null | head -1)
echo "banner=$banner"
case "$banner" in
  *dropbear_2026.94*) ;;
  *) echo "drill banner mismatch"; exit 1 ;;
esac
cp -p "$AK" "$D/authorized_keys.before"
"$ROOT/bin/dropbearkey" -t ed25519 -f "$D/test.key" >/dev/null 2>&1
pub=$("$ROOT/bin/dropbearkey" -y -f "$D/test.key" 2>/dev/null | grep '^ssh-')
echo "$pub drill-test@r2d" >> "$AK"
out=$(timeout -t 20 "$ROOT/bin/dbclient" -y -i "$D/test.key" -p 2223 127.0.0.1 'echo AUTH_OK' 2>&1)
echo "auth_out=$out"
cp -p "$D/authorized_keys.before" "$AK"
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
  echo "[$(date)] drill SUCCESS marker written"
  exit 0
fi
echo "drill auth failed"
exit 1
