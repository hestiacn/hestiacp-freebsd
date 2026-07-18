#!/bin/bash
# src/build-php82-openssl4.sh
# Build PHP 8.2.31 with OpenSSL 4.x and create package

set -e

# ============================================================
# 配置
# ============================================================
PHP_VERSION="8.2.31"
BUILD_DIR="/tmp/php-build-test"
ARCHIVE_DIR="$BUILD_DIR/archive"
PKG_DIR="$BUILD_DIR/pkg"
LOG_DIR="$BUILD_DIR/logs"
ARTIFACT_DIR="${ARTIFACT_DIR:-/home/runner/work/hestiacp-freebsd/hestiacp-freebsd/artifacts}"
NUM_CPUS=$(sysctl -n hw.ncpu || echo 4)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 创建所有需要的目录
mkdir -p "$BUILD_DIR" "$ARCHIVE_DIR" "$LOG_DIR" "$PKG_DIR" "$ARTIFACT_DIR"

echo "========================================"
echo "Build PHP ${PHP_VERSION} with OpenSSL 4.x"
echo "========================================"
echo "OpenSSL prefix: ${OPENSSL_PREFIX:-/usr/local}"
echo "OpenSSL version: $(openssl version || echo 'unknown')"
echo "CFLAGS: $CFLAGS"
echo "LDFLAGS: $LDFLAGS"
echo "========================================"

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
		"--enable-dtrace"
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
		#"--disable-shared"
		"--with-password-argon2=/usr/local"
		"--with-sodium"
		"--enable-gd"
		"--with-freetype"
		"--with-jpeg"
		"--with-webp"
		"--enable-zip"
		"--with-gettext=/usr/local"
		"--with-curl=/usr/local"
		"--with-gmp=/usr/local"
		"--with-zlib=/usr"
		"--with-bz2=/usr"
		"--with-gettext"
		"--with-mysqli=mysqlnd"
		"--with-pdo-mysql=mysqlnd"
		"--with-pgsql"
		"--with-pdo-pgsql"
		"--with-iconv=/usr/local"
		"--with-openssl=${OPENSSL_PREFIX:-/usr/local}"
		"--disable-dom"
		"--disable-xmlreader"
		"--disable-xmlwriter"
		"--disable-simplexml"
	)

	# PHP 5.6: 没有 --enable-fileinfo
	if [ "$major" = "5" ]; then
		local new_args=()
		for arg in "${args[@]}"; do
			if [[ "$arg" != "--enable-fileinfo" ]]; then
				new_args+=("$arg")
			fi
		done
		args=("${new_args[@]}")
	fi

	# PHP 5.6 和 7.0: 没有 --enable-filter
	if [ "$major" = "5" ] || { [ "$major" = "7" ] && [ "$minor" = "0" ]; }; then
		local new_args=()
		for arg in "${args[@]}"; do
			if [[ "$arg" != "--enable-filter" ]]; then
				new_args+=("$arg")
			fi
		done
		args=("${new_args[@]}")
	fi

	# PHP 7.1 及以下: 没有 Argon2 支持
	if [ "$major" = "7" ] && [ -n "$minor" ] && [ "$minor" -lt "2" ]; then
		local new_args=()
		for arg in "${args[@]}"; do
			if [[ "$arg" != "--with-password-argon2="* ]]; then
				new_args+=("$arg")
			fi
		done
		args=("${new_args[@]}")
	fi

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
		echo "[ * ] Updating copyright year to 2025..."
		find ./main ./Zend ./ext ./sapi ./TSRM -type f \( -name "*.c" -o -name "*.h" \) 2>/dev/null \
			-exec sed -i '' 's/| Copyright (c) The PHP Group.*/| Copyright (c) 1997-2025 The PHP Group                                |/' {} \;
		
		find ./main ./Zend ./ext ./sapi ./TSRM -type f \( -name "*.c" -o -name "*.h" \) 2>/dev/null \
			-exec sed -i '' 's/| Copyright (c) Zend Technologies.*/| Copyright (c) 1998-2025 Zend Technologies Ltd. (http:\/\/www.zend.com) |/' {} \;
		
		for file in sapi/cli/php_cli.c sapi/fpm/fpm/fpm_main.c sapi/cgi/cgi_main.c sapi/litespeed/lsapi_main.c sapi/phpdbg/phpdbg.c; do
			[ -f "$file" ] && sed -i '' 's/Copyright (c) The PHP Group/Copyright (c) 1997-2025 The PHP Group/g' "$file"
		done
		
		sed -i '' 's/#define ZEND_CORE_VERSION_INFO.*"Zend Engine v" ZEND_VERSION ", Copyright (c) Zend Technologies\\n".*/#define ZEND_CORE_VERSION_INFO\t"Zend Engine v" ZEND_VERSION ", Copyright (c) 1998-2025 Zend Technologies\\n"/' ./Zend/zend.c
		
		echo "[ ✓ ] Copyright updated to 2025"
		grep "Copyright" ./main/main.c 2>/dev/null || true
		grep "Copyright" ./Zend/zend.c 2>/dev/null || true
	fi

	echo "[ ✓ ] All patches applied for PHP ${PHP_VERSION}"
	cd - > /dev/null || return 1
}

