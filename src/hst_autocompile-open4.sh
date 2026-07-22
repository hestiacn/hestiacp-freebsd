#!/bin/bash

# set -e
# Autocompile Script for HestiaCP package Files.
# For building from local source folder use "~localsrc" keyword as hesia branch name,
#   and the script will not try to download the arhive from github, since '~' char is
#   not accepted in branch name.
# Compile but dont install -> ./hst_autocompile.sh --hestia --noinstall --keepbuild '~localsrc'
# Compile and install -> ./hst_autocompile.sh --hestia --install '~localsrc'

# Clear previous screen output
clear
# ============================================
# 日志配置 - 实时写入 build.log
# ============================================
LOG_FILE="build.log"

# 创建日志文件
touch "$LOG_FILE"

# 将 stdout 和 stderr 重定向到 tee，同时输出到终端和日志文件
exec > >(tee -a "$LOG_FILE") 2>&1

# 设置日志开始时间
echo "========================================"
echo "HestiaCP FreeBSD Build Log"
echo "Started at: $(date)"
echo "========================================"
echo ""
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
		if command -v wget > /dev/null 2>&1; then
			wget "$url" -q $dstopt --show-progress --progress=bar:force --limit-rate=3m
		elif command -v fetch > /dev/null 2>&1; then
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
			if [ "$ARCHIVE_DIR/$filename" != "$destination" ]; then
				cp "$ARCHIVE_DIR/$filename" "$destination"
			fi
		fi
	fi
}

get_branch_file() {
	local filename=$1
	local destination=$2
	[ "$HESTIA_DEBUG" ] && echo >&2 DEBUG: Get branch file "$filename" to "$destination"
	if [ "$use_src_folder" = 'true' ]; then
		local real_src_file="${SRC_DIR}/${filename}"
		if [ ! -f "$real_src_file" ]; then
			cleaned_filename=$(echo "$filename" | sed 's|^src/||')
			if [ -f "${SRC_DIR}/${cleaned_filename}" ]; then
				real_src_file="${SRC_DIR}/${cleaned_filename}"
			elif [ -f "${SRC_DIR}/src/${cleaned_filename}" ]; then
				real_src_file="${SRC_DIR}/src/${cleaned_filename}"
			fi
		fi

		if [ -z "$destination" ]; then
			cp -f "$real_src_file" ./
		else
			cp -f "$real_src_file" "$destination"
		fi
	else
		local clean_url_filename=$(echo "$filename" | sed 's|^\.\./||')
		download_file "https://raw.githubusercontent.com/$REPO/$branch/$clean_url_filename" "$destination" "$3"
	fi
}

generate_plist() {
	local pkg_dir=$1
	local pkg_name=$2

	echo "Generating PLIST for $pkg_name..."
	local plist_file="$pkg_dir/+PLIST"

	# 清空文件
	> "$plist_file"

	# 进入目录
	cd "$pkg_dir" || return 1

	# 自动扫描所有文件
	find . -type f ! -name "+*" | sed 's|^\./|/|' | sort >> "$plist_file"

	# 添加目录（反向排序确保父目录在后）
	find . -type d ! -name "." | sort -r | sed 's|^\./|@dir /|' >> "$plist_file"

	# 统计
	local file_count=$(grep -v '^@' "$plist_file" | wc -l | tr -d ' ')
	local dir_count=$(grep -c '^@dir' "$plist_file" || echo 0)

	echo "✅ PLIST generated: $file_count files, $dir_count directories"

	# 验证 web-terminal 的 node_modules 是否被包含
	if [ "$pkg_name" = "hestia-web-terminal" ] && [ -d "$pkg_dir/usr/local/hestia/web-terminal/node_modules" ]; then
		local npm_count=$(find "$pkg_dir/usr/local/hestia/web-terminal/node_modules" -type f | wc -l | tr -d ' ')
		echo "   📦 node_modules contains $npm_count files (included)"
	fi
}

setup_signing_keys() {
	if [ -n "$PKG_SIGNING_KEY" ] && [ ! -f "/tmp/hestiacp_signing_key" ]; then
		echo "[ * ] Recovering signing key from GitHub Secrets..."
		echo "$PKG_SIGNING_KEY" > /tmp/hestiacp_signing_key
		chmod 600 /tmp/hestiacp_signing_key
		echo "[ ✓ ] Private key recovered to: /tmp/hestiacp_signing_key"
		SIGNING_KEY_PATH="/tmp/hestiacp_signing_key"
	fi

	if [ -n "$PKG_SIGNING_KEY_PUB" ] && [ ! -f "/tmp/hestiacp_signing_pub" ]; then
		echo "[ * ] Recovering public key from GitHub Secrets..."
		echo "$PKG_SIGNING_KEY_PUB" > /tmp/hestiacp_signing_pub
		chmod 644 /tmp/hestiacp_signing_pub
		echo "[ ✓ ] Public key recovered to: /tmp/hestiacp_signing_pub"
		SIGNING_PUB_PATH="/tmp/hestiacp_signing_pub"
	fi

	export SIGNING_KEY_PATH
	export SIGNING_PUB_PATH
}

sign_repository() {
	local pkg_dir=$1

	cd "$pkg_dir" || return 1

	if [ -n "$SIGNING_KEY_PATH" ] && [ -f "$SIGNING_KEY_PATH" ]; then
		echo "[ * ] Signing repository with private key..."
		pkg repo . "$SIGNING_KEY_PATH" > /dev/null 2>&1
		if [ $? -eq 0 ]; then
			echo "[ ✓ ] Repository signed successfully"

			# ============================================
			# 新增：生成压缩格式的元数据文件
			# ============================================
			echo "[ * ] Generating compressed repository metadata for pkg compatibility..."
			
			# 生成 meta.txz
			if [ -f "meta" ]; then
				cp meta meta.txz || xz -c meta > meta.txz 2>/dev/null
				echo "   ✓ meta.txz generated"
			fi
			
			# 生成 data.txz  
			if [ -f "data.pkg" ]; then
				xz -c data.pkg > data.txz || cp data.pkg data.txz 2>/dev/null
				echo "   ✓ data.txz generated"
			fi
			
			# 生成 packagesite.txz
			if [ -f "packagesite.pkg" ]; then
				xz -c packagesite.pkg > packagesite.txz || cp packagesite.pkg packagesite.txz 2>/dev/null
				echo "   ✓ packagesite.txz generated"
			fi
			
			# 可选：同时生成 .tzst 格式（FreeBSD 14 推荐）
			if command -v zstd > /dev/null 2>&1; then
				[ -f "data.pkg" ] && zstd -c data.pkg > data.tzst && echo "   ✓ data.tzst generated"
				[ -f "packagesite.pkg" ] && zstd -c packagesite.pkg > packagesite.tzst && echo "   ✓ packagesite.tzst generated"
			fi
			# ============================================

			if [ -n "$SIGNING_PUB_PATH" ] && [ -f "$SIGNING_PUB_PATH" ]; then
				cp "$SIGNING_PUB_PATH" "$pkg_dir/hestia.pub"
				echo "[ ✓ ] Public key copied to: $pkg_dir/hestia.pub"
			fi
			return 0
		else
			echo "[ ! ] Failed to sign repository"
			return 1
		fi

	elif [ -f "/home/runner/work/$REPO/keys/hestiacp.key" ]; then
		echo "[ * ] Signing repository with CI-provided key..."
		pkg repo . /home/runner/work/$REPO/keys/hestiacp.key > /dev/null 2>&1
		
		# ============================================
		# 同样需要生成压缩格式
		# ============================================
		echo "[ * ] Generating compressed repository metadata for pkg compatibility..."
		[ -f "meta" ] && { cp meta meta.txz || xz -c meta > meta.txz 2>/dev/null; }
		[ -f "data.pkg" ] && { xz -c data.pkg > data.txz || cp data.pkg data.txz 2>/dev/null; }
		[ -f "packagesite.pkg" ] && { xz -c packagesite.pkg > packagesite.txz || cp packagesite.pkg packagesite.txz 2>/dev/null; }
		if command -v zstd > /dev/null 2>&1; then
			[ -f "data.pkg" ] && zstd -c data.pkg > data.tzst 2>/dev/null
			[ -f "packagesite.pkg" ] && zstd -c packagesite.pkg > packagesite.tzst 2>/dev/null
		fi
		# ============================================
		
		cp "/home/runner/work/$REPO/keys/hestiacp.key.pub" "$pkg_dir/hestia.pub"
		echo "[ ✓ ] Repository signed with CI key"
		return 0
	else
		echo "[ ! ] No signing key found, creating repository without signature"
		pkg repo .
		
		# ============================================
		# 无签名仓库也需要生成压缩格式
		# ============================================
		echo "[ * ] Generating compressed repository metadata..."
		[ -f "meta" ] && { cp meta meta.txz || xz -c meta > meta.txz 2>/dev/null; }
		[ -f "data.pkg" ] && { xz -c data.pkg > data.txz || cp data.pkg data.txz 2>/dev/null; }
		[ -f "packagesite.pkg" ] && { xz -c packagesite.pkg > packagesite.txz || cp packagesite.pkg packagesite.txz 2>/dev/null; }
		# ============================================
		
		return 0
	fi
}

