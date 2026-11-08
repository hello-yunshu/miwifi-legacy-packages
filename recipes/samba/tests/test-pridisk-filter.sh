#!/bin/sh
# Offline regression for the per-device disk access layer (pridisk).
#
#   sh recipes/samba/tests/test-pridisk-filter.sh
#
# The adapter is executed as a normal subprocess; S8_MACFILTER points at a
# fixture and S8_IPTABLES at a mock binary that keeps the chain/INPUT state in
# files.  Nothing here touches the host firewall, /etc/config or a device.
# POSIX sh only, so the same file runs under macOS /bin/sh and busybox ash.
set -u

HERE=$(cd "$(dirname "$0")" && pwd -P) || exit 2
ADAPTER=${S8_ADAPTER:-$(cd "$HERE/.." && pwd -P)/xiaomi-smb-adapter.sh}
TMP=$(mktemp -d "${TMPDIR:-/tmp}/s8-pridisk-test.XXXXXX") || exit 2
trap 'rm -rf "$TMP"' EXIT INT TERM

ROOT=$TMP/root
BIN=$TMP/bin
FWDIR=$TMP/fw
CMDLOG=$TMP/commands.log
OUT=$TMP/out.txt
mkdir -p "$ROOT/var/log" "$ROOT/var/state" "$BIN" "$FWDIR" || exit 2
: >"$CMDLOG"

cat >"$BIN/iptables" <<'MOCK'
#!/bin/sh
# Minimal iptables model: chain rules and INPUT rules are plain text files.
STATE=${MOCK_STATE:?}
LOG=${MOCK_LOG:?}
CHAIN=$STATE/chain.rules
INPUT=$STATE/input.rules
EXISTS=$STATE/chain.exists
printf '%s\n' "$*" >>"$LOG"
touch "$CHAIN" "$INPUT"

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
	[ -f "$EXISTS" ] || exit 1
	printf -- '-N %s\n' "$t"
	while IFS= read -r line; do
		printf -- '-A %s %s\n' "$t" "$line"
	done <"$CHAIN"
	exit 0
	;;
-N)
	: >"$CHAIN"
	: >"$EXISTS"
	exit 0
	;;
-F)
	t=$1
	if [ "$t" = INPUT ]; then : >"$INPUT"; else : >"$CHAIN"; fi
	exit 0
	;;
-X)
	[ -f "$EXISTS" ] || exit 1
	rm -f "$EXISTS"
	: >"$CHAIN"
	exit 0
	;;
-A)
	t=$1
	shift
	[ -f "$EXISTS" ] || exit 1
	printf '%s\n' "$(join "$@")" >>"$CHAIN"
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
	rm -rf "$FWDIR"
	mkdir -p "$FWDIR"
	: >"$CMDLOG"
	: >"$OUT"
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
	[ -f "$FWDIR/input.rules" ] && c=$(wc -l <"$FWDIR/input.rules")
	echo $c
}

input_nth() {
	[ -f "$FWDIR/input.rules" ] || return 0
	sed -n "${1}p" "$FWDIR/input.rules" 2>/dev/null
}

chain_count() {
	c=0
	[ -f "$FWDIR/chain.rules" ] && c=$(wc -l <"$FWDIR/chain.rules")
	echo $c
}

state_field() {
	sed -n "s/^$1=//p" "$ROOT/var/state/pridisk.state" 2>/dev/null
}

# --- 1. whitelist -----------------------------------------------------------
reset_fw
cat >"$FIX" <<'EOF'
config macfilter 'cfg'
	option pridisk 'whitelist'

config mac 'dev1'
	option mac 'AA:BB:CC:00:00:01'
	option pridisk 'yes'

config mac 'dev2'
	option mac 'aa:bb:cc:00:00:02'
	option pridisk 'yes'

config mac 'dev3'
	option mac 'aa:bb:cc:00:00:03'
	option pridisk 'no'
