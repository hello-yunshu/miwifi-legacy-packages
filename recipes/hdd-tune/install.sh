#!/bin/sh
# Install the HDD tuning hook on the device.
#
#   sh install.sh [host]        deploy + enable
#   sh install.sh [host] revert disable and restore the sysfs defaults
#
# Files (repo -> device):
#   hdd-tune.sh    -> /userdisk/data/.yunshu/live/tools/hdd-tune.sh
#   smart-check.sh -> /userdisk/data/.yunshu/live/tools/smart-check.sh
#   cron.smart     -> appended to /etc/crontabs/root (once)
#   hdd-tune.init  -> /etc/init.d/hdd-tune (enabled as S99)
#   85-hdd-tune    -> /etc/hotplug.d/block/85-hdd-tune
set -eu

host=${1:-root@192.168.3.2}
here=$(cd "$(dirname "$0")" && pwd)
tool=/userdisk/data/.yunshu/live/tools/hdd-tune.sh
smart=/userdisk/data/.yunshu/live/tools/smart-check.sh

case "${2:-}" in
revert)
	ssh "$host" "/etc/init.d/hdd-tune disable >/dev/null 2>&1
		rm -f /etc/init.d/hdd-tune /etc/hotplug.d/block/85-hdd-tune
		[ -x $tool ] && $tool revert
		rm -f $tool $smart
		sed -i '/smart-check.sh/d;/SMART self-test (hdd-tune)/d;/tmpfs guard (hdd-tune)/d;/messages\.old/d' /etc/crontabs/root
		/etc/init.d/cron restart >/dev/null 2>&1
		echo reverted"
	exit 0
	;;
esac

sid() { ssh "$host" 'cat > '"$1"; }

ssh "$host" "mkdir -p /userdisk/data/.yunshu/live/tools"
sid "$tool" <"$here/hdd-tune.sh"
sid "$smart" <"$here/smart-check.sh"
sid /etc/init.d/hdd-tune <"$here/hdd-tune.init"
sid /etc/hotplug.d/block/85-hdd-tune <"$here/85-hdd-tune"

if ! ssh "$host" "grep -q 'smart-check.sh' /etc/crontabs/root"; then
	ssh "$host" "cat >> /etc/crontabs/root" <"$here/cron.smart"
	ssh "$host" "/etc/init.d/cron restart >/dev/null 2>&1"
fi

if ! ssh "$host" "grep -q 'messages.old' /etc/crontabs/root"; then
	ssh "$host" "cat >> /etc/crontabs/root" <"$here/cron.tmpfs"
	ssh "$host" "/etc/init.d/cron restart >/dev/null 2>&1"
fi

ssh "$host" "chmod 755 $tool $smart /etc/init.d/hdd-tune /etc/hotplug.d/block/85-hdd-tune
	/etc/init.d/hdd-tune enable >/dev/null
	$tool apply
	$tool status"