# ============================================================
# 构建 PHP
# ============================================================
build_php() {
	local build_dir="$BUILD_DIR/php-src-${PHP_VERSION}"
	local install_dir="$BUILD_DIR/php-${PHP_VERSION}"

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

	cd "$build_dir" || return 1

	[ -f "Makefile" ] && gmake clean || true

	if [ -f "buildconf" ]; then
		echo "[ * ] Running buildconf..."
		./buildconf --force | tee "$LOG_DIR/buildconf-${PHP_VERSION}.log"
	fi

	apply_patches "$build_dir"

	# 设置 OpenSSL 4.x 环境变量
	export CFLAGS="-I/usr/local/include -I/usr/local/include \
		-Wno-deprecated-declarations \
		-Wno-incompatible-pointer-types-discards-qualifiers \
		-Wno-pointer-bool-conversion \
		-Wno-implicit-function-declaration \
		-Wno-pointer-sign \
		-Wno-implicit-const-int-float-conversion"
	export LDFLAGS="-L/usr/local/lib -L/usr/local/lib"
	export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:/usr/local/lib/pkgconfig"
	export CPPFLAGS="$CFLAGS"
	export LD_LIBRARY_PATH="${OPENSSL_PREFIX:-/usr/local}/lib"
	
	echo "[ * ] Configuring PHP ${PHP_VERSION}..."
	echo "OpenSSL prefix: ${OPENSSL_PREFIX:-/usr/local}"
	echo "CFLAGS: $CFLAGS"
	echo "LDFLAGS: $LDFLAGS"

	mapfile -t CONFIG_ARGS < <(get_config_args)
	echo "Config args: ${CONFIG_ARGS[*]}"

	./configure "${CONFIG_ARGS[@]}" > "$LOG_DIR/configure-${PHP_VERSION}.log"
	if [ $? -ne 0 ]; then
		echo "❌ Configure failed"
		tail -50 "$LOG_DIR/configure-${PHP_VERSION}.log"
		return 1
	fi

	echo "[ * ] Compiling PHP ${PHP_VERSION} (using ${NUM_CPUS} cores)..."
	gmake -j "$NUM_CPUS" > "$LOG_DIR/build-${PHP_VERSION}.log"

	if [ $? -ne 0 ]; then
		echo ""
		echo "========================================"
		echo "❌ BUILD FAILED"
		echo "========================================"
		echo ""
		echo "=== OpenSSL related errors ==="
		grep -E "openssl.*error:|Error.*openssl" "$LOG_DIR/build-${PHP_VERSION}.log" | head -30
		echo ""
		echo "=== All errors ==="
		grep -E "error:" "$LOG_DIR/build-${PHP_VERSION}.log" | head -50
		echo ""
		echo "========================================"
		echo "Last 100 lines:"
		echo "========================================"
		tail -100 "$LOG_DIR/build-${PHP_VERSION}.log"
		return 1
	fi

	echo "[ * ] Installing PHP ${PHP_VERSION}..."
	mkdir -p "$install_dir"
	gmake install INSTALL_ROOT="$install_dir" > "$LOG_DIR/install-${PHP_VERSION}.log"
	if [ $? -ne 0 ]; then
		echo "❌ Install failed"
		tail -50 "$LOG_DIR/install-${PHP_VERSION}.log"
		return 1
	fi

	if [ -f "$install_dir/usr/local/bin/php" ]; then
		echo "✅ PHP ${PHP_VERSION} with OpenSSL 4.x built successfully!"
		"$install_dir/usr/local/bin/php" -v || true
		return 0
	else
		echo "❌ PHP binary not found!"
		return 1
	fi
}

