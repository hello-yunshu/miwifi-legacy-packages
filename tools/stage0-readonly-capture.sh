#!/bin/sh
# Read-only MiWiFi stage 0 snapshot. Prints to stdout; writes no device files.

export LC_ALL=C

section() {
	printf '\n===== %s =====\n' "$1"
}

section identity
date 2>&1
uname -a 2>&1
uptime 2>&1
for f in /etc/openwrt_release /etc/miwifi_release /proc/version /proc/uptime; do
	if [ -r "$f" ]; then
		printf '\n--- %s ---\n' "$f"
		cat "$f" 2>&1
	fi
done

section storage
mount 2>&1
df -k 2>&1

section listeners
netstat -lntup 2>&1

section client_mac_mapping
client_ip=${1:-${SSH_CLIENT%% *}}
if [ -n "$client_ip" ]; then
	printf 'ssh_client_ip=%s\n' "$client_ip"
	if [ -r /proc/net/arp ]; then
		awk -v ip="$client_ip" '$1 == ip { print }' /proc/net/arp
	fi
fi

section target_processes
for commfile in /proc/[0-9]*/comm; do
	[ -r "$commfile" ] || continue
	comm=$(cat "$commfile" 2>/dev/null)
	case "$comm" in
		smbd|samba-s5d|nmbd|dropbear|curl|minidlna|minidlnad|lighttpd|nginx|sysapihttpd|taskmonitor|taskmonitorServer|supervisord)
			pid=${commfile#/proc/}
			pid=${pid%/comm}
			printf 'pid=%s comm=%s exe=' "$pid" "$comm"
			readlink "/proc/$pid/exe" 2>/dev/null || printf 'unavailable'
			printf '\n'
			case "$comm" in
				curl|taskmonitor|taskmonitorServer|supervisord) ;;
				*)
					if [ -r "/proc/$pid/cmdline" ]; then
						printf '  argv='
						tr '\000' ' ' < "/proc/$pid/cmdline" 2>/dev/null
						printf '\n'
					fi
					;;
			esac
			if [ -r "/proc/$pid/maps" ]; then
				awk '$NF ~ /^\// { print $NF }' "/proc/$pid/maps" 2>/dev/null | sort -u | sed 's/^/  map: /'
			fi
			;;
	esac
done

