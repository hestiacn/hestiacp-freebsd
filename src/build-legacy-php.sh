#!/bin/bash
# src/build-legacy-php.sh
# Build a single PHP version (called by GitHub Actions matrix)

set -e

# ============================================================
# 配置
# ============================================================
BUILD_DIR="/tmp/php-build"
ARCHIVE_DIR="$BUILD_DIR/archive"
PKG_DIR="$BUILD_DIR/pkg"
LOG_DIR="$BUILD_DIR/logs"
NUM_CPUS=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
ARTIFACT_DIR="${ARTIFACT_DIR:-/home/runner/work/hestiacp-freebsd/hestiacp-freebsd/artifacts}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$BUILD_DIR" "$ARCHIVE_DIR" "$PKG_DIR" "$LOG_DIR" "$ARTIFACT_DIR"

OPENSSL_PREFIX="/usr"

# ============================================================
# 函数定义
# ============================================================

download_php() {
	local version=$1
	local file="$ARCHIVE_DIR/php-${version}.tar.gz"

	if [ -f "$file" ]; then
		echo "[ ✓ ] PHP ${version} already downloaded"
		return 0
	fi

	echo "[ * ] Downloading PHP ${version}..."

	case "$version" in
		8.2.31|8.3.31|8.4.22|8.5.7)
			fetch -o "$file" "https://github.com/php/php-src/archive/refs/tags/php-${version}.tar.gz"
			;;
		*)
			fetch -o "$file" "https://www.php.net/distributions/php-${version}.tar.gz"
			;;
	esac

	if [ $? -ne 0 ]; then
		echo "❌ Failed to download PHP ${version}"
		return 1
	fi
	echo "[ ✓ ] Downloaded PHP ${version}"
	return 0
}

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
		"--enable-gd"
		"--enable-static"
		"--enable-static=yes"
		"--enable-shared=yes"
		#"--disable-shared"
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
        "--with-freetype=/usr/local"
        "--with-jpeg=/usr/local"
        "--with-webp=/usr/local"
		"--with-imagick=/usr/local"
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
	if [ "$major" = "5" ] || [ "$major" = "7" -a "$minor" = "0" ]; then
		local new_args=()
		for arg in "${args[@]}"; do
			if [[ "$arg" != "--enable-filter" ]]; then
				new_args+=("$arg")
			fi
		done
		args=("${new_args[@]}")
	fi

	printf "%s\n" "${args[@]}"
}

