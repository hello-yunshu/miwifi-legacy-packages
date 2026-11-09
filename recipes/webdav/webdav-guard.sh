#!/bin/sh
# R2D WebDAV policy guard + watchdog (isolated verification build).
#
# Three properties:
#   1. revocation <=5s: policy is re-read every second from macfilter and the
#      WEBDAV-ACL chain is rebuilt; a DROP rule by source MAC blocks every
#      packet (not only new connections), so keep-alive, downloads and uploads
#      stop within the same bound.
#   2. fail-closed: mode.lan missing/non-blacklist, uci read/parse failure, or
#      an unreadable policy makes the chain end in an unconditional DROP and
#      stops lighttpd.
#   3. watchdog: a separate process checks a lease written once per second and
#      stops lighttpd when the lease is older than 5s (guard died or hung).
#
# Usage: webdav-guard.sh start|stop|status|guard|watchdog|apply
# All paths can be overridden through environment variables.

set -u

STATE_DIR=${WEBDAV_STATE_DIR:-/userdisk/data/s8webdav}
PORT=${WEBDAV_PORT:-18084}
CHAIN=${WEBDAV_CHAIN:-WEBDAV-ACL}
UCI_DIR=${WEBDAV_UCI_DIR:-/etc/config}
LIGHTTPD=${WEBDAV_LIGHTTPD:-/userdisk/data/r2d-cand/b6-webdav/root/sbin/lighttpd}
CONF=${WEBDAV_CONF:-$STATE_DIR/lighttpd.conf}
PIDFILE=${WEBDAV_PIDFILE:-$STATE_DIR/lighttpd.pid}
LEASE_MAX=${WEBDAV_LEASE_MAX:-5}
LOG=${WEBDAV_LOG:-$STATE_DIR/guard.log}

export WEBDAV_STATE_DIR="$STATE_DIR" WEBDAV_PORT="$PORT" WEBDAV_CHAIN="$CHAIN"
export WEBDAV_UCI_DIR="$UCI_DIR" WEBDAV_LIGHTTPD="$LIGHTTPD" WEBDAV_CONF="$CONF"
export WEBDAV_PIDFILE="$PIDFILE" WEBDAV_LEASE_MAX="$LEASE_MAX" WEBDAV_LOG="$LOG"

log() {
    # keep the log bounded; this runs every second
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"
}

service_pid() {
    [ -f "$PIDFILE" ] || return 1
    pid=$(cat "$PIDFILE" 2>/dev/null)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && echo "$pid"
}

stop_service() {
    pid=$(service_pid) || return 0
    kill "$pid" 2>/dev/null
    log "stop lighttpd pid=$pid"
    return 0
}

# Prints "__OK__" followed by one lowercase MAC per line for devices whose
# lan flag is "no"; prints "__ERR__" when the policy cannot be trusted.
policy_read() {
    uci -c "$UCI_DIR" -q show macfilter 2>/dev/null | awk -F= '
        /^macfilter\.mode\.lan=/ { mode=$2 }
        /^macfilter\.@mac\[[0-9]+\]\.mac=/ {
            split($1, a, "["); i=a[2]; sub(/\].*/, "", i); mac[i]=$2
        }
        /^macfilter\.@mac\[[0-9]+\]\.lan=/ {
            split($1, a, "["); i=a[2]; sub(/\].*/, "", i); lan[i]=$2
        }
        END {
            if (mode != "blacklist") { print "__ERR__"; exit }
            print "__OK__"
            for (i in mac) {
                if (lan[i] == "no" && mac[i] != "") print tolower(mac[i])
            }
        }'
}

# apply_chain <deny_all> <mac...>
apply_chain() {
    deny_all=$1; shift
    iptables -N "$CHAIN" 2>/dev/null
    while iptables -D INPUT -p tcp --dport "$PORT" -j "$CHAIN" 2>/dev/null; do :; done
    iptables -F "$CHAIN" 2>/dev/null
    iptables -I INPUT 1 -p tcp --dport "$PORT" -j "$CHAIN" || return 1
    for m in "$@"; do
        iptables -I "$CHAIN" 1 -p tcp -m mac --mac-source "$m" -j DROP || return 1
    done
    [ "$deny_all" = "1" ] && iptables -A "$CHAIN" -j DROP
    return 0
}

