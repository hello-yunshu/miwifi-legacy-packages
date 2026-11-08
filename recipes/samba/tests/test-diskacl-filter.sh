#!/bin/sh
# Offline regression for the per-device SMB access layer (macfilter.lan).
#
#   sh recipes/samba/tests/test-diskacl-filter.sh
#
# The adapter is executed as a normal subprocess; S8_MACFILTER points at a
# fixture and S8_IPTABLES at a mock binary that keeps per-chain/INPUT state in
# files.  Nothing here touches the host firewall, /etc/config or a device.
# POSIX sh only, so the same file runs under macOS /bin/sh, /bin/dash and
# busybox ash.
set -u

HERE=$(cd "$(dirname "$0")" && pwd -P) || exit 2
ADAPTER=${S8_ADAPTER:-$(cd "$HERE/.." && pwd -P)/xiaomi-smb-adapter.sh}
SYNC=${S8_SYNC:-$(cd "$HERE/../s8-compat" && pwd -P)/diskacl-sync.sh}
TMP=$(mktemp -d "${TMPDIR:-/tmp}/s8-diskacl-test.XXXXXX") || exit 2
trap 'rm -rf "$TMP"' EXIT INT TERM

ROOT=$TMP/root
BIN=$TMP/bin
FWDIR=$TMP/fw
CMDLOG=$TMP/commands.log
OUT=$TMP/out.txt
CH=$FWDIR/chains
mkdir -p "$ROOT/var/log" "$ROOT/var/state" "$BIN" "$FWDIR" "$CH" || exit 2
: >"$CMDLOG"

cat >"$BIN/iptables" <<'MOCK'
#!/bin/sh
# Minimal iptables model: INPUT and every chain live in their own text file.
STATE=${MOCK_STATE:?}
CHDIR=$STATE/chains
LOG=${MOCK_LOG:?}
INPUT=$STATE/input.rules
printf '%s\n' "$*" >>"$LOG"
touch "$INPUT"
[ -d "$CHDIR" ] || mkdir -p "$CHDIR"

join() {
	s=""
	for a in "$@"; do s="$s $a"; done
	printf '%s' "${s# }"
}

cmd=$1
shift
case $cmd in
-S)
	t=$1
	if [ "$t" = INPUT ]; then
		while IFS= read -r line; do
			printf -- '-A INPUT %s\n' "$line"
		done <"$INPUT"
		exit 0
	fi
	[ -f "$CHDIR/$t.exists" ] || exit 1
	printf -- '-N %s\n' "$t"
	while IFS= read -r line; do
		printf -- '-A %s %s\n' "$t" "$line"
	done <"$CHDIR/$t.rules"
	exit 0
	;;
-N)
	t=$1
	[ -f "$CHDIR/$t.exists" ] && exit 1
	: >"$CHDIR/$t.rules"
	: >"$CHDIR/$t.exists"
	exit 0
	;;
-F)
	t=$1
	if [ "$t" = INPUT ]; then : >"$INPUT"; else
		[ -f "$CHDIR/$t.exists" ] || exit 1
		: >"$CHDIR/$t.rules"
	fi
	exit 0
	;;
-X)
	t=$1
	[ -f "$CHDIR/$t.exists" ] || exit 1
	grep -qF -- "-j $t" "$INPUT" && exit 1
	rm -f "$CHDIR/$t.exists"
	: >"$CHDIR/$t.rules"
	exit 0
	;;
-A)
	t=$1
	shift
	[ -f "$CHDIR/$t.exists" ] || exit 1
	printf '%s\n' "$(join "$@")" >>"$CHDIR/$t.rules"
	exit 0
	;;
-I)
	t=$1
	pos=$2
	shift 2
	[ "$t" = INPUT ] || exit 1
	spec=$(join "$@")
	awk -v p="$pos" -v s="$spec" 'NR==p{print s} {print} END{if (p > NR) print s}' \
		"$INPUT" >"$INPUT.new"
	mv "$INPUT.new" "$INPUT"
	exit 0
	;;
