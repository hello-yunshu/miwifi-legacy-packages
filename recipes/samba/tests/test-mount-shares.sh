#!/bin/sh
# Offline regression for the mount-derived share layer in render().
#
#   sh recipes/samba/tests/test-mount-shares.sh
#
# The adapter's render() is extracted verbatim and driven with a fixture
# mount table (S8_MOUNTS_FILE) and a fixture /extdisks root
# (S8_EXTDISK_ROOT).  No Samba binary and no device access is needed.
set -u

HERE=$(cd "$(dirname "$0")" && pwd -P) || exit 2
ADAPTER=${S8_ADAPTER:-$(cd "$HERE/.." && pwd -P)/xiaomi-smb-adapter.sh}
TMP=$(mktemp -d "${TMPDIR:-/tmp}/s8-mount-test.XXXXXX") || exit 2
trap 'rm -rf "$TMP"' EXIT INT TERM

ROOT=$TMP/root
PORT=445
MOUNTS_FILE=$TMP/mounts
EXTDISK_ROOT=$TMP/extdisks
if [ "${S8_LIVE:-0}" = 1 ]; then
	MOUNTS_FILE=${S8_MOUNTS_FILE:-/proc/mounts}
	EXTDISK_ROOT=${S8_EXTDISK_ROOT:-/extdisks}
fi
OUT=$TMP/smb.conf
mkdir -p "$ROOT/etc" || exit 2
[ "${S8_LIVE:-0}" = 1 ] || mkdir -p "$EXTDISK_ROOT" || exit 2

# render() dependencies.
bind_address() { echo 192.168.3.2; }
log() { :; }
uci_key() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }
uci_get() {
	k=$(uci_key "$1")
	eval "printf '%s' \"\${UCI_$k:-}\""
}
uci_bool() {
	case "$(uci_get "$1")" in
	1|on|true|yes|enabled) echo 1 ;;
	*) echo 0 ;;
	esac
}
share_sections() { printf '%s\n' "${SHARE_SECTIONS:-}"; }

sed -n '/^render() {/,/^}$/p' "$ADAPTER" > "$TMP/render.sh"
if [ ! -s "$TMP/render.sh" ]; then
	echo "FAIL: cannot extract render() from $ADAPTER" >&2
	exit 2
fi
. "$TMP/render.sh"

CASES=0
FAILS=0
assert_eq() {
	a_desc=$1
	a_want=$2
	a_got=$3
	CASES=$((CASES + 1))
	if [ "$a_want" = "$a_got" ]; then
		echo "PASS $a_desc"
	else
		FAILS=$((FAILS + 1))
		echo "FAIL $a_desc: want=[$a_want] got=[$a_got]"
	fi
}

count_section() {
	grep -c "^\[$2\]$" "$1" 2>/dev/null || true
}

