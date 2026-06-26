#!/bin/bash
# src/build-php56-openssl4.sh
# Build PHP 5.6.40 with OpenSSL 4.x and ImageMagick and create package

set -e

# ============================================================
# 配置
# ============================================================
PHP_VERSION="5.6.40"
BUILD_DIR="/tmp/php-build-test"
PHP_SRC_DIR="$BUILD_DIR/php-src-${PHP_VERSION}" 
PHP_INSTALL_DIR="$BUILD_DIR/php-${PHP_VERSION}"
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
	fetch -o "$file" "https://www.php.net/distributions/php-${PHP_VERSION}.tar.gz"
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
	
	# 找到解压出来的目录并重命名
	local extracted=$(find "$1/ext" -maxdepth 1 -type d -name "imagick-*" | head -1)
	[ -z "$extracted" ] && { echo "❌ Extract failed"; return 1; }
	
	mv "$extracted" "$imagick_dir"
	rm -f "/tmp/imagick.tar.gz"
	
	echo "[ ✓ ] ImageMagick extension ready"
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
        "--enable-xsl"
        
        # 性能/工具
        "--enable-opcache"
        "--enable-intl"
        "--enable-soap"
        "--enable-posix"
        "--enable-tokenizer"
        "--enable-readline"
        "--enable-phar"
        
        # IPC/内存
        "--enable-shmop"
        "--enable-sysvmsg"
        "--enable-sysvsem"
        "--enable-sysvshm"
        "--enable-calendar"
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
        "--with-png-dir=/usr/local"
        "--with-jpeg-dir=/usr/local"
        "--with-freetype-dir=/usr/local"
        "--enable-zip"
        #"--with-webp-dir=/usr/local"

        "--with-ldap=/usr/local"
        "--with-imap=/usr/local"
        "--with-imap-ssl=/usr/local"
        "--with-pspell=/usr/local"
        "--with-libedit"
        "--with-ffi"
        
        
	)

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

	# 补丁1: libxml2 ATTRIBUTE_UNUSED
	if [ -f "ext/libxml/libxml.c" ]; then
		if grep -q "int compression ATTRIBUTE_UNUSED)" ext/libxml/libxml.c 2>/dev/null; then
			sed -i '' 's/int compression ATTRIBUTE_UNUSED)/int compression)/' ext/libxml/libxml.c
			echo "[ ✓ ] Patch 1: libxml.c ATTRIBUTE_UNUSED removed"
		fi
	fi

	# 补丁2: libxml2 xmlSetStructuredErrorFunc
	if [ -f "ext/libxml/libxml.c" ]; then
		if grep -q "xmlSetStructuredErrorFunc(NULL, php_libxml_structured_error_handler);" ext/libxml/libxml.c 2>/dev/null; then
			sed -i '' 's/xmlSetStructuredErrorFunc(NULL, php_libxml_structured_error_handler);/xmlSetStructuredErrorFunc(NULL, (xmlStructuredErrorFunc)php_libxml_structured_error_handler);/' ext/libxml/libxml.c
			echo "[ ✓ ] Patch 2: libxml.c xmlSetStructuredErrorFunc cast"
		fi
	fi

	# 补丁3: libxml2 xmlGetLastError
	if [ -f "ext/libxml/libxml.c" ]; then
		if grep -q "error = xmlGetLastError();" ext/libxml/libxml.c 2>/dev/null; then
			sed -i '' 's/error = xmlGetLastError();/error = (xmlErrorPtr)xmlGetLastError();/' ext/libxml/libxml.c
			echo "[ ✓ ] Patch 3: libxml.c xmlGetLastError cast"
		fi
	fi

	# 补丁4: 修复 zlib 函数指针类型不匹配
	if [ -f "ext/zlib/zlib.c" ]; then
		if grep -q "ZEND_MODULE_GLOBALS_CTOR_N(zlib)" ext/zlib/zlib.c 2>/dev/null; then
			sed -i '' 's/ZEND_MODULE_GLOBALS_CTOR_N(zlib),/NULL,/' ext/zlib/zlib.c
			echo "[ ✓ ] Patch 4: zlib.c globals_ctor set to NULL"
		fi
	fi

	# 补丁5: dom_iterators.c const fix
	if [ -f "ext/dom/dom_iterators.c" ]; then
		if grep -q "itemHashScanner (void \*payload, void \*data, xmlChar \*name)" ext/dom/dom_iterators.c 2>/dev/null; then
			sed -i '' 's/itemHashScanner (void \*payload, void \*data, xmlChar \*name)/itemHashScanner (void *payload, void *data, const xmlChar *name)/' ext/dom/dom_iterators.c
			echo "[ ✓ ] Patch 5: dom_iterators.c itemHashScanner const fix"
		fi
	fi

	# 1. 修复 TRUE/FALSE（必须）
	echo "[ * ] Fixing TRUE/FALSE in intl files..."
	for file in ext/intl/collator/collator_sort.c \
				ext/intl/collator/collator_convert.c \
				ext/intl/collator/collator_locale.c \
				ext/intl/collator/collator_error.c \
				ext/intl/common/common_error.c; do
		if [ -f "$file" ] && ! grep -q "#define TRUE" "$file"; then
			sed -i '' '/#ifdef HAVE_CONFIG_H/,/#endif/ {
				/#endif/ a\