-D)
	t=$1
	shift
	[ "$t" = INPUT ] || exit 1
	spec=$(join "$@")
	awk -v s="$spec" 'BEGIN{d=0} {if (!d && $0==s) {d=1; next} print} END{exit d?0:1}' \
		"$INPUT" >"$INPUT.new"
	rc=$?
	mv "$INPUT.new" "$INPUT"
	exit $rc
	;;
*)
	exit 1
	;;
esac
MOCK
chmod 755 "$BIN/iptables"

CASES=0
FAILS=0
assert_eq() {
	CASES=$((CASES + 1))
	if [ "$2" = "$3" ]; then
		echo "PASS $1"
	else
		FAILS=$((FAILS + 1))
		echo "FAIL $1: want=[$2] got=[$3]"
	fi
}

assert_file_has() { # desc needle file
	CASES=$((CASES + 1))
	if grep -Fq -- "$2" "$3" 2>/dev/null; then
		echo "PASS $1"
	else
		FAILS=$((FAILS + 1))
		echo "FAIL $1: [$2] not in $3"
	fi
}

assert_file_not() { # desc needle file
	CASES=$((CASES + 1))
	if grep -Fq -- "$2" "$3" 2>/dev/null; then
		FAILS=$((FAILS + 1))
		echo "FAIL $1: [$2] unexpectedly in $3"
	else
		echo "PASS $1"
	fi
}

reset_fw() {
	rm -rf "$FWDIR" "$CH"
	mkdir -p "$FWDIR" "$CH"
	: >"$CMDLOG"
	: >"$OUT"
	rm -f "$ROOT/var/state/diskacl.state"
}

FIX=$TMP/macfilter
RUNSH=${S8_TEST_SH:-sh}
run_adapter() {
	env S8_MACFILTER="$FIX" S8_IPTABLES="$BIN/iptables" \
		MOCK_STATE="$FWDIR" MOCK_LOG="$CMDLOG" \
		"$RUNSH" "$ADAPTER" -r "$ROOT" "$@"
}

input_count() {
	c=0
	[ -f "$FWDIR/input.rules" ] && c=$(wc -l <"$FWDIR/input.rules" | tr -d ' ')
	echo "$c"
}

input_nth() {
	[ -f "$FWDIR/input.rules" ] || return 0
	sed -n "${1}p" "$FWDIR/input.rules" 2>/dev/null
}

chain_exists() {
	[ -f "$CH/$1.exists" ] && echo present || echo absent
}

chain_count() {
	c=0
	[ -f "$CH/$1.rules" ] && c=$(wc -l <"$CH/$1.rules" | tr -d ' ')
	echo "$c"
}

chain_nth() {
	[ -f "$CH/$1.rules" ] || return 0
	sed -n "${2}p" "$CH/$1.rules" 2>/dev/null
}

state_field() {
	sed -n "s/^$1=//p" "$ROOT/var/state/diskacl.state" 2>/dev/null
}