apply_patches() {
	local build_dir=$1
	local version=$2

	cd "$build_dir" || return 1

	echo "[ * ] Applying patches for PHP ${version}..."

	local major=$(echo "$version" | cut -d. -f1)
	local minor=$(echo "$version" | cut -d. -f2)

	# libxml2 补丁
	if [ -f "ext/libxml/libxml.c" ]; then
		if grep -q "int compression ATTRIBUTE_UNUSED)" ext/libxml/libxml.c 2>/dev/null; then
			sed -i '' 's/int compression ATTRIBUTE_UNUSED)/int compression)/' ext/libxml/libxml.c
			echo "[ ✓ ] libxml.c ATTRIBUTE_UNUSED removed"
		fi
		if grep -q "xmlSetStructuredErrorFunc(NULL, php_libxml_structured_error_handler);" ext/libxml/libxml.c 2>/dev/null; then
			sed -i '' 's/xmlSetStructuredErrorFunc(NULL, php_libxml_structured_error_handler);/xmlSetStructuredErrorFunc(NULL, (xmlStructuredErrorFunc)php_libxml_structured_error_handler);/' ext/libxml/libxml.c
			echo "[ ✓ ] libxml.c xmlSetStructuredErrorFunc cast"
		fi
		if grep -q "error = xmlGetLastError();" ext/libxml/libxml.c 2>/dev/null; then
			sed -i '' 's/error = xmlGetLastError();/error = (xmlErrorPtr)xmlGetLastError();/' ext/libxml/libxml.c
			echo "[ ✓ ] libxml.c xmlGetLastError cast"
		fi
	fi

	# zlib 补丁
	if [ -f "ext/zlib/zlib.c" ]; then
		if grep -q "ZEND_MODULE_GLOBALS_CTOR_N(zlib)" ext/zlib/zlib.c 2>/dev/null; then
			sed -i '' 's/ZEND_MODULE_GLOBALS_CTOR_N(zlib),/NULL,/' ext/zlib/zlib.c
			echo "[ ✓ ] zlib.c globals_ctor set to NULL"
		fi
	fi

	# OpenSSL 补丁（仅 PHP < 8.0）
	if [ "$major" -lt "8" ]; then
		echo "[ * ] Applying OpenSSL 3.x compatibility patches (PHP < 8.0)..."
		
		local custom_openssl_dir="$SCRIPT_DIR/php${major}.${minor}"
		[ ! -d "$custom_openssl_dir" ] && custom_openssl_dir="$SCRIPT_DIR/php${major}"
		[ ! -d "$custom_openssl_dir" ] && custom_openssl_dir="$SCRIPT_DIR/php7.4"
		
		if [ -d "$custom_openssl_dir" ]; then
			[ -f "$custom_openssl_dir/openssl.c" ] && cp "$custom_openssl_dir/openssl.c" "ext/openssl/openssl.c"
			[ -f "$custom_openssl_dir/xp_ssl.c" ] && cp "$custom_openssl_dir/xp_ssl.c" "ext/openssl/xp_ssl.c"
			echo "[ ✓ ] OpenSSL patches applied"
		else
			echo "⚠️  No OpenSSL patch files found for PHP ${version}"
		fi
	else
		echo "[ * ] PHP ${major}.${minor} has native OpenSSL 3.x support"
	fi

	# xxHash 补丁（PHP 8.1+）
	if [ "$major" -ge "8" ] && [ "$minor" -ge "1" ]; then
		if [ -f "ext/hash/hash_xxhash.c" ]; then
			sed -i '' 's|#include <xxhash.h>|#include "xxhash.h"|' ext/hash/hash_xxhash.c
			sed -i '' 's/&& ctx->s.memsize < 16)/\&\& 1)/' ext/hash/hash_xxhash.c
			sed -i '' 's/&& ctx->s.memsize < 32)/\&\& 1)/' ext/hash/hash_xxhash.c
			echo "[ ✓ ] xxHash compatibility fixed"
		fi
	fi

	# oniguruma 补丁
	if [ "$major" = "5" ] || [ "$major" = "7" -a "$minor" = "0" ]; then
		# oniguruma 补丁（仅 PHP 5.6）
		if [ "$major" = "5" ]; then
			if [ -f "ext/mbstring/php_onig_compat.h" ]; then
				sed -i '' 's|#include <oniguruma.h>|#include "oniguruma.h"|' ext/mbstring/php_onig_compat.h
			fi
			if [ -f "ext/mbstring/php_mbregex.c" ]; then
				sed -i '' 's|#include <oniguruma.h>|#include "oniguruma.h"|' ext/mbstring/php_mbregex.c
			fi
			echo "[ ✓ ] oniguruma fixed for PHP 5.6"
		fi
		
		if [ -f "ext/dom/dom_iterators.c" ]; then
			sed -i '' 's/xmlHashScan(ht, itemHashScanner, iter);/xmlHashScan(ht, (xmlHashScanner)itemHashScanner, iter);/' ext/dom/dom_iterators.c
			echo "[ ✓ ] Fixed libxml2 function pointer types in dom_iterators.c"
		fi
	fi

	# readdir_r 补丁（PHP 7.3+）
	if [ "$major" -ge "8" ] || [ "$major" = "7" -a "$minor" -ge "3" ]; then
		if [ -f "main/reentrancy.c" ]; then
			sed -i '' 's/readdir_r(dirp, entry);/readdir_r(dirp, entry, result);/' main/reentrancy.c
			echo "[ ✓ ] readdir_r fixed"
		fi
	fi

	echo "[ ✓ ] All patches applied"
	cd - > /dev/null || return 1
}