\
#ifndef TRUE\
#define TRUE 1\
#endif\
#ifndef FALSE\
#define FALSE 0\
#endif
			}' "$file"
			echo "[ ✓ ] Added TRUE/FALSE defines to $(basename "$file")"
		fi
	done

	# 2. 修复 UnicodeString 命名空间（必须）
	if [ -f "ext/intl/intl_convertcpp.h" ] && ! grep -q "using namespace icu;" ext/intl/intl_convertcpp.h; then
		sed -i '' '/#include <unicode\/unistr.h>/a\
\
using namespace icu;
	' ext/intl/intl_convertcpp.h
		echo "[ ✓ ] Added 'using namespace icu;' to intl_convertcpp.h"
	fi
	# 更新版权年份
    if [ -f "./main/main.c" ] && [ -f "./Zend/zend.c" ]; then
        echo "[ * ] Updating copyright year to 2019..."
        find ./main ./Zend ./ext ./sapi ./TSRM -type f \( -name "*.c" -o -name "*.h" \) 2>/dev/null \
            -exec sed -i '' 's/| Copyright (c) [0-9]\{4\}-[0-9]\{4\} The PHP Group.*/| Copyright (c) 1997-2019 The PHP Group                                |/' {} \;
        find ./main ./Zend ./ext ./sapi ./TSRM -type f \( -name "*.c" -o -name "*.h" \) 2>/dev/null \
            -exec sed -i '' 's/| Copyright (c) The PHP Group.*/| Copyright (c) 1997-2019 The PHP Group                                |/' {} \;
        find ./main ./Zend ./ext ./sapi ./TSRM -type f \( -name "*.c" -o -name "*.h" \) 2>/dev/null \
            -exec sed -i '' 's/| Copyright (c) [0-9]\{4\}-[0-9]\{4\} Zend Technologies.*/| Copyright (c) 1998-2019 Zend Technologies Ltd. (http:\/\/www.zend.com) |/' {} \;
        find ./main ./Zend ./ext ./sapi ./TSRM -type f \( -name "*.c" -o -name "*.h" \) 2>/dev/null \
            -exec sed -i '' 's/| Copyright (c) Zend Technologies.*/| Copyright (c) 1998-2019 Zend Technologies Ltd. (http:\/\/www.zend.com) |/' {} \;
        for file in sapi/cli/php_cli.c sapi/fpm/fpm/fpm_main.c sapi/cgi/cgi_main.c sapi/litespeed/lsapi_main.c sapi/phpdbg/phpdbg.c; do
        if [ -f "$file" ]; then
            sed -i '' 's/Copyright (c) [0-9]\{4\}-[0-9]\{4\} The PHP Group/Copyright (c) 1997-2019 The PHP Group/g' "$file"
            sed -i '' 's/Copyright (c) The PHP Group/Copyright (c) 1997-2019 The PHP Group/g' "$file"
        fi
        done
        sed -i '' 's/#define ZEND_CORE_VERSION_INFO.*"Zend Engine v" ZEND_VERSION ", Copyright (c) [0-9]\{4\}-[0-9]\{4\} Zend Technologies\\n".*/#define ZEND_CORE_VERSION_INFO\t"Zend Engine v" ZEND_VERSION ", Copyright (c) 1998-2019 Zend Technologies\\n"/' ./Zend/zend.c
        sed -i '' 's/#define ZEND_CORE_VERSION_INFO.*"Zend Engine v" ZEND_VERSION ", Copyright (c) Zend Technologies\\n".*/#define ZEND_CORE_VERSION_INFO\t"Zend Engine v" ZEND_VERSION ", Copyright (c) 1998-2019 Zend Technologies\\n"/' ./Zend/zend.c
        echo "[ ✓ ] Copyright updated to 2019"
        grep "Copyright" ./main/main.c 2>/dev/null || true
        grep "Copyright" ./Zend/zend.c 2>/dev/null || true
    fi

	# ============================================================
	# 使用预修改的 OpenSSL 源文件
	# ============================================================
	local custom_openssl_dir="$SCRIPT_DIR/php5.6"
	if [ -d "$custom_openssl_dir" ]; then
		echo "[ * ] Using pre-modified OpenSSL source files..."
		
		if [ -f "$custom_openssl_dir/openssl.c" ]; then
			cp "$custom_openssl_dir/openssl.c" "ext/openssl/openssl.c"
			echo "[ ✓ ] Replaced ext/openssl/openssl.c"
		else
			echo "⚠️  openssl.c not found in $custom_openssl_dir"
		fi
		
		if [ -f "$custom_openssl_dir/xp_ssl.c" ]; then
			cp "$custom_openssl_dir/xp_ssl.c" "ext/openssl/xp_ssl.c"
			echo "[ ✓ ] Replaced ext/openssl/xp_ssl.c"
		else
			echo "⚠️  xp_ssl.c not found in $custom_openssl_dir"
		fi
		
		echo "[ ✓ ] OpenSSL source files replaced"
	else
		echo "⚠️  Custom OpenSSL directory not found: $custom_openssl_dir"
        echo "    Skipping OpenSSL source replacement"
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

	# ============================================================
	# 下载 ImageMagick 扩展到
	# ============================================================
	if ! download_imagick "$build_dir"; then
		echo "⚠️  ImageMagick extension download failed, continuing without it"
	fi

	cd "$build_dir" || return 1

	[ -f "Makefile" ] && gmake clean || true

	apply_patches "$build_dir"

	# 设置 OpenSSL 4.x 环境变量
	export CFLAGS="-I/usr/local/include -I/usr/local/include \
		-Wno-deprecated-declarations \
		-Wno-incompatible-pointer-types-discards-qualifiers \
		-Wno-pointer-bool-conversion \
		-Wno-implicit-function-declaration \
		-Wno-pointer-sign \
		-Wno-implicit-const-int-float-conversion"
	export CFLAGS="$CFLAGS"
	export LDFLAGS="-L/usr/local/lib -L/usr/local/lib"
	export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:/usr/local/lib/pkgconfig"
	export CPPFLAGS="$CFLAGS"
	export LD_LIBRARY_PATH="${OPENSSL_PREFIX:-/usr/local}/lib"
	export LDFLAGS="-L/usr/local/lib -Wl,-rpath,/usr/local/lib -Wl,-zmuldefs"

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

	# ============================================================
	# 编译 ImageMagick 扩展（在 PHP 安装完成后）
	# ============================================================
    if [ -d "$build_dir/ext/imagick" ]; then
        echo "[ * ] Building ImageMagick extension..."
        
        local php_prefix="$install_dir/usr/local"
        local php_config="$php_prefix/bin/php-config"
        local phpize="$php_prefix/bin/phpize"
        
        if [ ! -f "$phpize" ] || [ ! -f "$php_config" ]; then
            echo "⚠️  phpize or php-config not found, skipping ImageMagick"
        else
            cd "$build_dir/ext/imagick"
            export PHP_PREFIX="$php_prefix"
            export PHP_CONFIG="$php_config"
            export PHPIZE="$phpize"
            ln -sf "$php_prefix/lib/php/build" /usr/local/lib/php/build
            # 修复头文件路径：将安装目录的 PHP 头文件链接到系统路径
            if [ -d "$php_prefix/include/php" ] && [ ! -d "/usr/local/include/php" ]; then
                echo "[ * ] Linking PHP headers to /usr/local/include/php..."
                # 创建父目录
                mkdir -p /usr/local/include
                # 创建软链接
                ln -sf "$php_prefix/include/php" /usr/local/include/php
            fi
            
            # 如果已经是软链接但指向错误，重新创建
            if [ -L "/usr/local/include/php" ] && [ ! -d "/usr/local/include/php/main" ]; then
                rm -f /usr/local/include/php
                ln -sf "$php_prefix/include/php" /usr/local/include/php
            fi
            
            # 创建 php -> . 的软链接（解决 /usr/local/include/php/php/ 路径问题）
            if [ -d "/usr/local/include/php" ] && [ ! -L "/usr/local/include/php/php" ]; then
                echo "[ * ] Creating php -> . symlink..."
                cd /usr/local/include/php
                ln -sf . php
                cd - > /dev/null
            fi
            
            echo "[ * ] Running phpize..."
            "$phpize"
            
            echo "[ * ] Configuring ImageMagick extension..."
            ./configure --with-php-config="$php_config" --with-imagick=/usr/local
            
            echo "[ * ] Compiling ImageMagick extension..."
            make
            
            echo "[ * ] Installing ImageMagick extension..."
            make install INSTALL_ROOT="$install_dir"
            
            # 创建 php.ini 启用 imagick
            local php_ini_dir="$install_dir/usr/local/etc"
            mkdir -p "$php_ini_dir"

            echo "extension=imagick.so" >> "$php_ini_dir/php.ini"
            echo "[ ✓ ] ImageMagick extension installed"
        fi
    fi

    # 检查 PHP 二进制文件（标准路径）
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
		echo "❌ PHP binary not found at $php_bin!"
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

	# 验证 ImageMagick 扩展并运行测试
	echo "[ * ] Verifying ImageMagick extension and running tests..."
	PHP_SRC_DIR="$BUILD_DIR/php-src-${PHP_VERSION}"
	ZEND_API_NO=$(grep "^#define ZEND_MODULE_API_NO" "$PHP_SRC_DIR/Zend/zend_modules.h" | awk '{print $3}')
	EXTENSION_DIR="$install_dir/usr/local/lib/php/extensions/no-debug-non-zts-${ZEND_API_NO}"

	if [ -f "$EXTENSION_DIR/imagick.so" ]; then
		echo "✅ ImageMagick extension found"
		
		# 运行完整测试
		"$php_bin" -d extension_dir="$EXTENSION_DIR" -d extension=imagick.so -r '
			$imagick_loaded = extension_loaded("imagick");
			echo "PHP Version: " . PHP_VERSION . "\n";
			echo "OpenSSL Version: " . OPENSSL_VERSION_TEXT . "\n";
			echo "OpenSSL functions: " . (function_exists("openssl_encrypt") ? "✅" : "❌") . "\n";
			echo "ImageMagick extension: " . ($imagick_loaded ? "✅" : "❌") . "\n";
			if ($imagick_loaded) {
				$formats = Imagick::queryFormats("*");
				echo "ImageMagick supports " . count($formats) . " formats\n";
			}
		'
	else
		echo "⚠️  ImageMagick extension file not found at: $EXTENSION_DIR/imagick.so"
	fi

    # 创建包目录结构
	PKG_NAME="php${ver_suffix}-openssl4"
	
	rm -rf "${PKG_DIR}"
	mkdir -p "${PKG_DIR}/usr/local"
	mkdir -p "${ARTIFACT_DIR}"
	
	echo "[ * ] Copying PHP files to ${PKG_DIR}..."
	cp -r "${install_dir}/usr/local/"* "${PKG_DIR}/usr/local/"
	
	if [ ! -f "${PKG_DIR}/usr/local/bin/php" ]; then
		echo "❌ PHP binary not found after copy!"
		echo "  Expected: ${PKG_DIR}/usr/local/bin/php"
		echo "  Files in PKG_DIR:"
		find "${PKG_DIR}" -type f | head -10
		return 1
	fi
	
	echo "[ ✓ ] Files copied successfully"
	
	# 创建 PLIST（列出所有文件）
    echo "[ ✓ ] Files copied successfully"
	echo "[ * ] Creating file list..."
	cd "${PKG_DIR}"
	find . -type f | sed 's|^\.||' > +PLIST
	
	echo "[ * ] Creating package metadata..."
	cat > "+MANIFEST" << EOF