put_input() {
	if [ $# -eq 0 ]; then
		: >"$FWDIR/input.rules"
	else
		printf '%s\n' "$@" >"$FWDIR/input.rules"
	fi
}

mkdir -p "$ROOT/var/state"

# --- 1. blacklist, mixed yes/no -------------------------------------------
reset_fw
cat >"$FIX" <<'EOF'
config mode 'mode'
	option lan 'blacklist'

config mac 'dev1'
	option mac 'AA:BB:CC:00:00:01'
	option lan 'no'

config mac 'dev2'
	option mac 'aa:bb:cc:00:00:02'
	option lan 'yes'

config mac 'dev3'
	option mac 'aa:bb:cc:00:00:03'
	option lan 'no'
EOF
run_adapter diskacl-apply >"$OUT" 2>&1
assert_eq "blacklist: exit 0" 0 "$?"
assert_eq "blacklist: two DROP + RETURN" 3 "$(chain_count s8-diskacl)"
assert_eq "blacklist: first DROP lower-cased" \
	'-m mac --mac-source aa:bb:cc:00:00:01 -j DROP' "$(chain_nth s8-diskacl 1)"
assert_eq "blacklist: second DROP" \
	'-m mac --mac-source aa:bb:cc:00:00:03 -j DROP' "$(chain_nth s8-diskacl 2)"
assert_eq "blacklist: tail RETURN" '-j RETURN' "$(chain_nth s8-diskacl 3)"
assert_eq "blacklist: two INPUT jumps" 2 "$(input_count)"
assert_eq "blacklist: state mode" blacklist "$(state_field mode)"
assert_eq "blacklist: state allowed" 1 "$(state_field allowed)"
assert_eq "blacklist: state denied" 2 "$(state_field denied)"
assert_eq "blacklist: state applied" applied "$(state_field decision)"

# --- 2. empty blacklist (all yes) creates no chain ------------------------
reset_fw
cat >"$FIX" <<'EOF'
config mode 'mode'
	option lan 'blacklist'

config mac 'dev1'
	option mac 'aa:bb:cc:00:00:11'
	option lan 'yes'

config mac 'dev2'
	option mac 'aa:bb:cc:00:00:12'
	option lan 'yes'
EOF
run_adapter diskacl-apply >"$OUT" 2>&1
assert_eq "empty blacklist: no chain" absent "$(chain_exists s8-diskacl)"
assert_eq "empty blacklist: no INPUT jump" 0 "$(input_count)"
assert_eq "empty blacklist: applied with deny=0" applied "$(state_field decision)"
assert_eq "empty blacklist: denied=0" 0 "$(state_field denied)"

# --- 3. all entries 'no' ---------------------------------------------------
reset_fw
cat >"$FIX" <<'EOF'
config mode 'mode'
	option lan 'blacklist'

config mac 'd1'
	option mac 'aa:bb:cc:00:01:01'
	option lan 'no'

config mac 'd2'
	option mac 'aa:bb:cc:00:01:02'
	option lan 'no'

config mac 'd3'
	option mac 'aa:bb:cc:00:01:03'
	option lan 'no'
EOF
run_adapter diskacl-apply >/dev/null 2>&1
assert_eq "all no: three DROP + RETURN" 4 "$(chain_count s8-diskacl)"
assert_eq "all no: denied=3" 3 "$(state_field denied)"
assert_eq "all no: allowed=0" 0 "$(state_field allowed)"

# --- 4. mixed yes / no / unset -------------------------------------------
reset_fw
cat >"$FIX" <<'EOF'
config mode 'mode'
	option lan 'blacklist'

config mac 'a'
	option mac 'aa:bb:cc:00:02:01'
	option lan 'no'

config mac 'b'
	option mac 'aa:bb:cc:00:02:02'
	option lan 'yes'

config mac 'c'
	option mac 'aa:bb:cc:00:02:03'

config mac 'd'
	option mac 'aa:bb:cc:00:02:04'
	option lan 'yes'

config mac 'e'
	option mac 'aa:bb:cc:00:02:05'
	option lan 'no'
EOF
run_adapter diskacl-apply >/dev/null 2>&1
assert_eq "mixed: two DROP + RETURN" 3 "$(chain_count s8-diskacl)"
assert_eq "mixed: allowed=3 (yes+y+unset)" 3 "$(state_field allowed)"
assert_eq "mixed: denied=2" 2 "$(state_field denied)"
assert_eq "mixed: unset counted" 1 "$(state_field unset)"

# --- 5. missing file: no firewall change -----------------------------
reset_fw
FIX=$TMP/does-not-exist
run_adapter diskacl-apply >"$OUT" 2>&1
assert_eq "missing: apply non-fatal" 0 "$?"
assert_eq "missing: no chain" absent "$(chain_exists s8-diskacl)"
assert_eq "missing: no jump" 0 "$(input_count)"
assert_eq "missing: state unavailable" unavailable "$(state_field decision)"
assert_file_has "missing: stderr warning" "unavailable" "$OUT"
assert_file_has "missing: adapter.log" "UNAVAILABLE" "$ROOT/var/log/adapter.log"
FIX=$TMP/macfilter

# --- 6. directory instead of a file --------------------------------------
reset_fw
FIX=$TMP/macfilter-dir
mkdir -p "$FIX"
run_adapter diskacl-apply >"$OUT" 2>&1
assert_eq "directory: unavailable" unavailable "$(state_field decision)"
assert_eq "directory: no chain" absent "$(chain_exists s8-diskacl)"
FIX=$TMP/macfilter

# --- 7. mode.lan=whitelist is refused -------------------------------------
reset_fw
cat >"$FIX" <<'EOF'
config mode 'mode'
	option lan 'whitelist'

config mac 'dev1'
	option mac 'aa:bb:cc:00:03:01'
	option lan 'no'
EOF
run_adapter diskacl-apply >"$OUT" 2>&1
rc=$?
assert_eq "whitelist: refused exit 8" 8 "$rc"
assert_eq "whitelist: no chain" absent "$(chain_exists s8-diskacl)"
assert_eq "whitelist: no jump" 0 "$(input_count)"
assert_eq "whitelist: state mode" whitelist "$(state_field mode)"
assert_eq "whitelist: state refused" refused "$(state_field decision)"
assert_file_has "whitelist: stderr" "refused mode.lan=whitelist" "$OUT"

# --- 8. mode section missing is refused -----------------------------------
reset_fw
cat >"$FIX" <<'EOF'
config mac 'dev1'
	option mac 'aa:bb:cc:00:03:11'
	option lan 'no'
EOF
run_adapter diskacl-apply >"$OUT" 2>&1
rc=$?
assert_eq "mode missing: refused exit 8" 8 "$rc"
assert_eq "mode missing: no chain" absent "$(chain_exists s8-diskacl)"
assert_eq "mode missing: state mode" missing "$(state_field mode)"
assert_eq "mode missing: state refused" refused "$(state_field decision)"

# --- 9. zero device sections is unavailable, not an empty allow -----------
reset_fw
cat >"$FIX" <<'EOF'
config mode 'mode'
	option lan 'blacklist'
EOF
run_adapter diskacl-apply >"$OUT" 2>&1
assert_eq "zero sections: unavailable" unavailable "$(state_field decision)"
assert_eq "zero sections: no chain" absent "$(chain_exists s8-diskacl)"

# --- 10. repeated apply is idempotent -------------------------------------
reset_fw
cat >"$FIX" <<'EOF'
config mode 'mode'
	option lan 'blacklist'

config mac 'dev1'
	option mac 'aa:bb:cc:00:04:01'
	option lan 'no'
EOF
run_adapter diskacl-apply >/dev/null 2>&1
run_adapter diskacl-apply >/dev/null 2>&1
assert_eq "idempotent: chain 2 rules" 2 "$(chain_count s8-diskacl)"
assert_eq "idempotent: INPUT 2 jumps" 2 "$(input_count)"
assert_eq "idempotent: tcp jump rule 1" \
	'-i br-lan -p tcp -m multiport --dports 139,445 -j s8-diskacl' "$(input_nth 1)"
assert_eq "idempotent: udp jump rule 2" \
	'-i br-lan -p udp -m multiport --dports 137,138 -j s8-diskacl' "$(input_nth 2)"

# --- 11. ordering before the vendor any-interface ACCEPT -------------------
reset_fw
put_input \
	'-p tcp -m multiport --dports 22,80,135:139,445 -j ACCEPT' \
	'-i br-lan -j zone_lan'
run_adapter diskacl-apply >/dev/null 2>&1
assert_eq "order: tcp jump first" \
	'-i br-lan -p tcp -m multiport --dports 139,445 -j s8-diskacl' "$(input_nth 1)"
assert_eq "order: udp jump second" \
	'-i br-lan -p udp -m multiport --dports 137,138 -j s8-diskacl' "$(input_nth 2)"
assert_eq "order: vendor ACCEPT third" \
	'-p tcp -m multiport --dports 22,80,135:139,445 -j ACCEPT' "$(input_nth 3)"
assert_eq "order: foreign rule kept" 4 "$(input_count)"

# --- 12. clear removes only our rules -------------------------------------
put_input \
	'-i br-lan -j zone_lan' \
	'-p tcp -m multiport --dports 22,80,135:139,445 -j ACCEPT'
run_adapter diskacl-clear >"$OUT" 2>&1
assert_eq "clear: chain deleted" absent "$(chain_exists s8-diskacl)"
assert_eq "clear: foreign rules survive" 2 "$(input_count)"
assert_eq "clear: first foreign rule kept" '-i br-lan -j zone_lan' "$(input_nth 1)"
assert_eq "clear: second foreign rule kept" \
	'-p tcp -m multiport --dports 22,80,135:139,445 -j ACCEPT' "$(input_nth 2)"
assert_eq "clear: state cleared" cleared "$(state_field decision)"
assert_file_has "clear: reported" "diskacl: cleared" "$OUT"

# --- 13. legacy s8-pridisk is removed before anything else ----------------
reset_fw
put_input \
	'-i br-lan -p tcp -m multiport --dports 139,445 -j s8-pridisk' \
	'-i br-lan -j zone_lan'
: >"$CH/s8-pridisk.rules"
printf '%s\n' '-j DROP' >"$CH/s8-pridisk.rules"
: >"$CH/s8-pridisk.exists"
cat >"$FIX" <<'EOF'
config mode 'mode'
	option lan 'blacklist'

config mac 'dev1'
	option mac 'aa:bb:cc:00:05:01'
	option lan 'no'
EOF
run_adapter diskacl-apply >"$OUT" 2>&1
assert_eq "legacy: chain removed" absent "$(chain_exists s8-pridisk)"
assert_file_not "legacy: jump removed" "-j s8-pridisk" "$FWDIR/input.rules"
assert_eq "legacy: new chain is DROP+RETURN" 2 "$(chain_count s8-diskacl)"
assert_eq "legacy: new tcp jump is first" \
	'-i br-lan -p tcp -m multiport --dports 139,445 -j s8-diskacl' "$(input_nth 1)"
assert_eq "legacy: foreign zone rule kept" '-i br-lan -j zone_lan' "$(input_nth 3)"

# --- 14. legacy removed even when the new policy is refused ---------------
reset_fw
put_input '-i br-lan -p tcp -m multiport --dports 139,445 -j s8-pridisk'
printf '%s\n' '-j DROP' >"$CH/s8-pridisk.rules"
: >"$CH/s8-pridisk.exists"
cat >"$FIX" <<'EOF'
config mode 'mode'
	option lan 'whitelist'

config mac 'dev1'
	option mac 'aa:bb:cc:00:05:11'
	option lan 'no'
EOF
run_adapter diskacl-apply >"$OUT" 2>&1
assert_eq "legacy+refused: exit 8" 8 "$?"
assert_eq "legacy+refused: old chain removed" absent "$(chain_exists s8-pridisk)"
assert_file_not "legacy+refused: old jump removed" "-j s8-pridisk" "$FWDIR/input.rules"
assert_eq "legacy+refused: no new chain" absent "$(chain_exists s8-diskacl)"
assert_eq "legacy+refused: no INPUT rule" 0 "$(input_count)"

# --- 15. externally destroyed chain is rebuilt ---------------------------
reset_fw
cat >"$FIX" <<'EOF'
config mode 'mode'
	option lan 'blacklist'

config mac 'dev1'
	option mac 'aa:bb:cc:00:06:01'
	option lan 'no'
EOF
run_adapter diskacl-apply >/dev/null 2>&1
rm -f "$CH/s8-diskacl.exists" "$CH/s8-diskacl.rules"
put_input
run_adapter diskacl-apply >/dev/null 2>&1
assert_eq "rebuild: chain back" present "$(chain_exists s8-diskacl)"
assert_eq "rebuild: DROP+RETURN" 2 "$(chain_count s8-diskacl)"
assert_eq "rebuild: two jumps" 2 "$(input_count)"

# --- 16. no -> yes removes the DROP ---------------------------------------
reset_fw
cat >"$FIX" <<'EOF'
config mode 'mode'
	option lan 'blacklist'

config mac 'dev1'
	option mac 'aa:bb:cc:00:07:01'
	option lan 'no'
EOF
run_adapter diskacl-apply >/dev/null 2>&1
cat >"$FIX" <<'EOF'
config mode 'mode'
	option lan 'blacklist'

config mac 'dev1'
	option mac 'aa:bb:cc:00:07:01'
	option lan 'yes'
EOF
run_adapter diskacl-apply >/dev/null 2>&1
assert_eq "no->yes: chain is RETURN-only" 1 "$(chain_count s8-diskacl)"
assert_eq "no->yes: RETURN is the tail" '-j RETURN' "$(chain_nth s8-diskacl 1)"
assert_file_not "no->yes: DROP gone" "-j DROP" "$CH/s8-diskacl.rules"
assert_eq "no->yes: jumps kept" 2 "$(input_count)"

# --- 17. invalid MAC entries are skipped ---------------------------------
reset_fw
cat >"$FIX" <<'EOF'
config mode 'mode'
	option lan 'blacklist'

config mac 'bad'
	option mac 'zz:zz:zz:zz:zz:zz'
	option lan 'no'

config mac 'good'
	option mac 'aa:bb:cc:00:08:01'
	option lan 'no'
EOF
run_adapter diskacl-apply >/dev/null 2>&1
assert_eq "invalid mac: only valid one denied" 1 "$(state_field denied)"
assert_eq "invalid mac: chain DROP+RETURN" 2 "$(chain_count s8-diskacl)"
assert_file_has "invalid mac: logged" "invalid mac" "$ROOT/var/log/adapter.log"

# --- 18. dry run prints and mutates nothing ------------------------------
reset_fw
cat >"$FIX" <<'EOF'
config mode 'mode'
	option lan 'blacklist'

config mac 'dev1'
	option mac 'aa:bb:cc:00:09:01'
	option lan 'no'
EOF
run_adapter -R diskacl-apply >"$OUT" 2>&1
assert_eq "dry-run: no chain" absent "$(chain_exists s8-diskacl)"
assert_eq "dry-run: no INPUT rule" 0 "$(input_count)"
assert_eq "dry-run: no state file" absent "$([ -f "$ROOT/var/state/diskacl.state" ] && echo present || echo absent)"
assert_file_has "dry-run: prints -N" "-N s8-diskacl" "$OUT"
assert_file_has "dry-run: prints DROP" \
	"-A s8-diskacl -m mac --mac-source aa:bb:cc:00:09:01 -j DROP" "$OUT"
assert_file_has "dry-run: prints tcp jump" "-I INPUT 1 -i br-lan -p tcp" "$OUT"
assert_file_has "dry-run: prints udp jump" "-I INPUT 2 -i br-lan -p udp" "$OUT"
assert_eq "dry-run: no mutation commands" 0 "$(grep -cE '^-([NAIDXF]) ' "$CMDLOG" 2>/dev/null || true)"

# --- 19. dry-run clear ---------------------------------------------------
run_adapter diskacl-apply >/dev/null 2>&1
before=$(chain_count s8-diskacl)
run_adapter -R diskacl-clear >"$OUT" 2>&1
assert_eq "dry-run clear: chain untouched" "$before" "$(chain_count s8-diskacl)"
assert_file_has "dry-run clear: prints -X" "-X s8-diskacl" "$OUT"
assert_file_has "dry-run clear: prints jump delete" "-D INPUT" "$OUT"

# --- 20. stock-shaped file with 'config mode' ---------------------------
# Matches the real device: option lan is inside a 'mode' section and every
# device carries its own option lan.
reset_fw
cat >"$FIX" <<'EOF'
config mode 'mode'
	option wan 'blacklist'
	option lan 'blacklist'
	option admin 'blacklist'
	option pridisk 'whitelist'

config mac 'a'
	option mac 'b8:c1:11:cd:f7:b2'
	option wan 'blacklist'
	option lan 'no'
	option pridisk 'no'

config mac 'b'
	option mac '00:15:5d:03:00:23'
	option lan 'yes'
EOF
run_adapter diskacl-apply >/dev/null 2>&1
assert_eq "stock shape: mode blacklist" blacklist "$(state_field mode)"
assert_eq "stock shape: allowed=1 (the yes device)" 1 "$(state_field allowed)"
assert_eq "stock shape: denied=1" 1 "$(state_field denied)"
assert_eq "stock shape: one DROP + RETURN" 2 "$(chain_count s8-diskacl)"

# --- 21. md5 watcher removes the DROP on no -> yes ----------------------
reset_fw
BASE=$TMP/base
mkdir -p "$BASE/versions/v1" "$BASE/state"
cp "$ADAPTER" "$BASE/versions/v1/xiaomi-smb-adapter.sh"
cp "$SYNC" "$BASE/versions/v1/diskacl-sync.sh"
chmod 755 "$BASE/versions/v1/xiaomi-smb-adapter.sh" \
	"$BASE/versions/v1/diskacl-sync.sh"
ln -sfn versions/v1 "$BASE/current"
cat >"$FIX" <<'EOF'
config mode 'mode'
	option lan 'blacklist'

config mac 'dev1'
	option mac 'aa:bb:cc:00:0a:01'
	option lan 'no'
EOF
sync_run() {
	env S8_BASE="$BASE" S8_SMB_ROOT="$ROOT" S8_MACFILTER="$FIX" \
		S8_IPTABLES="$BIN/iptables" S8_SYNC_STATE="$BASE/state" \
		MOCK_STATE="$FWDIR" MOCK_LOG="$CMDLOG" \
		"$RUNSH" "$SYNC" >"$OUT" 2>&1
}
sync_run
assert_eq "sync: first run applies DROP" 2 "$(chain_count s8-diskacl)"
mutations() { grep -cE '^-([NAIDXF]) ' "$CMDLOG" 2>/dev/null || true; }
before_mut=$(mutations)
sync_run
assert_eq "sync: unchanged md5 does not re-apply" "$before_mut" "$(mutations)"
cat >"$FIX" <<'EOF'
config mode 'mode'
	option lan 'blacklist'

config mac 'dev1'
	option mac 'aa:bb:cc:00:0a:01'
	option lan 'yes'
EOF
sync_run
assert_eq "sync: no->yes leaves RETURN-only" 1 "$(chain_count s8-diskacl)"
assert_file_not "sync: no->yes DROP removed" "-j DROP" "$CH/s8-diskacl.rules"

# --- 22. mode change from blacklist to whitelist is refused -------------
reset_fw
cat >"$FIX" <<'EOF'
config mode 'mode'
	option lan 'blacklist'

config mac 'dev1'
	option mac 'aa:bb:cc:00:0b:01'
	option lan 'no'
EOF
run_adapter diskacl-apply >/dev/null 2>&1
cat >"$FIX" <<'EOF'
config mode 'mode'
	option lan 'whitelist'

config mac 'dev1'
	option mac 'aa:bb:cc:00:0b:01'
	option lan 'no'
EOF
run_adapter diskacl-apply >"$OUT" 2>&1
assert_eq "switch to whitelist: exit 8" 8 "$?"
assert_eq "switch to whitelist: chain left as-is" 2 "$(chain_count s8-diskacl)"
assert_eq "switch to whitelist: state refused" refused "$(state_field decision)"

echo "cases=22 assertions=$CASES failures=$FAILS"
[ "$FAILS" -eq 0 ] || exit 1
exit 0
