#!/bin/sh

# ======================================================== #
#
# Hestia Control Panel Installation Routine
# Automatic OS detection wrapper
# https://www.hestiacp.com/
#
# Currently Supported Operating Systems:
#
# Debian 11, 12
# Ubuntu 20.04, 22.04, 24.04 LTS
# FreeBSD 13, 14, 15
#
# ======================================================== #

# Am I root?
if [ "x$(id -u)" != 'x0' ]; then
	echo 'Error: this script can only be executed by root'
	exit 1
fi

if [ -f /etc/freebsd-version ] || [ "$(uname -s)" = "FreeBSD" ]; then
	command -v bash >/dev/null 2>&1 || pkg install -y bash
    if [ ! -f /bin/bash ] && [ -f /usr/local/bin/bash ]; then
        ln -s /usr/local/bin/bash /bin/bash
    fi
fi

if command -v freebsd-version >/dev/null 2>&1 || [ "$(uname -s)" = "FreeBSD" ]; then
	if getent passwd admin >/dev/null 2>&1 && [ -z "$1" ]; then
		echo "Error: user admin exists on FreeBSD"
		echo
		echo 'Please remove admin user before proceeding.'
		echo 'If you want to do it automatically run installer with -f option:'
		echo "Example: bash $0 --force"
		exit 1
	fi
	if getent group admin >/dev/null 2>&1 && [ -z "$1" ]; then
		echo "Error: group admin exists on FreeBSD"
		echo
		echo 'Please remove admin group before proceeding.'
		echo 'If you want to do it automatically run installer with -f option:'
		echo "Example: bash $0 --force"
		exit 1
	fi
else
	if [ ! -z "$(grep ^admin: /etc/passwd 2>/dev/null)" ] && [ -z "$1" ]; then
	echo "Error: user admin exists"
	echo
	echo 'Please remove admin user before proceeding.'
	echo 'If you want to do it automatically run installer with -f option:'
	echo "Example: bash $0 --force"
		exit 1
	fi
	if [ ! -z "$(grep ^admin: /etc/group 2>/dev/null)" ] && [ -z "$1" ]; then
	echo "Error: group admin exists"
	echo
	echo 'Please remove admin group before proceeding.'
	echo 'If you want to do it automatically run installer with -f option:'
	echo "Example: bash $0 --force"
		exit 1
	fi
fi

# Detect OS
if [ -e "/etc/os-release" ] && [ ! -e "/etc/redhat-release" ]; then
	type=$(grep "^ID=" /etc/os-release | cut -f 2 -d '=')
	if [ "$type" = "ubuntu" ]; then
		# Check if lsb_release is installed
		if [ -e '/usr/bin/lsb_release' ]; then
			release="$(lsb_release -s -r)"
			VERSION='ubuntu'
		else
			echo "lsb_release is currently not installed, please install it:"
			echo "apt-get update && apt-get install lsb-release"
			exit 1
		fi
	elif [ "$type" = "debian" ]; then
		release=$(cat /etc/debian_version | grep -o "[0-9]\{1,2\}" | head -n1)
		VERSION='debian'
	else
		type="NoSupport"
	fi
elif command -v freebsd-version >/dev/null 2>&1 || [ "$(uname -s)" = "FreeBSD" ]; then
	type="freebsd"
	release=$(freebsd-version -u | cut -d'-' -f1 | cut -d'.' -f1)
	full_release=$(freebsd-version -u | cut -d'-' -f1)
	VERSION='freebsd'
	
	case "$release" in
		14)
			echo "FreeBSD 14 detected (version: $full_release)"
			;;
		15)
			echo "FreeBSD 15 detected (version: $full_release)"
			echo "Note: FreeBSD 15 introduces pkg-based base system"
			;;
		*)
			echo "Error: FreeBSD $release is not supported"
			echo "Supported versions: FreeBSD 14, 15"
			exit 1
			;;
	esac
else
	type="NoSupport"
fi

no_support_message() {
	echo "****************************************************"
	echo "Your operating system (OS) is not supported by"
	echo "Hestia Control Panel. Officially supported releases:"
	echo "****************************************************"
	echo "  Debian 11, 12"
	echo "  Ubuntu 22.04, 24.04 LTS"
	echo "  FreeBSD 14, 15"
	echo ""
	exit 1
}

if [ "$type" = "NoSupport" ]; then
	no_support_message
fi

ensure_utf8_locale() {
	if [ "$type" = "freebsd" ]; then
		return
	fi
	
	local locale_file="/etc/default/locale"

	if locale | grep -qi 'utf-8'; then
		return
	fi

	echo "[ * ] Enabling UTF-8 locale support via C.UTF-8"
	if ! locale-gen C.UTF-8; then
		echo "[ ! ] Failed to generate C.UTF-8 locale. Leaving existing locale untouched."
		return
	fi

	if ! update-locale LANG=C.UTF-8; then
		echo "[ ! ] Failed to update LANG in $locale_file. Leaving existing locale untouched."
		return
	fi

	export LANG=C.UTF-8
}

ensure_utf8_locale

check_wget_curl() {
	# Check wget
	if [ -e '/usr/bin/wget' ] || [ -e '/usr/local/bin/wget' ]; then
		wget -q https://raw.githubusercontent.com/hestiacp/hestiacp/release/install/hst-install-$type.sh -O hst-install-$type.sh
		if [ "$?" -eq '0' ]; then
			bash hst-install-$type.sh "$@"
			exit
		else
			echo "Error: hst-install-$type.sh download failed."
			exit 1
		fi
	fi

	# Check curl
	if [ -e '/usr/bin/curl' ] || [ -e '/usr/local/bin/curl' ]; then
		curl -s -O https://raw.githubusercontent.com/hestiacp/hestiacp/release/install/hst-install-$type.sh
		if [ "$?" -eq '0' ]; then
			bash hst-install-$type.sh "$@"
			exit
		else
			echo "Error: hst-install-$type.sh download failed."
			exit 1
		fi
	fi
	
	# FreeBSD: 使用 fetch
	if [ "$type" = "freebsd" ]; then
		fetch -o "hst-install-$type.sh" "https://raw.githubusercontent.com/hestiacn/hestiacp-freebsd/main/install/hst-install-$type.sh"
		if [ "$?" -eq '0' ]; then
			bash hst-install-$type.sh "$@"
			exit
		else
			echo "Error: hst-install-$type.sh download failed."
			exit 1
		fi
	fi
}

# Check for supported operating system
if [ "$type" = "freebsd" ]; then
	case "$release" in
		14|15) check_wget_curl "$@" ;;
		*)        no_support_message ;;
	esac
else
	case "$release" in
		11|12|13|22.04|24.04|26.04) check_wget_curl "$@" ;;
		*)                 no_support_message ;;
	esac
fi

exit