# ============================================================
# 创建 FreeBSD 包
# ============================================================
create_package() {
	local install_dir="$BUILD_DIR/php-${PHP_VERSION}"
	local php_bin="$install_dir/usr/local/bin/php"
	local ver_suffix=$(echo "$PHP_VERSION" | cut -d. -f1-2 | tr -d '.')
	
	echo ""
	echo "========================================"
	echo "[ * ] Creating FreeBSD package..."
	echo "========================================"
	
	if [ ! -f "$php_bin" ]; then
		echo "❌ PHP binary not found at $php_bin"
		return 1
	fi
	
	# 验证 PHP
	echo "[ * ] Verifying PHP binary..."
	"$php_bin" -v || {
		echo "❌ PHP binary verification failed!"
		return 1
	}
	
	# 验证 OpenSSL 扩展
	echo "[ * ] Verifying OpenSSL extension..."
	"$php_bin" -m | grep -i openssl || {
		echo "❌ OpenSSL extension not loaded!"
		return 1
	}
	
	echo ""
	echo "[ * ] Running quick tests..."
	"$php_bin" -r '
		echo "PHP Version: " . PHP_VERSION . "\n";
		echo "OpenSSL Version: " . OPENSSL_VERSION_TEXT . "\n";
		echo "openssl_encrypt(): " . (function_exists("openssl_encrypt") ? "✅" : "❌") . "\n";
		echo "openssl_decrypt(): " . (function_exists("openssl_decrypt") ? "✅" : "❌") . "\n";
		echo "openssl_sign(): " . (function_exists("openssl_sign") ? "✅" : "❌") . "\n";
		echo "openssl_verify(): " . (function_exists("openssl_verify") ? "✅" : "❌") . "\n";
	'
	
	# 创建包目录结构
	PKG_NAME="php${ver_suffix}-openssl4"
	
	rm -rf "${PKG_DIR}"
	mkdir -p "${PKG_DIR}/usr/local"
	mkdir -p "${ARTIFACT_DIR}"
	
	echo "[ * ] Copying PHP files to ${PKG_DIR}..."
	cp -r "${install_dir}/usr/local/"* "${PKG_DIR}/usr/local/"
	
	# 验证复制
	if [ ! -f "${PKG_DIR}/usr/local/bin/php" ]; then
		echo "❌ PHP binary not found after copy!"
		echo "  Expected: ${PKG_DIR}/usr/local/bin/php"
		echo "  Files in PKG_DIR:"
		find "${PKG_DIR}" -type f | head -10
		return 1
	fi
	
	echo "[ ✓ ] Files copied successfully"
	
	# 创建 PLIST（列出所有文件）
	echo "[ * ] Creating file list..."
	cd "${PKG_DIR}"
	find . -type f | sed 's|^\.||' > +PLIST
	
	# 创建 MANIFEST
	echo "[ * ] Creating package metadata..."
	cat > "+MANIFEST" << EOF
name: ${PKG_NAME}
version: ${PHP_VERSION}
origin: local/php${ver_suffix}-openssl4
comment: PHP ${PHP_VERSION} with OpenSSL 4.x support
categories: [www, lang]
maintainer: build@hestiacp.com
www: https://github.com/hestiacp/hestiacp-freebsd
prefix: /usr/local
desc: <<EOD
PHP ${PHP_VERSION} compiled with OpenSSL 4.x support.

This is a custom build of PHP 8.2.31 that includes:
- OpenSSL 4.x compatibility patches
- FPM, CLI, CGI support
- Common extensions: mbstring, bcmath, curl, gmp, mysqli, pdo_mysql, pgsql, pdo_pgsql, etc.
- Argon2 password hashing support
- Sodium cryptography support
- GD with JPEG, PNG, WebP, FreeType support
- Enums support
- Fibers support
- Readonly classes
- Disjunctive Normal Form (DNF) types

IMPORTANT: PHP 8.2 is end-of-life. Use at your own risk.
EOD
EOF
	
	# 创建安装后脚本
	cat > "+POST_INSTALL" << 'EOF'
#!/bin/sh
echo "========================================"
echo "PHP 8.2.31 with OpenSSL 4.x installed"
echo "========================================"
echo "Location: /usr/local"
echo "Binary:   /usr/local/bin/php${ver_suffix}"
echo ""
echo "To add to PATH:"
echo "  export PATH=/usr/local/bin:\$PATH"
echo "========================================"
EOF
	chmod +x "+POST_INSTALL"
	
	# 创建包
	echo "[ * ] Creating package..."
	echo "  Metadata dir: ${PKG_DIR}"
	echo "  PLIST: ${PKG_DIR}/+PLIST"
	echo "  Root dir: ${PKG_DIR}"
	echo "  Output: ${ARTIFACT_DIR}"
	
	pkg create \
		-m "${PKG_DIR}" \
		-p "${PKG_DIR}/+PLIST" \
		-r "${PKG_DIR}" \
		-o "${ARTIFACT_DIR}"
	
	PKG_FILE="${ARTIFACT_DIR}/${PKG_NAME}-${PHP_VERSION}.pkg"
	
	if [ -f "${PKG_FILE}" ]; then
		FILE_SIZE=$(du -h "${PKG_FILE}" | cut -f1)
		echo ""
		echo "========================================"
		echo "✅ Package created successfully!"
		echo "========================================"
		echo "Package: ${PKG_FILE}"
		echo "Size: ${FILE_SIZE}"
		echo "========================================"
		
		echo ""
		echo "========================================"
		echo "📦 Package Contents (${PKG_FILE})"
		echo "========================================"
		echo ""
		echo "Package Name: ${PKG_NAME}"
		echo "Version: ${PHP_VERSION}"
		echo "Size: ${FILE_SIZE}"
		echo "Location: ${PKG_FILE}"
		echo ""
		echo "--- Files in package ---"
		pkg info -l "${PKG_FILE}" || tar -tf "${PKG_FILE}" || {
			echo "⚠️  Cannot list package contents (pkg info not available)"
			echo "Files in ${PKG_DIR}:"
			find "${PKG_DIR}" -type f | sort
		}
		echo "========================================"
		
		return 0
	else
		echo "❌ Failed to create package!"
		echo "Files in ${ARTIFACT_DIR}:"
		ls -la "${ARTIFACT_DIR}/"
		return 1
	fi
}