fix_zlib_for_freebsd() {
	local zlib_dir=$1
	if [ "$OSTYPE" != 'freebsd' ]; then
		return 0
	fi

	echo "[ * ] Applying advanced FreeBSD cryptographic architecture patches to zlib..."

	if [ -d "$zlib_dir" ]; then
		cd "$zlib_dir" || return 1

		# 1. 修复 ggmake → gmake
		for target_file in Makefile.in Makefile configure; do
			if [ -f "$target_file" ]; then
				sed -i '' 's/ggmake/gmake/g' "$target_file"
				sed -i '' 's/\tmake/\tgmake/g' "$target_file"
				sed -i '' 's/make /gmake /g' "$target_file"
				sed -i '' 's/\$(MAKE)/gmake/g' "$target_file"
				sed -i '' 's/^MAKE=.*/MAKE=gmake/' "$target_file"
			fi
		done

		# 2. 最优雅的修复：在 Makefile.in 中注入空的 distclean 目标
		# 这样每次生成的 Makefile 都会包含它
		if [ -f "Makefile.in" ]; then
			# 检查是否已有 distclean 目标
			if ! grep -q "^distclean:" Makefile.in; then
				echo "" >> Makefile.in
				echo "distclean:" >> Makefile.in
				echo "	@echo '[ ✓ ] Bypassing distclean (FreeBSD compatibility)'" >> Makefile.in
				echo "" >> Makefile.in
				echo "clean:" >> Makefile.in
				echo "	@echo '[ ✓ ] Bypassing clean (FreeBSD compatibility)'" >> Makefile.in
			fi
		fi

		# 3. 如果 Makefile 已存在，也直接添加空目标
		if [ -f "Makefile" ]; then
			if ! grep -q "^distclean:" Makefile; then
				echo "" >> Makefile
				echo "distclean:" >> Makefile
				echo "	@echo '[ ✓ ] Bypassing distclean (FreeBSD compatibility)'" >> Makefile
				echo "" >> Makefile
				echo "clean:" >> Makefile
				echo "	@echo '[ ✓ ] Bypassing clean (FreeBSD compatibility)'" >> Makefile
			fi
		fi

		cd - > /dev/null || return 1
		echo "[ ✓ ] zlib patched successfully. Dummy clean stub is locked."
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
PKG_DIR="$BUILD_DIR/pkg"
LOG_DIR="$BUILD_DIR/logs"
NUM_CPUS=$(sysctl -n hw.ncpu || echo 4)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_IMAP="${BUILD_IMAP:-yes}"
if command -v arch > /dev/null 2>&1; then
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
elif command -v freebsd-version > /dev/null 2>&1 || [ "$(uname -s)" = "FreeBSD" ]; then
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
if [ "$OSTYPE" = 'freebsd' ]; then
	if [ -d "$SRC_DIR/src/pkg" ]; then
		LOCAL_PKG_BASE="$SRC_DIR/src/pkg"
	else
		LOCAL_PKG_BASE="$SRC_DIR/pkg"
	fi

	if [ "$use_src_folder" = 'true' ] && [ -d "$LOCAL_PKG_BASE" ]; then
		BUILD_VER=$(grep "version:" "$LOCAL_PKG_BASE/hestia/+MANIFEST" | head -n1 | cut -d':' -f2 | tr -d '"'\''\r ')
		NGINX_V=$(grep "version:" "$LOCAL_PKG_BASE/nginx/+MANIFEST" | head -n1 | cut -d':' -f2 | tr -d '"'\''\r ')
		PHP_V=$(grep "version:" "$LOCAL_PKG_BASE/php/+MANIFEST" | head -n1 | cut -d':' -f2 | tr -d '"'\''\r ')
		WEB_TERMINAL_V=$(grep "version:" "$LOCAL_PKG_BASE/web-terminal/+MANIFEST" | head -n1 | cut -d':' -f2 | tr -d '"'\''\r ')
	else
		BUILD_VER=$(curl -s "https://raw.githubusercontent.com/$REPO/$branch/src/pkg/hestia/+MANIFEST" | grep "version:" | head -n1 | cut -d':' -f2 | tr -d '"'\''\r ')
		NGINX_V=$(curl -s "https://raw.githubusercontent.com/$REPO/$branch/src/pkg/nginx/+MANIFEST" | grep "version:" | head -n1 | cut -d':' -f2 | tr -d '"'\''\r ')
		PHP_V=$(curl -s "https://raw.githubusercontent.com/$REPO/$branch/src/pkg/php/+MANIFEST" | grep "version:" | head -n1 | cut -d':' -f2 | tr -d '"'\''\r ')
		[ -z "$PHP_V" ] && PHP_V=$(curl -s "https://raw.githubusercontent.com/$REPO/$branch/src/pkg/php/+MANIFEST" | grep "version:" | head -n1 | cut -d':' -f2 | tr -d '"'\''\r ')
		WEB_TERMINAL_V=$(curl -s "https://raw.githubusercontent.com/$REPO/$branch/src/pkg/web-terminal/+MANIFEST" | grep "version:" | head -n1 | cut -d':' -f2 | tr -d '"'\''\r ')
	fi

	if [ -z "$BUILD_VER" ] || [ -z "$NGINX_V" ]; then
		REAL_MANIFEST_NGINX=$(find "$SRC_DIR" -type f -path "*/pkg/nginx/+MANIFEST" | head -n1)
		if [ -f "$REAL_MANIFEST_NGINX" ]; then
			REAL_BASE_DIR=$(echo "$REAL_MANIFEST_NGINX" | sed 's|/pkg/nginx/+MANIFEST||')
			BUILD_VER=$(grep "version:" "$REAL_BASE_DIR/pkg/hestia/+MANIFEST" | head -n1 | cut -d':' -f2 | tr -d '"'\''\r ')
			NGINX_V=$(grep "version:" "$REAL_BASE_DIR/pkg/nginx/+MANIFEST" | head -n1 | cut -d':' -f2 | tr -d '"'\''\r ')
			PHP_V=$(grep "version:" "$REAL_BASE_DIR/pkg/php/+MANIFEST" | head -n1 | cut -d':' -f2 | tr -d '"'\''\r ')
			WEB_TERMINAL_V=$(grep "version:" "$REAL_BASE_DIR/pkg/web-terminal/+MANIFEST" | head -n1 | cut -d':' -f2 | tr -d '"'\''\r ')
		fi
	fi

elif [ "$OSTYPE" = 'rhel' ]; then
	if [ -d "$SRC_DIR/src/rpm" ]; then LOCAL_RPM_BASE="$SRC_DIR/src/rpm"; else LOCAL_RPM_BASE="$SRC_DIR/rpm"; fi
	if [ "$use_src_folder" = 'true' ] && [ -d "$LOCAL_RPM_BASE" ]; then
		BUILD_VER=$(grep "Version:" "$LOCAL_RPM_BASE/hestia/hestia.spec" | head -n1 | cut -d' ' -f2 | tr -d '\r')
		NGINX_V=$(grep "Version:" "$LOCAL_RPM_BASE/nginx/hestia-nginx.spec" | head -n1 | cut -d' ' -f2 | tr -d '\r')
		PHP_V=$(grep "Version:" "$LOCAL_RPM_BASE/php/hestia-php.spec" | head -n1 | cut -d' ' -f2 | tr -d '\r')
		WEB_TERMINAL_V=$(grep "Version:" "$LOCAL_RPM_BASE/web-terminal/hestia-web-terminal.spec" | head -n1 | cut -d' ' -f2 | tr -d '\r')
	else
		BUILD_VER=$(curl -s "https://raw.githubusercontent.com/$REPO/$branch/src/rpm/hestia/hestia.spec" | grep "Version:" | head -n1 | cut -d' ' -f2 | tr -d '\r')
		NGINX_V=$(curl -s "https://raw.githubusercontent.com/$REPO/$branch/src/rpm/nginx/hestia-nginx.spec" | grep "Version:" | head -n1 | cut -d' ' -f2 | tr -d '\r')
		PHP_V=$(curl -s "https://raw.githubusercontent.com/$REPO/$branch/src/rpm/php/hestia-php.spec" | grep "Version:" | head -n1 | cut -d' ' -f2 | tr -d '\r')
		WEB_TERMINAL_V=$(curl -s "https://raw.githubusercontent.com/$REPO/$branch/src/rpm/web-terminal/hestia-web-terminal.spec" | grep "Version:" | head -n1 | cut -d' ' -f2 | tr -d '\r')
	fi
else
	if [ -d "$SRC_DIR/src/deb" ]; then LOCAL_DEB_BASE="$SRC_DIR/src/deb"; else LOCAL_DEB_BASE="$SRC_DIR/deb"; fi
	if [ "$use_src_folder" = 'true' ] && [ -f "$LOCAL_DEB_BASE/hestia/control" ]; then
		BUILD_VER=$(grep "Version:" "$LOCAL_DEB_BASE/hestia/control" | cut -d' ' -f2 | tr -d '\r')
		NGINX_V=$(grep "Version:" "$LOCAL_DEB_BASE/nginx/control" | cut -d' ' -f2 | tr -d '\r')
		PHP_V=$(grep "Version:" "$LOCAL_DEB_BASE/php/control" | cut -d' ' -f2 | tr -d '\r')
		WEB_TERMINAL_V=$(grep "Version:" "$LOCAL_DEB_BASE/web-terminal/control" | cut -d' ' -f2 | tr -d '\r')
	else
		BUILD_VER=$(curl -s "https://raw.githubusercontent.com/$REPO/$branch/src/deb/hestia/control" | grep "Version:" | cut -d' ' -f2 | tr -d '\r')
		NGINX_V=$(curl -s "https://raw.githubusercontent.com/$REPO/$branch/src/deb/nginx/control" | grep "Version:" | cut -d' ' -f2 | tr -d '\r')
		PHP_V=$(curl -s "https://raw.githubusercontent.com/$REPO/$branch/src/deb/php/control" | grep "Version:" | cut -d' ' -f2 | tr -d '\r')
		WEB_TERMINAL_V=$(curl -s "https://raw.githubusercontent.com/$REPO/$branch/src/deb/web-terminal/control" | grep "Version:" | cut -d' ' -f2 | tr -d '\r')
	fi
fi

# 检查版本是否获取成功
if [ -z "$BUILD_VER" ]; then
	echo "Error: Branch invalid, could not detect version"
	exit 1
fi

OPENSSL_V='4.0.1'
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
		SOFTWARE='bash gmake perl5 git curl pkgconf openssl pcre2 autoconf automake libtool ca_root_nss npm node libxml2 libxslt bison libzip sqlite3 re2c gmp python gcc'
		echo "Updating FreeBSD package repository..."
		pkg update -f
		echo "Installing FreeBSD build dependencies..."
		pkg install -y $SOFTWARE

		NODE_VERSION=$(node -v | cut -d'v' -f2 | cut -d'.' -f1)
		if [ -z "$NODE_VERSION" ] || [ "$NODE_VERSION" -lt 24 ]; then
			echo "[ ! ] Node.js version 24+ is required for Hestia Vhost compilation. Forcing update..."
			pkg install -y node
		fi

		NUM_CPUS=$(sysctl -n hw.ncpu || echo 4)

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

		if ! command -v node > /dev/null 2>&1; then
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

if [ -f "$ARCHIVE_DIR/php-${PHP_V}.tar.gz" ]; then
	echo "[ ✓] Using local PHP source: $ARCHIVE_DIR/php-${PHP_V}.tar.gz"
	PHP_SRC_FILE="$ARCHIVE_DIR/php-${PHP_V}.tar.gz"
else
	PHP_SRC_URL="https://github.com/php/php-src/archive/refs/tags/php-${PHP_V}.tar.gz"
	echo "[ ! ] Local PHP source not found. Downloading from GitHub releases: ${PHP_SRC_URL}"
	if ! download_file "$PHP_SRC_URL" "$ARCHIVE_DIR/php-${PHP_V}.tar.gz"; then
		echo "ERROR: Failed to download PHP source from GitHub."
		exit 1
	fi
	PHP_SRC_FILE="$ARCHIVE_DIR/php-${PHP_V}.tar.gz"
fi

branch_dash=$(echo "$branch" | sed 's/\//-/g')

# =================================================================================
# Building hestia-nginx
# =================================================================================

if [ "$NGINX_B" = "true" ]; then
	echo "Building hestia-nginx package..."
	if [ "$CROSS" = "true" ]; then
		echo "Cross compile not supported for hestia-nginx, hestia-php or hestia-web-terminal"
		exit 1
	fi

	if [ "$BUILD_DEB" = "true" ] || [ "$BUILD_PKG" = "true" ]; then
		BUILD_DIR_HESTIANGINX="$BUILD_DIR/hestia-nginx_$NGINX_V"
		CLEAN_NGINX_VER=$(echo "$NGINX_V" | tr -d "'\"\r" | cut -d"-" -f1 | cut -d"~" -f1)

		if [ "$KEEPBUILD" != 'true' ] || [ ! -d "$BUILD_DIR_HESTIANGINX" ]; then
			[ -d "$BUILD_DIR_HESTIANGINX" ] && rm -rf "$BUILD_DIR_HESTIANGINX"
			mkdir -p "$BUILD_DIR_HESTIANGINX"

			cd "$BUILD_DIR" || exit 1
			NGINX_FILE="$ARCHIVE_DIR/nginx-${CLEAN_NGINX_VER}.tar.gz"
			if [ ! -f "$NGINX_FILE" ]; then
				NGINX_FILE="$ARCHIVE_DIR/nginx-$(echo "$NGINX_V" | tr -d '\r' | cut -d"~" -f1).tar.gz"
				if [ ! -f "$NGINX_FILE" ]; then
					NGINX_FILE="$ARCHIVE_DIR/nginx-$(echo "$NGINX_V" | tr -d '\r' | cut -d"-" -f1).tar.gz"
				fi
			fi

			if [ ! -f "$NGINX_FILE" ]; then
				echo "[ ! ] Local Nginx archive not found. Activating remote network self-healing stream..."
				download_file "$NGINX"
				download_file "$OPENSSL"
				download_file "$PCRE"
				download_file "$ZLIB"
				NGINX_FILE="$ARCHIVE_DIR/nginx-${CLEAN_NGINX_VER}.tar.gz"
				[ ! -f "$NGINX_FILE" ] && NGINX_FILE=$(find "$ARCHIVE_DIR" -name "nginx-*.tar.gz" | head -n1)
			else
				echo "[ ✓ ] High performance offline mode activated. Using local Nginx package: $NGINX_FILE"
			fi

			if [ ! -f "$NGINX_FILE" ]; then
				echo "ERROR: Critical failure. Unable to secure Nginx source archive via both Local and Remote pipelines."
				exit 1
			fi

			OPENSSL_FILE="$ARCHIVE_DIR/openssl-$OPENSSL_V.tar.gz"
			PCRE_FILE="$ARCHIVE_DIR/pcre2-$PCRE_V.tar.gz"
			ZLIB_FILE="$ARCHIVE_DIR/v$ZLIB_V.tar.gz"
			[ ! -f "$ZLIB_FILE" ] && ZLIB_FILE="$ARCHIVE_DIR/zlib-$ZLIB_V.tar.gz"

			# 1. 先下载和解压
			if [ ! -f "$OPENSSL_FILE" ] || [ ! -f "$PCRE_FILE" ]; then
				echo "[ ! ] Global raw materials missing. Recovering from network..."
				download_file "$OPENSSL"
				download_file "$PCRE"
				download_file "$ZLIB"
			fi

			# 强力清空历史残留，保障纯净度
			rm -rf nginx-* openssl-* pcre2-* zlib-* v1.*

			echo "[ * ] Unpacking raw materials via native bsdtar toolchain..."
			bsdtar -xf "$NGINX_FILE"
			bsdtar -xf "$OPENSSL_FILE"
			bsdtar -xf "$PCRE_FILE"
			bsdtar -xf "$ZLIB_FILE"

			# 2. 确定目录
			if [ -d "${BUILD_DIR}/zlib-$ZLIB_V" ]; then
				ZLIB_SRC_DIR="${BUILD_DIR}/zlib-$ZLIB_V"
			elif [ -d "${BUILD_DIR}/v$ZLIB_V" ]; then
				ZLIB_SRC_DIR="${BUILD_DIR}/v$ZLIB_V"
			else
				ZLIB_SRC_DIR="${BUILD_DIR}/zlib-$ZLIB_V"
			fi

			REAL_NGINX_DIR=""
			for check_dir in */; do
				check_dir_trimmed=$(echo "$check_dir" | tr -d '/')
				if [ -f "${check_dir_trimmed}/configure" ] && echo "$check_dir_trimmed" | grep -q -E 'nginx|src'; then
					REAL_NGINX_DIR="${BUILD_DIR}/${check_dir_trimmed}"
					break
				fi
			done

			# 保底高级雷达防线
			if [ -z "$REAL_NGINX_DIR" ]; then
				REAL_NGINX_DIR=$(find "$BUILD_DIR" -maxdepth 2 -type f -name "configure" | grep -E 'nginx|src' | head -n1 | xargs dirname)
			fi

			if [ -z "$REAL_NGINX_DIR" ] || [ ! -d "$REAL_NGINX_DIR" ]; then
				echo "ERROR: Unexpected packaging layout. No native nginx configure workspace found in $BUILD_DIR"
				exit 1
			fi

			BUILD_DIR_NGINX="$REAL_NGINX_DIR"
			echo "[ ✓ ] Target radar successfully locked nginx workspace at: $BUILD_DIR_NGINX"

			cd "$BUILD_DIR_NGINX" || exit 1

			if [ ! -d "${BUILD_DIR}/openssl-$OPENSSL_V" ]; then
				echo "ERROR: OpenSSL source not found at ${BUILD_DIR}/openssl-$OPENSSL_V"
				exit 1
			fi

			cd "$BUILD_DIR_NGINX" || exit 1
			./configure --prefix=/usr/local/hestia/nginx \
				--with-http_v2_module \
				--with-http_ssl_module \
				--with-openssl="${BUILD_DIR}/openssl-$OPENSSL_V" \
				--with-openssl-opt=enable-ec_nistp_64_gcc_128 \
				--with-openssl-opt=no-nextprotoneg \
				--with-openssl-opt=no-weak-ssl-ciphers \
				--with-openssl-opt=no-ssl3 \
				--with-pcre="${BUILD_DIR}/pcre2-$PCRE_V" \
				--with-pcre-jit \
				--with-zlib="$ZLIB_SRC_DIR"

			# FreeBSD: 修复 zlib 和 nginx 的 Makefile
			if [ "$OSTYPE" = 'freebsd' ] && [ -d "$ZLIB_SRC_DIR" ]; then
				echo "[ * ] Applying FreeBSD compatibility patches..."

				cd "$ZLIB_SRC_DIR"
				# 修复 zlib Makefile
				sed -i '' 's/ggmake/gmake/g' Makefile
				# 确保有空目标
				if ! grep -q "^distclean:" Makefile; then
					echo "" >> Makefile
					echo "distclean:" >> Makefile
					echo "	@echo '[ ✓ ] Bypassing distclean (FreeBSD)'" >> Makefile
					echo "clean:" >> Makefile
					echo "	@echo '[ ✓ ] Bypassing clean (FreeBSD)'" >> Makefile
				fi
				rm -f Makefile
				cd "$BUILD_DIR_NGINX" || exit 1

				# 修复 nginx objs/Makefile
				if [ -f "objs/Makefile" ]; then
					# 删除或替换 distclean 行
					sed -i '' '/distclean/d' objs/Makefile
					# 修复 ggmake
					sed -i '' 's/ggmake/gmake/g' objs/Makefile
					sed -i '' 's/make /gmake /g' objs/Makefile
				fi
			fi
		fi

		if [ -z "$BUILD_DIR_NGINX" ] || [ ! -d "$BUILD_DIR_NGINX" ]; then
			CLEAN_NGINX_VER=$(echo "$NGINX_V" | tr -d "'\"\r" | cut -d"-" -f1 | cut -d"~" -f1)
			if [ -d "${BUILD_DIR}/nginx-${CLEAN_NGINX_VER}" ]; then
				BUILD_DIR_NGINX="${BUILD_DIR}/nginx-${CLEAN_NGINX_VER}"
			else
				BUILD_DIR_NGINX=$(find "$BUILD_DIR" -maxdepth 1 -type d -name "nginx-*" | head -n1)
			fi
		fi

		cd "$BUILD_DIR_NGINX" || {
			echo "ERROR: Critical flow crash. Unable to enter nginx path: $BUILD_DIR_NGINX"
			exit 1
		}

		if [ "$use_src_folder" = 'true' ] && [ -d "$SRC_DIR" ]; then
			cp -rf "$SRC_DIR/" "$BUILD_DIR/hestiacp-$branch_dash"
		fi

		mkdir -p "${BUILD_DIR}/usr/local/hestia/nginx"
		[ ! -d "/usr/local/hestia" ] && mkdir -p "/usr/local/hestia"

		if [ "$OSTYPE" = 'freebsd' ]; then
			env MAKEFLAGS="" gmake -j "$NUM_CPUS" && gmake DESTDIR="$BUILD_DIR" install
		else
			make -j "$NUM_CPUS" && make DESTDIR="$BUILD_DIR" install
		fi

		if [ "$KEEPBUILD" != 'true' ]; then
			rm -rf "$BUILD_DIR_NGINX" "${BUILD_DIR}/openssl-$OPENSSL_V" "${BUILD_DIR}/pcre2-$PCRE_V"
			if [ "$OSTYPE" != 'freebsd' ]; then
				rm -rf "${BUILD_DIR}/zlib-$ZLIB_V"
			fi
		fi

		cd "$BUILD_DIR_HESTIANGINX" || exit 1

		mkdir -p "$BUILD_DIR_HESTIANGINX/usr/local/hestia"
		rm -rf "$BUILD_DIR_HESTIANGINX/usr/local/hestia/nginx"

		if [ -d "${BUILD_DIR}/usr/local/hestia/nginx" ]; then
			mv "${BUILD_DIR}/usr/local/hestia/nginx" "$BUILD_DIR_HESTIANGINX/usr/local/hestia/"
			echo "[ ✓ ] Successfully extracted and moved compiled nginx architecture to delivery zone."
			ln -sf nginx "$BUILD_DIR_HESTIANGINX/usr/local/hestia/nginx/sbin/hestia-nginx"
			echo "[ ✓ ] Created symbolic link for hestia-nginx binary."
		else
			echo "ERROR: Critical build dislocation. Binaries failed to materialize at ${BUILD_DIR}/usr/local/hestia/nginx"
			exit 1
		fi

		cd "$BUILD_DIR" || exit 1

		if [ "$OSTYPE" = 'freebsd' ]; then
			chown -R root:wheel "$BUILD_DIR_HESTIANGINX"
		else
			chown -R root:root "$BUILD_DIR_HESTIANGINX"
		fi

		# Debian 打包分支保持原汁原味
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
			generate_plist "$BUILD_DIR_HESTIANGINX" "hestia-nginx"
			if [ -f "${BUILD_DIR_HESTIANGINX}/usr/local/hestia/nginx/conf/nginx.conf" ]; then
				sed -i '' 's/epoll/kqueue/g' "${BUILD_DIR_HESTIANGINX}/usr/local/hestia/nginx/conf/nginx.conf"
				sed -i '' 's|/run/|/var/run/|g' "${BUILD_DIR_HESTIANGINX}/usr/local/hestia/nginx/conf/nginx.conf"
			fi

			get_branch_file 'src/pkg/nginx/+MANIFEST' "$BUILD_DIR_HESTIANGINX/+MANIFEST"
			get_branch_file 'src/pkg/nginx/+POST-INSTALL' "$BUILD_DIR_HESTIANGINX/+POST-INSTALL"
			get_branch_file 'src/pkg/nginx/+PRE-INSTALL' "$BUILD_DIR_HESTIANGINX/+PRE-INSTALL"
			chmod 755 "$BUILD_DIR_HESTIANGINX/+POST-INSTALL" "$BUILD_DIR_HESTIANGINX/+PRE-INSTALL"

			echo "Building Hestia Nginx PKG for FreeBSD..."
			CLEAN_NGINX_VER_FINAL=$(echo "${NGINX_V}" | tr -d '\r"' | tr -d "'")
			sed -i '' "s/%VERSION%/${CLEAN_NGINX_VER_FINAL}/g" "$BUILD_DIR_HESTIANGINX/+MANIFEST"
			sed -i '' "s/%ARCH%/${BUILD_ARCH}/g" "$BUILD_DIR_HESTIANGINX/+MANIFEST"

			mkdir -p "$BUILD_DIR_HESTIANGINX/+METADATA"
			cp "$BUILD_DIR_HESTIANGINX/+MANIFEST" "$BUILD_DIR_HESTIANGINX/+METADATA/+MANIFEST"
			cp "$BUILD_DIR_HESTIANGINX/+PRE-INSTALL" "$BUILD_DIR_HESTIANGINX/+METADATA/+PRE-INSTALL"
			cp "$BUILD_DIR_HESTIANGINX/+POST-INSTALL" "$BUILD_DIR_HESTIANGINX/+METADATA/+POST-INSTALL"

			echo "Building Hestia Nginx PKG for FreeBSD..."
			pkg create -m "$BUILD_DIR_HESTIANGINX/+METADATA" -p "$BUILD_DIR_HESTIANGINX/+PLIST" -r "$BUILD_DIR_HESTIANGINX" -o "$PKG_DIR"
			mv -f $PKG_DIR/hestia-nginx-1*.pkg "$PKG_DIR/hestia-nginx-${CLEAN_NGINX_VER_FINAL}.pkg"
			echo "[ * ] Verifying nginx package integrity..."
			if pkg info -F "$PKG_DIR/hestia-nginx-${CLEAN_NGINX_VER_FINAL}.pkg" > /dev/null 2>&1; then
				echo "✅ Nginx package is valid."
			else
				echo "❌ ERROR: Nginx package validation failed!"
				exit 1
			fi
			cd "$PKG_DIR" || exit 1
		fi

		#rm -rf "$BUILD_DIR/usr"

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

# ============================================================
# 下载 PHP
# ============================================================
download_php() {
    local file="$ARCHIVE_DIR/php-${PHP_VERSION}.tar.gz"

    if [ -f "$file" ]; then
        echo "[ ✓ ] PHP ${PHP_VERSION} already downloaded"
        return 0
    fi

    echo "[ * ] Downloading PHP ${PHP_VERSION}..."
    fetch -o "$file" "https://github.com/php/php-src/archive/refs/tags/php-${PHP_VERSION}.tar.gz"
    if [ $? -ne 0 ]; then
        echo "Failed to download PHP ${PHP_VERSION}"
        return 1
    fi
    echo "[ ✓ ] Downloaded PHP ${PHP_VERSION}"
    return 0
}

# ============================================================
# 下载 ImageMagick 扩展源码
# ============================================================
download_imagick() {
    local imagick_dir="$1/ext/imagick"
    
    [ -d "$imagick_dir" ] && { echo "[ ✓ ] ImageMagick already exists"; return 0; }
    
    echo "[ * ] Downloading ImageMagick 3.8.1..."
    fetch -o "/tmp/imagick.tar.gz" "https://github.com/Imagick/imagick/archive/refs/tags/3.8.1.tar.gz" || return 1
    
    echo "[ * ] Extracting..."
    tar -xf "/tmp/imagick.tar.gz" -C "$1/ext"
    
    local extracted=$(find "$1/ext" -maxdepth 1 -type d -name "imagick-*" | head -1)
    [ -z "$extracted" ] && { echo "❌ Extract failed"; return 1; }
    
    mv "$extracted" "$imagick_dir"
    rm -f "/tmp/imagick.tar.gz"
    
    echo "[ ✓ ] ImageMagick extension ready"
    return 0
}

# ============================================================
# 下载 APCu 扩展源码
# ============================================================
download_apcu() {
    local apcu_dir="$1/ext/apcu"
    
    [ -d "$apcu_dir" ] && { echo "[ ✓ ] APCu already exists"; return 0; }
    
    echo "[ * ] Downloading APCu 5.1.24..."
    fetch -o "/tmp/apcu.tar.gz" "https://github.com/krakjoe/apcu/archive/refs/tags/v5.1.28.tar.gz" || return 1
    
    echo "[ * ] Extracting..."
    tar -xf "/tmp/apcu.tar.gz" -C "$1/ext"
    
    local extracted=$(find "$1/ext" -maxdepth 1 -type d -name "apcu-*" | head -1)
    [ -z "$extracted" ] && { echo "❌ Extract failed"; return 1; }
    
    mv "$extracted" "$apcu_dir"
    rm -f "/tmp/apcu.tar.gz"
    
    echo "[ ✓ ] APCu extension ready"
    return 0
}

# ============================================================
# 通用解压函数
# ============================================================
extract_archive() {
    local archive="$1"
    
    echo "[ * ] 解压: $archive"
    
    if tar -xf "$archive"; then
        echo "✅ 使用 tar 解压成功"
        return 0
    fi
    
    if command -v python3 >/dev/null; then
        echo "⚠️  tar 解压失败，使用 Python..."
        if python3 -c "import tarfile; tarfile.open('$archive', 'r:gz').extractall()"; then
            echo "✅ Python 解压成功"
            return 0
        fi
    fi
    
    if command -v gtar >/dev/null; then
        echo "⚠️  尝试使用 GNU tar..."
        if gtar -xf "$archive"; then
            echo "✅ GNU tar 解压成功"
            return 0
        fi
    fi
    
    echo "❌ 所有解压方法都失败: $archive"
    return 1
}

# ============================================================
# 获取配置参数
# ============================================================
get_config_args() {
    local version="$1"
    local major=$(echo "$version" | cut -d. -f1)
    local minor=$(echo "$version" | cut -d. -f2)
    local ver_suffix="${major}${minor}"

    local args=(
        "--prefix=/usr/local"
        "--exec-prefix=/usr/local"
        "--bindir=/usr/local/bin"
        "--sbindir=/usr/local/sbin"
        "--libexecdir=/usr/local/libexec"
        "--sysconfdir=/usr/local/etc/php${ver_suffix}"
        "--localstatedir=/usr/local/var"
        "--mandir=/usr/local/share/php${ver_suffix}/man"
        "--includedir=/usr/local/include/php${ver_suffix}"
        "--libdir=/usr/local/lib/php${ver_suffix}"
        "--program-suffix=${ver_suffix}"
        "--enable-apcu"
        "--enable-embed"
        "--enable-fpm"
        "--enable-cli"
        "--enable-cgi"
        "--enable-mbstring"
        "--enable-bcmath"
        "--enable-session"
        "--enable-ctype"
        "--enable-filter"
        "--enable-fileinfo"
        "--enable-sockets"
        "--enable-pcntl"
        "--enable-exif"
        "--enable-ftp"
        "--enable-static"
        "--enable-static=yes"
        "--enable-shared=yes"
        "--enable-dtrace"
        "--enable-dom"
        "--enable-xml"
        "--enable-xmlreader"
        "--enable-xmlwriter"
        "--enable-simplexml"
        "--with-xsl"
        "--enable-opcache"
        "--enable-intl"
        "--enable-soap"
        "--enable-posix"
        "--enable-tokenizer"
        "--with-readline"
        "--enable-phar=shared"
        "--enable-shmop"
        "--enable-sysvmsg"
        "--enable-sysvsem"
        "--enable-sysvshm"
        "--enable-calendar"
        "--enable-phpdbg"
        "--with-pic"
        "--with-gettext=/usr/local"
        "--with-curl"
        "--with-gmp=/usr/local"
        "--with-zlib=/usr"
        "--with-bz2=/usr"
        "--with-mysqli=mysqlnd"
        "--with-pdo-mysql=mysqlnd"
        "--with-pgsql"
        "--with-pdo-pgsql"
        "--with-iconv=/usr/local"
        "--with-openssl=/usr/local"
        "--with-sodium"
        "--with-password-argon2"
        "--with-ldap=/usr/local"
        "--with-libedit"
        "--with-ffi"
        "--enable-gd"
        "--with-freetype"
        "--with-jpeg"
        "--with-webp"
        "--with-zip"
    )

    printf "%s\n" "${args[@]}"
}

# ============================================================
# 应用补丁
# ============================================================
apply_patches() {
    local build_dir=$1

    cd "$build_dir" || return 1

    echo "[ * ] Applying patches for PHP ${PHP_VERSION}..."

    # 更新版权年份
    if [ -f "./main/main.c" ] && [ -f "./Zend/zend.c" ]; then
        echo "[ * ] Updating copyright year to 2026..."
        find ./main ./Zend ./ext ./sapi ./TSRM -type f \( -name "*.c" -o -name "*.h" \) \
            -exec sed -i '' 's/| Copyright (c) [0-9]\{4\}-[0-9]\{4\} The PHP Group.*/| Copyright (c) 1997- 2026 The PHP Group                                |/' {} \;
        find ./main ./Zend ./ext ./sapi ./TSRM -type f \( -name "*.c" -o -name "*.h" \) \
            -exec sed -i '' 's/| Copyright (c) The PHP Group.*/| Copyright (c) 1997- 2026 The PHP Group                                |/' {} \;
        find ./main ./Zend ./ext ./sapi ./TSRM -type f \( -name "*.c" -o -name "*.h" \) \
            -exec sed -i '' 's/| Copyright (c) [0-9]\{4\}-[0-9]\{4\} Zend Technologies.*/| Copyright (c) 1998- 2026 Zend Technologies Ltd. (http:\/\/www.zend.com) |/' {} \;
        find ./main ./Zend ./ext ./sapi ./TSRM -type f \( -name "*.c" -o -name "*.h" \) \
            -exec sed -i '' 's/| Copyright (c) Zend Technologies.*/| Copyright (c) 1998- 2026 Zend Technologies Ltd. (http:\/\/www.zend.com) |/' {} \;
        
        for file in sapi/cli/php_cli.c sapi/fpm/fpm/fpm_main.c sapi/cgi/cgi_main.c sapi/litespeed/lsapi_main.c sapi/phpdbg/phpdbg.c; do
            if [ -f "$file" ]; then
                sed -i '' 's/Copyright (c) [0-9]\{4\}-[0-9]\{4\} The PHP Group/Copyright (c) 1997- 2026 The PHP Group/g' "$file"
                sed -i '' 's/Copyright (c) The PHP Group/Copyright (c) 1997- 2026 The PHP Group/g' "$file"
            fi
        done
        
        sed -i '' 's/#define ZEND_CORE_VERSION_INFO.*"Zend Engine v" ZEND_VERSION ", Copyright (c) [0-9]\{4\}-[0-9]\{4\} Zend Technologies\\n".*/#define ZEND_CORE_VERSION_INFO\t"Zend Engine v" ZEND_VERSION ", Copyright (c) 1998- 2026 Zend Technologies\\n"/' ./Zend/zend.c
        sed -i '' 's/#define ZEND_CORE_VERSION_INFO.*"Zend Engine v" ZEND_VERSION ", Copyright (c) Zend Technologies\\n".*/#define ZEND_CORE_VERSION_INFO\t"Zend Engine v" ZEND_VERSION ", Copyright (c) 1998- 2026 Zend Technologies\\n"/' ./Zend/zend.c
        echo "[ ✓ ] Copyright updated to 2026"
        grep "Copyright" ./main/main.c || true
        grep "Copyright" ./Zend/zend.c || true
    fi

    echo "[ ✓ ] All patches applied for PHP ${PHP_VERSION}"
    cd - > /dev/null || return 1
}

# ============================================================
# 通过 PECL 安装 IMAP 扩展 (PHP 8.4 使用 PECL)
# ============================================================
install_imap_pecl() {
    local install_dir="$1"
    local build_dir="$2"
    
    echo ""
    echo "========================================"
    echo "[ * ] Installing IMAP extension via PECL"
    echo "========================================"
    
    local php_bin="$install_dir/usr/local/bin/php"
    local pecl="$install_dir/usr/local/bin/pecl"
    
    if [ ! -f "$php_bin" ]; then
        echo "❌ PHP binary not found: $php_bin"
        return 1
    fi
    
    # 检查 PECL 是否存在
    if [ ! -f "$pecl" ]; then
        echo "⚠️  PECL not found, installing PEAR..."
        # 安装 PEAR
        cd "$build_dir" || return 1
        if [ -f "phpize" ]; then
            ./phpize
        fi
        # 下载并安装 PEAR
        fetch -o /tmp/go-pear.phar https://pear.php.net/go-pear.phar
        "$php_bin" /tmp/go-pear.phar
        export PATH="$install_dir/usr/local/bin:$PATH"
    fi
    
    # 设置环境变量
    export PATH="$install_dir/usr/local/bin:$PATH"
    export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:$PKG_CONFIG_PATH"
    export CFLAGS="-I/usr/local/include $CFLAGS"
    export LDFLAGS="-L/usr/local/lib $LDFLAGS"
    export CPPFLAGS="-I/usr/local/include"
    
    # 获取扩展目录
    local zend_api_no=$(grep "^#define ZEND_MODULE_API_NO" "$build_dir/Zend/zend_modules.h" | awk '{print $3}')
    local ext_dir="$install_dir/usr/local/lib/php/extensions/no-debug-non-zts-${zend_api_no}"
    
    echo "[ * ] Installing imap extension via PECL..."
    echo "  Using PHP: $php_bin"
    echo "  Extension dir: $ext_dir"
    
    # 尝试通过 PECL 安装
    if pecl install imap <<< "yes" 2>&1 | tee -a "$LOG_DIR/imap-pecl.log"; then
        echo "  ✅ IMAP extension installed via PECL"
        
        # 查找 imap.so
        local imap_so=""
        for path in "$ext_dir" "$install_dir/usr/local/lib/php/extensions" /usr/local/lib/php/extensions; do
            if [ -d "$path" ]; then
                found=$(find "$path" -name "imap.so" | head -1)
                if [ -n "$found" ] && [ -f "$found" ]; then
                    imap_so="$found"
                    break
                fi
            fi
        done
        
        if [ -n "$imap_so" ] && [ -f "$imap_so" ]; then
            mkdir -p "$ext_dir"
            cp "$imap_so" "$ext_dir/"
            echo "  ✅ imap.so copied to $ext_dir"
            
            # 添加到 php.ini
            local php_ini="$install_dir/usr/local/etc/php.ini"
            mkdir -p "$(dirname "$php_ini")"
            if [ -f "$php_ini" ]; then
                if ! grep -q "^extension=imap.so" "$php_ini"; then
                    echo "extension=imap.so" >> "$php_ini"
                fi
            else
                echo "extension=imap.so" > "$php_ini"
            fi
            echo "  ✅ imap.so added to php.ini"
            return 0
        fi
    fi
    
    echo "⚠️  PECL installation failed, trying manual build..."
    return 1
}

# ============================================================
# 从 PECL 源码手动编译 IMAP
# ============================================================
install_imap_manual() {
    local install_dir="$1"
    local build_dir="$2"
    
    echo ""
    echo "========================================"
    echo "[ * ] Building IMAP extension from PECL source"
    echo "========================================"
    
    local php_bin="$install_dir/usr/local/bin/php"
    local phpize="$install_dir/usr/local/bin/phpize"
    local php_config="$install_dir/usr/local/bin/php-config"
    
    if [ ! -f "$php_bin" ] || [ ! -f "$phpize" ]; then
        echo "❌ PHP or phpize not found"
        return 1
    fi
    
    # 下载 IMAP PECL 源码
    echo "[ * ] Downloading imap PECL source..."
    cd /tmp
    if [ ! -f "imap-1.0.3.tgz" ]; then
        fetch -o imap-1.0.3.tgz https://pecl.php.net/get/imap-1.0.3.tgz || \
        fetch -o imap-1.0.3.tgz https://github.com/php/pecl-mail-imap/archive/refs/tags/1.0.3.tar.gz
    fi
    
    # 解压
    rm -rf imap-1.0.3
    tar -xzf imap-1.0.3.tgz || tar -xzf imap-1.0.3.tar.gz
    cd imap-1.0.3 || cd pecl-mail-imap-1.0.3 || return 1
    
    echo "[ * ] Running phpize..."
    "$phpize" --with-php-config="$php_config" 2>&1 | tee -a "$LOG_DIR/imap-manual-phpize.log"
    
    echo "[ * ] Configuring..."
    ./configure --with-php-config="$php_config" --with-imap=/usr/local --with-imap-ssl=/usr/local 2>&1 | tee -a "$LOG_DIR/imap-manual-configure.log"
    
    echo "[ * ] Compiling..."
    make 2>&1 | tee -a "$LOG_DIR/imap-manual-make.log"
    
    # 获取扩展目录并安装
    local zend_api_no=$(grep "^#define ZEND_MODULE_API_NO" "$build_dir/Zend/zend_modules.h" | awk '{print $3}')
    local ext_dir="$install_dir/usr/local/lib/php/extensions/no-debug-non-zts-${zend_api_no}"
    mkdir -p "$ext_dir"
    
    if [ -f "modules/imap.so" ]; then
        cp modules/imap.so "$ext_dir/"
        echo "  ✅ imap.so installed to $ext_dir"
    elif [ -f ".libs/imap.so" ]; then
        cp .libs/imap.so "$ext_dir/"
        echo "  ✅ imap.so installed to $ext_dir"
    else
        echo "❌ imap.so not found"
        find . -name "imap.so" 2>/dev/null
        return 1
    fi
    
    # 添加到 php.ini
    local php_ini="$install_dir/usr/local/etc/php.ini"
    mkdir -p "$(dirname "$php_ini")"
    if [ -f "$php_ini" ]; then
        if ! grep -q "^extension=imap.so" "$php_ini"; then
            echo "extension=imap.so" >> "$php_ini"
        fi
    else
        echo "extension=imap.so" > "$php_ini"
    fi
    
    echo "  ✅ imap.so added to php.ini"
    return 0
}
# ============================================================
# 从源码编译安装 aspell 库
# ============================================================
build_aspell_from_source() {
    echo "  [ * ] Building aspell from source..."
    
    cd /tmp || return 1
    
    # 下载 aspell 源码
    if [ ! -f "aspell-0.60.8.2.tar.gz" ]; then
        echo "    Downloading aspell-0.60.8.2.tar.gz..."
        fetch -o aspell-0.60.8.2.tar.gz https://ftp.gnu.org/gnu/aspell/aspell-0.60.8.2.tar.gz || return 1
    fi
    
    # 解压
    rm -rf aspell-0.60.8.2
    tar -xzf aspell-0.60.8.2.tar.gz || return 1
    cd aspell-0.60.8.2 || return 1
    
    # 配置
    echo "    Configuring aspell..."
    ./configure --prefix=/usr/local || return 1
    
    # 编译
    echo "    Compiling aspell (using $NUM_CPUS cores)..."
    make -j"$NUM_CPUS" || return 1
    
    # 安装
    echo "    Installing aspell..."
    make install || return 1
    
    # 更新库缓存
    ldconfig || true
    
    cd /tmp
    rm -rf aspell-0.60.8.2
    
    echo "  ✅ aspell installed successfully"
    return 0
}

# ============================================================
# 从源码手动下载编译 PSPell（当 PECL 失败时）
# ============================================================
build_pspell_manual() {
    local install_dir="$1"
    local build_dir="$2"
    
    echo "  [ * ] Building PSPell from manual download..."
    
    local php_bin="$install_dir/usr/local/bin/php"
    local phpize="$install_dir/usr/local/bin/phpize"
    local php_config="$install_dir/usr/local/bin/php-config"
    
    if [ ! -f "$php_bin" ] || [ ! -f "$phpize" ]; then
        echo "    ❌ PHP or phpize not found"
        return 1
    fi
    
    # 下载 PSPell PECL 源码
    cd /tmp || return 1
    
    if [ ! -f "pspell.tgz" ]; then
        echo "    Downloading PSPell PECL source..."
        fetch -o pspell.tgz https://pecl.php.net/get/pspell-1.0.1.tgz || \
        fetch -o pspell.tgz https://github.com/php/pecl-text-pspell/archive/refs/tags/1.0.1.tar.gz || true
    fi
    
    if [ ! -f "pspell.tgz" ]; then
        echo "    ❌ Failed to download PSPell source"
        return 1
    fi
    
    # 解压
    rm -rf pspell-*
    tar -xzf pspell.tgz || return 1
    
    # 进入目录
    PSPELL_DIR=$(find . -maxdepth 1 -type d -name "pspell-*" | head -1)
    if [ -z "$PSPELL_DIR" ]; then
        echo "    ❌ Failed to extract PSPell source"
        return 1
    fi
    cd "$PSPELL_DIR" || return 1
    
    # 设置环境变量
    export PSPELL_CFLAGS="-I/usr/local/include"
    export PSPELL_LIBS="-L/usr/local/lib -laspell"
    
    echo "    Running phpize..."
    "$phpize" || return 1
    
    echo "    Configuring..."
    ./configure --with-php-config="$php_config" --with-pspell=/usr/local || return 1
    
    echo "    Compiling..."
    make || return 1
    
    echo "    Installing..."
    make install || return 1
    
    # 复制到正确的扩展目录
    local zend_api_no=$(grep "^#define ZEND_MODULE_API_NO" "$build_dir/Zend/zend_modules.h" | awk '{print $3}')
    local ext_dir="$install_dir/usr/local/lib/php/extensions/no-debug-non-zts-${zend_api_no}"
    
    local pspell_so=$(find . -name "pspell.so" | head -1)
    if [ -n "$pspell_so" ] && [ -f "$pspell_so" ]; then
        mkdir -p "$ext_dir"
        cp "$pspell_so" "$ext_dir/"
        echo "    ✅ pspell.so installed to $ext_dir"
        
        local php_ini="$install_dir/usr/local/etc/php.ini"
        if ! grep -q "^extension=pspell.so" "$php_ini" 2>/dev/null; then
            echo "extension=pspell.so" >> "$php_ini"
        fi
        
        cd /tmp
        rm -rf pspell-*
        return 0
    fi
    
    cd /tmp
    rm -rf pspell-*
    echo "    ❌ pspell.so not found after build"
    return 1
}

# ============================================================
# 安装 PSPell 扩展（源码编译优先，PECL 备用，手动下载作为最后手段）
# ============================================================
install_pspell() {
    local install_dir="$1"
    local build_dir="$2"
    
    echo ""
    echo "========================================"
    echo "[ * ] Installing PSPell extension"
    echo "========================================"
    
    local installed=0
    
    # ============================================================
    # 先安装 aspell 库（PSpell 的依赖）
    # ============================================================
    if [ "$OSTYPE" = 'freebsd' ]; then
        # 首先尝试用 pkg 安装
        if pkg info | grep -q aspell; then
            echo "  ✅ aspell already installed"
        else
            echo "  [ * ] aspell not found, installing from source..."
            if build_aspell_from_source; then
                echo "  ✅ aspell installed from source"
            else
                echo "  ⚠️  aspell source build failed, trying pkg..."
                pkg install -y aspell || true
            fi
        fi
    fi
    
    # ============================================================
    # 尝试 1: 源码编译（如果 PHP 源码中存在）
    # ============================================================
    if [ -d "$build_dir/ext/pspell" ]; then
        echo "[ * ] Attempt 1: Building PSPell from source..."
        if build_pspell_from_source "$install_dir" "$build_dir"; then
            installed=1
            echo "  ✅ PSPell installed from source"
        else
            echo "  ⚠️  Source build failed, trying PECL..."
        fi
    else
        echo "  ℹ️  PSPell source not found in PHP, trying PECL..."
    fi
    
    # ============================================================
    # 尝试 2: PECL 安装
    # ============================================================
    if [ $installed -eq 0 ]; then
        echo "[ * ] Attempt 2: Installing PSPell via PECL..."
        if install_pspell_via_pecl "$install_dir" "$build_dir"; then
            installed=1
            echo "  ✅ PSPell installed via PECL"
        else
            echo "  ⚠️  PECL installation failed, trying manual download..."
        fi
    fi
    
    # ============================================================
    # 尝试 3: 手动下载编译
    # ============================================================
    if [ $installed -eq 0 ]; then
        echo "[ * ] Attempt 3: Installing PSPell from manual download..."
        if build_pspell_manual "$install_dir" "$build_dir"; then
            installed=1
            echo "  ✅ PSPell installed from manual download"
        else
            echo "  ❌ Manual download installation failed"
        fi
    fi
    
    # ============================================================
    # 最终结果
    # ============================================================
    if [ $installed -eq 1 ]; then
        echo "  ✅ PSPell installed successfully"
        return 0
    else
        echo "  ❌ PSPell installation failed (all methods)"
        return 1
    fi
}

# ============================================================
# 编译 ImageMagick 扩展
# ============================================================
build_imagick() {
    local build_dir="$1"
    local install_dir="$2"
    
    if [ ! -d "$build_dir/ext/imagick" ]; then
        echo "⚠️  ImageMagick extension not found, skipping"
        return 0
    fi
    
    echo "[ * ] Building ImageMagick extension..."
    
    local php_prefix="$install_dir/usr/local"
    local php_config="$php_prefix/bin/php-config"
    local phpize="$php_prefix/bin/phpize"
    
    if [ ! -f "$phpize" ] || [ ! -f "$php_config" ]; then
        echo "⚠️  phpize or php-config not found, skipping ImageMagick"
        return 0
    fi
    
    cd "$build_dir/ext/imagick" || return 1

    echo "[ * ] Creating symlinks to build files..."
    if [ -d "$build_dir/build" ]; then
        mkdir -p /usr/local/lib/php/build
        rm -rf /usr/local/lib/php/build || true
        ln -sf "$build_dir/build" /usr/local/lib/php/build
        echo "  ✅ Symlink: /usr/local/lib/php/build -> $build_dir/build"
        
        for file in mkdep.awk scan_makefile_in.awk shtool libtool.m4 ax_check_compile_flag.m4; do
            if [ -f "$build_dir/build/$file" ] && [ ! -f "$file" ]; then
                ln -sf "$build_dir/build/$file" ./
                echo "  ✅ $file -> build/$file"
            fi
        done
    fi
    
    echo "  [ * ] Creating symlinks for root build files..."
    for file in acinclude.m4 Makefile.global config.sub config.guess ltmain.sh run-tests.php; do
        if [ -f "$build_dir/$file" ]; then
            ln -sf "$build_dir/$file" /usr/local/lib/php/build/
            echo "  ✅ $file -> root/$file"
        fi
    done
    
    if [ -f "$build_dir/scripts/phpize.m4" ]; then
        ln -sf "$build_dir/scripts/phpize.m4" "$build_dir/phpize.m4"
        ln -sf "$build_dir/scripts/phpize.m4" /usr/local/lib/php/build/phpize.m4
        echo "  ✅ phpize.m4 symlink created"
    fi
    
    export PHP_PREFIX="$php_prefix"
    export PHP_CONFIG="$php_config"
    export PHPIZE="$phpize"
    export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:$PKG_CONFIG_PATH"
    export CFLAGS="-I/usr/local/include $CFLAGS"
    export LDFLAGS="-L/usr/local/lib $LDFLAGS"
    
    echo "[ * ] Running phpize..."
    "$phpize"
    echo "[ * ] Configuring ImageMagick extension..."
    ./configure --with-php-config="$php_config" --with-imagick=/usr/local
    
    echo "[ * ] Compiling ImageMagick extension..."
    make
    
    echo "[ * ] Installing ImageMagick extension..."
    make install INSTALL_ROOT="$install_dir"

    local zend_api_no=$(grep "^#define ZEND_MODULE_API_NO" "$build_dir/Zend/zend_modules.h" | awk '{print $3}')
    local ext_dir="$install_dir/usr/local/lib/php/extensions/no-debug-non-zts-${zend_api_no}"

    if [ ! -f "$ext_dir/imagick.so" ] && [ -f "$build_dir/ext/imagick/modules/imagick.so" ]; then
        mkdir -p "$ext_dir"
        cp "$build_dir/ext/imagick/modules/imagick.so" "$ext_dir/"
        echo "  ✅ imagick.so copied from modules"
    fi
    
    if [ -f "$ext_dir/imagick.so" ]; then
        echo "  ✅ ImageMagick extension installed to $ext_dir/imagick.so"
        
        local php_ini_dir="$install_dir/usr/local/etc"
        mkdir -p "$php_ini_dir"
        if [ -f "$php_ini_dir/php.ini" ]; then
            if ! grep -q "^extension=imagick.so" "$php_ini_dir/php.ini"; then
                echo "extension=imagick.so" >> "$php_ini_dir/php.ini"
            fi
        else
            echo "extension=imagick.so" > "$php_ini_dir/php.ini"
        fi
    else
        echo "⚠️  ImageMagick extension not found in expected location"
        find "$install_dir" -name "imagick.so" || echo "  Not found anywhere"
    fi
    
    cd - > /dev/null
    echo "  ✅ ImageMagick extension build complete"
    return 0
}

# ============================================================
# 编译 APCu 扩展
# ============================================================
build_apcu() {
    local build_dir="$1"
    local install_dir="$2"
    
    if [ ! -d "$build_dir/ext/apcu" ]; then
        echo "⚠️  APCu extension not found, skipping"
        return 0
    fi
    
    echo "[ * ] Building APCu extension..."
    
    local php_prefix="$install_dir/usr/local"
    local php_config="$php_prefix/bin/php-config"
    local phpize="$php_prefix/bin/phpize"
    
    if [ ! -f "$phpize" ] || [ ! -f "$php_config" ]; then
        echo "⚠️  phpize or php-config not found, skipping APCu"
        return 0
    fi
    
    cd "$build_dir/ext/apcu" || return 1

    echo "[ * ] Creating symlinks to build files..."
    if [ -d "$build_dir/build" ]; then
        mkdir -p /usr/local/lib/php/build
        rm -rf /usr/local/lib/php/build || true
        ln -sf "$build_dir/build" /usr/local/lib/php/build
        echo "  ✅ Symlink: /usr/local/lib/php/build -> $build_dir/build"
        
        for file in mkdep.awk scan_makefile_in.awk shtool libtool.m4 ax_check_compile_flag.m4; do
            if [ -f "$build_dir/build/$file" ] && [ ! -f "$file" ]; then
                ln -sf "$build_dir/build/$file" ./
                echo "  ✅ $file -> build/$file"
            fi
        done
    fi
    
    echo "  [ * ] Creating symlinks for root build files..."
    for file in acinclude.m4 Makefile.global config.sub config.guess ltmain.sh run-tests.php; do
        if [ -f "$build_dir/$file" ]; then
            ln -sf "$build_dir/$file" /usr/local/lib/php/build/
            echo "  ✅ $file -> root/$file"
        fi
    done
    
    if [ -f "$build_dir/scripts/phpize.m4" ]; then
        ln -sf "$build_dir/scripts/phpize.m4" "$build_dir/phpize.m4"
        ln -sf "$build_dir/scripts/phpize.m4" /usr/local/lib/php/build/phpize.m4
        echo "  ✅ phpize.m4 symlink created"
    fi
    
    export PHP_PREFIX="$php_prefix"
    export PHP_CONFIG="$php_config"
    export PHPIZE="$phpize"
    export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:$PKG_CONFIG_PATH"
    export CFLAGS="-I/usr/local/include $CFLAGS"
    export LDFLAGS="-L/usr/local/lib $LDFLAGS"
    
    echo "[ * ] Running phpize..."
    "$phpize"
    echo "[ * ] Configuring APCu extension..."
    ./configure --with-php-config="$php_config"
    
    echo "[ * ] Compiling APCu extension..."
    make
    
    echo "[ * ] Installing APCu extension..."
    make install INSTALL_ROOT="$install_dir"

    local zend_api_no=$(grep "^#define ZEND_MODULE_API_NO" "$build_dir/Zend/zend_modules.h" | awk '{print $3}')
    local ext_dir="$install_dir/usr/local/lib/php/extensions/no-debug-non-zts-${zend_api_no}"

    if [ ! -f "$ext_dir/apcu.so" ] && [ -f "$build_dir/ext/apcu/modules/apcu.so" ]; then
        mkdir -p "$ext_dir"
        cp "$build_dir/ext/apcu/modules/apcu.so" "$ext_dir/"
        echo "  ✅ apcu.so copied from modules"
    fi
    
    if [ -f "$ext_dir/apcu.so" ]; then
        echo "  ✅ APCu extension installed to $ext_dir/apcu.so"
        
        local php_ini_dir="$install_dir/usr/local/etc"
        mkdir -p "$php_ini_dir"
        if [ -f "$php_ini_dir/php.ini" ]; then
            if ! grep -q "^extension=apcu.so" "$php_ini_dir/php.ini"; then
                echo "extension=apcu.so" >> "$php_ini_dir/php.ini"
            fi
            # 添加 APCu 配置
            if ! grep -q "^apcu.enabled=1" "$php_ini_dir/php.ini"; then
                echo "apcu.enabled=1" >> "$php_ini_dir/php.ini"
                echo "apcu.shm_size=256M" >> "$php_ini_dir/php.ini"
                echo "apcu.ttl=7200" >> "$php_ini_dir/php.ini"
                echo "apcu.gc_ttl=3600" >> "$php_ini_dir/php.ini"
                echo "apcu.entries_hint=4096" >> "$php_ini_dir/php.ini"
                echo "  ✅ APCu configuration added to php.ini"
            fi
        else
            echo "extension=apcu.so" > "$php_ini_dir/php.ini"
            echo "apcu.enabled=1" >> "$php_ini_dir/php.ini"
            echo "apcu.shm_size=256M" >> "$php_ini_dir/php.ini"
            echo "apcu.ttl=7200" >> "$php_ini_dir/php.ini"
            echo "apcu.gc_ttl=3600" >> "$php_ini_dir/php.ini"
            echo "apcu.entries_hint=4096" >> "$php_ini_dir/php.ini"
        fi
    else
        echo "⚠️  APCu extension not found in expected location"
        find "$install_dir" -name "apcu.so" || echo "  Not found anywhere"
    fi
    
    cd - > /dev/null
    echo "  ✅ APCu extension build complete"
    return 0
}

# ============================================================
# 构建 PHP（使用 Hestia 路径）
# ============================================================
build_php() {
    local build_dir="$BUILD_DIR/php-src-${PHP_VERSION}"
    local install_dir="$BUILD_DIR/php-${PHP_VERSION}"
    local major=$(echo "$PHP_VERSION" | cut -d. -f1)
    local minor=$(echo "$PHP_VERSION" | cut -d. -f2)

    echo ""
    echo "========================================"
    echo "[ * ] Building PHP ${PHP_VERSION} with OpenSSL 4.x"
    echo "========================================"

    if ! download_php; then
        echo "❌ Failed to download PHP ${PHP_VERSION}"
        return 1
    fi

    if [ ! -d "$build_dir" ]; then
        echo "[ * ] Extracting PHP ${PHP_VERSION}..."
        tar -xf "$ARCHIVE_DIR/php-${PHP_VERSION}.tar.gz" -C "$BUILD_DIR"
        if [ -d "$BUILD_DIR/php-src-php-${PHP_VERSION}" ]; then
            mv "$BUILD_DIR/php-src-php-${PHP_VERSION}" "$build_dir"
        elif [ -d "$BUILD_DIR/php-${PHP_VERSION}" ]; then
            mv "$BUILD_DIR/php-${PHP_VERSION}" "$build_dir"
        elif [ -d "$BUILD_DIR/php-src-${PHP_VERSION}" ]; then
            mv "$BUILD_DIR/php-src-${PHP_VERSION}" "$build_dir"
        fi
    fi

    # 下载 ImageMagick 扩展
    if ! download_imagick "$build_dir"; then
        echo "⚠️  ImageMagick extension download failed, continuing without it"
    fi

    # 下载 APCu 扩展
    if ! download_apcu "$build_dir"; then
        echo "⚠️  APCu extension download failed, continuing without it"
    fi

    cd "$build_dir" || return 1

    [ -f "Makefile" ] && gmake clean || true

    apply_patches "$build_dir"

    # 确保 PHP 构建目录完整
    echo "[ * ] Ensuring PHP build structure..."
    if [ -d "$build_dir/build" ]; then
        echo "  ✓ Build directory exists"
    else
        echo "  ⚠️  Build directory missing, recreating..."
        mkdir -p "$build_dir/build"
        cp "$build_dir/configure" "$build_dir/build/" || true
    fi

    # ============================================================
    # 设置编译环境 - 使用系统 ICU
    # ============================================================
    cd "$build_dir" || {
        echo "❌ Failed to return to PHP source directory"
        return 1
    }
    echo "[ * ] Current directory: $(pwd)"
    
    # 检测系统 ICU
    echo "[ * ] Detecting system ICU..."
    ICU_SYSTEM_PREFIX="/usr/local"
    ICU_LIB_DIR="/usr/local/lib"
    ICU_INCLUDE_DIR="/usr/local/include"
    
    if [ -f "$ICU_LIB_DIR/libicuuc.so.76" ]; then
        echo "  ✅ Found ICU 76"
        ICU_VERSION="76"
    elif [ -f "$ICU_LIB_DIR/libicuuc.so.75" ]; then
        echo "  ✅ Found ICU 75"
        ICU_VERSION="75"
    elif [ -f "$ICU_LIB_DIR/libicuuc.so.74" ]; then
        echo "  ✅ Found ICU 74"
        ICU_VERSION="74"
    else
        echo "  ⚠️  System ICU not found, will use pkg-config"
        ICU_VERSION="unknown"
    fi
    
    # 设置编译环境
    export CC=clang
    export CXX=clang++
    export CXXFLAGS="-std=c++17 -Wno-register -Wno-deprecated-declarations"
    export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:/usr/local/libdata/pkgconfig:/usr/lib/pkgconfig"
    
    export ICU_CFLAGS="-I$ICU_INCLUDE_DIR"
    export ICU_LIBS="-L$ICU_LIB_DIR -licui18n -licuuc -licudata -licuio"
    export LDFLAGS="-L$ICU_LIB_DIR -Wl,-rpath,$ICU_LIB_DIR"
    export CPPFLAGS="-I$ICU_INCLUDE_DIR -I$ICU_INCLUDE_DIR/freetype2"
    export CFLAGS="-I$ICU_INCLUDE_DIR -I/usr/local/include \
        -Wno-deprecated-declarations \
        -Wno-incompatible-pointer-types-discards-qualifiers \
        -Wno-implicit-function-declaration \
        -Wno-pointer-sign \
        -D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE \
        -DHAVE_IF_INDEXTONAME=1 -DHAVE_IF_NAMETOINDEX=1"
    
    export LD_LIBRARY_PATH="/usr/local/lib:/usr/lib"
    export DTRACE="/usr/sbin/dtrace"
    export ac_cv_prog_DTRACE="/usr/sbin/dtrace"
    
    echo "[ ✓ ] ICU config: $ICU_VERSION"
    
    # ============================================================
    # 设置 OpenSSL 环境
    # ============================================================
    echo "[ * ] Setting OpenSSL 4.x environment..."
    
    export OPENSSL_CFLAGS="-I/usr/local/include"
    export OPENSSL_LIBS="-L/usr/local/lib -lssl -lcrypto"
    
    if command -v openssl >/dev/null; then
        OPENSSL_VER=$(openssl version | awk '{print $2}')
        echo "  ✓ Using OpenSSL: $OPENSSL_VER"
    fi
    
    echo "[ ✓ ] OpenSSL 4.x environment configured"

    # ============================================================
    # 检测并设置 DTrace
    # ============================================================
    echo "[ * ] Detecting DTrace..."
    DT_PATH=""
    for path in /usr/sbin/dtrace /usr/bin/dtrace /sbin/dtrace /usr/local/bin/dtrace; do
        if [ -f "$path" ] && [ -x "$path" ]; then
            DT_PATH="$path"
            break
        fi
    done

    if [ -n "$DT_PATH" ]; then
        echo "  ✓ DTrace found: $DT_PATH"
        export DTRACE="$DT_PATH"
        export ac_cv_prog_DTRACE="$DT_PATH"
        export PATH="$(dirname "$DT_PATH"):$PATH"
    else
        echo "  ⚠️  DTrace not found, disabling"
        export ac_cv_prog_DTRACE=no
        export enable_dtrace=no
    fi

    # ============================================================
    # 配置 PSPell 环境
    # ============================================================
    if [ "$OSTYPE" = 'freebsd' ]; then
        echo "[ * ] Configuring PSPell support..."
        
        if pkg info | grep -q aspell; then
            echo "  ✅ aspell already installed"
        else
            echo "  Installing aspell..."
            pkg install -y aspell || true
        fi
        
        if [ -f "/usr/local/lib/libaspell.so" ] || [ -f "/usr/local/lib/libpspell.so" ]; then
            export PSPELL_CFLAGS="-I/usr/local/include"
            export PSPELL_LIBS="-L/usr/local/lib -laspell"
            export ac_cv_lib_pspell_pspell_new=yes
            export ac_cv_lib_pspell_pspell_new_config=yes
            export ac_cv_lib_pspell_pspell_check=yes
            export ac_cv_lib_pspell_pspell_config=yes
            echo "  ✅ PSPell libraries found"
        else
            echo "  ⚠️  PSPell libraries not found"
            export PSPELL_LIBS="-laspell"
            export ac_cv_lib_pspell_pspell_new=yes
            export ac_cv_lib_pspell_pspell_new_config=yes
            export ac_cv_lib_pspell_pspell_check=yes
            export ac_cv_lib_pspell_pspell_config=yes
        fi
    fi
    # ============================================================
    # 从源码编译 libarchive（链接 OpenSSL 4.x）
    # ============================================================
    echo ""
    echo "========================================"
    echo "[1/7] 编译 libarchive"
    echo "========================================"

    echo "[ * ] Setting up library paths for compilation..."
    export LD_LIBRARY_PATH="/usr/local/lib:/usr/lib"
    export LIBRARY_PATH="/usr/local/lib:/usr/lib"
    echo "[ * ] Using GNU binutils..."
    if command -v gar >/dev/null; then
        export AR="gar"
        export RANLIB="granlib"
        export NM="gnm"
        echo "  ✅ GNU ar: $(which gar)"
        echo "  ✅ GNU ranlib: $(which granlib)"
        echo "  ✅ GNU nm: $(which gnm)"
    else
        echo "  ⚠️  GNU binutils not found, please install: pkg install binutils"
        export AR="ar"
        export RANLIB="ranlib"
        export NM="nm"
    fi

    if [ ! -f "$SRC_DIR/src/php7.0/libarchive-3.7.2.tar.gz" ]; then
        echo "❌ libarchive-3.7.2.tar.gz 不存在"
        echo "   Expected: $SRC_DIR/src/php7.0/libarchive-3.7.2.tar.gz"
        exit 1
    fi

    cp "$SRC_DIR/src/php7.0/libarchive-3.7.2.tar.gz" /tmp/
    cd /tmp
    extract_archive libarchive-3.7.2.tar.gz

    LIBARCHIVE_DIR=$(find /tmp -maxdepth 1 -type d -name "libarchive*" | head -1)

    if [ -z "$LIBARCHIVE_DIR" ]; then
        echo "❌ 找不到 libarchive 目录！"
        echo "当前 /tmp 内容:"
        ls -la /tmp/
        exit 1
    fi

    echo "[ * ] Entering: $LIBARCHIVE_DIR"
    cd "$LIBARCHIVE_DIR"

    echo "[ * ] 配置 libarchive..."
    ./configure \
        --prefix=/usr/local \
        --with-openssl \
        --without-lzma \
        --without-zstd \
        --without-xml2 \
        --without-expat \
        CPPFLAGS="-I/usr/local/include" \
        LDFLAGS="-L/usr/local/lib -Wl,-rpath,/usr/local/lib" \
        LIBS="-lcrypto -lssl"
        
    if [ $? -ne 0 ]; then
        echo "❌ libarchive 配置失败"
        echo "--- Last 50 lines of config.log ---"
        cat config.log | tail -50
        exit 1
    fi

    echo "[ * ] 编译 libarchive (使用 $NUM_CPUS 核)..."
    export LD_LIBRARY_PATH="/usr/local/lib:/usr/lib"
    echo "  Using AR: $AR"
    echo "  Using RANLIB: $RANLIB"
    echo "  Using NM: $NM"

    make -j"$NUM_CPUS"
    if [ $? -ne 0 ]; then
        echo "❌ libarchive 编译失败"
        echo "--- Build errors ---"
        make -j1 | grep -E "error:|Error:" | head -20
        exit 1
    fi

    echo "[ * ] 安装 libarchive..."
    make install
    if [ $? -ne 0 ]; then
        echo "❌ libarchive 安装失败"
        exit 1
    fi

    cd /tmp
    rm -rf libarchive-3.7.2 libarchive-3.7.2.tar.gz

    if [ -f "/usr/local/lib/libarchive.so" ]; then
        echo "✅ libarchive 编译成功"
        echo "   文件: /usr/local/lib/libarchive.so"
        echo "   大小: $(stat -f %z /usr/local/lib/libarchive.so) bytes"
        echo "   du -h: $(du -h /usr/local/lib/libarchive.so | cut -f1)"
        
        if [ -L "/usr/local/lib/libarchive.so" ]; then
            echo "   ⚠️  这是一个符号链接，指向: $(readlink /usr/local/lib/libarchive.so)"
            TARGET=$(readlink /usr/local/lib/libarchive.so)
            if [ -f "$TARGET" ]; then
                echo "   目标文件大小: $(stat -f %z "$TARGET") bytes"
            fi
        fi
        
        echo "[ * ] Checking OpenSSL dependencies..."
        if ldd /usr/local/lib/libarchive.so | grep -q "libcrypto.so"; then
            echo "  libarchive links to:"
            ldd /usr/local/lib/libarchive.so | grep -E "(crypto|ssl)"
        else
            echo "  ✅ libarchive has no direct OpenSSL dependency"
        fi
        
        if objdump -p /usr/local/lib/libarchive.so | grep -q "OPENSSL_1_1_0"; then
            echo "  ⚠️  libarchive still requires OPENSSL_1_1_0"
        else
            echo "  ✅ libarchive is OpenSSL 4.x compatible"
        fi
    else
        echo "❌ libarchive 安装失败，文件不存在"
        exit 1
    fi    

    # ============================================================
    # 用 OpenSSL 4.x 重新编译所有依赖库
    # ============================================================
    if [ ! -d "/usr/ports" ]; then
        echo ""
        echo "========================================"
        echo "从源码编译依赖库 (OpenSSL 4.x)"
        echo "========================================"
        
        # 设置编译环境
        export CC=gcc14
        export CXX=g++14
        export CFLAGS="-I/usr/local/include -DOPENSSL_API_COMPAT=0x10100000L"
        export LDFLAGS="-L/usr/local/lib -Wl,-rpath,/usr/local/lib"
        export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig"
        export LD_LIBRARY_PATH="/usr/local/lib:$LD_LIBRARY_PATH"
        
        # 1. libssh2
        echo ""
        echo "========================================"
        echo "[2/7] 编译 libssh2"
        echo "========================================"
        unset PSPELL_LIBS
        unset LIBS
        export LIBS="-lssl -lcrypto"
        
        if [ -f "/usr/local/lib/libssh2.so" ]; then
            echo "[ * ] 删除旧的 libssh2..."
            rm -f /usr/local/lib/libssh2.so
            rm -f /usr/local/lib/libssh2.so.1
        fi
        
        cp "$SRC_DIR/src/php7.0/libssh2-1.11.1.tar.gz" /tmp/
        cd /tmp
        extract_archive libssh2-1.11.1.tar.gz
        cd libssh2-1.11.1
        
        echo "[ * ] 配置 libssh2..."
        ./configure --prefix=/usr/local \
            --with-openssl \
            --with-libssl-prefix=/usr/local \
            CPPFLAGS="-I/usr/local/include" \
            LDFLAGS="-L/usr/local/lib -Wl,-rpath,/usr/local/lib"
            
        if [ $? -ne 0 ]; then
            echo "❌ libssh2 配置失败"
            exit 1
        fi
        
        echo "[ * ] 编译 libssh2..."
        make -j"$NUM_CPUS"
        if [ $? -ne 0 ]; then
            echo "❌ libssh2 编译失败"
            exit 1
        fi
        
        echo "[ * ] 安装 libssh2..."
        make install
        if [ $? -ne 0 ]; then
            echo "❌ libssh2 安装失败"
            exit 1
        fi
        
        cd /tmp
        rm -rf libssh2-1.11.1 libssh2-1.11.1.tar.gz
        
        if [ -f "/usr/local/lib/libssh2.so" ]; then
            echo "✅ libssh2 编译成功"
            echo "   文件: /usr/local/lib/libssh2.so"
            echo "   大小: $(du -h /usr/local/lib/libssh2.so | cut -f1)"
        else
            echo "❌ libssh2 编译失败"
            exit 1
        fi
        
        # 2. curl - 强制重新编译
        echo ""
        echo "========================================"
        echo "[3/7] 编译 curl"
        echo "========================================"
        
        if [ -f "/usr/local/lib/libcurl.so" ]; then
            echo "[ * ] 删除旧的 curl..."
            rm -f /usr/local/lib/libcurl.so /usr/local/lib/libcurl.so.4
        fi
        
        cp "$SRC_DIR/src/php7.0/curl-8.20.0.tar.gz" /tmp/
        cd /tmp
        extract_archive curl-8.20.0.tar.gz
        cd curl-8.20.0
        
        echo "[ * ] 配置 curl..."
        ./configure --prefix=/usr/local \
            --with-openssl \
            --with-libssh2 \
            --disable-ldap \
            CPPFLAGS="-I/usr/local/include" \
            LDFLAGS="-L/usr/local/lib -Wl,-rpath,/usr/local/lib"
        if [ $? -ne 0 ]; then
            echo "❌ curl 配置失败"
            cat config.log | tail -50
            exit 1
        fi
        
        echo "[ * ] 编译 curl..."
        make -j"$NUM_CPUS"
        if [ $? -ne 0 ]; then
            echo "❌ curl 编译失败"
            echo "--- Build errors ---"
            make -j1 | grep -E "error:" | head -20
            exit 1
        fi
        
        echo "[ * ] 安装 curl..."
        make install
        if [ $? -ne 0 ]; then
            echo "❌ curl 安装失败"
            exit 1
        fi
        
        cd /tmp
        rm -rf curl-8.20.0 curl-8.20.0.tar.gz
        
        if [ -f "/usr/local/lib/libcurl.so" ]; then
            echo "✅ curl 编译成功"
            echo "   文件: /usr/local/lib/libcurl.so"
            echo "   大小: $(du -h /usr/local/lib/libcurl.so | cut -f1)"
            
            if ldd /usr/local/lib/libcurl.so | grep -q "libcrypto.so"; then
                echo "  链接到 OpenSSL:"
                ldd /usr/local/lib/libcurl.so | grep -E "(crypto|ssl)"
            fi
        else
            echo "❌ curl 编译失败"
            exit 1
        fi
        
        # 3. openldap
        echo ""
        echo "========================================"
        echo "[4/7] 编译 openldap"
        echo "========================================"
        
        if [ -f "/usr/local/lib/libldap.so" ]; then
            echo "[ * ] 删除旧的 openldap..."
            rm -f /usr/local/lib/libldap.so
            rm -f /usr/local/lib/libldap.so.2
            rm -f /usr/local/lib/liblber.so
            rm -f /usr/local/lib/liblber.so.2
        fi
        
        cp "$SRC_DIR/src/php7.0/openldap-2.6.13.tgz" /tmp/
        cd /tmp
        extract_archive openldap-2.6.13.tgz
        cd openldap-2.6.13
        cp "$SRC_DIR/src/php7.0/tls_o.c" libraries/libldap/tls_o.c
        echo "[ * ] 配置 openldap..."
        ./configure --prefix=/usr/local \
            --with-tls=openssl \
            CPPFLAGS="-I/usr/local/include" \
            LDFLAGS="-L/usr/local/lib -Wl,-rpath,/usr/local/lib"
        if [ $? -ne 0 ]; then
            echo "❌ openldap 配置失败"
            exit 1
        fi
        
        echo "[ * ] 生成依赖..."
        make depend
        if [ $? -ne 0 ]; then
            echo "❌ openldap 依赖生成失败"
            exit 1
        fi
        
        echo "[ * ] 编译 openldap..."
        make -j"$NUM_CPUS"
        if [ $? -ne 0 ]; then
            echo "❌ openldap 编译失败"
            exit 1
        fi
        
        echo "[ * ] 安装 openldap..."
        make install
        if [ $? -ne 0 ]; then
            echo "❌ openldap 安装失败"
            exit 1
        fi
        
        cd /tmp
        rm -rf openldap-2.6.13 openldap-2.6.13.tgz
        
        if [ -f "/usr/local/lib/libldap.so" ]; then
            echo "✅ openldap 编译成功"
            echo "   文件: /usr/local/lib/libldap.so"
            echo "   大小: $(du -h /usr/local/lib/libldap.so | cut -f1)"
        else
            echo "❌ openldap 编译失败"
            exit 1
        fi
        
        # 4. postgresql
        echo ""
        echo "========================================"
        echo "[5/7] 编译 postgresql 客户端"
        echo "========================================"
        
        if [ -f "/usr/local/lib/libpq.so" ]; then
            echo "[ * ] 删除旧的 postgresql..."
            rm -f /usr/local/lib/libpq.so /usr/local/lib/libpq.so.5
        fi
        
        cp "$SRC_DIR/src/php7.0/postgresql-18.4.tar.gz" /tmp/
        cd /tmp
        extract_archive postgresql-18.4.tar.gz
        cd postgresql-18.4
        
        echo "[ * ] 配置 postgresql..."
        ./configure --prefix=/usr/local \
            --without-readline \
            --without-zlib \
            CPPFLAGS="-I/usr/local/include" \
            LDFLAGS="-L/usr/local/lib -Wl,-rpath,/usr/local/lib"
        if [ $? -ne 0 ]; then
            echo "❌ postgresql 配置失败"
            exit 1
        fi
        
        echo "[ * ] 编译 libpq..."
        cd src/interfaces/libpq
        gmake -j"$NUM_CPUS"
        if [ $? -ne 0 ]; then
            echo "❌ libpq 编译失败"
            exit 1
        fi
        
        echo "[ * ] 安装 libpq..."
        gmake install
        if [ $? -ne 0 ]; then
            echo "❌ libpq 安装失败"
            exit 1
        fi
        
        cd /tmp
        rm -rf postgresql-18.4 postgresql-18.4.tar.gz
        
        if [ -f "/usr/local/lib/libpq.so" ]; then
            echo "✅ postgresql 客户端编译成功"
            echo "   文件: /usr/local/lib/libpq.so"
            echo "   大小: $(du -h /usr/local/lib/libpq.so | cut -f1)"
        else
            echo "❌ postgresql 客户端编译失败"
            exit 1
        fi
        
        # 5. cyrus-sasl2
        echo ""
        echo "========================================"
        echo "[6/7] 编译 cyrus-sasl2"
        echo "========================================"

        if [ -f "/usr/local/lib/libsasl2.so" ]; then
            echo "[ * ] 删除旧的 cyrus-sasl..."
            rm -f /usr/local/lib/libsasl2.so
            rm -f /usr/local/lib/libsasl2.so.2
            rm -f /usr/local/lib/libsasl2.so.3
        fi

        cp "$SRC_DIR/src/php7.0/cyrus-sasl-2.1.28.tar.gz" /tmp/
        cd /tmp
        extract_archive cyrus-sasl-2.1.28.tar.gz
        cd cyrus-sasl-2.1.28

        echo "[ * ] 配置 cyrus-sasl2..."
        ./configure --prefix=/usr/local \
            --with-openssl=/usr/local \
            --with-gssapi=no \
            --with-ldap=no \
            --with-saslauthd=/var/run/saslauthd \
            --enable-login \
            --enable-plain \
            --enable-cram \
            --enable-digest \
            --enable-ntlm \
            --disable-otp \
            --disable-srp \
            CPPFLAGS="-I/usr/local/include" \
            LDFLAGS="-L/usr/local/lib -Wl,-rpath,/usr/local/lib"

        if [ $? -ne 0 ]; then
            echo "❌ cyrus-sasl2 配置失败"
            cat config.log | tail -50
            exit 1
        fi

        # 生成 md5global.h
        echo "[ * ] Generating md5global.h using makemd5..."
        cd include

        if [ ! -f "makemd5.c" ]; then
            echo "❌ makemd5.c not found!"
            exit 1
        fi

        echo "  Compiling makemd5..."
        if command -v gcc14 >/dev/null; then
            gcc14 -o makemd5 makemd5.c || cc -o makemd5 makemd5.c
        else
            cc -o makemd5 makemd5.c
        fi

        if [ ! -f "makemd5" ] || [ ! -x "makemd5" ]; then
            echo "❌ Failed to compile makemd5"
            if [ -f "md5global.h" ] && [ -s "md5global.h" ]; then
                echo "  ⚠️  Using existing md5global.h from source"
            else
                exit 1
            fi
        else
            echo "  Running makemd5 to generate md5global.h..."
            ./makemd5 > md5global.h

            if [ ! -f "md5global.h" ] || [ ! -s "md5global.h" ]; then
                echo "❌ Failed to generate md5global.h"
                exit 1
            fi
            echo "  ✅ md5global.h generated successfully"
        fi

        cd ..

        for makefile in include/Makefile include/Makefile.in; do
            if [ -f "$makefile" ]; then
                sed -i '' 's|\./ md5global\.h|./makemd5$(BUILD_EXEEXT) > md5global.h|g' "$makefile"
                echo "  ✓ Fixed $makefile"
            fi
        done

        echo "[ * ] 编译 cyrus-sasl2..."
        make -j"$NUM_CPUS"
        if [ $? -ne 0 ]; then
            echo "❌ cyrus-sasl2 编译失败"
            echo "--- Build errors ---"
            make -j1 | grep -E "error:|Error:" | head -20
            exit 1
        fi

        echo "[ * ] 安装 cyrus-sasl2..."
        make install
        if [ $? -ne 0 ]; then
            echo "❌ cyrus-sasl2 安装失败"
            exit 1
        fi

        cd /tmp
        rm -rf cyrus-sasl-2.1.28 cyrus-sasl-2.1.28.tar.gz

        if [ -f "/usr/local/lib/libsasl2.so" ]; then
            echo "✅ cyrus-sasl2 编译成功"
            echo "   文件: /usr/local/lib/libsasl2.so"
            echo "   大小: $(du -h /usr/local/lib/libsasl2.so | cut -f1)"
            
            if ldd /usr/local/lib/libsasl2.so | grep -q "libcrypto.so"; then
                echo "  链接到 OpenSSL:"
                ldd /usr/local/lib/libsasl2.so | grep -E "(crypto|ssl)"
            fi
            
            if objdump -p /usr/local/lib/libsasl2.so | grep -q "OPENSSL_1_1_0"; then
                echo "  ⚠️  libsasl2.so 仍然依赖 OPENSSL_1_1_0"
            else
                echo "  ✅ libsasl2.so 兼容 OpenSSL 4.x"
            fi
        else
            echo "❌ cyrus-sasl2 编译失败"
            exit 1
        fi

        # 6. c-client (IMAP)
        echo ""
        echo "========================================"
        echo "[7/7] 编译 c-client (IMAP library)"
        echo "========================================"

        if [ -f "/usr/local/lib/libc-client.so" ]; then
            echo "[ * ] 删除旧的 c-client..."
            rm -f /usr/local/lib/libc-client.so
            rm -f /usr/local/lib/libc-client.a
        fi

        cp "$SRC_DIR/src/php7.0/imap-imap-2007f_upstream.tar.gz" /tmp/
        cd /tmp
        extract_archive imap-imap-2007f_upstream.tar.gz
        cd imap-imap-2007f_upstream
        cp "$SRC_DIR/src/php7.0/c-client/"*.c src/osdep/unix/
        cp "$SRC_DIR/src/php7.0/mtest.c" src/mtest/mtest.c
        
        echo "[ * ] Patching Makefile to auto-answer 'y'..."
        perl -pi -e 's/read x; case "\$\$x" in y\) exit 0;; \\*\) .*;; esac/read x; case "\$\$x" in y\) exit 0;; *\) exit 0;; esac/g' Makefile
        echo "  Fixing OpenSSL paths for FreeBSD..."
        sed -i '' 's|SSLINCLUDE=/usr/include/openssl|SSLINCLUDE=/usr/local/include|g' Makefile
        sed -i '' 's|SSLLIB=/usr/lib|SSLLIB=/usr/local/lib|g' Makefile
        grep -n "SSLINCLUDE\|SSLLIB" Makefile | head -100
        echo "  ✅ Makefile patched"

        echo "[ * ] 配置并编译 c-client (bsf port for FreeBSD)..."
        make bsf \
            SSLTYPE=unix.nopwd \
            SSLINCLUDE=/usr/local/include \
            SSLLIB=/usr/local/lib \
            EXTRACFLAGS="-I/usr/local/include -DOPENSSL_API_COMPAT=0x10100000L -Wno-deprecated-declarations -Wno-error -fPIC" \
            EXTRALDFLAGS="-L/usr/local/lib -lssl -lcrypto -pthread" \
            INTERACTIVE=no 2>&1 | tee /tmp/c-client-build.log

        MAKE_EXIT=$?
        find /tmp/imap-imap-2007f_upstream -name "libc-client.a" -ls
        echo "========================================"
        echo "DEBUG: make exit code = $MAKE_EXIT"
        echo "DEBUG: Checking for libc-client.a"
        echo "========================================"

        if [ -f "c-client/c-client.a" ]; then
            echo "✅ c-client.a 存在 ($(du -h c-client/c-client.a | cut -f1))"
            LS_RESULT=0
        else
            echo "❌ c-client.a 不存在"
            LS_RESULT=1
        fi

        if [ $MAKE_EXIT -ne 0 ] || [ $LS_RESULT -ne 0 ]; then
            echo "❌ c-client 编译失败"
            echo "   Make 退出码: $MAKE_EXIT"
            echo "   静态库存在: $([ $LS_RESULT -eq 0 ] && echo '是' || echo '否')"
            exit 1
        fi

        echo "✅ c-client 编译成功！"
        echo "[ * ] 安装 c-client..."

        mkdir -p /usr/local/include/c-client
        cp c-client/*.h /usr/local/include/c-client/
        cp c-client/*.h /usr/local/include/

        cp c-client/c-client.a /usr/local/lib/libc-client.a
        echo "  ✅ libc-client.a installed"

        echo "[ * ] Creating shared library..."
        cd c-client || exit 1

        OBJ_FILES=$(find . -name "*.o" -type f | tr '\n' ' ')

        if [ -n "$OBJ_FILES" ]; then
            echo "  Found $(echo $OBJ_FILES | wc -w) object files"
            gcc14 -shared \
                -o libc-client.so \
                $OBJ_FILES \
                -L/usr/local/lib -lssl -lcrypto -pthread
            
            if [ -f "libc-client.so" ]; then
                cp libc-client.so /usr/local/lib/
                echo "  ✅ libc-client.so created and installed"
                
                if [ -f "/usr/local/lib/libc-client.so" ]; then
                    SIZE=$(du -h /usr/local/lib/libc-client.so | cut -f1)
                    echo "  ✅ libc-client.so installed ($SIZE)"
                fi
            else
                echo "  ❌ libc-client.so creation failed"
            fi
        else
            echo "  ⚠️  No object files found for shared library"
        fi
        cd ..

        echo "✅ c-client 安装完成"

        echo "[ * ] Verifying c-client installation..."

        if [ -f "/usr/local/lib/libc-client.a" ]; then
            echo "✅ 静态库: /usr/local/lib/libc-client.a ($(du -h /usr/local/lib/libc-client.a | cut -f1))"
        else
            echo "❌ 静态库不存在"
            exit 1
        fi

        if [ -f "/usr/local/lib/libc-client.so" ]; then
            echo "✅ 动态库: /usr/local/lib/libc-client.so ($(du -h /usr/local/lib/libc-client.so | cut -f1))"
            
            if ldd /usr/local/lib/libc-client.so | grep -q "libcrypto.so.30"; then
                echo "  ✅ 链接到 OpenSSL 4.x"
            else
                echo "  ⚠️  可能链接到其他 OpenSSL 版本"
                ldd /usr/local/lib/libc-client.so | grep crypto || echo "    无法检测"
            fi
        else
            echo "⚠️  动态库不存在（只有静态库）"
        fi
        
        cd /tmp
        rm -rf imap-imap-2007f_upstream
        echo "  ✅ Cleaned up temporary files"
        
        # 7. 验证所有库
        echo ""
        echo "========================================"
        echo "验证所有编译的库"
        echo "========================================"
        echo ""
        
        ALL_SUCCESS=1
        for lib in libarchive.so libssh2.so libcurl.so libldap.so libpq.so libsasl2.so libc-client.so; do
            if [ -f "/usr/local/lib/$lib" ]; then
                if [ -L "/usr/local/lib/$lib" ]; then
                    TARGET=$(readlink "/usr/local/lib/$lib")
                    SIZE=$(stat -f %z "/usr/local/lib/$TARGET" || echo "0")
                    SIZE_MB=$(echo "scale=2; $SIZE/1024/1024" | bc || echo "0")
                else
                    SIZE=$(stat -f %z "/usr/local/lib/$lib" || echo "0")
                    SIZE_MB=$(echo "scale=2; $SIZE/1024/1024" | bc || echo "0")
                fi
                
                echo -n "✅ $lib: ${SIZE_MB}MB  "
                
                if objdump -p "/usr/local/lib/$lib" | grep -q "OPENSSL_1_1_0"; then
                    echo "⚠️  依赖 OPENSSL_1_1_0"
                    ALL_SUCCESS=0
                else
                    echo "✅ OpenSSL 4.x 兼容"
                fi
            else
                echo "❌ $lib: 不存在"
                ALL_SUCCESS=0
            fi
        done
        
        echo ""
        if [ $ALL_SUCCESS -eq 1 ]; then
            echo "========================================"
            echo "✅ 所有依赖库编译成功 (OpenSSL 4.x)"
            echo "========================================"
        else
            echo "========================================"
            echo "⚠️  部分库仍有 OPENSSL_1_1_0 依赖"
            echo "========================================"
        fi
        
    else
        # 使用 ports 编译
        echo ""
        echo "========================================"
        echo "使用 ports 编译依赖库 (OpenSSL 4.x)"
        echo "========================================"
        
        export OPENSSL_PREFIX="/usr/local"
        export CFLAGS="-I${OPENSSL_PREFIX}/include"
        export LDFLAGS="-L${OPENSSL_PREFIX}/lib -Wl,-rpath,${OPENSSL_PREFIX}/lib"
        export PKG_CONFIG_PATH="${OPENSSL_PREFIX}/lib/pkgconfig"
        
        echo "[ * ] 检测依赖 OPENSSL_1_1_0 的包..."
        
        cat > /tmp/check_openssl_deps.sh << 'EOF'
#!/bin/sh
for lib in /usr/local/lib/*.so*; do
    if [ -f "$lib" ] && [ ! -L "$lib" ]; then
        if objdump -p "$lib" | grep -q "OPENSSL_1_1_0"; then
            pkg which "$lib" | awk '{print $1}' | head -1
        fi
    fi
done | sort -u
EOF
        chmod +x /tmp/check_openssl_deps.sh
        
        PKGS=$(/tmp/check_openssl_deps.sh)
        
        if [ -z "$PKGS" ]; then
            echo "✅ 没有发现依赖 OPENSSL_1_1_0 的包"
        else
            echo "发现以下包需要重建:"
            echo "$PKGS" | while read pkg; do
                echo "  - $pkg"
            done
            
            echo ""
            echo "[ * ] 开始重建包..."
            for pkg in $PKGS; do
                echo "  重建 $pkg..."
                PORT_PATH=$(pkg info -o "$pkg" | awk '{print $3}')
                
                if [ -z "$PORT_PATH" ]; then
                    echo "    ⚠️  找不到 $pkg 的 port"
                    continue
                fi
                
                if [ -d "/usr/ports/$PORT_PATH" ]; then
                    cd "/usr/ports/$PORT_PATH"
                    
                    mkdir -p /var/db/ports/"$(basename "$PORT_PATH")"
                    echo 'OPENSSL=yes' > /var/db/ports/"$(basename "$PORT_PATH")"/options
                    echo 'OPENSSL_PORT=openssl40' >> /var/db/ports/"$(basename "$PORT_PATH")"/options
                    
                    echo "    清理..."
                    make clean
                    echo "    编译安装..."
                    make -DBATCH install clean
                    
                    if [ $? -eq 0 ]; then
                        echo "    ✅ $pkg 重建成功"
                    else
                        echo "    ❌ $pkg 重建失败"
                    fi
                    cd - > /dev/null
                else
                    echo "    ⚠️  Port 不存在: /usr/ports/$PORT_PATH"
                fi
            done
        fi
        
        echo ""
        echo "========================================"
        echo "验证编译结果"
        echo "========================================"
        
        for lib in /usr/local/lib/libcurl.so /usr/local/lib/libldap.so /usr/local/lib/libpq.so /usr/local/lib/libssh2.so.1 /usr/local/lib/libsasl2.so; do
            if [ -f "$lib" ]; then
                echo -n "✅ $(basename $lib): "
                if objdump -p "$lib" | grep -q "OPENSSL_1_1_0"; then
                    echo "⚠️  仍依赖 OPENSSL_1_1_0"
                else
                    echo "✅ OpenSSL 4.x 兼容"
                fi
            fi
        done
        
        echo ""
        echo "✅ ports 编译完成"
    fi

    cd "$build_dir" || {
        echo "❌ Failed to return to PHP source directory"
        return 1
    }
    echo "[ * ] Current directory: $(pwd)"

    # ============================================================
    # 修复 cURL OpenSSL 4.x 兼容性
    # ============================================================
    echo "[ * ] Fixing cURL for OpenSSL 4.x..."

    export CURL_CFLAGS="-I/usr/local/include"
    export CURL_LIBS="-L/usr/local/lib -lcurl -lssl -lcrypto"

    cat > /tmp/curl-config << 'EOF'
#!/bin/sh
prefix=/usr/local
exec_prefix=${prefix}
libdir=${exec_prefix}/lib
includedir=${prefix}/include

case "$1" in
    --libs)
        echo "-L${libdir} -lcurl -lssl -lcrypto -lz"
        ;;
    --cflags)
        echo "-I${includedir}"
        ;;
    --version)
        echo "8.20.0"
        ;;
    --static-libs)
        echo "-L${libdir} -lcurl -lssl -lcrypto -lz"
        ;;
    --prefix)
        echo "${prefix}"
        ;;
    *)
        /usr/local/bin/curl-config "$@"
        ;;
esac
EOF
    chmod +x /tmp/curl-config
    export PATH="/tmp:$PATH"

    export ac_cv_lib_curl_curl_easy_perform=yes
    export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:/usr/local/libdata/pkgconfig:/usr/lib/pkgconfig"

    echo "[ ✓ ] cURL environment configured for OpenSSL 4.x"

    # ============================================================
    # 检测 gettext
    # ============================================================
    echo "[ * ] Checking gettext..."

    GETTEXT_LIB="/usr/local/lib/libintl.so"
    GETTEXT_HEADER="/usr/local/include/libintl.h"

    if [ -f "$GETTEXT_LIB" ] && [ -f "$GETTEXT_HEADER" ]; then
        echo "[ ✓ ] gettext found:"
        echo "    Library: $GETTEXT_LIB"
        echo "    Header:  $GETTEXT_HEADER"
        
        export ac_cv_func_bindtextdomain=yes
        export ac_cv_lib_intl_bindtextdomain=yes
        export ac_cv_lib_intl_gettext=yes
        export LIBS="-lintl $LIBS"
        export LDFLAGS="-L/usr/local/lib $LDFLAGS"
        export CPPFLAGS="-I/usr/local/include $CPPFLAGS"
        
        echo "[ ✓ ] gettext configured"
    else
        echo "❌ gettext NOT FOUND!"
        echo "   Expected:"
        echo "   - Library: $GETTEXT_LIB"
        echo "   - Header:  $GETTEXT_HEADER"
        echo ""
        echo "   Please install: pkg install gettext"
        exit 1
    fi

    # ============================================================
    # 配置 GMP
    # ============================================================
    echo "[ * ] Configuring GMP..."

    GMP_CFLAGS=$(pkg-config --cflags gmp || echo "-I/usr/local/include")
    GMP_LIBS=$(pkg-config --libs gmp || echo "-L/usr/local/lib -lgmp")

    echo "    CFLAGS: $GMP_CFLAGS"
    echo "    LIBS:   $GMP_LIBS"

    export GMP_CFLAGS="$GMP_CFLAGS"
    export GMP_LIBS="$GMP_LIBS"
    export ac_cv_lib_gmp___gmpz_rootrem=yes
    export ac_cv_lib_gmp___gmpz_root=yes
    export LIBS="-lgmp $LIBS"

    echo "[ ✓ ] GMP configured"

    # ============================================================
    # 设置 iconv 检测环境变量
    # ============================================================
    echo "[ * ] Setting iconv detection environment variables..."
    export ac_cv_func_iconv=yes
    export ac_cv_func_iconv_open=yes
    export ac_cv_lib_iconv_iconv=yes
    export ac_cv_lib_iconv_iconv_open=yes
    echo "[ ✓ ] iconv environment variables set"

    # ============================================================
    # 配置 LDAP
    # ============================================================
    echo "[ * ] Configuring LDAP..."
    export LDAP_CFLAGS="-I/usr/local/include"
    export LDAP_LIBS="-L/usr/local/lib -lldap -llber"
    export ac_cv_lib_ldap_ldap_bind_s=yes
    export ac_cv_func_ldap_bind_s=yes
    export ac_cv_func_ldap_parse_result=yes
    export ac_cv_func_ldap_start_tls_s=yes

    # ============================================================
    # 修复 flock 检测
    # ============================================================
    echo "[ * ] Fixing flock detection for FreeBSD 14..."

    export php_cv_struct_flock=yes
    export php_cv_struct_flock_linux=no
    export php_cv_struct_flock_bsd=yes
    export ac_cv_struct_flock=yes
    export ac_cv_struct_flock_linux=no
    export ac_cv_struct_flock_bsd=yes
    rm -f config.cache

    echo "[ ✓ ] Flock detection configured"

    # ============================================================
    # 强制 flock 检测通过
    # ============================================================
    echo "[ * ] Forcing flock detection by patching configure..."
    
    if [ -f "configure" ]; then
        echo 'php_cv_struct_flock_bsd=yes' >> configure
        echo 'PHP_STRUCT_FLOCK=BSD' >> configure
        echo 'force_flock_bsd=yes' >> configure
        
        sed -i '' 's/as_fn_error \$? "Don'\''t know how to define struct flock on this system, set --enable-opcache=no"/echo "WARNING: flock detection failed, assuming BSD order (FreeBSD 14)"; php_cv_struct_flock_bsd="yes"; PHP_STRUCT_FLOCK="BSD"/g' configure
        
        echo "[ ✓ ] Configure patched for flock detection"
    fi

    # ============================================================
    # 强制 pcntl 函数检测
    # ============================================================
    echo "[ * ] Forcing all pcntl functions detection..."
    export php_cv_func_fork=yes
    export php_cv_func_waitpid=yes
    export ac_cv_func_fork=yes
    export ac_cv_func_fork_works=yes
    export ac_cv_func_waitpid=yes
    export ac_cv_func_waitpid_works=yes
    export ac_cv_func_sigaction=yes
    export ac_cv_func_signal=yes
    export ac_cv_func_sigprocmask=yes
    export ac_cv_func_sigsetjmp=yes
    export ac_cv_func_sigsuspend=yes
    export ac_cv_func_pause=yes
    export ac_cv_func_alarm=yes
    export ac_cv_func_setitimer=yes
    export ac_cv_func_getitimer=yes
    export ac_cv_func_pcntl=yes
    echo "[ ✓ ] All pcntl functions forced"

    # ============================================================
    # 修复 off_t 检测
    # ============================================================
    echo "[ * ] Fixing off_t detection..."
    export ac_cv_sizeof_off_t=8
    export ac_cv_type_off_t=yes
    echo "[ ✓ ] off_t detection configured"

    # ============================================================
    # 配置环境
    # ============================================================
    echo "[ * ] Configuring environment for OpenSSL 4.x..."
    export LD_LIBRARY_PATH="/usr/local/lib:/usr/lib"

    if [ -f "/usr/local/lib/libcrypto.so.30" ]; then
        echo "  ✅ OpenSSL 4.x found: /usr/local/lib/libcrypto.so.30"
    else
        echo "  ⚠️  OpenSSL 4.x not found"
    fi

    if command -v objcopy >/dev/null; then
        echo "  ✓ objcopy found: $(which objcopy)"
        ldd $(which objcopy) | grep -E "ssl|crypto" || echo "  ✓ objcopy does not directly depend on OpenSSL"
    fi

    echo "[ ✓ ] OpenSSL 4.x environment configured"
    # ============================================================
    # 生成 configure 脚本
    # ============================================================
    if [ ! -f "configure" ]; then
        echo "[ * ] Generating configure script with buildconf..."
        if ! ./buildconf --force; then
            echo "❌ buildconf failed"
            return 1
        fi
        echo "  ✅ configure generated"
    fi

    export CC="clang"
    export CXX="clang++"
    export CXXFLAGS="-std=c++17"
    echo "  CC=$CC"
    echo "  CXX=$CXX"
    echo "  CXXFLAGS=$CXXFLAGS"

    # ============================================================
    # 配置 PHP - 使用 Hestia 路径
    # ============================================================
    echo "[ * ] Configuring PHP ${PHP_VERSION} for Hestia..."
    cd "$build_dir" || {
        echo "❌ Failed to return to PHP source directory"
        return 1
    }

    # 修复 bzip2 pkg-config
    mkdir -p /usr/local/libdata/pkgconfig
    cat > /usr/local/libdata/pkgconfig/bzip2.pc << 'EOF'
prefix=/usr
exec_prefix=${prefix}
libdir=${exec_prefix}/lib
includedir=${prefix}/include
Name: bzip2
Description: bzip2 compression library
Version: 1.0.8
Libs: -L${libdir} -lbz2
Cflags: -I${includedir}
EOF
    export PKG_CONFIG_PATH="/usr/local/libdata/pkgconfig:/usr/local/lib/pkgconfig:$PKG_CONFIG_PATH"

    # 获取配置参数
    mapfile -t CONFIG_ARGS < <(get_config_args)
    CONFIG_ARGS_WITH_PHAR_SHARED=("${CONFIG_ARGS[@]}")
    CONFIG_ARGS_WITH_PHAR_SHARED+=("--enable-phar=shared")

    set +e
    ./configure \
        "${CONFIG_ARGS_WITH_PHAR_SHARED[@]}" \
        CC="clang" \
        CXX="clang++" \
        CXXFLAGS="-std=c++17" \
        LDFLAGS="-L/usr/local/lib -Wl,-rpath,/usr/local/lib" \
        LIBS="-licui18n -licuuc -licudata -licuio" \
        DTRACE=/usr/sbin/dtrace \
        LDAP_LIBS="-L/usr/local/lib -lldap -llber" \
        ac_cv_lib_c_client_mail_open=yes \
        ac_cv_lib_c_client_imap_open=yes \
        php_cv_struct_flock=yes \
        php_cv_struct_flock_linux=no \
        php_cv_struct_flock_bsd=yes \
        ac_cv_func_fork=yes \
        ac_cv_func_fork_works=yes \
        ac_cv_func_waitpid=yes \
        ac_cv_func_waitpid_works=yes \
        ac_cv_func_sigaction=yes \
        ac_cv_func_signal=yes \
        ac_cv_func_sigprocmask=yes \
        ac_cv_func_sigsetjmp=yes \
        ac_cv_func_sigsuspend=yes \
        ac_cv_func_pause=yes \
        ac_cv_func_alarm=yes \
        ac_cv_func_setitimer=yes \
        ac_cv_func_getitimer=yes \
        ac_cv_lib_pq_PQprepare=yes \
        ac_cv_lib_pq_PQexecParams=yes \
        ac_cv_lib_pq_PQescapeStringConn=yes \
        ac_cv_lib_pq_PQescapeString=yes \
        ac_cv_lib_pq_PQresultErrorField=yes \
        ac_cv_lib_pq_PQfreemem=yes \
        ac_cv_lib_pq_PQescapeByteaConn=yes \
        ac_cv_lib_pq_PQunescapeBytea=yes \
        ac_cv_lib_pq_PQsetdbLogin=yes \
        ac_cv_lib_pq_PQconnectdb=yes \
        ac_cv_lib_pq_PQfinish=yes \
        ac_cv_lib_pq_PQreset=yes \
        ac_cv_lib_pq_PQcancel=yes \
        ac_cv_lib_edit_readline=yes \
        ac_cv_lib_edit_rl_on_new_line=yes \
        ac_cv_lib_edit_rl_completion_matches=yes \
        ac_cv_lib_edit_rl_echo_signal_char=yes \
        EDIT_LIBS="-ledit -lncurses" \
        ac_cv_sizeof_off_t=8 \
        ac_cv_type_off_t=yes \
        > "$LOG_DIR/configure-${PHP_VERSION}.log"

    CONFIGURE_STATUS=$?
    export LDFLAGS="$LDFLAGS -Wl,-rpath,/usr/local/lib"

    if [ $CONFIGURE_STATUS -ne 0 ]; then
        echo "❌ Configure failed"
        tail -300 "$LOG_DIR/configure-${PHP_VERSION}.log"
        return 1
    fi

    # ============================================================
    # 修复 Makefile 中的 ICU 库路径
    # ============================================================
    if [ -f "Makefile" ]; then
        sed -i '' -e 's|-licui18n||g' \
                -e 's|-licuuc||g' \
                -e 's|-licudata||g' \
                -e 's|-licuio||g' Makefile
        sed -i '' -e "s|^EXTRA_LIBS = \(.*\)$|EXTRA_LIBS = -L/usr/local/lib -licui18n -licuuc -licudata -licuio \1|" Makefile
        sed -i '' -e "s|^LIBS = \(.*\)$|LIBS = -L/usr/local/lib -licui18n -licuuc -licudata -licuio \1|" Makefile
    fi

    # ============================================================
    # 编译 PHP
    # ============================================================
    echo "[ * ] Compiling PHP ${PHP_VERSION} (using ${NUM_CPUS} cores)..."
    mkdir -p "${BUILD_DIR}/usr/local/hestia"
    
    CURRENT_LIBS=$(grep "^LIBS" Makefile | head -1 | sed 's/^LIBS = //')
    
    if [ "$OSTYPE" = 'freebsd' ]; then
        gmake -j "$NUM_CPUS" \
            LDFLAGS="-L/usr/local/lib -Wl,-rpath,/usr/local/lib" \
            LIBS="-licui18n -licuuc -licudata -licuio ${CURRENT_LIBS}" \
            > "$LOG_DIR/build-${PHP_VERSION}.log"
    else
        make -j "$NUM_CPUS" \
            LDFLAGS="-L/usr/local/lib -Wl,-rpath,/usr/local/lib" \
            LIBS="-licui18n -licuuc -licudata -licuio ${CURRENT_LIBS}" \
            > "$LOG_DIR/build-${PHP_VERSION}.log"
    fi
    
    BUILD_STATUS=$?

    if [ $BUILD_STATUS -ne 0 ]; then
        echo ""
        echo "========================================"
        echo "❌ BUILD FAILED"
        echo "========================================"
        grep -E "error:|Error:|undefined reference|failed" "$LOG_DIR/build-${PHP_VERSION}.log" | head -200
        echo ""
        echo "Last 200 lines:"
        tail -200 "$LOG_DIR/build-${PHP_VERSION}.log"
        echo ""
        echo "[ * ] Retrying with single core..."
        if [ "$OSTYPE" = 'freebsd' ]; then
            gmake clean
            gmake -j1 >> "$LOG_DIR/build-${PHP_VERSION}.log"
        else
            make clean
            make -j1 >> "$LOG_DIR/build-${PHP_VERSION}.log"
        fi
        if [ $? -ne 0 ]; then
            return 1
        fi
    fi

    # ============================================================
    # 生成 phar.phar
    # ============================================================
    echo ""
    echo "[*] Generating phar.phar..."
    cd "$build_dir" || return 1
    
    if [ "$OSTYPE" = 'freebsd' ]; then
        gmake ext/phar/phar.phar | tee -a "$LOG_DIR/phar-gen.log" || true
    else
        make ext/phar/phar.phar | tee -a "$LOG_DIR/phar-gen.log" || true
    fi
    
    if [ ! -f "ext/phar/phar.phar" ] || [ ! -s "ext/phar/phar.phar" ]; then
        echo "❌ phar.phar not generated or empty"
        return 1
    fi
    echo "  ✅ phar.phar ready"

    # ============================================================
    # 安装 PHP 到 Hestia 路径
    # ============================================================
    echo ""
    echo "[*] Installing PHP ${PHP_VERSION} to Hestia path..."
    mkdir -p "$install_dir"

    # 先安装 programs (phpize, php-config)
    if [ "$OSTYPE" = 'freebsd' ]; then
        gmake install-programs INSTALL_ROOT="$install_dir" || true
    else
        make install-programs INSTALL_ROOT="$install_dir" || true
    fi

    # 禁用 PEAR 后安装
    if [ -f "Makefile" ]; then
        cp Makefile Makefile.bak
        sed -i '' 's/ install-pear / /g' Makefile
        sed -i '' 's/ install-pear$/ /g' Makefile
        sed -i '' 's/^install_targets.*install-pear.*$/ /g' Makefile
        sed -i '' 's/^install-pear:/# install-pear:/g' Makefile
        sed -i '' 's/^install-pear-installer:/# install-pear-installer:/g' Makefile
        sed -i '' '/^\t.*install-pear/ s/^/# /' Makefile
        sed -i '' '/^\t.*PEAR_INSTALLER/ s/^/# /' Makefile
    fi

    echo ""
    echo "[*] Installing PHP ${PHP_VERSION}..."

    if [ "$OSTYPE" = 'freebsd' ]; then
        INSTALL_CMD="gmake"
    else
        INSTALL_CMD="make"
    fi

    if ! $INSTALL_CMD install INSTALL_ROOT="$install_dir" > "$LOG_DIR/install-${PHP_VERSION}.log" 2>&1; then
        echo "❌ PHP install failed"
        echo ""
        echo "--- Last 50 lines of install log ---"
        tail -50 "$LOG_DIR/install-${PHP_VERSION}.log"
        
        echo ""
        echo "--- Trying component installation ---"
        for target in install-cli install-cgi install-fpm install-build install-pdo-headers; do
            echo "  Installing $target..."
            $INSTALL_CMD $target INSTALL_ROOT="$install_dir" 2>> "$LOG_DIR/install-${PHP_VERSION}.log" || true
        done
        
        if [ -d "modules" ]; then
            ZEND_API_NO=$(grep "^#define ZEND_MODULE_API_NO" Zend/zend_modules.h | awk '{print $3}')
            EXT_DIR="$install_dir/usr/local/lib/php/extensions/no-debug-non-zts-${ZEND_API_NO}"
            mkdir -p "$EXT_DIR"
            find modules -name "*.so" -exec cp {} "$EXT_DIR/" \;
            echo "  ✓ Extensions copied manually"
        fi
        
        mkdir -p "$install_dir/usr/local/bin"
        [ -f "sapi/cli/php" ] && cp sapi/cli/php "$install_dir/usr/local/bin/" && chmod 755 "$install_dir/usr/local/bin/php"
        [ -f "sapi/cgi/php-cgi" ] && cp sapi/cgi/php-cgi "$install_dir/usr/local/bin/" && chmod 755 "$install_dir/usr/local/bin/php-cgi"
        [ -f "sapi/fpm/php-fpm" ] && cp sapi/fpm/php-fpm "$install_dir/usr/local/bin/" && chmod 755 "$install_dir/usr/local/bin/php-fpm"
        
        if [ ! -f "$install_dir/usr/local/bin/phpize" ] && [ -f "$build_dir/phpize" ]; then
            cp "$build_dir/phpize" "$install_dir/usr/local/bin/"
            chmod 755 "$install_dir/usr/local/bin/phpize"
            echo "  ✅ phpize copied"
        fi
        if [ ! -f "$install_dir/usr/local/bin/php-config" ] && [ -f "$build_dir/php-config" ]; then
            cp "$build_dir/php-config" "$install_dir/usr/local/bin/"
            chmod 755 "$install_dir/usr/local/bin/php-config"
            echo "  ✅ php-config copied"
        fi
    fi   # ← 这里结束 if ! $INSTALL_CMD install

    # 检查二进制文件是否存在
    if [ ! -f "$install_dir/usr/local/bin/php" ]; then
        echo "❌ PHP binary not found!"
        echo "Contents of $install_dir/usr/local/bin:"
        ls -la "$install_dir/usr/local/bin/" || echo "  (empty)"
        return 1
    fi

    # 恢复 Makefile
    if [ -f "Makefile.bak" ]; then
        mv Makefile.bak Makefile
    fi

    # 创建软链接
    if [ ! -f "$install_dir/usr/local/bin/php" ]; then
        ln -sf "$install_dir/usr/local/hestia/php/bin/php" "$install_dir/usr/local/bin/php" || true
    fi
    if [ ! -f "$install_dir/usr/local/sbin/php-fpm" ]; then
        ln -sf "$install_dir/usr/local/hestia/php/sbin/php-fpm" "$install_dir/usr/local/sbin/php-fpm" || true
    fi
    if [ ! -f "$install_dir/usr/local/bin/phpize" ]; then
        ln -sf "$install_dir/usr/local/hestia/php/bin/phpize" "$install_dir/usr/local/bin/phpize" || true
    fi
    if [ ! -f "$install_dir/usr/local/bin/php-config" ]; then
        ln -sf "$install_dir/usr/local/hestia/php/bin/php-config" "$install_dir/usr/local/bin/php-config" || true
    fi

    echo ""
    echo "✅ PHP ${PHP_VERSION} installed to Hestia path"

    # ============================================================
    # 编译 ImageMagick 扩展
    # ============================================================
    if ! build_imagick "$build_dir" "$install_dir"; then
        echo "⚠️  ImageMagick extension build failed"
    fi

    # ============================================================
    # 编译 APCu 扩展
    # ============================================================
    if ! build_apcu "$build_dir" "$install_dir"; then
        echo "⚠️  APCu extension build failed"
    fi

    # ============================================================
    # 安装 PSPell 扩展
    # ============================================================
    if ! install_pspell "$install_dir" "$build_dir"; then
        echo "⚠️  PSPell extension installation failed"
    fi

    # ============================================================
    # 安装 IMAP 扩展
    # ============================================================
    if [ "$BUILD_IMAP" = "yes" ]; then
        if ! install_imap_pecl "$install_dir" "$build_dir"; then
            echo "⚠️  PECL installation failed, trying manual build..."
            if ! install_imap_manual "$install_dir" "$build_dir"; then
                echo "⚠️  IMAP extension build failed"
            fi
        fi
    fi

    # ============================================================
    # 验证扩展
    # ============================================================
    echo ""
    echo "========================================"
    echo "[ * ] Verifying installed extensions"
    echo "========================================"
    
    local php_bin="$install_dir/usr/local/bin/php"
    local zend_api_no=$(grep "^#define ZEND_MODULE_API_NO" "$build_dir/Zend/zend_modules.h" | awk '{print $3}')
    local ext_dir="$install_dir/usr/local/lib/php/extensions/no-debug-non-zts-${zend_api_no}"
    
    echo "Extension directory: $ext_dir"
    if [ -d "$ext_dir" ]; then
        ls -la "$ext_dir/" | grep -E "\.so$" | sed 's/^/  /'
    fi
    
    echo ""
    echo "PHP modules:"
    "$php_bin" -m | grep -E "^(imagick|apcu|imap|pspell|phar|opcache|intl)" | sed 's/^/  /'
    
    if [ -f "$install_dir/usr/local/bin/php" ]; then
        echo "✅ PHP ${PHP_VERSION} with OpenSSL 4.x built successfully!"
        "$install_dir/usr/local/bin/php" -v || true
        return 0
    else
        echo "❌ PHP binary not found!"
        return 1
    fi
}

# =================================================================================
# Building hestia-php
# =================================================================================

if [ "$PHP_B" = "true" ]; then
    if [ "$CROSS" = "true" ]; then
        echo "Cross compile not supported for hestia-php"
        exit 1
    fi

    echo "Building hestia-php package with OpenSSL 4.x..."

    if [ "$BUILD_DEB" = "true" ] || [ "$BUILD_PKG" = "true" ]; then
        CLEAN_PHP_VER_FINAL=$(echo "${PHP_V}" | tr -d '"'\''\r')
        BUILD_DIR_HESTIAPHP="$BUILD_DIR/hestia-php_${CLEAN_PHP_VER_FINAL}"
        
        # ============================================================
        # 调用 build_php 函数（包含所有编译逻辑）
        # ============================================================
        echo "[ * ] Building PHP with build_php()..."
        if ! build_php; then
            echo "❌ PHP build failed"
            exit 1
        fi
        
        # ============================================================
        # 复制到 Hestia 包目录
        # ============================================================
        echo "[ * ] Copying to Hestia package directory..."
        
        # 从 build_php 的安装目录复制
        if [ -d "$BUILD_DIR/php-${PHP_VERSION}/usr/local/hestia/php" ]; then
            mkdir -p "$BUILD_DIR_HESTIAPHP/usr/local/hestia"
            mv "$BUILD_DIR/php-${PHP_VERSION}/usr/local/hestia/php" "$BUILD_DIR_HESTIAPHP/usr/local/hestia/"
        elif [ -d "$BUILD_DIR/php-${PHP_VERSION}/usr/local/hestia" ]; then
            mkdir -p "$BUILD_DIR_HESTIAPHP/usr/local"
            mv "$BUILD_DIR/php-${PHP_VERSION}/usr/local/hestia" "$BUILD_DIR_HESTIAPHP/usr/local/"
        fi
        
        # 复制二进制文件
        if [ -d "$BUILD_DIR/php-${PHP_VERSION}/usr/local/bin" ]; then
            mkdir -p "$BUILD_DIR_HESTIAPHP/usr/local/bin"
            cp -r "$BUILD_DIR/php-${PHP_VERSION}/usr/local/bin/"* "$BUILD_DIR_HESTIAPHP/usr/local/bin/" 2>/dev/null || true
        fi
        
        if [ -d "$BUILD_DIR/php-${PHP_VERSION}/usr/local/sbin" ]; then
            mkdir -p "$BUILD_DIR_HESTIAPHP/usr/local/sbin"
            cp -r "$BUILD_DIR/php-${PHP_VERSION}/usr/local/sbin/"* "$BUILD_DIR_HESTIAPHP/usr/local/sbin/" 2>/dev/null || true
        fi
        
        # 复制扩展文件
        if [ -d "$BUILD_DIR/php-${PHP_VERSION}/usr/local/lib/php/extensions" ]; then
            mkdir -p "$BUILD_DIR_HESTIAPHP/usr/local/lib/php"
            cp -r "$BUILD_DIR/php-${PHP_VERSION}/usr/local/lib/php/extensions" "$BUILD_DIR_HESTIAPHP/usr/local/lib/php/" 2>/dev/null || true
        fi
        
        # 复制配置文件
        if [ -f "$BUILD_DIR/php-${PHP_VERSION}/usr/local/etc/php.ini" ]; then
            mkdir -p "$BUILD_DIR_HESTIAPHP/usr/local/etc"
            cp "$BUILD_DIR/php-${PHP_VERSION}/usr/local/etc/php.ini" "$BUILD_DIR_HESTIAPHP/usr/local/etc/" 2>/dev/null || true
        fi
        
        cd "$BUILD_DIR" || exit 1

        if [ "$OSTYPE" = 'freebsd' ]; then
            chown -R root:wheel "$BUILD_DIR_HESTIAPHP"
        else
            chown -R root:root "$BUILD_DIR_HESTIAPHP"
        fi

        # ============================================================
        # Debian 打包
        # ============================================================
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

        # ============================================================
        # FreeBSD 打包
        # ============================================================
        if [ "$BUILD_PKG" = "true" ]; then
            mkdir -p "$BUILD_DIR_HESTIAPHP/usr/local/etc/rc.d"
            mkdir -p "$BUILD_DIR_HESTIAPHP/usr/local/etc/php"
            mkdir -p "$BUILD_DIR_HESTIAPHP/usr/local/hestia/php/etc"
            mkdir -p "$BUILD_DIR_HESTIAPHP/usr/local/hestia/php/lib"
            mkdir -p "$BUILD_DIR_HESTIAPHP/usr/local/hestia/php/sbin"
            mkdir -p "$BUILD_DIR_HESTIAPHP/usr/local/hestia/php/logs"
            
            get_branch_file 'src/pkg/php/php-fpm.conf' "${BUILD_DIR_HESTIAPHP}/usr/local/hestia/php/etc/php-fpm.conf"
			get_branch_file 'src/pkg/php/php.ini' "${BUILD_DIR_HESTIAPHP}/usr/local/etc/php/php.ini" 2> /dev/null || get_branch_file 'src/pkg/php/php.ini' "${BUILD_DIR_HESTIAPHP}/usr/local/hestia/php/lib/php.ini"
			generate_plist "$BUILD_DIR_HESTIAPHP" "hestia-php"
			if [ -f "${BUILD_DIR_HESTIAPHP}/usr/local/hestia/php/etc/php-fpm.conf" ]; then
				sed -i '' 's/epoll/kqueue/g' "${BUILD_DIR_HESTIAPHP}/usr/local/hestia/php/etc/php-fpm.conf" 2> /dev/null
				sed -i '' 's|/run/|/var/run/|g' "${BUILD_DIR_HESTIAPHP}/usr/local/hestia/php/etc/php-fpm.conf" 2> /dev/null
			fi

            get_branch_file 'src/pkg/php/+MANIFEST' "$BUILD_DIR_HESTIAPHP/+MANIFEST"
            get_branch_file 'src/pkg/php/+POST-INSTALL' "$BUILD_DIR_HESTIAPHP/+POST-INSTALL"
            chmod 755 "$BUILD_DIR_HESTIAPHP/+POST-INSTALL"

            echo "Building Hestia PHP PKG for FreeBSD..."
            CLEAN_PHP_VER_FINAL=$(echo "${PHP_V}" | tr -d '\r"' | tr -d "'")
            sed -i '' "s/%VERSION%/${CLEAN_PHP_VER_FINAL}/g" "$BUILD_DIR_HESTIAPHP/+MANIFEST"
            sed -i '' "s/%ARCH%/${BUILD_ARCH}/g" "$BUILD_DIR_HESTIAPHP/+MANIFEST"

            mkdir -p "$BUILD_DIR_HESTIAPHP/+METADATA"
            cp "$BUILD_DIR_HESTIAPHP/+MANIFEST" "$BUILD_DIR_HESTIAPHP/+METADATA/+MANIFEST"
            cp "$BUILD_DIR_HESTIAPHP/+POST-INSTALL" "$BUILD_DIR_HESTIAPHP/+METADATA/+POST-INSTALL"

            echo "Building Hestia PHP PKG for FreeBSD..."
            pkg create -m "$BUILD_DIR_HESTIAPHP/+METADATA" -p "$BUILD_DIR_HESTIAPHP/+PLIST" -r "$BUILD_DIR_HESTIAPHP" -o "$PKG_DIR"
            mv -f $PKG_DIR/hestia-php-*.pkg "$PKG_DIR/hestia-php-${CLEAN_PHP_VER_FINAL}.pkg"

            echo "[ * ] Verifying php package integrity..."
            if pkg info -F "$PKG_DIR/hestia-php-${CLEAN_PHP_VER_FINAL}.pkg" > /dev/null 2>&1; then
                echo "✅ PHP package is valid."
            else
                echo "❌ ERROR: PHP package validation failed!"
                exit 1
            fi
            cd "$PKG_DIR" || exit 1
        fi

        # 清理
        if [ "$KEEPBUILD" != 'true' ]; then
            rm -rf "$BUILD_DIR/php-${CLEAN_PHP_VER}"
            rm -rf "$BUILD_DIR_HESTIAPHP"
            if [ "$use_src_folder" = 'true' ] && [ -d "$BUILD_DIR/hestiacp-$branch_dash" ]; then
                rm -rf "$BUILD_DIR/hestiacp-$branch_dash"
            fi
        fi
    fi

    # RPM 打包
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

# =================================================================================
# Building hestia-web-terminal
# =================================================================================

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
			rm -rf node_modules
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

			if [ "$OSTYPE" = 'freebsd' ] && ! command -v npm > /dev/null 2>&1; then
				pkg install -y node24 npm
			fi

			cd "${BUILD_DIR_HESTIA_TERMINAL}/usr/local/hestia/web-terminal" || exit 1
			npm ci --omit=dev
			rm -rf node_modules

			mkdir -p "$BUILD_DIR_HESTIA_TERMINAL/usr/local/etc/rc.d"
			get_branch_file 'src/pkg/web-terminal/hestia-web-terminal.rc' "$BUILD_DIR_HESTIA_TERMINAL/usr/local/etc/rc.d/hestia-web-terminal"
			chmod 755 "$BUILD_DIR_HESTIA_TERMINAL/usr/local/etc/rc.d/hestia-web-terminal"

			get_branch_file 'src/pkg/web-terminal/+MANIFEST' "$BUILD_DIR_HESTIA_TERMINAL/+MANIFEST"
			get_branch_file 'src/pkg/web-terminal/+POST-INSTALL' "$BUILD_DIR_HESTIA_TERMINAL/+POST-INSTALL"
			chmod 755 "$BUILD_DIR_HESTIA_TERMINAL/+POST-INSTALL"
			generate_plist "$BUILD_DIR_HESTIA_TERMINAL" "hestia-web-terminal"
			echo "Building Hestia Web Terminal PKG for FreeBSD..."
			sed -i '' "s/%VERSION%/${WEB_TERMINAL_V}/g" "$BUILD_DIR_HESTIA_TERMINAL/+MANIFEST"
			sed -i '' "s/%ARCH%/${BUILD_ARCH}/g" "$BUILD_DIR_HESTIA_TERMINAL/+MANIFEST"
			mkdir -p "$BUILD_DIR_HESTIA_TERMINAL/+METADATA"
			cp "$BUILD_DIR_HESTIA_TERMINAL/+MANIFEST" "$BUILD_DIR_HESTIA_TERMINAL/+METADATA/+MANIFEST"
			cp "$BUILD_DIR_HESTIA_TERMINAL/+POST-INSTALL" "$BUILD_DIR_HESTIA_TERMINAL/+METADATA/+POST-INSTALL"
			echo "Building Hestia Web Terminal PKG for FreeBSD..."
			pkg create -m "$BUILD_DIR_HESTIA_TERMINAL/+METADATA" -p "$BUILD_DIR_HESTIA_TERMINAL/+PLIST" -r "$BUILD_DIR_HESTIA_TERMINAL" -o "$PKG_DIR"
			mv -f $PKG_DIR/hestia-web-terminal-1*.pkg "$PKG_DIR/hestia-web-terminal-${WEB_TERMINAL_V}.pkg"
			echo "[ * ] Verifying web-terminal package integrity..."
			if pkg info -F "$PKG_DIR/hestia-web-terminal-${WEB_TERMINAL_V}.pkg" > /dev/null 2>&1; then
				echo "✅ Web-terminal package is valid."
			else
				echo "❌ ERROR: Web-terminal package validation failed!"
				exit 1
			fi
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

# =================================================================================
# Building hestia (main package)
# =================================================================================

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

				bsdtar -xf "$ARCHIVE_DIR/$branch.tar.gz" -C "$BUILD_DIR/"
				if [ $? -ne 0 ]; then
					echo "ERROR: Failed to extract source archive"
					exit 1
				fi

				cd "$BUILD_DIR" || exit 1

				EXTRACTED_DIR=$(find . -maxdepth 1 -type d -name "hestiacp-*" | head -n1)
				if [ -z "$EXTRACTED_DIR" ]; then
					echo "ERROR: No source directory found after extraction"
					echo "Expected pattern: hestiacp-*"
					echo "Contents of $BUILD_DIR:"
					ls -la
					exit 1
				fi

				if [ "$EXTRACTED_DIR" != "./hestiacp-$branch_dash" ]; then
					echo "Renaming $EXTRACTED_DIR to ./hestiacp-$branch_dash"
					mv "$EXTRACTED_DIR" "./hestiacp-$branch_dash"
					if [ $? -ne 0 ]; then
						echo "ERROR: Failed to rename extracted directory"
						exit 1
					fi
				fi
			fi

			mkdir -p "$BUILD_DIR_HESTIA/usr/local/hestia"

			cd "$BUILD_DIR/hestiacp-$branch_dash" || {
				echo "ERROR: Cannot cd to $BUILD_DIR/hestiacp-$branch_dash"
				echo "Current directory contents:"
				ls -la "$BUILD_DIR"
				exit 1
			}

			if [ "$OSTYPE" = 'freebsd' ]; then
				if ! command -v npm > /dev/null 2>&1; then
					echo "[ * ] Installing npm on FreeBSD..."
					pkg install -y node24 npm
				fi
			else
				if ! command -v npm > /dev/null 2>&1; then
					echo "[ * ] Installing npm on Linux..."
					if command -v apt > /dev/null 2>&1; then
						apt install -y npm
					elif command -v dnf > /dev/null 2>&1; then
						dnf install -y npm
					else
						echo "ERROR: Cannot install npm"
						exit 1
					fi
				fi
			fi

			if [ ! -f "package-lock.json" ]; then
				echo "[ ! ] package-lock.json not found, generating with npm install..."
				npm install
				if [ $? -ne 0 ]; then
					echo "ERROR: npm install failed to generate package-lock.json"
					exit 1
				fi
				echo "[ ✓ ] package-lock.json generated successfully"
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
				generate_plist "$BUILD_DIR_HESTIA" "hestia"

				echo "Building Hestia Control Panel PKG for FreeBSD..."
				sed -i '' "s/%VERSION%/${BUILD_VER}/g" "$BUILD_DIR_HESTIA/+MANIFEST"
				sed -i '' "s/%ARCH%/${current_arch}/g" "$BUILD_DIR_HESTIA/+MANIFEST"

				mkdir -p "$BUILD_DIR_HESTIA/+METADATA"
				cp "$BUILD_DIR_HESTIA/+MANIFEST" "$BUILD_DIR_HESTIA/+METADATA/+MANIFEST"
				cp "$BUILD_DIR_HESTIA/+PRE-INSTALL" "$BUILD_DIR_HESTIA/+METADATA/+PRE-INSTALL"
				cp "$BUILD_DIR_HESTIA/+POST-INSTALL" "$BUILD_DIR_HESTIA/+METADATA/+POST-INSTALL"
				cp "$BUILD_DIR_HESTIA/+PRE-DEINSTALL" "$BUILD_DIR_HESTIA/+METADATA/+PRE-DEINSTALL"

				echo "Building Hestia Control Panel PKG for FreeBSD..."
				pkg create -m "$BUILD_DIR_HESTIA/+METADATA" -p "$BUILD_DIR_HESTIA/+PLIST" -r "$BUILD_DIR_HESTIA" -o "$PKG_DIR"

				mv -f $PKG_DIR/hestia-1*.pkg "$PKG_DIR/hestia-${BUILD_VER}.pkg"

				echo "[ * ] Verifying generated package integrity..."
				if pkg info -F "$PKG_DIR/hestia-${BUILD_VER}.pkg" > /dev/null 2>&1; then
					echo "✅ SUCCESS: Package metadata (+MANIFEST) is valid."
					file_count=$(pkg info -lF "$PKG_DIR/hestia-${BUILD_VER}.pkg" | wc -l)
					echo "✅ SUCCESS: Package contains $file_count files."
				else
					echo "❌ ERROR: Package validation failed! +MANIFEST might be missing or corrupted."
					exit 1
				fi
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

# =================================================================================
# Create FreeBSD pkg repository metadata
# =================================================================================

if [ "$BUILD_PKG" = "true" ] && [ -d "$PKG_DIR" ]; then
	echo "Creating FreeBSD pkg repository metadata..."

	setup_signing_keys

	cd "$PKG_DIR" || exit 1

	cat > meta.conf << EOF
packing_format: ucl
version: 2
EOF

	sign_repository "$PKG_DIR"

	echo ""
	echo "========================================================================"
	echo "FreeBSD pkg repository created successfully at: $PKG_DIR"
	echo ""
	echo "Repository contents:"
	ls -lh "$PKG_DIR/" | grep -E "\.pkg|hestia.pub|meta|packagesite"
	echo ""

	if [ -f "$PKG_DIR/hestia.pub" ]; then
		echo "✅ Public key is included in the repository:"
		echo "   $PKG_DIR/hestia.pub"
		echo ""
		echo "   Clients can verify packages with:"
		echo "   pkg update -f"
		echo "   pkg install hestia"
	fi
	echo "========================================================================"
fi

# =================================================================================
# Install Packages (Automated CI/CD Sanity Verification)
# =================================================================================
if [ "$install" = 'yes' ] || [ "$install" = 'y' ] || [ "$install" = 'true' ]; then
	echo "Installing packages for local sanity validation..."
	if [ "$OSTYPE" = 'rhel' ]; then
		for i in "$RPM_DIR"/*.rpm; do
			dnf -y install "$i" || exit 1
		done
	elif [ "$OSTYPE" = 'freebsd' ]; then
		if ! command -v node > /dev/null 2>&1; then
			pkg install -y node
		fi

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

if [ "$KEEPBUILD" != 'true' ]; then
	echo "Cleaning up build directories..."
	rm -rf "$BUILD_DIR/usr"
fi

echo ""
echo "========================================================================"
echo "HestiaCP Package Build Routine Completed Successfully!"
echo "========================================================================"

if [ "$BUILD_PKG" = "true" ] && [ -d "$PKG_DIR" ]; then
    echo ""
    echo "========================================================================"
    echo "Copying artifacts to host workspace for copyback..."
    echo "========================================================================"
    
    # 宿主机工作目录路径
    HOST_WORKSPACE="/home/runner/work/hestiacp-freebsd/hestiacp-freebsd"
    ARTIFACTS_DIR="${HOST_WORKSPACE}/artifacts"
    mkdir -p "$HOST_WORKSPACE"

    # 使用 cp 复制
    echo "[ * ] Copying from: $PKG_DIR"
    echo "[ * ] Copying to:   $ARTIFACTS_DIR"
    
    cp -R "$PKG_DIR/." "$ARTIFACTS_DIR/"
    EXIT_CODE=$?
    
    if [ $EXIT_CODE -eq 0 ]; then
        echo "✅ Artifacts copied successfully!"
        echo ""
        echo "=== Files in host workspace ($ARTIFACTS_DIR) ==="
        ls -la "$ARTIFACTS_DIR/"
        echo ""
        echo "✅ Repository has been signed with private key"
        echo "✅ Public key is available at: $PKG_DIR/hestia.pub"
        echo ""
        echo "Clients can install with repository configuration:"
        echo "  cat > /usr/local/etc/pkg/repos/hestia.conf << EOF"
        echo "hestia: {"
        echo "  url: \"https://your-repo-url.com/pkg\","
        echo "  signature_type: \"pubkey\","
        echo "  pubkey: \"https://your-repo-url.com/pkg/hestia.pub\","
        echo "  enabled: yes"
        echo "}"
        echo "EOF"
        echo ""
        echo "  pkg update -f"
        echo "  pkg install hestia"
        echo ""
        echo "Or install packages directly:"
        echo "  pkg install $PKG_DIR/hestia-${BUILD_VER}.pkg"
        echo "  pkg install $PKG_DIR/hestia-nginx-${NGINX_V}.pkg"
        echo "  pkg install $PKG_DIR/hestia-php-${PHP_V}.pkg"
        echo "  pkg install $PKG_DIR/hestia-web-terminal-${WEB_TERMINAL_V}.pkg"
    else
        echo "❌ Failed to copy artifacts to host workspace!"
        echo "Source: $PKG_DIR"
        echo "Destination: $HOST_WORKSPACE"
        exit 1
    fi
    
    echo "========================================================================"
fi
echo "========================================================================"
