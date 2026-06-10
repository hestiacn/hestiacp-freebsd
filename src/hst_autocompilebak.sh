#!/bin/sh

# set -e
# Autocompile Script for HestiaCP package Files.
# For building from local source folder use "~localsrc" keyword as hesia branch name,
#   and the script will not try to download the arhive from github, since '~' char is
#   not accepted in branch name.
# Compile but dont install -> ./hst_autocompile.sh --hestia --noinstall --keepbuild '~localsrc'
# Compile and install -> ./hst_autocompile.sh --hestia --install '~localsrc'

# Clear previous screen output
clear

# Define download function
download_file() {
	local url=$1
	local destination=$2
	local force=$3

	[ "$HESTIA_DEBUG" ] && echo >&2 DEBUG: Downloading file "$url" to "$destination"

	local dstopt=""
	local is_archive=""
	local filename=""

	if [ ! -z "$(echo "$url" | grep -E "\.(gz|gzip|bz2|zip|xz)$")" ]; then
		dstopt="--directory-prefix=$ARCHIVE_DIR"
		is_archive="true"
		filename="${url##*/}"
		if [ -z "$filename" ]; then
			echo >&2 "[!] No filename was found in url, exiting ($url)"
			exit 1
		fi
		if [ ! -z "$force" ] && [ -f "$ARCHIVE_DIR/$filename" ]; then
			rm -f "$ARCHIVE_DIR/$filename"
		fi
	elif [ ! -z "$destination" ]; then
		dstopt="-O $destination"
	fi
	
	if [ -f "$ARCHIVE_DIR/$filename" ] && [ "$is_archive" = "true" ]; then
		tar -tzf "$ARCHIVE_DIR/$filename" > /dev/null 2>&1
		if [ $? -ne 0 ]; then
			echo >&2 "[!] Archive $ARCHIVE_DIR/$filename is corrupted, redownloading"
			rm -f "$ARCHIVE_DIR/$filename"
		fi
	fi

	if [ ! -f "$ARCHIVE_DIR/$filename" ]; then
		[ "$HESTIA_DEBUG" ] && echo >&2 DEBUG: Fetching $url ...
		if command -v wget >/dev/null 2>&1; then
			wget "$url" -q $dstopt --show-progress --progress=bar:force --limit-rate=3m
		elif command -v fetch >/dev/null 2>&1; then
			if [ "$is_archive" = "true" ]; then
				fetch -q -o "$ARCHIVE_DIR/$filename" "$url"
			elif [ ! -z "$destination" ]; then
				fetch -q -o "$destination" "$url"
			fi
		else
			echo >&2 "[!] Error: Neither wget nor fetch is available in this VM sandboxing environment."
			exit 1
		fi

		if [ $? -ne 0 ]; then
			echo >&2 "[!] Archive $ARCHIVE_DIR/$filename is corrupted and exit script"
			rm -f "$ARCHIVE_DIR/$filename"
			exit 1
		fi
	fi

	if [ ! -z "$destination" ] && [ "$is_archive" = "true" ]; then
		if [ "$destination" = "-" ]; then
			cat "$ARCHIVE_DIR/$filename"
		elif [ -d "$(dirname "$destination")" ]; then
			cp "$ARCHIVE_DIR/$filename" "$destination"
		fi
	fi
}

get_branch_file() {
	local filename=$1
	local destination=$2
	[ "$HESTIA_DEBUG" ] && echo >&2 DEBUG: Get branch file "$filename" to "$destination"
	if [ "$use_src_folder" = 'true' ]; then
		if [ -z "$destination" ]; then
			[ "$HESTIA_DEBUG" ] && echo >&2 DEBUG: cp -f "$SRC_DIR/$filename" ./
			cp -f "$SRC_DIR/$filename" ./
		else
			[ "$HESTIA_DEBUG" ] && echo >&2 DEBUG: cp -f "$SRC_DIR/$filename" "$destination"
			cp -f "$SRC_DIR/$filename" "$destination"
		fi
	else
		download_file "https://raw.githubusercontent.com/$REPO/$branch/$filename" "$destination" "$3"
	fi
}

usage() {
	echo "Usage:"
	echo "    $0 (--all|--hestia|--nginx|--php|--web-terminal) [options] [branch] [Y]"
	echo ""
	echo "    --all           Build all hestia packages."
	echo "    --hestia        Build only the Control Panel package."
	echo "    --nginx         Build only the backend nginx engine package."
	echo "    --php           Build only the backend php engine package"
	echo "    --web-terminal  Build only the backend web terminal websocket package"
	echo "  Options:"
	echo "    --install       Install generated packages"
	echo "    --keepbuild     Don't delete downloaded source and build folders"
	echo "    --cross         Compile hestia package for both AMD64 and ARM64"
	echo "    --debug         Debug mode"
	echo ""
	echo "For automated builds and installations, you may specify the branch"
	echo "after one of the above flags. To install the packages, specify 'Y'"
	echo "following the branch name."
	echo ""
	echo "Example: bash hst_autocompile.sh --hestia develop Y"
	echo "This would install a Hestia Control Panel package compiled with the"
	echo "develop branch code."
}

# Set compiling directory
REPO='hestiacn/hestiacp-freebsd'
BUILD_DIR='/tmp/hestiacp-src'
INSTALL_DIR='/usr/local/hestia'
SRC_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ARCHIVE_DIR="$SRC_DIR/src/archive"

if command -v arch >/dev/null 2>&1; then
	architecture="$(arch)"
else
	architecture="$(uname -p)"
fi

if [ "$architecture" = 'aarch64' ] || [ "$architecture" = 'arm64' ]; then
	BUILD_ARCH='arm64'
else
	BUILD_ARCH='amd64'
fi

RPM_DIR="$BUILD_DIR/rpm"
DEB_DIR="$BUILD_DIR/deb"
PKG_DIR="$BUILD_DIR/pkg"

if [ -f '/etc/redhat-release' ]; then
	BUILD_RPM=true
	BUILD_DEB=false
	BUILD_PKG=false
	OSTYPE='rhel'
elif command -v freebsd-version >/dev/null 2>&1 || [ "$(uname -s)" = "FreeBSD" ]; then
	BUILD_RPM=false
	BUILD_DEB=false
	BUILD_PKG=true
	OSTYPE='freebsd'
else
	BUILD_RPM=false
	BUILD_DEB=true
	BUILD_PKG=false
	OSTYPE='debian'
fi

if [ "$BUILD_PKG" = "true" ]; then
	mkdir -p "$PKG_DIR" "$ARCHIVE_DIR"
fi

