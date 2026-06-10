#!/bin/sh
# Clean installation bootstrap for development purposes only
# Usage:    ./hst_bootstrap_install.sh [fork] [branch] [os] [repo]
# Example:  ./hst_bootstrap_install.sh hestiacn main freebsd

# Define variables with robust default values (Fallback Mechanism)
fork=${1:-hestiacn}
branch=${2:-main}
os=${3:-freebsd}
repo=${4:-hestiacp-freebsd}

if [ -f /etc/freebsd-version ] || [ "$(uname -s)" = "FreeBSD" ]; then
	echo "[ * ] FreeBSD detected. Instantly aligning Linux bash compatibility layer..."
	command -v bash >/dev/null 2>&1 || pkg install -y bash
	[ ! -f /bin/bash ] && ln -s /usr/local/bin/bash /bin/bash
	[ ! -d /usr/bin ] && mkdir -p /usr/bin
	[ ! -f /usr/bin/bash ] && ln -s /usr/local/bin/bash /usr/bin/bash
	export SHELL=/usr/local/bin/bash
fi

download_bootstrap_file() {
	local target_url="$1"
	local target_name="$2"
	
	echo "[ * ] Downloading $target_name from GitHub cluster..."
	if command -v wget >/dev/null 2>&1; then
		wget -q "$target_url" -O "$target_name"
	elif command -v fetch >/dev/null 2>&1; then
		fetch -q -o "$target_name" "$target_url"
	else
		echo >&2 "Error: Neither wget nor fetch is available on this environment."
		exit 1
	fi
	
	if [ ! -s "$target_name" ]; then
		echo >&2 "Error: Download failed or empty payload returned for $target_name."
		exit 1
	fi
}

# 动态组装下载链接并开始执行自愈抓取
download_bootstrap_file "https://raw.githubusercontent.com/$fork/$repo/$branch/install/hst-install-$os.sh" "hst-install-$os.sh"
download_bootstrap_file "https://raw.githubusercontent.com/$fork/$repo/$branch/src/hst_autocompile.sh" "hst_autocompile.sh"

# Execute compiler and build hestia core package
chmod +x hst_autocompile.sh
./hst_autocompile.sh --hestia "$branch" no

# Execute Hestia Control Panel installer
if [ "$os" = "freebsd" ] || [ "$(uname -s)" = "FreeBSD" ]; then
    PACKAGE_DIR="/tmp/hestiacp-src/pkg"
    INSTALL_CMD="bash hst-install-$os.sh -f -y no -e 'admin@test.local' -p 'P@ssw0rd' \
        -s \"hestia-$branch-$os.test.local\" --with-pkgs $PACKAGE_DIR"
elif [ -f "/etc/redhat-release" ]; then
    PACKAGE_DIR="/tmp/hestiacp-src/rpm"
    INSTALL_CMD="bash hst-install-$os.sh -f -y no -e 'admin@test.local' -p 'P@ssw0rd' \
        -s \"hestia-$branch-$os.test.local\" --with-rpms $PACKAGE_DIR"
else
    PACKAGE_DIR="/tmp/hestiacp-src/deb"
    INSTALL_CMD="bash hst-install-$os.sh -f -y no -e 'admin@test.local' -p 'P@ssw0rd' \
        -s \"hestia-$branch-$os.test.local\" --with-debs $PACKAGE_DIR"
fi

if [ ! -d "$PACKAGE_DIR" ]; then
    echo "[ ! ] Error: Package verification failed! Directory $PACKAGE_DIR not found!"
    ls -la /tmp/hestiacp-src/ 2>/dev/null
    exit 1
fi

# Execute Hestia Control Panel installer via clean eval stream
eval "$INSTALL_CMD"

echo "[ * ] Bootstrap installation completed successfully!"