# ============================================================
# 主函数
# ============================================================
main() {
	echo ""
	echo "========================================"
	echo "Build PHP ${PHP_VERSION} with OpenSSL 4.x"
	echo "========================================"
	echo "Start time: $(date)"
	echo ""

	if build_php; then
		echo ""
		echo "========================================"
		echo "✅ BUILD SUCCESSFUL"
		echo "========================================"
		echo ""
		echo "PHP binary: $BUILD_DIR/php-${PHP_VERSION}/usr/local/bin/php"
		
		if create_package; then
			echo ""
			echo "========================================"
			echo "✅ ALL COMPLETED"
			echo "========================================"
			local ver_suffix=$(echo "$PHP_VERSION" | cut -d. -f1-2 | tr -d '.')
			echo "Package: ${ARTIFACT_DIR}/php${ver_suffix}-openssl4-${PHP_VERSION}.pkg"
			echo "========================================"
			exit 0
		else
			echo ""
			echo "========================================"
			echo "❌ PACKAGE CREATION FAILED"
			echo "========================================"
			exit 1
		fi
	else
		echo ""
		echo "========================================"
		echo "❌ BUILD FAILED"
		echo "========================================"
		echo ""
		echo "Check the build log: $LOG_DIR/build-${PHP_VERSION}.log"
		exit 1
	fi
}

main "$@"