section software_versions
for item in \
	'/usr/sbin/smbd:-V' \
	'/usr/sbin/nmbd:-V' \
	'/usr/sbin/dropbear:-V' \
	'/usr/bin/curl:--version' \
	'/usr/sbin/minidlnad:-V' \
	'/usr/sbin/lighttpd:-v'; do
	bin=${item%%:*}
	arg=${item#*:}
	if [ -x "$bin" ]; then
		printf '\n--- %s %s ---\n' "$bin" "$arg"
		"$bin" "$arg" 2>&1 | head -n 12
	fi
done

if [ -x /userdisk/data/.dev/live/samba/current/sbin/samba-s5d ]; then
	section active_samba_version
	LD_LIBRARY_PATH=/userdisk/data/.dev/live/samba/current/lib:/userdisk/data/.dev/live/samba/current/lib/private \
		/userdisk/data/.dev/live/samba/current/sbin/samba-s5d -V 2>&1
fi

taskmonitor_tool=$(command -v taskmonitorTool 2>/dev/null)
if [ -n "$taskmonitor_tool" ] && [ -x "$taskmonitor_tool" ]; then
	section taskmonitor_list
	"$taskmonitor_tool" -t list 2>&1 | head -n 100
fi
if [ -r /tmp/taskmonitor/taskmonitor.conf ] && command -v strings >/dev/null 2>&1; then
	section taskmonitor_smb_entries
	strings /tmp/taskmonitor/taskmonitor.conf 2>/dev/null |
		grep -Ei 'samba|smbd|nmbd|dropbear|curl|minidlna|lighttpd' |
		head -n 100
fi

if [ -L /userdisk/data/.dev/live/samba/current ] || [ -d /userdisk/data/.dev/live/samba/current ]; then
	section smb_current_release
	ls -ld /userdisk/data/.dev/live/samba/current 2>&1
	for f in /userdisk/data/.dev/live/samba/current/VERSION /userdisk/data/.dev/live/samba/current/MANIFEST.md5; do
		if [ -r "$f" ]; then
			printf '\n--- %s ---\n' "$f"
			cat "$f" 2>&1
		fi
	done
	if [ -r /userdisk/data/.dev/live/samba/current/MANIFEST.md5 ]; then
		(cd /userdisk/data/.dev/live/samba/current && md5sum -c MANIFEST.md5) 2>&1
	fi
	for f in /userdisk/data/.dev/live/samba/current/sbin/smbd /userdisk/data/.dev/live/samba/current/sbin/samba-s5d; do
		[ -f "$f" ] && md5sum "$f" 2>&1
	done
fi

section smb_config_hashes
md5sum \
	/userdisk/data/.dev/live/samba/current/sbin/samba-s5d \
	/userdisk/data/.dev/live/samba/current/etc/smb.conf \
	/var/etc/smb.conf \
	/etc/config/macfilter \
	/etc/init.d/samba \
	/etc/init.d/samba.vendor \
	/etc/hotplug.d/block/80-sambaAndDlna 2>&1

section macfilter_policy
if command -v uci >/dev/null 2>&1; then
	uci show macfilter 2>&1
else
	cat /etc/config/macfilter 2>&1
fi

section firewall_acl
iptables -vnL INPUT --line-numbers 2>&1
iptables -vnL s8-diskacl --line-numbers 2>&1
iptables -S 2>&1 | grep -E 's8-diskacl|s8-guest|br-guest.*(139|445)|139,445|137,138'
if command -v ip6tables >/dev/null 2>&1; then
	section firewall_ipv6_input
	ip6tables -vnL INPUT --line-numbers 2>&1
fi

section diskacl_cron
for f in /etc/crontabs/root /etc/crontabs/roothuXWkn; do
	if [ -r "$f" ]; then
		grep -nEi 'diskacl|samba|s8' "$f" 2>/dev/null
	fi
done

section homes_setting
if command -v uci >/dev/null 2>&1; then
	uci -q get 'samba.@samba[0].homes' 2>&1
fi
for f in /userdisk/data/.dev/live/samba/current/etc/smb.conf /var/etc/smb.conf; do
	[ -r "$f" ] || continue
	printf '\n--- homes section: %s ---\n' "$f"
	awk '
		/^\[homes\][[:space:]]*$/ { in_homes=1; print; next }
		/^\[/ && in_homes { exit }
		in_homes { print }
	' "$f"
done
if [ -x /userdisk/data/.dev/live/samba/current/bin/pdbedit ]; then
	section smb_passdb_users
	ls -l /userdisk/data/.dev/live/samba/current/var/private/smbpasswd 2>&1
	LD_LIBRARY_PATH=/userdisk/data/.dev/live/samba/current/lib:/userdisk/data/.dev/live/samba/current/lib/private \
		/userdisk/data/.dev/live/samba/current/bin/pdbedit \
		-s /userdisk/data/.dev/live/samba/current/etc/smb.conf -L 2>&1
fi
section unix_home_accounts
awk -F: '$6 != "" && $6 != "/dev/null" { printf "%s uid=%s home=%s\n", $1, $3, $6 }' /etc/passwd 2>&1

section startup_entry_names
for d in /etc/init.d /etc/rc.d /etc/hotplug.d /etc/cron.d /etc/crontabs; do
	if [ -d "$d" ]; then
		find "$d" -maxdepth 2 -type f 2>/dev/null |
			grep -Ei 'samba|smb|dropbear|curl|mini.?dlna|lighttpd|taskmonitor|cron' 2>/dev/null
	fi
done

section curl_script_reference_paths
for d in /etc/init.d /etc/rc.d /etc/hotplug.d /userdisk/app; do
	[ -d "$d" ] || continue
	find "$d" -type f 2>/dev/null | while IFS= read -r f; do
		case "$f" in
			*.sh|*.lua|*.conf|*/rc.local)
				if grep -I -qi 'curl' "$f" 2>/dev/null; then
					printf '%s: contains curl reference (line contents omitted)\n' "$f"
				fi
				;;
		esac
	done
done
if [ -d /userdisk/data ]; then
	find /userdisk/data -maxdepth 3 -type f \
		\( -name '*.sh' -o -name '*.lua' -o -name '*.py' \) 2>/dev/null |
		while IFS= read -r f; do
			if grep -I -qi 'curl' "$f" 2>/dev/null; then
				printf '%s: contains curl reference (line contents omitted)\n' "$f"
			fi
		done
fi

section end
printf 'Capture complete. Review output locally; it may contain LAN/MAC addresses and daemon arguments.\n'