EOF
if run_adapter pridisk-apply >"$OUT" 2>&1; then
	assert_eq "whitelist: chain has 3 rules (allow,allow,drop)" 3 "$(chain_count)"
	assert_eq "whitelist: first rule allows dev1 (lower-cased)" \
		'-m mac --mac-source aa:bb:cc:00:00:01 -j RETURN' "$(sed -n 1p "$FWDIR/chain.rules")"
	assert_eq "whitelist: second rule allows dev2" \
		'-m mac --mac-source aa:bb:cc:00:00:02 -j RETURN' "$(sed -n 2p "$FWDIR/chain.rules")"
	assert_eq "whitelist: tail is DROP" '-j DROP' "$(sed -n 3p "$FWDIR/chain.rules")"
	assert_eq "whitelist: two INPUT jumps" 2 "$(input_count)"
	assert_eq "whitelist: tcp jump scoped to lan/139,445" \
		'-i br-lan -p tcp -m multiport --dports 139,445 -j s8-pridisk' "$(input_nth 1)"
	assert_eq "whitelist: udp jump scoped to lan/137,138" \
		'-i br-lan -p udp -m multiport --dports 137,138 -j s8-pridisk' "$(input_nth 2)"
	assert_eq "whitelist: state mode" whitelist "$(state_field mode)"
	assert_eq "whitelist: state allowed" 2 "$(state_field allowed)"
	assert_eq "whitelist: state denied" 1 "$(state_field denied)"
	assert_file_has "whitelist: not a dry run" "pridisk: applied mode=whitelist" "$OUT"
fi

# --- 2. blacklist ----------------------------------------------------------
reset_fw
cat >"$FIX" <<'EOF'
config macfilter 'cfg'
	option pridisk 'blacklist'

config mac 'dev1'
	option mac 'aa:bb:cc:00:00:0a'
	option pridisk 'no'

config mac 'dev2'
	option mac 'aa:bb:cc:00:00:0b'
	option pridisk 'yes'
EOF
if run_adapter pridisk-apply >"$OUT" 2>&1; then
	assert_eq "blacklist: two chain rules" 2 "$(chain_count)"
	assert_eq "blacklist: deny dev1" \
		'-m mac --mac-source aa:bb:cc:00:00:0a -j DROP' "$(sed -n 1p "$FWDIR/chain.rules")"
	assert_eq "blacklist: tail allows the rest" '-j RETURN' "$(sed -n 2p "$FWDIR/chain.rules")"
	assert_eq "blacklist: state mode" blacklist "$(state_field mode)"
	assert_eq "blacklist: state denied" 1 "$(state_field denied)"
fi

# --- 3. missing mode: defaults to blacklist --------------------------------
reset_fw
cat >"$FIX" <<'EOF'
config mac 'dev1'
	option mac 'aa:bb:cc:00:00:0c'
	option pridisk 'no'
EOF
if run_adapter pridisk-apply >"$OUT" 2>&1; then
	assert_eq "default mode: treated as blacklist" blacklist "$(state_field mode)"
	assert_eq "default mode: recorded as default" default "$(state_field mode_source)"
	assert_eq "default mode: only explicit no is denied" '-m mac --mac-source aa:bb:cc:00:00:0c -j DROP' \
		"$(sed -n 1p "$FWDIR/chain.rules")"
	assert_eq "default mode: two rules" 2 "$(chain_count)"
fi

# --- 4. unknown mode value -> blacklist + log ------------------------------
reset_fw
cat >"$FIX" <<'EOF'
config macfilter 'cfg'
	option pridisk 'weird-mode'

config mac 'dev1'
	option mac 'aa:bb:cc:00:00:0d'
	option pridisk 'no'
EOF
if run_adapter pridisk-apply >"$OUT" 2>&1; then
	assert_eq "unknown mode: falls back to blacklist" blacklist "$(state_field mode)"
	assert_eq "unknown mode: source=fallback" fallback "$(state_field mode_source)"
	assert_file_has "unknown mode: logged" "unknown pridisk mode 'weird-mode'" "$ROOT/var/log/adapter.log"
fi