# Set packages to compile
for i in "$@"; do
	case "$i" in
		--all)
			NGINX_B='true'
			PHP_B='true'
			WEB_TERMINAL_B='true'
			HESTIA_B='true'
			;;
		--nginx)
			NGINX_B='true'
			;;
		--php)
			PHP_B='true'
			;;
		--web-terminal)
			WEB_TERMINAL_B='true'
			;;
		--hestia)
			HESTIA_B='true'
			;;
		--debug)
			HESTIA_DEBUG='true'
			;;
		--install | Y)
			install='true'
			;;
		--noinstall | N)
			install='false'
			;;
		--keepbuild)
			KEEPBUILD='true'
			;;
		--cross)
			CROSS='true'
			;;
		--help | -h)
			usage
			exit 1
			;;
		--dontinstalldeps)
			dontinstalldeps='true'
			;;
		*)
			branch="$i"
			;;
	esac
done

if [ $# -eq 0 ]; then
	usage
	exit 1
fi

# Clear previous screen output
clear

# Set command variables
if [ -z "$branch" ]; then
	echo -n "Please enter the name of the branch to build from (e.g. main): "
	read branch
fi

if echo "$branch" | grep -q '^~localsrc'; then
	branch=$(echo "$branch" | sed 's/^~//')
	use_src_folder='true'
else
	use_src_folder='false'
fi

if [ -z "$install" ]; then
	echo -n 'Would you like to install the compiled packages? [y/N] '
	read install
fi

# Set Version for compiling
if [ -f "$SRC_DIR/src/deb/hestia/control" ] && [ "$use_src_folder" = 'true' ]; then
	BUILD_VER=$(grep "Version:" "$SRC_DIR/src/deb/hestia/control" | cut -d' ' -f2)
	if [ "$OSTYPE" != 'freebsd' ]; then
		NGINX_V=$(grep "Version:" "$SRC_DIR/src/deb/nginx/control" | cut -d' ' -f2)
		PHP_V=$(grep "Version:" "$SRC_DIR/src/deb/php/control" | cut -d' ' -f2)
		WEB_TERMINAL_V=$(grep "Version:" "$SRC_DIR/src/deb/web-terminal/control" | cut -d' ' -f2)
	else
		NGINX_V=$(grep "version:" "$SRC_DIR/src/pkg/nginx/+MANIFEST" 2>/dev/null | head -1 | cut -d' ' -f2)
		PHP_V=$(grep "version:" "$SRC_DIR/src/pkg/php/+MANIFEST" 2>/dev/null | head -1 | cut -d' ' -f2)
		WEB_TERMINAL_V=$(grep "version:" "$SRC_DIR/src/pkg/web-terminal/+MANIFEST" 2>/dev/null | head -1 | cut -d' ' -f2)
	fi
else
	BUILD_VER=$(curl -s "https://raw.githubusercontent.com/$REPO/$branch/src/deb/hestia/control" | grep "Version:" | cut -d' ' -f2)
	if [ "$OSTYPE" != 'freebsd' ]; then
		NGINX_V=$(curl -s "https://raw.githubusercontent.com/$REPO/$branch/src/deb/nginx/control" | grep "Version:" | cut -d' ' -f2)
		PHP_V=$(curl -s "https://raw.githubusercontent.com/$REPO/$branch/src/deb/php/control" | grep "Version:" | cut -d' ' -f2)
		WEB_TERMINAL_V=$(curl -s "https://raw.githubusercontent.com/$REPO/$branch/src/deb/web-terminal/control" | grep "Version:" | cut -d' ' -f2)
	else
		NGINX_V=$(curl -s "https://raw.githubusercontent.com/$REPO/$branch/src/pkg/nginx/+MANIFEST" | grep "version:" | head -1 | cut -d' ' -f2)
		PHP_V=$(curl -s "https://raw.githubusercontent.com/$REPO/$branch/src/pkg/php/+MANIFEST" | grep "version:" | head -1 | cut -d' ' -f2)
		WEB_TERMINAL_V=$(curl -s "https://raw.githubusercontent.com/$REPO/$branch/src/pkg/web-terminal/+MANIFEST" | grep "version:" | head -1 | cut -d' ' -f2)
	fi
fi

if [ -z "$BUILD_VER" ]; then
	echo "Error: Branch invalid, could not detect version"
	exit 1
fi

OPENSSL_V='3.4.4'
PCRE_V='10.47'
ZLIB_V='1.3.2'

# 根据操作系统显示不同的版本信息
if [ "$OSTYPE" = 'freebsd' ]; then
	echo "Build version $BUILD_VER for FreeBSD"
	echo "Nginx version: $NGINX_V, PHP version: $PHP_V, Web Terminal version: $WEB_TERMINAL_V"
	HESTIA_V="${BUILD_VER}_freebsd_${BUILD_ARCH}"
else
	echo "Build version $BUILD_VER, with Nginx version $NGINX_V, PHP version $PHP_V and Web Terminal version $WEB_TERMINAL_V"
	HESTIA_V="${BUILD_VER}_${BUILD_ARCH}"
fi

# Create build directories
if [ "$KEEPBUILD" != 'true' ]; then
	rm -rf "$BUILD_DIR"
fi
mkdir -p "$BUILD_DIR" "$DEB_DIR" "$RPM_DIR" "$PKG_DIR" "$ARCHIVE_DIR"

# Define a timestamp function
timestamp() {
	date +%s
}

# 安装编译依赖
if [ "$dontinstalldeps" != 'true' ]; then
	if [ "$OSTYPE" = 'freebsd' ]; then
		SOFTWARE='tar git curl gmake autoconf automake libtool pkgconf openssl ca_root_nss pcre2 npm node'
		
		echo "Updating FreeBSD package repository..."
		pkg update -f
		echo "Installing FreeBSD build dependencies..."
		pkg install -y $SOFTWARE
		
		NODE_VERSION=$(node -v 2>/dev/null | cut -d'v' -f2 | cut -d'.' -f1)
		if [ -z "$NODE_VERSION" ] || [ "$NODE_VERSION" -lt 24 ]; then
			echo "[ ! ] Node.js version 24+ is required for Hestia Vhost compilation. Forcing update..."
			pkg install -y node
		fi
		
		NUM_CPUS=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
		
	elif [ "$OSTYPE" = 'rhel' ]; then
		SOFTWARE='wget tar git curl mock rpm-build rpmdevtools'
		echo "Updating system DNF repositories..."
		dnf install -y -q 'dnf-command(config-manager)'
		dnf install -y -q dnf-plugins-core epel-release
		dnf config-manager --set-enabled powertools > /dev/null 2>&1
		dnf config-manager --set-enabled PowerTools > /dev/null 2>&1
		dnf config-manager --set-enabled crb > /dev/null 2>&1
		dnf upgrade -y -q
		echo "Installing dependencies for compilation..."
		dnf install -y -q $SOFTWARE
		rpmdev-setuptree
		if [ ! -d "/var/lib/mock/rocky+epel-9-$(arch)-bootstrap" ]; then
			mock -r rocky+epel-9-$(arch) --init
		fi
		NUM_CPUS=$(grep "^cpu cores" /proc/cpuinfo | uniq | awk '{print $4}')
	else
		SOFTWARE='wget tar git curl build-essential libxml2-dev libz-dev libzip-dev libgmp-dev libcurl4-gnutls-dev unzip openssl libssl-dev pkg-config libsqlite3-dev libonig-dev rpm lsb-release'
		echo "Updating system APT repositories..."
		apt-get -qq update > /dev/null 2>&1
		echo "Installing dependencies for compilation..."
		apt-get -qq install -y $SOFTWARE > /dev/null 2>&1

		apt="/etc/apt/sources.list.d"
		codename="$(lsb_release -s -c)"

		if ! command -v node >/dev/null 2>&1; then
			curl -fsSL https://deb.nodesource.com/setup_24.x | bash -
		fi

		echo "Installing Node.js..."
		apt-get -qq update > /dev/null 2>&1
		apt -qq install -y nodejs > /dev/null 2>&1
		nodejs_version=$(node -v | cut -f1 -d'.' | sed 's/v//g')

		if [ "$nodejs_version" -lt 18 ]; then
			echo "Requires Node.js 18.x or higher"
			exit 1
		fi

		if [ "$BUILD_ARCH" = "amd64" ]; then
			if [ ! -L /usr/local/include/curl ]; then
				ln -s /usr/include/x86_64-linux-gnu/curl /usr/local/include/curl
			fi
		fi
		NUM_CPUS=$(grep "^cpu cores" /proc/cpuinfo | uniq | awk '{print $4}')
	fi
fi

if [ "$HESTIA_DEBUG" ]; then
	if [ "$OSTYPE" = 'freebsd' ]; then
		echo "OS type          : FreeBSD"
	elif [ "$OSTYPE" = 'rhel' ]; then
		echo "OS type          : RHEL / Rocky Linux / AlmaLinux / EuroLinux"
	else
		echo "OS type          : Debian / Ubuntu"
	fi
	echo "Branch           : $branch"
	echo "Install          : $install"
	echo "Build PKG        : $BUILD_PKG"
	echo "Build RPM        : $BUILD_RPM"
	echo "Build DEB        : $BUILD_DEB"
	echo "Hestia version   : $BUILD_VER"
	echo "Nginx version    : $NGINX_V"
	echo "PHP version      : $PHP_V"
	echo "Web Term version : $WEB_TERMINAL_V"
	echo "Architecture     : $BUILD_ARCH"
	echo "Debug mode       : $HESTIA_DEBUG"
	echo "Source directory : $SRC_DIR"
fi

# Generate Links for sourcecode
HESTIA_ARCHIVE_LINK="https://github.com/$REPO/archive/$branch.tar.gz"

if echo "$NGINX_V" | grep -q '-'; then
	NGINX='https://nginx.org/download/nginx-'$(echo "$NGINX_V" | cut -d"-" -f1)'.tar.gz'
else
	NGINX='https://nginx.org/download/nginx-'$(echo "$NGINX_V" | cut -d"~" -f1)'.tar.gz'
fi

OPENSSL='https://www.openssl.org/source/openssl-'$OPENSSL_V'.tar.gz'
PCRE='https://github.com/PCRE2Project/pcre2/releases/download/pcre2-'$PCRE_V'/pcre2-'$PCRE_V'.tar.gz'
ZLIB='https://github.com/madler/zlib/archive/refs/tags/v'$ZLIB_V'.tar.gz'

if echo "$PHP_V" | grep -q '-'; then
	PHP='http://de2.php.net/distributions/php-'$(echo "$PHP_V" | cut -d"-" -f1)'.tar.gz'
else
	PHP='http://de2.php.net/distributions/php-'$(echo "$PHP_V" | cut -d"~" -f1)'.tar.gz'
fi

branch_dash=$(echo "$branch" | sed 's/\//-/g')

#################################################################################
# Building hestia-nginx
#################################################################################

if [ "$NGINX_B" = "true" ]; then
	echo "Building hestia-nginx package..."
	if [ "$CROSS" = "true" ]; then
		echo "Cross compile not supported for hestia-nginx, hestia-php or hestia-web-terminal"
		exit 1
	fi

	if [ "$BUILD_DEB" = "true" ] || [ "$BUILD_PKG" = "true" ]; then
		BUILD_DIR_HESTIANGINX="$BUILD_DIR/hestia-nginx_$NGINX_V"
		if echo "$NGINX_V" | grep -q '-'; then
			BUILD_DIR_NGINX="$BUILD_DIR/nginx-$(echo "$NGINX_V" | cut -d"-" -f1)"
		else
			BUILD_DIR_NGINX="$BUILD_DIR/nginx-$(echo "$NGINX_V" | cut -d"~" -f1)"
		fi

		if [ "$KEEPBUILD" != 'true' ] || [ ! -d "$BUILD_DIR_HESTIANGINX" ]; then
			[ -d "$BUILD_DIR_HESTIANGINX" ] && rm -rf "$BUILD_DIR_HESTIANGINX"
			mkdir -p "$BUILD_DIR_HESTIANGINX"

			download_file "$NGINX"
			download_file "$OPENSSL"
			download_file "$PCRE"
			download_file "$ZLIB"

			cd "$BUILD_DIR" || exit 1
			tar -xzf "$ARCHIVE_DIR/nginx-$(echo "$NGINX_V" | cut -d"~" -f1).tar.gz" 2>/dev/null || tar -xzf "$ARCHIVE_DIR/nginx-$(echo "$NGINX_V" | cut -d"-" -f1).tar.gz"
			tar -xzf "$ARCHIVE_DIR/openssl-$OPENSSL_V.tar.gz"
			tar -xzf "$ARCHIVE_DIR/pcre2-$PCRE_V.tar.gz"
			tar -xzf "$ARCHIVE_DIR/v$ZLIB_V.tar.gz" 2>/dev/null || tar -xzf "$ARCHIVE_DIR/zlib-$ZLIB_V.tar.gz"

			cd "$BUILD_DIR_NGINX" || exit 1

			if [ ! -d "../openssl-$OPENSSL_V" ]; then
				echo "ERROR: OpenSSL source not found at ../openssl-$OPENSSL_V"
				exit 1
			fi

			./configure --prefix=/usr/local/hestia/nginx \
				--with-http_v2_module \
				--with-http_ssl_module \
				--with-openssl=../openssl-$OPENSSL_V \
				--with-openssl-opt=enable-ec_nistp_64_gcc_128 \
				--with-openssl-opt=no-nextprotoneg \
				--with-openssl-opt=no-weak-ssl-ciphers \
				--with-openssl-opt=no-ssl3 \
				--with-pcre=../pcre2-$PCRE_V \
				--with-pcre-jit \
				--with-zlib=../zlib-$ZLIB_V
		fi

		cd "$BUILD_DIR_NGINX" || exit 1

		if [ -d "$BUILD_DIR$INSTALL_DIR" ]; then
			rm -rf "$BUILD_DIR$INSTALL_DIR"
		fi

		if [ "$use_src_folder" = 'true' ] && [ -d "$SRC_DIR" ]; then
			cp -rf "$SRC_DIR/" "$BUILD_DIR/hestiacp-$branch_dash"
		fi

		if [ "$OSTYPE" = 'freebsd' ]; then
			gmake -j "$NUM_CPUS" && gmake DESTDIR="$BUILD_DIR" install
		else
			make -j "$NUM_CPUS" && make DESTDIR="$BUILD_DIR" install
		fi

		if [ "$KEEPBUILD" != 'true' ]; then
			rm -rf "$BUILD_DIR_NGINX" "$BUILD_DIR/openssl-$OPENSSL_V" "$BUILD_DIR/pcre2-$PCRE_V" "$BUILD_DIR/zlib-$ZLIB_V"
		fi
		
		cd "$BUILD_DIR_HESTIANGINX" || exit 1

		mkdir -p "$BUILD_DIR_HESTIANGINX/usr/local/hestia"
		rm -rf "$BUILD_DIR_HESTIANGINX/usr/local/hestia/nginx"
		mv "$BUILD_DIR/usr/local/hestia/nginx" "$BUILD_DIR_HESTIANGINX/usr/local/hestia/"

		rm -f "$BUILD_DIR_HESTIANGINX/usr/local/hestia/nginx/conf/nginx.conf"
		mv "$BUILD_DIR_HESTIANGINX/usr/local/hestia/nginx/sbin/nginx" "$BUILD_DIR_HESTIANGINX/usr/local/hestia/nginx/sbin/hestia-nginx"

		cd "$BUILD_DIR" || exit 1
		
		if [ "$OSTYPE" = 'freebsd' ]; then
			chown -R root:wheel "$BUILD_DIR_HESTIANGINX"
		else
			chown -R root:root "$BUILD_DIR_HESTIANGINX"
		fi
		
		if [ "$BUILD_DEB" = true ]; then
			mkdir -p "$BUILD_DIR_HESTIANGINX/DEBIAN"
			get_branch_file 'src/deb/nginx/control' "$BUILD_DIR_HESTIANGINX/DEBIAN/control"
			[ "$BUILD_ARCH" != "amd64" ] && sed -i "s/amd64/${BUILD_ARCH}/g" "$BUILD_DIR_HESTIANGINX/DEBIAN/control"
			get_branch_file 'src/deb/nginx/copyright' "$BUILD_DIR_HESTIANGINX/DEBIAN/copyright"
			get_branch_file 'src/deb/nginx/postinst' "$BUILD_DIR_HESTIANGINX/DEBIAN/postinst"
			get_branch_file 'src/deb/nginx/postrm' "$BUILD_DIR_HESTIANGINX/DEBIAN/portrm"
			chmod +x "$BUILD_DIR_HESTIANGINX/DEBIAN/postinst" "$BUILD_DIR_HESTIANGINX/DEBIAN/portrm"

			mkdir -p "$BUILD_DIR_HESTIANGINX/etc/init.d"
			get_branch_file 'src/deb/nginx/hestia' "$BUILD_DIR_HESTIANGINX/etc/init.d/hestia"
			chmod +x "$BUILD_DIR_HESTIANGINX/etc/init.d/hestia"

			get_branch_file 'src/deb/nginx/nginx.conf' "${BUILD_DIR_HESTIANGINX}/usr/local/hestia/nginx/conf/nginx.conf"

			echo "Building Nginx DEB"
			dpkg-deb -Zxz --build "$BUILD_DIR_HESTIANGINX" "$DEB_DIR"
		fi
		
		if [ "$BUILD_PKG" = true ]; then
			mkdir -p "$BUILD_DIR_HESTIANGINX/usr/local/etc/rc.d"
			get_branch_file 'src/pkg/nginx/hestia-nginx.rc' "$BUILD_DIR_HESTIANGINX/usr/local/etc/rc.d/hestia-nginx"
			chmod 755 "$BUILD_DIR_HESTIANGINX/usr/local/etc/rc.d/hestia-nginx"
			
			get_branch_file 'src/pkg/nginx/nginx.conf' "${BUILD_DIR_HESTIANGINX}/usr/local/hestia/nginx/conf/nginx.conf"
			
			# FreeBSD 专属高性能事件循环 kqueue 置换
			if [ -f "${BUILD_DIR_HESTIANGINX}/usr/local/hestia/nginx/conf/nginx.conf" ]; then
				sed -i '' 's/epoll/kqueue/g' "${BUILD_DIR_HESTIANGINX}/usr/local/hestia/nginx/conf/nginx.conf"
				sed -i '' 's|/run/|/var/run/|g' "${BUILD_DIR_HESTIANGINX}/usr/local/hestia/nginx/conf/nginx.conf"
			fi
			
			# 复制并拉取包描述核心元数据
			get_branch_file 'src/pkg/nginx/+MANIFEST' "$BUILD_DIR_HESTIANGINX/+MANIFEST"
			get_branch_file 'src/pkg/nginx/+POST-INSTALL' "$BUILD_DIR_HESTIANGINX/+POST-INSTALL"
			chmod 755 "$BUILD_DIR_HESTIANGINX/+POST-INSTALL"
			
			echo "Building Hestia Nginx PKG for FreeBSD..."
			sed -i '' "s/%VERSION%/${NGINX_V}/g" "$BUILD_DIR_HESTIANGINX/+MANIFEST"
			sed -i '' "s/%ARCH%/${BUILD_ARCH}/g" "$BUILD_DIR_HESTIANGINX/+MANIFEST"
			pkg create -M "$BUILD_DIR_HESTIANGINX/+MANIFEST" -r "$BUILD_DIR_HESTIANGINX" -o "$PKG_DIR"
			mv -f $PKG_DIR/hestia-nginx-*.pkg $PKG_DIR/hestia-nginx-${NGINX_V}.pkg 2>/dev/null
			cd "$PKG_DIR" || exit 1
		fi

		rm -rf "$BUILD_DIR/usr"

		if [ "$KEEPBUILD" != 'true' ]; then
			rm -rf "$BUILD_DIR_HESTIANGINX" "$BUILD_DIR/rpmbuild"
			if [ "$use_src_folder" = 'true' ] && [ -d "$BUILD_DIR/hestiacp-$branch_dash" ]; then
				rm -rf "$BUILD_DIR/hestiacp-$branch_dash"
			fi
		fi
	fi

	# RPM 打包保持原汁原味
	if [ "$BUILD_RPM" = true ]; then
		get_branch_file 'src/rpm/nginx/nginx.conf' "$HOME/rpmbuild/SOURCES/nginx.conf"
		get_branch_file 'src/rpm/nginx/hestia-nginx.spec' "$HOME/rpmbuild/SPECS/hestia-nginx.spec"
		get_branch_file 'src/rpm/nginx/hestia-nginx.service' "$HOME/rpmbuild/SOURCES/hestia-nginx.service"
		download_file "$NGINX" "$HOME/rpmbuild/SOURCES/"
		echo "Building Nginx RPM"
		rpmbuild -bs ~/rpmbuild/SPECS/hestia-nginx.spec
		mock -r rocky+epel-9-$(arch) ~/rpmbuild/SRPMS/hestia-nginx-$NGINX_V-1.el9.src.rpm
		cp /var/lib/mock/rocky+epel-9-$(arch)/result/*.rpm "$RPM_DIR"
		rm -rf ~/rpmbuild/SPECS/* ~/rpmbuild/SOURCES/* ~/rpmbuild/SRPMS/*
	fi
fi

#################################################################################
# Building hestia-php
#################################################################################

if [ "$PHP_B" = "true" ]; then
	if [ "$CROSS" = "true" ]; then
		echo "Cross compile not supported for hestia-nginx, hestia-php or hestia-web-terminal"
		exit 1
	fi

	echo "Building hestia-php package..."

	if [ "$BUILD_DEB" = "true" ] || [ "$BUILD_PKG" = "true" ]; then
		BUILD_DIR_HESTIAPHP="$BUILD_DIR/hestia-php_$PHP_V"

		if echo "$PHP_V" | grep -q '-'; then
			BUILD_DIR_PHP="$BUILD_DIR/php-$(echo "$PHP_V" | cut -d"-" -f1)"
		else
			BUILD_DIR_PHP="$BUILD_DIR/php-$(echo "$PHP_V" | cut -d"~" -f1)"
		fi

		if [ "$KEEPBUILD" != 'true' ] || [ ! -d "$BUILD_DIR_HESTIAPHP" ]; then
			[ -d "$BUILD_DIR_HESTIAPHP" ] && rm -rf "$BUILD_DIR_HESTIAPHP"
			mkdir -p "$BUILD_DIR_HESTIAPHP"

			cd "$BUILD_DIR" || exit 1
			
			download_file "$PHP"
			
			if echo "$PHP_V" | grep -q '-'; then
				tar -xzf "$ARCHIVE_DIR/php-$(echo "$PHP_V" | cut -d"-" -f1).tar.gz"
			else
				tar -xzf "$ARCHIVE_DIR/php-$(echo "$PHP_V" | cut -d"~" -f1).tar.gz"
			fi

			cd "$BUILD_DIR_PHP" || exit 1

			if [ "$OSTYPE" = 'freebsd' ]; then
				export CFLAGS="-I/usr/local/include"
				export LDFLAGS="-L/usr/local/lib"
				
				./configure --prefix=/usr/local/hestia/php \
					--enable-fpm --with-fpm-user=admin --with-fpm-group=admin \
					--with-openssl=/usr \
					--with-mysqli \
					--with-gettext=/usr/local \
					--with-curl=/usr/local \
					--with-zip \
					--with-gmp=/usr/local \
					--enable-mbstring
			else
				# Linux 原版自编译配置
				./configure --prefix=/usr/local/hestia/php \
					--with-libdir=lib/$(arch)-linux-gnu \
					--enable-fpm --with-fpm-user=admin --with-fpm-group=admin \
					--with-openssl \
					--with-mysqli \
					--with-gettext \
					--with-curl \
					--with-zip \
					--with-gmp \
					--enable-mbstring
			fi
		fi

		cd "$BUILD_DIR_PHP" || exit 1

		if [ "$OSTYPE" = 'freebsd' ]; then
			gmake -j "$NUM_CPUS" && gmake INSTALL_ROOT="$BUILD_DIR" install
		else
			make -j "$NUM_CPUS" && make INSTALL_ROOT="$BUILD_DIR" install
		fi

		if [ "$use_src_folder" = 'true' ] && [ -d "$SRC_DIR" ]; then
			cp -rf "$SRC_DIR/" "$BUILD_DIR/hestiacp-$branch_dash"
		fi
		
		mkdir -p "$BUILD_DIR_HESTIAPHP/usr/local/hestia"

		if [ -d "$BUILD_DIR_HESTIAPHP/usr/local/hestia/php" ]; then
			rm -rf "$BUILD_DIR_HESTIAPHP/usr/local/hestia/php"
		fi

		mv "${BUILD_DIR}/usr/local/hestia/php" "${BUILD_DIR_HESTIAPHP}/usr/local/hestia/"
		cp "$BUILD_DIR_HESTIAPHP/usr/local/hestia/php/sbin/php-fpm" "$BUILD_DIR_HESTIAPHP/usr/local/hestia/php/sbin/hestia-php"

		cd "$BUILD_DIR" || exit 1
		
		if [ "$OSTYPE" = 'freebsd' ]; then
			chown -R root:wheel "$BUILD_DIR_HESTIAPHP"
		else
			chown -R root:root "$BUILD_DIR_HESTIAPHP"
		fi
		
		# Debian 打包保持原汁原味
		if [ "$BUILD_DEB" = true ]; then
			mkdir -p "$BUILD_DIR_HESTIAPHP/DEBIAN"
			get_branch_file 'src/deb/php/control' "$BUILD_DIR_HESTIAPHP/DEBIAN/control"
			[ "$BUILD_ARCH" != "amd64" ] && sed -i "s/amd64/${BUILD_ARCH}/g" "$BUILD_DIR_HESTIAPHP/DEBIAN/control"

			os=$(lsb_release -is)
			release=$(lsb_release -rs)
			if [ "$os" = "Ubuntu" ] && [ "$release" = "20.04" ]; then
				sed -i "/Conflicts: libzip5/d" "$BUILD_DIR_HESTIAPHP/DEBIAN/control"
				sed -i "s/libzip4/libzip5/g" "$BUILD_DIR_HESTIAPHP/DEBIAN/control"
			fi
			if [ "$os" = "Ubuntu" ] && [ "$release" = "24.04" ]; then
				sed -i "/Conflicts: libzip5/d" "$BUILD_DIR_HESTIAPHP/DEBIAN/control"
				sed -i "s/libzip4/libzip4t64/g" "$BUILD_DIR_HESTIAPHP/DEBIAN/control"
			fi

			get_branch_file 'src/deb/php/copyright' "$BUILD_DIR_HESTIAPHP/DEBIAN/copyright"
			get_branch_file 'src/deb/php/postinst' "$BUILD_DIR_HESTIAPHP/DEBIAN/postinst"
			chmod +x "$BUILD_DIR_HESTIAPHP/DEBIAN/postinst"
			get_branch_file 'src/deb/php/php-fpm.conf' "${BUILD_DIR_HESTIAPHP}/usr/local/hestia/php/etc/php-fpm.conf"
			get_branch_file 'src/deb/php/php.ini' "${BUILD_DIR_HESTIAPHP}/usr/local/hestia/php/lib/php.ini"

			echo "Building PHP DEB"
			dpkg-deb -Zxz --build "$BUILD_DIR_HESTIAPHP" "$DEB_DIR"
		fi

		if [ "$BUILD_PKG" = true ]; then
			mkdir -p "$BUILD_DIR_HESTIAPHP/usr/local/etc/rc.d"
			get_branch_file 'src/pkg/php/hestia-php.rc' "$BUILD_DIR_HESTIAPHP/usr/local/etc/rc.d/hestia-php"
			chmod 755 "$BUILD_DIR_HESTIAPHP/usr/local/etc/rc.d/hestia-php"
			
			get_branch_file 'src/pkg/php/php-fpm.conf' "${BUILD_DIR_HESTIAPHP}/usr/local/hestia/php/etc/php-fpm.conf"
			get_branch_file 'src/pkg/php/php.ini' "${BUILD_DIR_HESTIAPHP}/usr/local/hestia/php/lib/php.ini"
			if [ -f "${BUILD_DIR_HESTIAPHP}/usr/local/hestia/php/etc/php-fpm.conf" ]; then
				sed -i '' 's/epoll/kqueue/g' "${BUILD_DIR_HESTIAPHP}/usr/local/hestia/php/etc/php-fpm.conf"
				sed -i '' 's|/run/|/var/run/|g' "${BUILD_DIR_HESTIAPHP}/usr/local/hestia/php/etc/php-fpm.conf"
			fi

			get_branch_file 'src/pkg/php/+MANIFEST' "$BUILD_DIR_HESTIAPHP/+MANIFEST"
			get_branch_file 'src/pkg/php/+POST-INSTALL' "$BUILD_DIR_HESTIAPHP/+POST-INSTALL"
			chmod 755 "$BUILD_DIR_HESTIAPHP/+POST-INSTALL"
			
			echo "Building Hestia PHP PKG for FreeBSD..."
			sed -i '' "s/%VERSION%/${PHP_V}/g" "$BUILD_DIR_HESTIAPHP/+MANIFEST"
			sed -i '' "s/%ARCH%/${BUILD_ARCH}/g" "$BUILD_DIR_HESTIAPHP/+MANIFEST"
			pkg create -M "$BUILD_DIR_HESTIAPHP/+MANIFEST" -r "$BUILD_DIR_HESTIAPHP" -o "$PKG_DIR"
			mv -f $PKG_DIR/hestia-php-*.pkg $PKG_DIR/hestia-php-${PHP_V}.pkg 2>/dev/null
			cd "$PKG_DIR" || exit 1
		fi

		rm -rf "$BUILD_DIR/usr"

		if [ "$KEEPBUILD" != 'true' ]; then
			rm -rf "$BUILD_DIR/php-$(echo "$PHP_V" | cut -d"~" -f1)" 2>/dev/null || rm -rf "$BUILD_DIR/php-$(echo "$PHP_V" | cut -d"-" -f1)"
			rm -rf "$BUILD_DIR_HESTIAPHP"
			if [ "$use_src_folder" = 'true' ] && [ -d "$BUILD_DIR/hestiacp-$branch_dash" ]; then
				rm -rf "$BUILD_DIR/hestiacp-$branch_dash"
			fi
		fi
	fi

	# RPM 打包保持原汁原味
	if [ "$BUILD_RPM" = true ]; then
		get_branch_file 'src/rpm/php/php-fpm.conf' "$HOME/rpmbuild/SOURCES/php-fpm.conf"
		get_branch_file 'src/rpm/php/php.ini' "$HOME/rpmbuild/SOURCES/php.ini"
		get_branch_file 'src/rpm/php/hestia-php.spec' "$HOME/rpmbuild/SPECS/hestia-php.spec"
		get_branch_file 'src/rpm/php/hestia-php.service' "$HOME/rpmbuild/SOURCES/hestia-php.service"
		download_file "$PHP" "$HOME/rpmbuild/SOURCES/"
		echo "Building PHP RPM"
		rpmbuild -bs ~/rpmbuild/SPECS/hestia-php.spec
		mock -r rocky+epel-9-$(arch) ~/rpmbuild/SRPMS/hestia-php-$PHP_V-1.el9.src.rpm
		cp /var/lib/mock/rocky+epel-9-$(arch)/result/*.rpm $RPM_DIR
		rm -rf ~/rpmbuild/SPECS/* ~/rpmbuild/SOURCES/* ~/rpmbuild/SRPMS/*
	fi
fi

#################################################################################
# Building hestia-web-terminal
#################################################################################

if [ "$WEB_TERMINAL_B" = "true" ]; then
	if [ "$CROSS" = "true" ]; then
		echo "Cross compile not supported for hestia-nginx, hestia-php or hestia-web-terminal"
		exit 1
	fi

	echo "Building hestia-web-terminal package..."

	if [ "$BUILD_DEB" = "true" ] || [ "$BUILD_PKG" = "true" ]; then
		BUILD_DIR_HESTIA_TERMINAL="$BUILD_DIR/hestia-web-terminal_$WEB_TERMINAL_V"

		[ -d "$BUILD_DIR_HESTIA_TERMINAL" ] && rm -rf "$BUILD_DIR_HESTIA_TERMINAL"

		mkdir -p "$BUILD_DIR_HESTIA_TERMINAL"
		if [ "$OSTYPE" = 'freebsd' ]; then
			chown -R root:wheel "$BUILD_DIR_HESTIA_TERMINAL"
		else
			chown -R root:root "$BUILD_DIR_HESTIA_TERMINAL"
		fi
		
		# Debian 打包保持原汁原味
		if [ "$BUILD_DEB" = "true" ]; then
			mkdir -p "$BUILD_DIR_HESTIA_TERMINAL/DEBIAN"
			get_branch_file 'src/deb/web-terminal/control' "$BUILD_DIR_HESTIA_TERMINAL/DEBIAN/control"
			[ "$BUILD_ARCH" != "amd64" ] && sed -i "s/amd64/${BUILD_ARCH}/g" "$BUILD_DIR_HESTIA_TERMINAL/DEBIAN/control"

			get_branch_file 'src/deb/web-terminal/copyright' "$BUILD_DIR_HESTIA_TERMINAL/DEBIAN/copyright"
			get_branch_file 'src/deb/web-terminal/postinst' "$BUILD_DIR_HESTIA_TERMINAL/DEBIAN/postinst"
			chmod +x "$BUILD_DIR_HESTIA_TERMINAL/DEBIAN/postinst"

			mkdir -p "${BUILD_DIR_HESTIA_TERMINAL}/usr/local/hestia/web-terminal"
			get_branch_file 'src/deb/web-terminal/package.json' "${BUILD_DIR_HESTIA_TERMINAL}/usr/local/hestia/web-terminal/package.json"
			get_branch_file 'src/deb/web-terminal/package-lock.json' "${BUILD_DIR_HESTIA_TERMINAL}/usr/local/hestia/web-terminal/package-lock.json"
			get_branch_file 'src/deb/web-terminal/server.js' "${BUILD_DIR_HESTIA_TERMINAL}/usr/local/hestia/web-terminal/server.js"
			chmod +x "${BUILD_DIR_HESTIA_TERMINAL}/usr/local/hestia/web-terminal/server.js"

			cd "$BUILD_DIR_HESTIA_TERMINAL/usr/local/hestia/web-terminal" || exit 1
			npm ci --omit=dev

			mkdir -p "$BUILD_DIR_HESTIA_TERMINAL/etc/systemd/system"
			get_branch_file 'src/deb/web-terminal/hestia-web-terminal.service' "$BUILD_DIR_HESTIA_TERMINAL/etc/systemd/system/hestia-web-terminal.service"

			echo "Building Web Terminal DEB"
			dpkg-deb -Zxz --build "$BUILD_DIR_HESTIA_TERMINAL" "$DEB_DIR"
		fi

		if [ "$BUILD_PKG" = "true" ]; then
			mkdir -p "${BUILD_DIR_HESTIA_TERMINAL}/usr/local/hestia/web-terminal"
			get_branch_file 'src/pkg/web-terminal/package.json' "${BUILD_DIR_HESTIA_TERMINAL}/usr/local/hestia/web-terminal/package.json"
			get_branch_file 'src/pkg/web-terminal/package-lock.json' "${BUILD_DIR_HESTIA_TERMINAL}/usr/local/hestia/web-terminal/package-lock.json"
			get_branch_file 'src/pkg/web-terminal/server.js' "${BUILD_DIR_HESTIA_TERMINAL}/usr/local/hestia/web-terminal/server.js"
			chmod +x "${BUILD_DIR_HESTIA_TERMINAL}/usr/local/hestia/web-terminal/server.js"

            if [ "$OSTYPE" = 'freebsd' ] && ! command -v npm >/dev/null 2>&1; then
                pkg install -y npm
            fi

			cd "${BUILD_DIR_HESTIA_TERMINAL}/usr/local/hestia/web-terminal" || exit 1
			npm ci --omit=dev
			
			mkdir -p "$BUILD_DIR_HESTIA_TERMINAL/usr/local/etc/rc.d"
			get_branch_file 'src/pkg/web-terminal/hestia-web-terminal.rc' "$BUILD_DIR_HESTIA_TERMINAL/usr/local/etc/rc.d/hestia-web-terminal"
			chmod 755 "$BUILD_DIR_HESTIA_TERMINAL/usr/local/etc/rc.d/hestia-web-terminal"
			
			get_branch_file 'src/pkg/web-terminal/+MANIFEST' "$BUILD_DIR_HESTIA_TERMINAL/+MANIFEST"
			get_branch_file 'src/pkg/web-terminal/+POST-INSTALL' "$BUILD_DIR_HESTIA_TERMINAL/+POST-INSTALL"
			chmod 755 "$BUILD_DIR_HESTIA_TERMINAL/+POST-INSTALL"
			
			echo "Building Hestia Web Terminal PKG for FreeBSD..."
			sed -i '' "s/%VERSION%/${WEB_TERMINAL_V}/g" "$BUILD_DIR_HESTIA_TERMINAL/+MANIFEST"
			sed -i '' "s/%ARCH%/${BUILD_ARCH}/g" "$BUILD_DIR_HESTIA_TERMINAL/+MANIFEST"
			
			pkg create -M "$BUILD_DIR_HESTIA_TERMINAL/+MANIFEST" -r "$BUILD_DIR_HESTIA_TERMINAL" -o "$PKG_DIR"
			mv -f $PKG_DIR/hestia-web-terminal-*.pkg $PKG_DIR/hestia-web-terminal-${WEB_TERMINAL_V}.pkg 2>/dev/null
			cd "$PKG_DIR" || exit 1
		fi

		if [ "$KEEPBUILD" != 'true' ]; then
			rm -rf "$BUILD_DIR_HESTIA_TERMINAL"
			if [ "$use_src_folder" = 'true' ] && [ -d "$BUILD_DIR/hestiacp-$branch_dash" ]; then
				rm -rf "$BUILD_DIR/hestiacp-$branch_dash"
			fi
		fi
	fi
fi

#################################################################################
# Building hestia (main package)
#################################################################################

arch="$BUILD_ARCH"

if [ "$HESTIA_B" = "true" ]; then
	if [ "$CROSS" = "true" ]; then
		arch="amd64 arm64"
	fi
	for current_arch in $arch; do
		echo "Building Hestia Control Panel package for Architecture: $current_arch..."

		if [ "$BUILD_DEB" = "true" ] || [ "$BUILD_PKG" = "true" ]; then
			BUILD_DIR_HESTIA="$BUILD_DIR/hestia_$HESTIA_V"

			cd "$BUILD_DIR" || exit 1

			if [ "$KEEPBUILD" != 'true' ] || [ ! -d "$BUILD_DIR_HESTIA" ]; then
				[ -d "$BUILD_DIR_HESTIA" ] && rm -rf "$BUILD_DIR_HESTIA"
				mkdir -p "$BUILD_DIR_HESTIA"
			fi

			cd "$BUILD_DIR" || exit 1
			rm -rf "$BUILD_DIR/hestiacp-$branch_dash"
			
			if [ "$use_src_folder" = 'true' ]; then
				cp -rf "$SRC_DIR/" "$BUILD_DIR/hestiacp-$branch_dash"
			elif [ -d "$SRC_DIR" ]; then
				download_file "$HESTIA_ARCHIVE_LINK"
				tar -xzf "$ARCHIVE_DIR/$branch.tar.gz" -C "$BUILD_DIR/"
			fi

			mkdir -p "$BUILD_DIR_HESTIA/usr/local/hestia"

            cd "$BUILD_DIR/hestiacp-$branch_dash" || exit 1

            if [ "$OSTYPE" = 'freebsd' ]; then
                if ! command -v npm >/dev/null 2>&1; then
                    pkg install -y npm
                fi
            else
                if ! command -v npm >/dev/null 2>&1; then
                    apt install -y npm
                fi
            fi

            npm ci --ignore-scripts
            npm run build
			cp -rf bin func install web "$BUILD_DIR_HESTIA/usr/local/hestia/"

			find "$BUILD_DIR_HESTIA/usr/local/hestia/" -type f -exec chmod -x {} \;

			chmod +x "$BUILD_DIR_HESTIA/usr/local/hestia/web/inc/mail-wrapper.php"
			chmod +x "$BUILD_DIR_HESTIA/usr/local/hestia/bin/"*
			find "$BUILD_DIR_HESTIA/usr/local/hestia/install/" \( -name '*.sh' \) -exec chmod +x {} \;
			chmod -x "$BUILD_DIR_HESTIA/usr/local/hestia/install/"*.sh
			
			if [ "$OSTYPE" = 'freebsd' ]; then
				chown -R root:wheel "$BUILD_DIR_HESTIA"
			else
				chown -R root:root "$BUILD_DIR_HESTIA"
			fi
			
			if [ "$BUILD_DEB" = true ]; then
				mkdir -p "$BUILD_DIR_HESTIA/DEBIAN"
				get_branch_file 'src/deb/hestia/control' "$BUILD_DIR_HESTIA/DEBIAN/control"
				if [ "$current_arch" != "amd64" ]; then
					sed -i "s/amd64/${current_arch}/g" "$BUILD_DIR_HESTIA/DEBIAN/control"
				fi
				get_branch_file 'src/deb/hestia/copyright' "$BUILD_DIR_HESTIA/DEBIAN/copyright"
				get_branch_file 'src/deb/hestia/preinst' "$BUILD_DIR_HESTIA/DEBIAN/preinst"
				get_branch_file 'src/deb/hestia/postinst' "$BUILD_DIR_HESTIA/DEBIAN/postinst"
				chmod +x "$BUILD_DIR_HESTIA/DEBIAN/postinst" "$BUILD_DIR_HESTIA/DEBIAN/preinst"

				echo "Building Hestia DEB"
				dpkg-deb -Zxz --build "$BUILD_DIR_HESTIA" "$DEB_DIR"
			fi
			
			if [ "$BUILD_PKG" = "true" ]; then
				mkdir -p "$BUILD_DIR_HESTIA/usr/local/etc/rc.d"
				get_branch_file 'src/pkg/hestia/hestia.rc' "$BUILD_DIR_HESTIA/usr/local/etc/rc.d/hestia"
				chmod 755 "$BUILD_DIR_HESTIA/usr/local/etc/rc.d/hestia"
				
				mkdir -p "$BUILD_DIR_HESTIA/usr/local/etc/hestia"
				
				get_branch_file 'src/pkg/hestia/+MANIFEST' "$BUILD_DIR_HESTIA/+MANIFEST"
				get_branch_file 'src/pkg/hestia/+POST-INSTALL' "$BUILD_DIR_HESTIA/+POST-INSTALL"
				get_branch_file 'src/pkg/hestia/+PRE-INSTALL' "$BUILD_DIR_HESTIA/+PRE-INSTALL"
				get_branch_file 'src/pkg/hestia/+PRE-DEINSTALL' "$BUILD_DIR_HESTIA/+PRE-DEINSTALL"
				chmod 755 "$BUILD_DIR_HESTIA/+POST-INSTALL" "$BUILD_DIR_HESTIA/+PRE-INSTALL" "$BUILD_DIR_HESTIA/+PRE-DEINSTALL"
				
				echo "Building Hestia Control Panel PKG for FreeBSD..."
				sed -i '' "s/%VERSION%/${BUILD_VER}/g" "$BUILD_DIR_HESTIA/+MANIFEST"
				sed -i '' "s/%ARCH%/${current_arch}/g" "$BUILD_DIR_HESTIA/+MANIFEST"
				
				pkg create -M "$BUILD_DIR_HESTIA/+MANIFEST" -r "$BUILD_DIR_HESTIA" -o "$PKG_DIR"
				mv -f $PKG_DIR/hestia-1*.pkg $PKG_DIR/hestia-${BUILD_VER}.pkg 2>/dev/null
				
				echo "FreeBSD pkg package created successfully: $PKG_DIR/hestia-${BUILD_VER}.pkg"
			fi

			if [ "$KEEPBUILD" != 'true' ]; then
				rm -rf "$BUILD_DIR_HESTIA" "$BUILD_DIR/hestiacp-$branch_dash"
			fi
		fi

		# RPM 发行打包保持原汁原味
		if [ "$BUILD_RPM" = "true" ]; then
			rm -rf ~/rpmbuild/SOURCES/*
			get_branch_file 'src/rpm/hestia/hestia.spec' "$HOME/rpmbuild/SPECS/hestia.spec"
			get_branch_file 'src/rpm/hestia/hestia.service' "$HOME/rpmbuild/SOURCES/hestia.service"
			tar -czf $HOME/rpmbuild/SOURCES/hestia-$BUILD_VER.tar.gz -C $SRC_DIR/.. hestiacp
			echo "Building Hestia RPM"
			rpmbuild -bs ~/rpmbuild/SPECS/hestia.spec
			mock -r rocky+epel-9-$(arch) ~/rpmbuild/SRPMS/hestia-$BUILD_VER-1.el9.src.rpm
			cp /var/lib/mock/rocky+epel-9-$(arch)/result/*.rpm "$RPM_DIR"
			rm -rf ~/rpmbuild/SPECS/* ~/rpmbuild/SOURCES/* ~/rpmbuild/SRPMS/*
		fi

	done
fi

#################################################################################
# Create FreeBSD pkg repository metadata
#################################################################################

if [ "$BUILD_PKG" = "true" ] && [ -d "$PKG_DIR" ]; then
    echo "Creating FreeBSD pkg repository metadata..."
    
    cd "$PKG_DIR" || exit 1

    if [ -f "/home/runner/work/$REPO/keys/hestiacp.key" ]; then
        echo "[ * ] Signing repository with CI-provided key..."
        pkg repo . /home/runner/work/$REPO/keys/hestiacp.key >/dev/null 2>&1
        cp "/home/runner/work/$REPO/keys/hestiacp.key.pub" "$PKG_DIR/hestiacp.pub" 2>/dev/null || true
    else
        echo "[ ! ] No signing key found, creating repository without signature"
        pkg repo . 2>/dev/null || true
    fi

    # 刷新仓库元数据
    cat > meta.conf << EOF
packing_format: ucl
version: 2
EOF
    
    echo "FreeBSD pkg repository created successfully at: $PKG_DIR"
    ls -la "$PKG_DIR/"
fi

#################################################################################
# Install Packages (Automated CI/CD Sanity Verification)
#################################################################################

# 💡 优化纠偏：单等号规范对齐
if [ "$install" = 'yes' ] || [ "$install" = 'y' ] || [ "$install" = 'true' ]; then
	echo "Installing packages for local sanity validation..."
	if [ "$OSTYPE" = 'rhel' ]; then
		for i in "$RPM_DIR"/*.rpm; do
			dnf -y install "$i" || exit 1
		done
	elif [ "$OSTYPE" = 'freebsd' ]; then
		if ! command -v node >/dev/null 2>&1; then
			pkg install -y node
		fi
		
		# 💡 核心修复：全面抛弃陈旧的 .txz 死路径，精准替换为我们刚刚全新打磨生产出来的 .pkg 正统发行包！
		for i in "$PKG_DIR"/hestia-*.pkg; do
			if [ -f "$i" ]; then
				pkg install -y "$i"
				if [ $? -ne 0 ]; then
					echo "Warning: Sanity installation failed for package asset: $i"
					exit 1
				fi
			fi
		done
	else
		for i in "$DEB_DIR"/*.deb; do
			dpkg -i "$i" || exit 1
		done
	fi
	unset answer
fi

echo ""
echo "========================================================================"
echo "HestiaCP Package Build Routine Completed Successfully!"
if [ "$BUILD_PKG" = "true" ]; then
	echo "FreeBSD .pkg production assets are securely bundled in: $PKG_DIR"
	echo ""
	echo "To manually sign or update this pkg repository downstream:"
	echo "  cd $PKG_DIR"
	echo "  pkg repo . /path/to/your/private_rsa.key"
	echo ""
	echo "To deploy these package nodes standalone natively on FreeBSD CLIENTS:"
	echo "  pkg install $PKG_DIR/hestia-${BUILD_VER}.pkg"
fi
echo "========================================================================"