name: ${PKG_NAME}
version: ${PHP_VERSION}
origin: local/php${ver_suffix}-openssl4
comment: PHP ${PHP_VERSION} with OpenSSL 4.x and ImageMagick support
categories: [www, lang]
maintainer: build@hestiacp.com
www: https://github.com/hestiacp/hestiacp-freebsd
prefix: /usr/local
desc: <<EOD
PHP ${PHP_VERSION} compiled with OpenSSL 4.x support.

This is a custom build of PHP 5.6.40 that includes:
- OpenSSL 4.x compatibility patches
- ImageMagick extension (imagick)
- FPM, CLI, CGI support
- Common extensions: mbstring, bcmath, curl, gmp, mysqli, pdo_mysql, pgsql, pdo_pgsql, etc.
- GD with JPEG, PNG, FreeType support

IMPORTANT: PHP 5.6 is end-of-life. Use at your own risk.
EOD
EOF
	
	cat > "+POST_INSTALL" << EOF
#!/bin/sh
echo "========================================"
echo "PHP ${PHP_VERSION} with OpenSSL 4.x installed"
echo "========================================"
echo "Location: /usr/local"
echo "Binary:   /usr/local/bin/php${ver_suffix}"
echo ""
echo "To add to PATH:"
echo "  export PATH=/usr/local/bin:\$PATH"
echo ""
echo "Verify ImageMagick:"
/usr/local/bin/php${ver_suffix} -m | grep imagick || echo "imagick not loaded"
echo "========================================"
EOF
	chmod +x "+POST_INSTALL"
	
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
		# 打印完整包文件清单
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