# --- 5. missing macfilter: no firewall change, explicit warning -------------
reset_fw
FIX=$TMP/does-not-exist
if run_adapter pridisk-apply >"$OUT" 2>&1; then
	assert_eq "missing: apply is non-fatal" 0 0
	assert_eq "missing: no chain created" 0 "$(chain_count)"
	assert_eq "missing: no INPUT jump" 0 "$(input_count)"
	assert_eq "missing: state unavailable" unavailable "$(state_field mode)"
	assert_file_has "missing: stderr warning" "unavailable" "$OUT"
	assert_file_has "missing: adapter.log ERROR" "UNAVAILABLE" "$ROOT/var/log/adapter.log"
fi
FIX=$TMP/macfilter

# --- 6. macfilter is a directory: same explicit policy ---------------------
reset_fw
FIX=$TMP/macfilter-dir
mkdir -p "$FIX"
run_adapter pridisk-apply >"$OUT" 2>&1
assert_eq "directory: state unavailable" unavailable "$(state_field mode)"
assert_eq "directory: no chain" 0 "$(chain_count)"
FIX=$TMP/macfilter

# --- 7. whitelist with an empty table blocks LAN SMB -----------------------
reset_fw
cat >"$FIX" <<'EOF'
config macfilter 'cfg'
	option pridisk 'whitelist'
EOF
if run_adapter pridisk-apply >"$OUT" 2>&1; then
	assert_eq "empty whitelist: single DROP rule" 1 "$(chain_count)"
	assert_eq "empty whitelist: tail is DROP" '-j DROP' "$(sed -n 1p "$FWDIR/chain.rules")"
	assert_eq "empty whitelist: zero allowed" 0 "$(state_field allowed)"
	assert_file_has "empty whitelist: warning logged" "WARNING" "$ROOT/var/log/adapter.log"
fi

# --- 8. blacklist with an empty table is a no-op ---------------------------
reset_fw
cat >"$FIX" <<'EOF'
config macfilter 'cfg'
	option pridisk 'blacklist'
EOF
if run_adapter pridisk-apply >"$OUT" 2>&1; then
	assert_eq "empty blacklist: single RETURN rule" 1 "$(chain_count)"
	assert_eq "empty blacklist: tail allows" '-j RETURN' "$(sed -n 1p "$FWDIR/chain.rules")"
	assert_eq "empty blacklist: still two jumps" 2 "$(input_count)"
fi

# --- 9. reload twice: no duplicate rules or jumps --------------------------
reset_fw
cat >"$FIX" <<'EOF'
config macfilter 'cfg'
	option pridisk 'whitelist'

config mac 'dev1'
	option mac 'aa:bb:cc:00:00:11'
	option pridisk 'yes'
EOF
run_adapter pridisk-apply >/dev/null 2>&1
run_adapter pridisk-apply >/dev/null 2>&1
assert_eq "idempotent: chain still 2 rules" 2 "$(chain_count)"
assert_eq "idempotent: INPUT still 2 jumps" 2 "$(input_count)"

# --- 10. jump ordering precedes the vendor any-interface ACCEPT ------------
reset_fw
printf '%s\n' \
	'-p tcp -m multiport --dports 22,80,135:139,445 -j ACCEPT' \
	'-i br-lan -j zone_lan' >"$FWDIR/input.rules"
run_adapter pridisk-apply >/dev/null 2>&1
assert_eq "order: tcp jump is rule 1" \
	'-i br-lan -p tcp -m multiport --dports 139,445 -j s8-pridisk' "$(input_nth 1)"
assert_eq "order: udp jump is rule 2" \
	'-i br-lan -p udp -m multiport --dports 137,138 -j s8-pridisk' "$(input_nth 2)"
assert_eq "order: vendor ACCEPT moved below ours" \
	'-p tcp -m multiport --dports 22,80,135:139,445 -j ACCEPT' "$(input_nth 3)"
assert_eq "order: foreign zone rule kept" 4 "$(input_count)"

# --- 11. clear removes only our chain and jumps ----------------------------
run_adapter pridisk-clear >"$OUT" 2>&1
assert_eq "clear: chain deleted" absent "$( [ -f "$FWDIR/chain.exists" ] && echo present || echo absent )"
assert_eq "clear: our jumps gone" 2 "$(input_count)"
assert_eq "clear: vendor ACCEPT survives" \
	'-p tcp -m multiport --dports 22,80,135:139,445 -j ACCEPT' "$(input_nth 1)"