build_php() {
	local version=$1
	
	local build_dir="$BUILD_DIR/php-src-${version}"
	local install_dir="$BUILD_DIR/php-${version}"
	
	echo ""
	echo "========================================"
	echo "[ * ] Building PHP ${version}"
	echo "========================================"

	if ! download_php "$version"; then
		return 1
	fi

	if [ ! -d "$build_dir" ]; then
		echo "[ * ] Extracting PHP ${version}..."
		tar -xf "$ARCHIVE_DIR/php-${version}.tar.gz" -C "$BUILD_DIR"
		if [ -d "$BUILD_DIR/php-src-php-${version}" ]; then
			mv "$BUILD_DIR/php-src-php-${version}" "$build_dir"
		elif [ -d "$BUILD_DIR/php-${version}" ]; then
			mv "$BUILD_DIR/php-${version}" "$build_dir"
		elif [ -d "$BUILD_DIR/php-src-${version}" ]; then
			mv "$BUILD_DIR/php-src-${version}" "$build_dir"
		fi
	fi

	cd "$build_dir" || return 1
	if [ ! -f "configure" ]; then
		echo "[ * ] configure not found, running buildconf..."
		if [ -f "buildconf" ]; then
			./buildconf --force | tee "$LOG_DIR/buildconf-${version}.log"
			if [ $? -ne 0 ]; then
				echo "❌ buildconf failed"
				return 1
			fi
			echo "[ ✓ ] buildconf completed"
		else
			echo "❌ Neither configure nor buildconf found"
			ls -la
			return 1
		fi
	fi
	[ -f "Makefile" ] && gmake clean 2>/dev/null || true

	local major=$(echo "$version" | cut -d. -f1)
	local minor=$(echo "$version" | cut -d. -f2)
	local ver_suffix="${major}${minor}"
	if [ "$major" = "5" ]; then
		if [ -f "buildconf" ]; then
			echo "[ * ] Running buildconf for PHP 5.6..."
			./buildconf --force | tee "$LOG_DIR/buildconf-${version}.log"
		fi
	fi

	apply_patches "$build_dir" "$version"

	export CFLAGS="-I/usr/include -I/usr/local/include \
		-Wno-deprecated-declarations \
		-Wno-incompatible-pointer-types-discards-qualifiers \
		-Wno-pointer-bool-conversion \
		-Wno-implicit-function-declaration \
		-Wno-pointer-sign \
		-Wno-implicit-const-int-float-conversion \
		-Wno-unused-value \
		-Wno-unused-but-set-variable"
	export LDFLAGS="-L/usr/lib -L/usr/local/lib"
	export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig"
	export CPPFLAGS="$CFLAGS"
	export LD_LIBRARY_PATH="${OPENSSL_PREFIX}/lib"

	echo "[ * ] Configuring PHP ${version}..."
	mapfile -t CONFIG_ARGS < <(get_config_args "$version")

	./configure "${CONFIG_ARGS[@]}" > "$LOG_DIR/configure-${version}.log" 2>&1
	if [ $? -ne 0 ]; then
		echo "❌ Configure failed"
		tail -50 "$LOG_DIR/configure-${version}.log"
		return 1
	fi

	echo "[ * ] Compiling PHP ${version} (using ${NUM_CPUS} cores)..."
	gmake -j "$NUM_CPUS" > "$LOG_DIR/build-${version}.log" 2>&1
	if [ $? -ne 0 ]; then
		echo "❌ Build failed, retrying single thread..."
		gmake -j 1 >> "$LOG_DIR/build-${version}.log" 2>&1
		if [ $? -ne 0 ]; then
			tail -100 "$LOG_DIR/build-${version}.log"
			return 1
		fi
	fi

	echo "[ * ] Installing PHP ${version}..."
	mkdir -p "$install_dir"
	gmake install INSTALL_ROOT="$install_dir" > "$LOG_DIR/install-${version}.log" 2>&1
	if [ $? -ne 0 ]; then
		echo "❌ Install failed"
		tail -50 "$LOG_DIR/install-${version}.log"
		return 1
	fi

	# Copy php.ini files to the correct location
	echo "[ * ] Copying php.ini files..."
	mkdir -p "$install_dir/usr/local/etc/php${ver_suffix}"
	cp php.ini-production "$install_dir/usr/local/etc/php${ver_suffix}/php.ini-production"
	cp php.ini-development "$install_dir/usr/local/etc/php${ver_suffix}/php.ini-development"

	local php_bin="$install_dir/usr/local/bin/php${ver_suffix}"
	if [ -f "$php_bin" ]; then
		echo "✅ PHP ${version} built successfully!"
		"$php_bin" -v
		return 0
	else
		echo "❌ PHP binary not found at: $php_bin"
		echo "=== Contents of bin directory ==="
		ls -la "$install_dir/usr/local/bin/" || echo "bin directory not found"
		return 1
	fi
}

