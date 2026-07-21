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
	local file_count=$(grep -v '^@' "$plist_file" 2> /dev/null | wc -l | tr -d ' ')
	local dir_count=$(grep -c '^@dir' "$plist_file" 2> /dev/null || echo 0)

	echo "✅ PLIST generated: $file_count files, $dir_count directories"

	# 验证 web-terminal 的 node_modules 是否被包含
	if [ "$pkg_name" = "hestia-web-terminal" ] && [ -d "$pkg_dir/usr/local/hestia/web-terminal/node_modules" ]; then
		local npm_count=$(find "$pkg_dir/usr/local/hestia/web-terminal/node_modules" -type f 2> /dev/null | wc -l | tr -d ' ')
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
		
		cp "/home/runner/work/$REPO/keys/hestiacp.key.pub" "$pkg_dir/hestia.pub" 2> /dev/null || true
		echo "[ ✓ ] Repository signed with CI key"
		return 0
	else
		echo "[ ! ] No signing key found, creating repository without signature"
		pkg repo . 2> /dev/null || true
		
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
				sed -i '' 's/ggmake/gmake/g' "$target_file" 2> /dev/null || true
				sed -i '' 's/\tmake/\tgmake/g' "$target_file" 2> /dev/null || true
				sed -i '' 's/make /gmake /g' "$target_file" 2> /dev/null || true
				sed -i '' 's/\$(MAKE)/gmake/g' "$target_file" 2> /dev/null || true
				sed -i '' 's/^MAKE=.*/MAKE=gmake/' "$target_file" 2> /dev/null || true
			fi
		done

		# 2. 最优雅的修复：在 Makefile.in 中注入空的 distclean 目标
		# 这样每次生成的 Makefile 都会包含它
		if [ -f "Makefile.in" ]; then
			# 检查是否已有 distclean 目标
			if ! grep -q "^distclean:" Makefile.in 2> /dev/null; then
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
			if ! grep -q "^distclean:" Makefile 2> /dev/null; then
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
		BUILD_VER=$(grep "version:" "$LOCAL_PKG_BASE/hestia/+MANIFEST" 2> /dev/null | head -n1 | cut -d':' -f2 | tr -d '"'\''\r ')
		NGINX_V=$(grep "version:" "$LOCAL_PKG_BASE/nginx/+MANIFEST" 2> /dev/null | head -n1 | cut -d':' -f2 | tr -d '"'\''\r ')
		PHP_V=$(grep "version:" "$LOCAL_PKG_BASE/php/+MANIFEST" 2> /dev/null | head -n1 | cut -d':' -f2 | tr -d '"'\''\r ')
		WEB_TERMINAL_V=$(grep "version:" "$LOCAL_PKG_BASE/web-terminal/+MANIFEST" 2> /dev/null | head -n1 | cut -d':' -f2 | tr -d '"'\''\r ')
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
			BUILD_VER=$(grep "version:" "$REAL_BASE_DIR/pkg/hestia/+MANIFEST" 2> /dev/null | head -n1 | cut -d':' -f2 | tr -d '"'\''\r ')
			NGINX_V=$(grep "version:" "$REAL_BASE_DIR/pkg/nginx/+MANIFEST" 2> /dev/null | head -n1 | cut -d':' -f2 | tr -d '"'\''\r ')
			PHP_V=$(grep "version:" "$REAL_BASE_DIR/pkg/php/+MANIFEST" 2> /dev/null | head -n1 | cut -d':' -f2 | tr -d '"'\''\r ')
			WEB_TERMINAL_V=$(grep "version:" "$REAL_BASE_DIR/pkg/web-terminal/+MANIFEST" 2> /dev/null | head -n1 | cut -d':' -f2 | tr -d '"'\''\r ')
		fi
	fi

elif [ "$OSTYPE" = 'rhel' ]; then
	if [ -d "$SRC_DIR/src/rpm" ]; then LOCAL_RPM_BASE="$SRC_DIR/src/rpm"; else LOCAL_RPM_BASE="$SRC_DIR/rpm"; fi
	if [ "$use_src_folder" = 'true' ] && [ -d "$LOCAL_RPM_BASE" ]; then
		BUILD_VER=$(grep "Version:" "$LOCAL_RPM_BASE/hestia/hestia.spec" 2> /dev/null | head -n1 | cut -d' ' -f2 | tr -d '\r')
		NGINX_V=$(grep "Version:" "$LOCAL_RPM_BASE/nginx/hestia-nginx.spec" 2> /dev/null | head -n1 | cut -d' ' -f2 | tr -d '\r')
		PHP_V=$(grep "Version:" "$LOCAL_RPM_BASE/php/hestia-php.spec" 2> /dev/null | head -n1 | cut -d' ' -f2 | tr -d '\r')
		WEB_TERMINAL_V=$(grep "Version:" "$LOCAL_RPM_BASE/web-terminal/hestia-web-terminal.spec" 2> /dev/null | head -n1 | cut -d' ' -f2 | tr -d '\r')
	else
		BUILD_VER=$(curl -s "https://raw.githubusercontent.com/$REPO/$branch/src/rpm/hestia/hestia.spec" | grep "Version:" | head -n1 | cut -d' ' -f2 | tr -d '\r')
		NGINX_V=$(curl -s "https://raw.githubusercontent.com/$REPO/$branch/src/rpm/nginx/hestia-nginx.spec" | grep "Version:" | head -n1 | cut -d' ' -f2 | tr -d '\r')
		PHP_V=$(curl -s "https://raw.githubusercontent.com/$REPO/$branch/src/rpm/php/hestia-php.spec" | grep "Version:" | head -n1 | cut -d' ' -f2 | tr -d '\r')
		WEB_TERMINAL_V=$(curl -s "https://raw.githubusercontent.com/$REPO/$branch/src/rpm/web-terminal/hestia-web-terminal.spec" 2> /dev/null | grep "Version:" | head -n1 | cut -d' ' -f2 | tr -d '\r')
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
		SOFTWARE='bash gmake perl5 git curl pkgconf openssl pcre2 autoconf automake libtool ca_root_nss npm node libxml2 libxslt bison libzip sqlite3 re2c gmp python gcc'
		echo "Updating FreeBSD package repository..."
		pkg update -f
		echo "Installing FreeBSD build dependencies..."
		pkg install -y $SOFTWARE

		NODE_VERSION=$(node -v 2> /dev/null | cut -d'v' -f2 | cut -d'.' -f1)
		if [ -z "$NODE_VERSION" ] || [ "$NODE_VERSION" -lt 24 ]; then
			echo "[ ! ] Node.js version 24+ is required for Hestia Vhost compilation. Forcing update..."
			pkg install -y node
		fi

		NUM_CPUS=$(sysctl -n hw.ncpu 2> /dev/null || echo 4)

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
			rm -rf nginx-* openssl-* pcre2-* zlib-* v1.* 2> /dev/null

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
				REAL_NGINX_DIR=$(find "$BUILD_DIR" -maxdepth 2 -type f -name "configure" | grep -E 'nginx|src' | head -n1 | xargs dirname 2> /dev/null)
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
				sed -i '' 's/ggmake/gmake/g' Makefile 2> /dev/null || true
				# 确保有空目标
				if ! grep -q "^distclean:" Makefile 2> /dev/null; then
					echo "" >> Makefile
					echo "distclean:" >> Makefile
					echo "	@echo '[ ✓ ] Bypassing distclean (FreeBSD)'" >> Makefile
					echo "clean:" >> Makefile
					echo "	@echo '[ ✓ ] Bypassing clean (FreeBSD)'" >> Makefile
				fi
				rm -f Makefile 2> /dev/null || true
				cd "$BUILD_DIR_NGINX" || exit 1

				# 修复 nginx objs/Makefile
				if [ -f "objs/Makefile" ]; then
					# 删除或替换 distclean 行
					sed -i '' '/distclean/d' objs/Makefile 2> /dev/null || true
					# 修复 ggmake
					sed -i '' 's/ggmake/gmake/g' objs/Makefile 2> /dev/null || true
					sed -i '' 's/make /gmake /g' objs/Makefile 2> /dev/null || true
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
		[ ! -d "/usr/local/hestia" ] && mkdir -p "/usr/local/hestia" 2> /dev/null || true

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
			mv -f $PKG_DIR/hestia-nginx-1*.pkg "$PKG_DIR/hestia-nginx-${CLEAN_NGINX_VER_FINAL}.pkg" 2> /dev/null
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

# =================================================================================
# Building hestia-php
# =================================================================================

if [ "$PHP_B" = "true" ]; then
	if [ "$CROSS" = "true" ]; then
		echo "Cross compile not supported for hestia-nginx, hestia-php or hestia-web-terminal"
		exit 1
	fi

	echo "Building hestia-php package..."

	if [ "$BUILD_DEB" = "true" ] || [ "$BUILD_PKG" = "true" ]; then
		CLEAN_PHP_VER_FINAL=$(echo "${PHP_V}" | tr -d '"'\''\r')
		BUILD_DIR_HESTIAPHP="$BUILD_DIR/hestia-php_${CLEAN_PHP_VER_FINAL}"
		CLEAN_PHP_VER=$(echo "$PHP_V" | tr -d "'\"\r" | cut -d"-" -f1 | cut -d"~" -f1)

		if [ "$KEEPBUILD" != 'true' ] || [ ! -d "$BUILD_DIR_HESTIAPHP" ]; then
			[ -d "$BUILD_DIR_HESTIAPHP" ] && rm -rf "$BUILD_DIR_HESTIAPHP"
			mkdir -p "$BUILD_DIR_HESTIAPHP"

			cd "$BUILD_DIR" || exit 1

			PHP_FILE="$ARCHIVE_DIR/php-${CLEAN_PHP_VER}.tar.gz"
			if [ ! -f "$PHP_FILE" ]; then
				PHP_FILE="$ARCHIVE_DIR/php-$(echo "$PHP_V" | tr -d '\r' | cut -d"~" -f1).tar.gz"
				if [ ! -f "$PHP_FILE" ]; then
					PHP_FILE="$ARCHIVE_DIR/php-$(echo "$PHP_V" | tr -d '\r' | cut -d"-" -f1).tar.gz"
				fi
			fi

			if [ ! -f "$PHP_FILE" ]; then
				echo "[ ! ] Local PHP archive not found. Activating remote network self-healing stream..."
				download_file "$PHP"
				PHP_FILE="$ARCHIVE_DIR/php-${CLEAN_PHP_VER}.tar.gz"
				[ ! -f "$PHP_FILE" ] && PHP_FILE=$(find "$ARCHIVE_DIR" -name "php-*.tar.gz" | head -n1)
			else
				echo "[ ✓ ] High performance offline mode activated. Using local PHP package: $PHP_FILE"
			fi

			if [ ! -f "$PHP_FILE" ]; then
				echo "ERROR: Critical failure. Unable to secure PHP source archive."
				exit 1
			fi

			# 清理历史残余
			rm -rf php-* 2> /dev/null

			echo "[ * ] Unpacking PHP raw materials via native bsdtar..."
			bsdtar -xf "$PHP_FILE"

			PHP_SRC_DIR="${BUILD_DIR}/php-src-php-${CLEAN_PHP_VER}"
			if [ ! -d "$PHP_SRC_DIR" ]; then
				PHP_SRC_DIR=$(find "$BUILD_DIR" -maxdepth 1 -type d -name "php-*" | head -n1)
			fi

			if [ -d "$PHP_SRC_DIR" ]; then
				cd "$PHP_SRC_DIR" || exit 1
				if [ -f "buildconf" ]; then
					echo "[ * ] Generating configure script via buildconf..."
					./buildconf --force
				fi
				BUILD_DIR_PHP="$PHP_SRC_DIR"
			else
				REAL_PHP_DIR=$(find "$BUILD_DIR" -type f -name "configure" -o -name "configure.ac" | head -n1 | xargs dirname 2> /dev/null)
				if [ -n "$REAL_PHP_DIR" ] && [ -d "$REAL_PHP_DIR" ]; then
					cd "$REAL_PHP_DIR" || exit 1
					[ -f "buildconf" ] && ./buildconf --force
					BUILD_DIR_PHP="$REAL_PHP_DIR"
				else
					echo "ERROR: PHP source directory not found"
					exit 1
				fi
			fi

			echo "[ ✓ ] Target radar successfully pierced and locked PHP workspace at: $BUILD_DIR_PHP"

			cd "$BUILD_DIR_PHP" || exit 1

			if [ "$OSTYPE" = 'freebsd' ]; then
				pw groupadd admin 2> /dev/null || true
				pw useradd admin -g admin -s /bin/sh -d /home/admin -m 2> /dev/null || true
				export CFLAGS="-I/usr/local/include"
				export LDFLAGS="-L/usr/local/lib"
				export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig"
			fi

			if [ "$OSTYPE" = 'freebsd' ]; then
				if [ ! -d "${BUILD_DIR}/openssl-$OPENSSL_V" ]; then
					echo "[ ! ] Warning: Local isolated OpenSSL source pool missing. Re-extracting for PHP static link..."
					OPENSSL_FILE="$ARCHIVE_DIR/openssl-$OPENSSL_V.tar.gz"
					if [ -f "$OPENSSL_FILE" ]; then
						cd "$BUILD_DIR" && bsdtar -xf "$OPENSSL_FILE" && cd "$BUILD_DIR_PHP"
					else
						echo "ERROR: Local openssl archive missing, unable to boot link pipeline."
						exit 1
					fi
				fi

				./configure --prefix=/usr/local/hestia/php \
					--enable-fpm \
					--with-fpm-user=admin \
					--with-fpm-group=admin \
					--with-openssl="${BUILD_DIR}/openssl-$OPENSSL_V" \
					--with-mysqli=mysqlnd \
					--with-gettext=/usr/local \
					--with-curl=/usr/local \
					--with-zip \
					--with-gmp=/usr/local \
					--enable-mbstring \
					--with-iconv=/usr/local
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

		if [ -z "$BUILD_DIR_PHP" ] || [ ! -d "$BUILD_DIR_PHP" ]; then
			BUILD_DIR_PHP=$(find "$BUILD_DIR" -type f -name "configure" | head -n1 | xargs dirname 2> /dev/null)
		fi

		cd "$BUILD_DIR_PHP" || {
			echo "ERROR: Critical flow crash. Unable to re-enter PHP workspace: $BUILD_DIR_PHP"
			exit 1
		}

		mkdir -p "${BUILD_DIR}/usr/local/hestia"
		[ ! -d "/usr/local/hestia" ] && mkdir -p "/usr/local/hestia" 2> /dev/null || true

		if [ "$OSTYPE" = 'freebsd' ]; then
			env MAKEFLAGS="" gmake -j "$NUM_CPUS" && gmake INSTALL_ROOT="$BUILD_DIR" install
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
			mv -f $PKG_DIR/hestia-php-1*.pkg "$PKG_DIR/hestia-php-${CLEAN_PHP_VER_FINAL}.pkg" 2> /dev/null

			echo "[ * ] Verifying php package integrity..."
			if pkg info -F "$PKG_DIR/hestia-php-${CLEAN_PHP_VER_FINAL}.pkg" > /dev/null 2>&1; then
				echo "✅ PHP package is valid."
			else
				echo "❌ ERROR: PHP package validation failed!"
				exit 1
			fi
			cd "$PKG_DIR" || exit 1
		fi

		#rm -rf "$BUILD_DIR/usr"

		if [ "$KEEPBUILD" != 'true' ]; then
			rm -rf "$BUILD_DIR/php-${CLEAN_PHP_VER}" 2> /dev/null
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
			mv -f $PKG_DIR/hestia-web-terminal-1*.pkg "$PKG_DIR/hestia-web-terminal-${WEB_TERMINAL_V}.pkg" 2> /dev/null
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

				mv -f $PKG_DIR/hestia-1*.pkg "$PKG_DIR/hestia-${BUILD_VER}.pkg" 2> /dev/null

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
    echo "[ * ] Copying to:   $HOST_WORKSPACE"
    
    cp -R "$PKG_DIR/." "$ARTIFACTS_DIR/"
    EXIT_CODE=$?
    
    if [ $EXIT_CODE -eq 0 ]; then
        echo "✅ Artifacts copied successfully!"
        echo ""
        echo "=== Files in host workspace ($HOST_WORKSPACE) ==="
        ls -la "$HOST_WORKSPACE/"
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
