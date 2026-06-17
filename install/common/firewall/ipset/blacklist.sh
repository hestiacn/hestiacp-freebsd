#!/bin/bash
# Script and blacklist urls partially taken from:
# https://github.com/trick77/nftables-blacklist/raw/refs/heads/master/nftables-blacklist.conf
#

if [ -f /etc/redhat-release ] || [ -f /etc/debian_version ]; then
	OS="linux"
else
	OS="freebsd"
fi

BLACKLISTS=(
	"https://check.torproject.org/cgi-bin/TorBulkExitList.py?ip=1.1.1.1"
	"https://danger.rulez.sk/projects/bruteforceblocker/blist.php"
	"https://www.spamhaus.org/drop/drop.lasso"
	"https://cinsscore.com/list/ci-badguys.txt"
	"https://lists.blocklist.de/lists/all.txt"
	"https://blocklist.greensnow.co/greensnow.txt"
	"https://iplists.firehol.org/files/firehol_level1.netset"
	"https://iplists.firehol.org/files/stopforumspam_7d.ipset"
	"https://raw.githubusercontent.com/borestad/blocklist-abuseipdb/refs/heads/main/abuseipdb-s100-30d.ipv4"
)

IP_BLACKLIST_TMP=$(mktemp)
for i in "${BLACKLISTS[@]}"; do
	IP_TMP=$(mktemp)
	
	if [ "$OS" = "freebsd" ]; then
		HTTP_RC=$(fetch -o "$IP_TMP" -T 10 "$i" 2>/dev/null && echo "200" || echo "000")
	else
		HTTP_RC=$(curl -L --connect-timeout 10 --max-time 10 -o "$IP_TMP" -s -w "%{http_code}" "$i")
	fi
	
	if [ "$HTTP_RC" = "200" ] || [ "$HTTP_RC" = "302" ] || [ "$HTTP_RC" = "0" ]; then
		if [ "$OS" = "freebsd" ]; then
			grep -E -o '(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)(/[0-9]{1,2})?' "$IP_TMP" >> "$IP_BLACKLIST_TMP"
		else
			grep -Po '(?:\d{1,3}\.){3}\d{1,3}(?:/\d{1,2})?' "$IP_TMP" | sed -E 's/^0*([0-9]+)\.0*([0-9]+)\.0*([0-9]+)\.0*([0-9]+)(.*)$/\1.\2.\3.\4\5/' >> "$IP_BLACKLIST_TMP"
		fi
	elif [ "$HTTP_RC" = "503" ]; then
		echo >&2 -e "\\nUnavailable (${HTTP_RC}): $i"
	else
		echo >&2 -e "\\nWarning: download returned HTTP response code $HTTP_RC for URL $i"
	fi
	rm -f "$IP_TMP"
done

sed -E -e '/^(0\.0\.0\.0|10\.|127\.|172\.1[6-9]\.|172\.2[0-9]\.|172\.3[0-1]\.|192\.168\.|22[4-9]\.|23[0-9]\.)/d' "$IP_BLACKLIST_TMP" | sort -Vu > /usr/local/hestia/data/firewall/ipset/blacklist.txt
rm -f "$IP_BLACKLIST_TMP"