field() {
	awk -v s="$2" -v k="$3" '
		$0 == "[" s "]" { ins = 1; next }
		ins && /^\[/ { exit }
		ins {
			line = $0
			sub(/^[ \t]+/, "", line)
			split(line, a, " = ")
			if (a[1] == k) { print a[2]; exit }
		}
	' "$1"
}

reset_uci() {
	for v in $(set | awk -F= '/^UCI_[A-Za-z0-9_]*=/{print $1}'); do
		unset "$v"
	done
	SHARE_SECTIONS=""
	UCI_samba__samba_0__name="XiaoMi_8041"
	UCI_samba__samba_0__workgroup="WORKGROUP"
	UCI_samba__samba_0__homes="0"
	UCI_samba__samba_0__charset="UTF8"
	UCI_samba__samba_0__description="Router share"
}

mounts() {
	printf '%s\n' "$@" > "$MOUNTS_FILE"
}

render_ok() {
	render "$OUT" >/dev/null 2>&1 || {
		echo "FAIL render rc=$? in $1" >&2
		return 1
	}
	return 0
}

if [ "${S8_LIVE:-0}" = 1 ]; then
	reset_uci
	want=$(awk '$1 ~ /^\/dev\// && $2 ~ /^\/extdisks\/[^\/]+$/ {print $2}' \
		"$MOUNTS_FILE" 2>/dev/null | sort | head -1)
	if [ -z "$want" ]; then
		echo "SKIP live: no /extdisks mount in $MOUNTS_FILE"
		exit 0
	fi
	if render_ok live; then
		assert_eq "live: synthetic section" 1 "$(count_section "$OUT" XiaoMi-usb0)"
		assert_eq "live: path" "$want" "$(field "$OUT" XiaoMi-usb0 path)"
		assert_eq "live: browseable" no "$(field "$OUT" XiaoMi-usb0 browseable)"
		assert_eq "live: guest ok" yes "$(field "$OUT" XiaoMi-usb0 'guest ok')"
		assert_eq "live: force user" root "$(field "$OUT" XiaoMi-usb0 'force user')"
	fi
	echo "cases=1 assertions=$CASES failures=$FAILS"
	[ "$FAILS" -eq 0 ] || exit 1
	exit 0
fi

# 1. Mount with no UCI share: synthesize XiaoMi-usb0 with vendor fields.
reset_uci
mkdir -p "$EXTDISK_ROOT/sdb1"
mounts "/dev/sdb1 $EXTDISK_ROOT/sdb1 tntfs rw 0 0"
if render_ok case1; then
	assert_eq "case1: one section" 1 "$(count_section "$OUT" XiaoMi-usb0)"
	assert_eq "case1: path" "$EXTDISK_ROOT/sdb1" "$(field "$OUT" XiaoMi-usb0 path)"
	assert_eq "case1: read only" no "$(field "$OUT" XiaoMi-usb0 'read only')"
	assert_eq "case1: guest ok" yes "$(field "$OUT" XiaoMi-usb0 'guest ok')"
	assert_eq "case1: force user" root "$(field "$OUT" XiaoMi-usb0 'force user')"
	assert_eq "case1: browseable" no "$(field "$OUT" XiaoMi-usb0 browseable)"
	assert_eq "case1: create mask" 0777 "$(field "$OUT" XiaoMi-usb0 'create mask')"
	assert_eq "case1: directory mask" 0777 "$(field "$OUT" XiaoMi-usb0 'directory mask')"
fi

# 2. UCI already covers the mount path: no synthesized duplicate.
reset_uci
SHARE_SECTIONS=cfg0
UCI_samba_cfg0_name=XiaoMi-usb0
UCI_samba_cfg0_path=$EXTDISK_ROOT/sdb1
mounts "/dev/sdb1 $EXTDISK_ROOT/sdb1 tntfs rw 0 0"
if render_ok case2; then
	assert_eq "case2: UCI section kept once" 1 "$(count_section "$OUT" XiaoMi-usb0)"
	assert_eq "case2: no extra section" 0 "$(count_section "$OUT" XiaoMi-usb1)"
fi

# 3. No mounts: no synthesized section.
reset_uci
: > "$MOUNTS_FILE"
if render_ok case3; then
	assert_eq "case3: no synthetic section" 0 "$(count_section "$OUT" XiaoMi-usb0)"
fi

# 4. Two mounts: stable usb0/usb1 assignment.
reset_uci
mkdir -p "$EXTDISK_ROOT/sdb1" "$EXTDISK_ROOT/sdc1"
mounts "/dev/sdb1 $EXTDISK_ROOT/sdb1 tntfs rw 0 0" \
	"/dev/sdc1 $EXTDISK_ROOT/sdc1 tntfs rw 0 0"
if render_ok case4; then
	assert_eq "case4: usb0 path" "$EXTDISK_ROOT/sdb1" "$(field "$OUT" XiaoMi-usb0 path)"
	assert_eq "case4: usb1 path" "$EXTDISK_ROOT/sdc1" "$(field "$OUT" XiaoMi-usb1 path)"
	assert_eq "case4: exactly two" 2 "$(grep -c '^\[XiaoMi-usb' "$OUT" 2>/dev/null || true)"
fi

# 5. Two mounts, UCI covers one: the other takes the next free name.
reset_uci
SHARE_SECTIONS=cfg0
UCI_samba_cfg0_name=XiaoMi-usb0
UCI_samba_cfg0_path=$EXTDISK_ROOT/sdb1
mounts "/dev/sdb1 $EXTDISK_ROOT/sdb1 tntfs rw 0 0" \
	"/dev/sdc1 $EXTDISK_ROOT/sdc1 tntfs rw 0 0"
if render_ok case5; then
	assert_eq "case5: UCI usb0 once" 1 "$(count_section "$OUT" XiaoMi-usb0)"
	assert_eq "case5: synthesized usb1" 1 "$(count_section "$OUT" XiaoMi-usb1)"
	assert_eq "case5: usb1 path" "$EXTDISK_ROOT/sdc1" "$(field "$OUT" XiaoMi-usb1 path)"
fi

# 6. Non-/extdisks mount is ignored.
reset_uci
mkdir -p "$TMP/mnt/foo"
mounts "/dev/sdd1 $TMP/mnt/foo ext4 rw 0 0"
if render_ok case6; then
	assert_eq "case6: ignored" 0 "$(count_section "$OUT" XiaoMi-usb0)"
fi

# 7. Stale /extdisks entry (mountpoint missing) is ignored.
reset_uci
mounts "/dev/sdz1 $EXTDISK_ROOT/sdz1 tntfs rw 0 0"
if render_ok case7; then
	assert_eq "case7: stale ignored" 0 "$(count_section "$OUT" XiaoMi-usb0)"
fi

# 8. Nested mount under an extdisk is ignored.
reset_uci
mkdir -p "$EXTDISK_ROOT/sdb1/sub"
mounts "/dev/sdb1 $EXTDISK_ROOT/sdb1 tntfs rw 0 0" \
	"/dev/sdb2 $EXTDISK_ROOT/sdb1/sub ext4 rw 0 0"
if render_ok case8; then
	assert_eq "case8: parent only" 1 "$(count_section "$OUT" XiaoMi-usb0)"
	assert_eq "case8: nested ignored" 0 "$(count_section "$OUT" XiaoMi-usb1)"
fi

# 9. Non-block device (tmpfs) is ignored.
reset_uci
mkdir -p "$EXTDISK_ROOT/ram"
mounts "tmpfs $EXTDISK_ROOT/ram tmpfs rw 0 0"
if render_ok case9; then
	assert_eq "case9: tmpfs ignored" 0 "$(count_section "$OUT" XiaoMi-usb0)"
fi

# 10. Missing mount table: render still succeeds, no synthetic section.
reset_uci
rm -f "$MOUNTS_FILE"
if render_ok case10; then
	assert_eq "case10: no synthetic section" 0 "$(count_section "$OUT" XiaoMi-usb0)"
fi

# 11. UCI path with a trailing slash still suppresses the synthetic share.
reset_uci
SHARE_SECTIONS=cfg0
UCI_samba_cfg0_name=XiaoMi-usb0
UCI_samba_cfg0_path=$EXTDISK_ROOT/sdb1/
mounts "/dev/sdb1 $EXTDISK_ROOT/sdb1 tntfs rw 0 0"
if render_ok case11; then
	assert_eq "case11: UCI usb0 once" 1 "$(count_section "$OUT" XiaoMi-usb0)"
	assert_eq "case11: no extra section" 0 "$(count_section "$OUT" XiaoMi-usb1)"
fi

# 12. Re-render is byte-identical (idempotent).
reset_uci
mkdir -p "$EXTDISK_ROOT/sdb1"
mounts "/dev/sdb1 $EXTDISK_ROOT/sdb1 tntfs rw 0 0"
if render_ok case12a; then
	cp "$OUT" "$TMP/first.conf"
	if render_ok case12b; then
		assert_eq "case12: idempotent" identical \
			"$(cmp -s "$TMP/first.conf" "$OUT" && echo identical || echo different)"
	fi
fi

# 13. UCI name collision on another path: synthesized share takes usb1.
reset_uci
SHARE_SECTIONS=cfg0
UCI_samba_cfg0_name=XiaoMi-usb0
UCI_samba_cfg0_path=/userdisk/data/other
mkdir -p "$EXTDISK_ROOT/sdb1"
mounts "/dev/sdb1 $EXTDISK_ROOT/sdb1 tntfs rw 0 0"
if render_ok case13; then
	assert_eq "case13: UCI name kept" 1 "$(count_section "$OUT" XiaoMi-usb0)"
	assert_eq "case13: usb1 synthesized" 1 "$(count_section "$OUT" XiaoMi-usb1)"
	assert_eq "case13: usb1 path" "$EXTDISK_ROOT/sdb1" "$(field "$OUT" XiaoMi-usb1 path)"
fi

# 14. Comments and blank lines in the mount table are ignored.
reset_uci
mkdir -p "$EXTDISK_ROOT/sdb1"
mounts "# comment" "" "/dev/sdb1 $EXTDISK_ROOT/sdb1 tntfs rw 0 0"
if render_ok case14; then
	assert_eq "case14: parsed one mount" 1 "$(count_section "$OUT" XiaoMi-usb0)"
	assert_eq "case14: path" "$EXTDISK_ROOT/sdb1" "$(field "$OUT" XiaoMi-usb0 path)"
fi

CASE_GROUPS=$(grep -oE 'case[0-9]+' "$0" | sort -u | wc -l | tr -d ' ')
echo "cases=$CASE_GROUPS assertions=$CASES failures=$FAILS"
[ "$FAILS" -eq 0 ] || exit 1
exit 0