package_php() {
	local version=$1
	local install_dir="$BUILD_DIR/php-${version}"
	local build_dir="$BUILD_DIR/php-src-${version}"
	local major=$(echo "$version" | cut -d. -f1)
	local minor=$(echo "$version" | cut -d. -f2)
	local ver_suffix="${major}${minor}"
	local php_bin="$install_dir/usr/local/bin/php${ver_suffix}"
	
	echo ""
	echo "========================================"
	echo "[ * ] Creating package for PHP ${version}..."
	echo "========================================"
	
	if [ ! -f "$php_bin" ]; then
		echo "❌ PHP binary not found at: $php_bin"
		return 1
	fi
	
	echo "[ * ] Verifying..."
	"$php_bin" -v || return 1
	"$php_bin" -m | grep -i openssl || echo "⚠️  OpenSSL extension not loaded"
	
	echo ""
	"$php_bin" -r '
		echo "PHP Version: " . PHP_VERSION;
		echo "OpenSSL Version: " . OPENSSL_VERSION_TEXT;
		echo "openssl_encrypt(): " . (function_exists("openssl_encrypt") ? "✅" : "❌");
		echo "openssl_decrypt(): " . (function_exists("openssl_decrypt") ? "✅" : "❌");
	'
	
	local pkg_name="php${ver_suffix}"

	rm -rf "${PKG_DIR}"
	mkdir -p "${PKG_DIR}"

	cp -r "${install_dir}/usr" "${PKG_DIR}/"
	LEXBOR_SRC=""
	if [ -d "$build_dir/ext/lexbor" ]; then
		# PHP 8.5+: ext/lexbor/
		LEXBOR_SRC="$build_dir/ext/lexbor"
	elif [ -d "$build_dir/ext/dom/lexbor" ]; then
		# PHP 8.4: ext/dom/lexbor/
		LEXBOR_SRC="$build_dir/ext/dom/lexbor"
	fi

	if [ -n "$LEXBOR_SRC" ] && [ -d "$LEXBOR_SRC/lexbor" ]; then
		mkdir -p "${PKG_DIR}/usr/local/include/php${ver_suffix}/ext/lexbor"
		cd "$LEXBOR_SRC/lexbor"
		find . -name "*.h" | while read -r file; do
			dir=$(dirname "$file")
			mkdir -p "${PKG_DIR}/usr/local/include/php${ver_suffix}/ext/lexbor/$dir"
			cp "$file" "${PKG_DIR}/usr/local/include/php${ver_suffix}/ext/lexbor/$file"
		done
		cd - > /dev/null
		echo "[ ✓ ] lexbor headers copied from $LEXBOR_SRC"
	fi
	
	# Fix include path: remove extra php/ subdirectory
	if [ -d "${PKG_DIR}/usr/local/include/php${ver_suffix}/php" ]; then
		echo "[ * ] Fixing include path: removing extra php/ subdirectory..."
		cp -r "${PKG_DIR}/usr/local/include/php${ver_suffix}/php"/* \
			"${PKG_DIR}/usr/local/include/php${ver_suffix}/"
		rm -rf "${PKG_DIR}/usr/local/include/php${ver_suffix}/php"
		echo "[ ✓ ] Include path fixed"
	fi
	
	# Fix status.html path
	if [ -f "${PKG_DIR}/usr/local/php/php/fpm/status.html" ]; then
		echo "[ * ] Fixing status.html path..."
		mkdir -p "${PKG_DIR}/usr/local/share/php${ver_suffix}/fpm/"
		mv "${PKG_DIR}/usr/local/php/php/fpm/status.html" \
		   "${PKG_DIR}/usr/local/share/php${ver_suffix}/fpm/status.html"
		ls -la "${PKG_DIR}/usr/local/share/php${ver_suffix}/fpm/"
		rm -rf "${PKG_DIR}/usr/local/php"
		echo "[ ✓ ] status.html path fixed"
	fi

	# Rename man pages (remove version suffix from filenames)
	echo "[ * ] Fixing man page names..."
	if [ -d "${PKG_DIR}/usr/local/share/php${ver_suffix}/man/man1" ]; then
		cd "${PKG_DIR}/usr/local/share/php${ver_suffix}/man/man1"
		
		if [ -f "php${ver_suffix}.1" ]; then
			mv "php${ver_suffix}.1" "php.1"
			echo "[ ✓ ] Renamed man page: php${ver_suffix}.1 → php.1"
		fi
		if [ -f "php-cgi${ver_suffix}.1" ]; then
			mv "php-cgi${ver_suffix}.1" "php-cgi.1"
			echo "[ ✓ ] Renamed man page: php-cgi${ver_suffix}.1 → php-cgi.1"
		fi
		if [ -f "php-config${ver_suffix}.1" ]; then
			mv "php-config${ver_suffix}.1" "php-config.1"
			echo "[ ✓ ] Renamed man page: php-config${ver_suffix}.1 → php-config.1"
		fi
		if [ -f "phpize${ver_suffix}.1" ]; then
			mv "phpize${ver_suffix}.1" "phpize.1"
			echo "[ ✓ ] Renamed man page: phpize${ver_suffix}.1 → phpize.1"
		fi
		if [ -f "phar${ver_suffix}.1" ]; then
			mv "phar${ver_suffix}.1" "phar.1"
			echo "[ ✓ ] Renamed man page: phar${ver_suffix}.1 → phar.1"
		fi
		if [ -f "phar${ver_suffix}.phar.1" ]; then
			mv "phar${ver_suffix}.phar.1" "phar.phar.1"
			echo "[ ✓ ] Renamed man page: phar${ver_suffix}.phar.1 → phar.phar.1"
		fi
		if [ -f "phpdbg${ver_suffix}.1" ]; then
			mv "phpdbg${ver_suffix}.1" "phpdbg.1"
			echo "[ ✓ ] Renamed man page: phpdbg${ver_suffix}.1 → phpdbg.1"
		fi
	fi
	
	if [ -d "${PKG_DIR}/usr/local/share/php${ver_suffix}/man/man8" ]; then
		cd "${PKG_DIR}/usr/local/share/php${ver_suffix}/man/man8"
		
		if [ -f "php-fpm${ver_suffix}.8" ]; then
			mv "php-fpm${ver_suffix}.8" "php-fpm.8"
			echo "[ ✓ ] Renamed man page: php-fpm${ver_suffix}.8 → php-fpm.8"
		fi
	fi
		
	# Create rc.d startup script
	echo "[ * ] Creating rc.d script..."
	mkdir -p "${PKG_DIR}/usr/local/etc/rc.d"
	cat > "${PKG_DIR}/usr/local/etc/rc.d/php${ver_suffix}-fpm" << EOF
#!/bin/sh
# PROVIDE: php${ver_suffix}-fpm
# REQUIRE: LOGIN
# KEYWORD: shutdown

. /etc/rc.subr

name="php${ver_suffix}-fpm"
rcvar="php${ver_suffix}_fpm_enable"

load_rc_config \$name

: \${php${ver_suffix}_fpm_enable:="NO"}

command="/usr/local/sbin/php${ver_suffix}-fpm"
pidfile="/var/run/php${ver_suffix}-fpm.pid"

run_rc_command "\$1"
EOF
	chmod +x "${PKG_DIR}/usr/local/etc/rc.d/php${ver_suffix}-fpm"
	echo "[ ✓ ] Created rc.d script: php${ver_suffix}-fpm"
	
	# Ensure directories exist
	mkdir -p "${PKG_DIR}/usr/local/bin"
	mkdir -p "${PKG_DIR}/usr/local/sbin"
	
	cd "${PKG_DIR}/usr/local/bin"
	if [ -f "php-cgi${ver_suffix}" ]; then
		mv "php-cgi${ver_suffix}" "php${ver_suffix}-cgi"
		echo "[ ✓ ] Renamed: php-cgi${ver_suffix} → php${ver_suffix}-cgi"
	fi
	if [ -f "php-config${ver_suffix}" ]; then
		mv "php-config${ver_suffix}" "php${ver_suffix}-config"
		echo "[ ✓ ] Renamed: php-config${ver_suffix} → php${ver_suffix}-config"
	fi
	if [ -f "phpize${ver_suffix}" ]; then
		mv "phpize${ver_suffix}" "php${ver_suffix}-phpize"
		echo "[ ✓ ] Renamed: phpize${ver_suffix} → php${ver_suffix}-phpize"
	fi
	if [ -f "phpdbg${ver_suffix}" ]; then
		mv "phpdbg${ver_suffix}" "php${ver_suffix}-phpdbg"
		echo "[ ✓ ] Renamed: phpdbg${ver_suffix} → php${ver_suffix}-phpdbg"
	fi
	
	cd "${PKG_DIR}/usr/local/sbin"
	if [ -f "php-fpm${ver_suffix}" ]; then
		mv "php-fpm${ver_suffix}" "php${ver_suffix}-fpm"
		echo "[ ✓ ] Renamed: php-fpm${ver_suffix} → php${ver_suffix}-fpm"
	fi
	
	cd "${PKG_DIR}"
	# 创建许可证目录
	mkdir -p "${PKG_DIR}/usr/local/share/licenses/${pkg_name}-${version}"

	# 创建 LICENSE 文件
	cat > "${PKG_DIR}/usr/local/share/licenses/${pkg_name}-${version}/LICENSE" << 'EOF'
This package has a single license: PHP301 (PHP License version 3.01).
EOF

	# 创建 PHP301 文件（完整许可证文本）
	cat > "${PKG_DIR}/usr/local/share/licenses/${pkg_name}-${version}/PHP301" << 'EOF'
-------------------------------------------------------------------- 
                  The PHP License, version 3.01
Copyright (c) 1999 - 2010 The PHP Group. All rights reserved.
-------------------------------------------------------------------- 

Redistribution and use in source and binary forms, with or without
modification, is permitted provided that the following conditions
are met:

  1. Redistributions of source code must retain the above copyright
     notice, this list of conditions and the following disclaimer.
 
  2. Redistributions in binary form must reproduce the above copyright
     notice, this list of conditions and the following disclaimer in
     the documentation and/or other materials provided with the
     distribution.
 
  3. The name "PHP" must not be used to endorse or promote products
     derived from this software without prior written permission. For
     written permission, please contact group@php.net.
  
  4. Products derived from this software may not be called "PHP", nor
     may "PHP" appear in their name, without prior written permission
     from group@php.net.  You may indicate that your software works in
     conjunction with PHP by saying "Foo for PHP" instead of calling
     it "PHP Foo" or "phpfoo"
 
  5. The PHP Group may publish revised and/or new versions of the
     license from time to time. Each version will be given a
     distinguishing version number.
     Once covered code has been published under a particular version
     of the license, you may always continue to use it under the terms
     of that version. You may also choose to use such covered code
     under the terms of any subsequent version of the license
     published by the PHP Group. No one other than the PHP Group has
     the right to modify the terms applicable to covered code created
     under this License.

  6. Redistributions of any form whatsoever must retain the following
     acknowledgment:
     "This product includes PHP software, freely available from
     <http://www.php.net/software/>".

THIS SOFTWARE IS PROVIDED BY THE PHP DEVELOPMENT TEAM ``AS IS'' AND 
ANY EXPRESSED OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A 
PARTICULAR PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE PHP
DEVELOPMENT TEAM OR ITS CONTRIBUTORS BE LIABLE FOR ANY DIRECT, 
INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES 
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR 
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED
OF THE POSSIBILITY OF SUCH DAMAGE.

-------------------------------------------------------------------- 

This software consists of voluntary contributions made by many
individuals on behalf of the PHP Group.

The PHP Group can be contacted via Email at group@php.net.

For more information on the PHP Group and the PHP project, 
please see <http://www.php.net>.

PHP includes the Zend Engine, freely available at
<http://www.zend.com>.
EOF

	# 创建 catalog.mk
	cat > "${PKG_DIR}/usr/local/share/licenses/${pkg_name}-${version}/catalog.mk" << EOF
_LICENSE=PHP301
_LICENSE_NAME=PHP License version 3.01
_LICENSE_PERMS=dist-mirror dist-sell pkg-mirror pkg-sell auto-accept
_LICENSE_GROUPS=FSF OSI
_LICENSE_DISTFILES=php-${version}.tar.xz
EOF
	find . -type f | sed 's|^\.||' > +PLIST
	
	cat > "+MANIFEST" << EOF
name: ${pkg_name}
version: ${version}
origin: local/php${ver_suffix}
comment: PHP ${version} with OpenSSL 3.x support
categories: [www, lang]
maintainer: hestiacn@tuta.io
www: https://github.com/hestiacn/hestiacp-freebsd
prefix: /usr/local
desc: <<EOD
PHP ${version} compiled with OpenSSL 3.x support.
Installs to standard /usr/local path.

Binaries:
  /usr/local/bin/php${ver_suffix}
  /usr/local/bin/php${ver_suffix}-cgi
  /usr/local/bin/php${ver_suffix}-config
  /usr/local/bin/php${ver_suffix}-phpize
  /usr/local/sbin/php${ver_suffix}-fpm

Startup script:
  /usr/local/etc/rc.d/php${ver_suffix}-fpm
EOD
EOF
	
	cat > "+POST_INSTALL" << EOF
#!/bin/sh
echo "========================================"
echo "PHP ${version} with OpenSSL 3.x installed"
echo "========================================"
echo ""
echo "PHP CLI:   /usr/local/bin/php${ver_suffix}"
echo "PHP-FPM:   /usr/local/sbin/php${ver_suffix}-fpm"
echo "php-cgi:   /usr/local/bin/php${ver_suffix}-cgi"
echo "php-config: /usr/local/bin/php${ver_suffix}-config"
echo ""
echo "To enable PHP-FPM:"
echo "   cp /usr/local/etc/php${ver_suffix}/php-fpm.conf.default /usr/local/etc/php${ver_suffix}/php-fpm.conf"
echo "   cp /usr/local/etc/php${ver_suffix}/php-fpm.d/www.conf.default /usr/local/etc/php${ver_suffix}/php-fpm.d/www.conf"
echo ""
echo "To start PHP-FPM at boot:"
echo "   sysrc php${ver_suffix}_fpm_enable=YES"
echo ""
echo "To start PHP-FPM now:"
echo "   service php${ver_suffix}-fpm start"
echo ""
echo "To check PHP version:"
echo "   /usr/local/bin/php${ver_suffix} -v"
echo ""
echo "========================================"
EOF
	chmod +x "+POST_INSTALL"
	
	pkg create -m "${PKG_DIR}" -p "${PKG_DIR}/+PLIST" -r "${PKG_DIR}" -o "${ARTIFACT_DIR}" 2>&1
	
	local pkg_file="${ARTIFACT_DIR}/${pkg_name}-${version}.pkg"
	if [ -f "${pkg_file}" ]; then
		echo "✅ Package: ${pkg_file} ($(du -h "${pkg_file}" | cut -f1))"
		return 0
	else
		echo "❌ Package creation failed"
		return 1
	fi
}

# ============================================================
# 主函数 - 只构建传入的单个版本
# ============================================================
main() {
	local version="$1"
	
	if [ -z "$version" ]; then
		echo "Usage: $0 <php-version>"
		echo "Example: $0 8.4.8"
		echo ""
		echo "Supported versions: 5.6.40, 7.0.33, 7.1.33, 7.2.34, 7.3.33, 7.4.33, 8.0.30, 8.1.34, 8.2.30, 8.3.30, 8.4.8"
		return 1
	fi

	echo ""
	echo "========================================"
	echo "Building PHP ${version} with OpenSSL 3.x"
	echo "========================================"
	echo "Start time: $(date)"
	echo ""

	if build_php "$version"; then
		if package_php "$version"; then
			echo ""
			echo "✅ ALL COMPLETED"
			exit 0
		else
			echo "❌ PACKAGE FAILED"
			exit 1
		fi
	else
		echo "❌ BUILD FAILED"
		echo "Log: $LOG_DIR/build-${version}.log"
		exit 1
	fi
}

main "$@"