assert_eq "clear: state cleared" cleared "$(state_field mode)"
assert_file_has "clear: reported" "pridisk: cleared" "$OUT"

# --- 12. invalid MAC entries are skipped and logged ------------------------
reset_fw
cat >"$FIX" <<'EOF'
config macfilter 'cfg'
	option pridisk 'whitelist'

config mac 'bad1'
	option mac 'zz:zz:zz:zz:zz:zz'
	option pridisk 'yes'

config mac 'good'
	option mac 'aa:bb:cc:00:00:12'
	option pridisk 'yes'
EOF
run_adapter pridisk-apply >/dev/null 2>&1
assert_eq "invalid mac: only the valid one allowed" 1 "$(state_field allowed)"
assert_eq "invalid mac: no DROP-less chain" 2 "$(chain_count)"
assert_file_has "invalid mac: logged" "invalid mac" "$ROOT/var/log/adapter.log"

# --- 13. dry run prints commands and executes nothing ----------------------
reset_fw
cat >"$FIX" <<'EOF'
config macfilter 'cfg'
	option pridisk 'blacklist'

config mac 'dev1'
	option mac 'aa:bb:cc:00:00:21'
	option pridisk 'no'
EOF
run_adapter -R pridisk-apply >"$OUT" 2>&1
assert_eq "dry-run: no chain state written" 0 "$(chain_count)"
assert_eq "dry-run: no INPUT rule written" 0 "$(input_count)"
assert_file_has "dry-run: prints chain creation" "-N s8-pridisk" "$OUT"
assert_file_has "dry-run: prints drop rule" "-A s8-pridisk -m mac --mac-source aa:bb:cc:00:00:21 -j DROP" "$OUT"
assert_file_has "dry-run: prints tcp jump" "-I INPUT 1 -i br-lan -p tcp" "$OUT"
assert_file_has "dry-run: prints udp jump" "-I INPUT 2 -i br-lan -p udp" "$OUT"
mutations=$(grep -cE '^-((N|A|I|D|X|F)) ' "$CMDLOG" 2>/dev/null || true)
assert_eq "dry-run: mock saw no mutation" 0 "$mutations"

# --- 14. dry-run clear -----------------------------------------------------
reset_fw
run_adapter pridisk-apply >/dev/null 2>&1
before=$(chain_count)
run_adapter -R pridisk-clear >"$OUT" 2>&1
assert_eq "dry-run clear: chain untouched" "$before" "$(chain_count)"
assert_file_has "dry-run clear: prints -X" "-X s8-pridisk" "$OUT"
assert_file_has "dry-run clear: prints jump delete" "-D INPUT" "$OUT"

# --- 15. stock-shaped file ('config mode', every entry 'no') --------------
# Matches the real /etc/config/macfilter: whitelist intent, no device marked
# yes yet.  This must produce an explicit all-LAN DROP, never an exception.
reset_fw
cat >"$FIX" <<'EOF'
config mode 'mode'
	option wan 'blacklist'
	option lan 'blacklist'
	option admin 'blacklist'
	option pridisk 'whitelist'

config mac
	option mac 'b8:c1:11:cd:f7:b2'
	option pridisk 'no'
EOF
run_adapter pridisk-apply >"$OUT" 2>&1
assert_eq "stock shape: mode read from 'config mode'" whitelist "$(state_field mode)"
assert_eq "stock shape: zero allowed" 0 "$(state_field allowed)"
assert_eq "stock shape: one denied" 1 "$(state_field denied)"
assert_eq "stock shape: chain is a single DROP" '-j DROP' "$(sed -n 1p "$FWDIR/chain.rules")"
assert_file_has "stock shape: all-block warning" "WARNING" "$ROOT/var/log/adapter.log"

echo "cases=15 assertions=$CASES failures=$FAILS"
[ "$FAILS" -eq 0 ] || exit 1
exit 0