check_policy() {
    out=$(policy_read)
    first=$(echo "$out" | head -n 1)
    macs=$(echo "$out" | tail -n +2 | grep -v '^$')
    if [ "$first" != "__OK__" ]; then
        return 1
    fi
    # shellcheck disable=SC2086
    apply_chain 0 $macs || return 1
    return 0
}

do_apply() {
    if check_policy; then
        date +%s > "$STATE_DIR/lease.tmp" && mv "$STATE_DIR/lease.tmp" "$STATE_DIR/lease"
        rm -f "$STATE_DIR/fail"
        return 0
    fi
    rm -f "$STATE_DIR/lease"
    : > "$STATE_DIR/fail"
    apply_chain 1
    log "POLICY_UNHEALTHY fail-closed deny-all"
    stop_service
    return 1
}

run_guard() {
    mkdir -p "$STATE_DIR"
    last=""
    while :; do
        now_macs=$(policy_read | tail -n +2 | grep -v '^$' | sort | tr '\n' ' ')
        if do_apply; then
            if [ "$now_macs" != "$last" ]; then
                log "POLICY_CHANGE deny_macs='$now_macs'"
                last=$now_macs
            fi
        fi
        sleep 1
    done
}

run_watchdog() {
    while :; do
        if [ -f "$STATE_DIR/fail" ]; then
            stop_service
        else
            lease=$(cat "$STATE_DIR/lease" 2>/dev/null)
            now=$(date +%s)
            if [ -z "$lease" ] || [ $((now - lease)) -gt "$LEASE_MAX" ]; then
                stop_service
            fi
        fi
        sleep 0.2 2>/dev/null || sleep 1
    done
}

start_children() {
    nohup sh "$0" guard >>"$LOG" 2>&1 &
    echo $! > "$STATE_DIR/guard.pid"
    nohup sh "$0" watchdog >>"$LOG" 2>&1 &
    echo $! > "$STATE_DIR/watchdog.pid"
}

case "${1:-}" in
start)
    mkdir -p "$STATE_DIR"
    : > "$LOG"
    # 1. default deny before listening
    apply_chain 1 || { echo "chain_failed"; exit 1; }
    # 2. policy must be healthy before the listener starts
    check_policy || { echo "policy_unhealthy"; stop_service; exit 1; }
    date +%s > "$STATE_DIR/lease"
    # 3. listener
    [ -n "$(service_pid)" ] || "$LIGHTTPD" -f "$CONF" || { echo "lighttpd_failed"; exit 1; }
    # 4. watchdog and guard
    start_children
    echo "started port=$PORT"
    ;;
stop)
    [ -f "$STATE_DIR/guard.pid" ] && kill "$(cat "$STATE_DIR/guard.pid")" 2>/dev/null
    [ -f "$STATE_DIR/watchdog.pid" ] && kill "$(cat "$STATE_DIR/watchdog.pid")" 2>/dev/null
    rm -f "$STATE_DIR/guard.pid" "$STATE_DIR/watchdog.pid"
    stop_service
    while iptables -D INPUT -p tcp --dport "$PORT" -j "$CHAIN" 2>/dev/null; do :; done
    iptables -F "$CHAIN" 2>/dev/null
    iptables -X "$CHAIN" 2>/dev/null
    rm -f "$STATE_DIR/lease" "$STATE_DIR/fail"
    echo "stopped"
    ;;
status)
    echo "policy_denied: $(policy_read | tail -n +2 | grep -v '^$' | tr '\n' ' ')"
    echo "lighttpd_pid: $(service_pid || echo none)"
    echo "lease: $(cat "$STATE_DIR/lease" 2>/dev/null || echo none) now=$(date +%s)"
    echo "guard_pid: $(cat "$STATE_DIR/guard.pid" 2>/dev/null || echo none)"
    echo "watchdog_pid: $(cat "$STATE_DIR/watchdog.pid" 2>/dev/null || echo none)"
    echo "chain:"; iptables -S "$CHAIN" 2>/dev/null
    echo "listen:"; netstat -ln 2>/dev/null | grep ":$PORT " || echo "not listening"
    ;;
guard) run_guard ;;
watchdog) run_watchdog ;;
apply) do_apply ;;
*) echo "usage: $0 start|stop|status|guard|watchdog|apply"; exit 2 ;;
esac
