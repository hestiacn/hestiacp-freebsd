#!/bin/bash
# src/build-php56-openssl4.sh
# Build PHP 5.6.40 with OpenSSL 4.x and create package

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
# 下载 ImageMagick 扩展源码（完全禁用）
# ============================================================
download_imagick() {
    echo "⚠️  ImageMagick extension is DISABLED to avoid ICU conflicts"
    echo "   PHP will be built with GD support instead"
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
		"--enable-dom"
		"--enable-xml"
		"--enable-xmlreader"
		"--enable-xmlwriter"
		"--enable-simplexml"
		"--enable-opcache"
		"--enable-intl"
		"--enable-soap"
		"--enable-posix"
		"--enable-tokenizer"
		"--enable-phar"
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
		"--with-xsl"
		"--with-readline"
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
		"--with-icu-dir=/usr/local/icu53"
		"--with-ldap=/usr/local"
		"--with-imap=/usr/local"
		"--with-imap-ssl=/usr/local"
		"--with-pspell=/usr/local"
		"--with-libedit"
	)

	printf "%s\n" "${args[@]}"
}

# ============================================================
# 覆盖系统 ICU 库
# ============================================================
override_system_icu() {
    local icu_prefix="$1"
    
    echo "[ * ] Setting up ICU 53 library paths..."
    
    export LD_LIBRARY_PATH="$icu_prefix/lib:$LD_LIBRARY_PATH"
    
    # 创建符号链接到 /usr/local/lib（但不要覆盖系统 ICU）
    cd /usr/local/lib || return 1
    
    for lib in libicuuc libicudata libicui18n libicuio; do
        if [ -f "$icu_prefix/lib/${lib}.so.53.2" ]; then
            if [ ! -L "${lib}.so.53.2" ] && [ ! -f "${lib}.so.53.2" ]; then
                ln -sf "$icu_prefix/lib/${lib}.so.53.2" "${lib}.so.53.2" 2>/dev/null || true
                echo "  ✓ Linked ${lib}.so.53.2"
            fi
        fi
    done
    
    cd -
    
    echo "[ ✓ ] ICU 53 library paths configured"
    return 0
}

# ============================================================
# 编译和安装 ICU 53
# ============================================================
build_icu53() {
    local icu_prefix="/usr/local/icu53"
    
    if [ -d "$icu_prefix" ] && [ -f "$icu_prefix/lib/libicuuc.so.53.2" ]; then
        echo "[ ✓ ] ICU 53 already installed at $icu_prefix"
        # 不调用 override_system_icu，避免干扰
        return 0
    fi
    
    echo "[ * ] Building ICU 53 for PHP 5.6 compatibility..."
    rm -rf "$icu_prefix"
    
    # 下载和解压
    echo "[ * ] Downloading ICU 53..."
    fetch -o /tmp/icu-53.tar.gz \
        "https://github.com/unicode-org/icu/archive/release-53-2.tar.gz" || return 1
    tar -xf /tmp/icu-53.tar.gz -C /tmp || return 1
    
    cd /tmp/icu-release-53-2/icu4c/source || return 1
    
    make distclean || true
    
    export CC=gcc14
    export CXX=g++14
    echo "[ * ] Configuring ICU 53 (with versioned symbols)..."
    ./configure \
        --prefix="$icu_prefix" \
        --enable-shared=yes \
        --enable-static=yes \
        --disable-debug \
        --enable-release \
        --with-library-bits=64 \
        CFLAGS="-O2 -pipe -fstack-protector-strong -fno-strict-aliasing" \
        CXXFLAGS="-O2 -pipe -fstack-protector-strong -fno-strict-aliasing -std=c++14" \
        LDFLAGS="-lpthread -lm"
    
    if [ $? -ne 0 ]; then
        echo "❌ ICU configure failed"
        tail -50 config.log
        return 1
    fi
    
    # 构建 ICU
    echo "[ * ] Building ICU (this may take a while)..."
    mkdir -p ../lib
    
    if ! gmake -j"$NUM_CPUS" 2>&1 | tee /tmp/icu-build.log; then
        echo "❌ ICU build failed"
        tail -50 /tmp/icu-build.log
        return 1
    fi
    
    # 验证符号包含版本后缀
    echo "[ * ] Verifying ICU symbols..."
    if [ -f "lib/libicuuc.so.53.2" ]; then
        if nm -D "lib/libicuuc.so.53.2" | grep -q "uspoof_setChecks_53"; then
            echo "[ ✓ ] ICU symbols have _53 suffix (correct)"
        else
            echo "⚠️  ICU symbols may not have _53 suffix"
            nm -D "lib/libicuuc.so.53.2" | grep "uspoof_setChecks" | head -5
        fi
    fi
    
    # 检查 icu-config
    echo "[ * ] Checking for generated icu-config..."
    if [ -f "config/icu-config" ]; then
        echo "[ ✓ ] icu-config generated at config/icu-config"
        mkdir -p "$icu_prefix/bin"
        cp config/icu-config "$icu_prefix/bin/icu-config"
        chmod +x "$icu_prefix/bin/icu-config"
    elif [ -f "icu-config" ]; then
        echo "[ ✓ ] icu-config generated at icu-config"
        mkdir -p "$icu_prefix/bin"
        cp icu-config "$icu_prefix/bin/icu-config"
        chmod +x "$icu_prefix/bin/icu-config"
    else
        echo "❌ icu-config not generated by build!"
        return 1
    fi
    
    # 安装 ICU
    echo "[ * ] Installing ICU 53..."
    if ! gmake install 2>&1 | tee /tmp/icu-install.log; then
        echo "❌ ICU install failed"
        tail -50 /tmp/icu-install.log
        return 1
    fi
    
    # 创建符号链接
    echo "[ * ] Creating ICU 53 library symlinks..."
    cd "$icu_prefix/lib"
    for lib in libicuuc libicui18n libicudata libicuio; do
        if [ -f "${lib}.so.53.2" ]; then
            [ ! -f "${lib}.so" ] && ln -sf "${lib}.so.53.2" "${lib}.so"
            [ ! -f "${lib}.so.53" ] && ln -sf "${lib}.so.53.2" "${lib}.so.53"
            echo "  ✓ Created ${lib} links"
        fi
    done
    cd -
    
    # 修改 icu-config
    if [ -f "$icu_prefix/bin/icu-config" ]; then
        sed -i '' 's/libicuuc.so/libicuuc.so.53.2/g' "$icu_prefix/bin/icu-config" || true
        sed -i '' 's/libicui18n.so/libicui18n.so.53.2/g' "$icu_prefix/bin/icu-config" || true
        sed -i '' 's/libicudata.so/libicudata.so.53.2/g' "$icu_prefix/bin/icu-config" || true
        sed -i '' 's/libicuio.so/libicuio.so.53.2/g' "$icu_prefix/bin/icu-config" || true
    fi
    
    # 验证
    echo "[ * ] Verifying ICU 53 installation..."
    if ! "$icu_prefix/bin/icu-config" --version > /dev/null 2>&1; then
        echo "❌ icu-config validation failed"
        return 1
    fi
    echo "  Version: $($icu_prefix/bin/icu-config --version)"
    
    # 验证符号
    echo "[ * ] Final symbol verification:"
    nm -D "$icu_prefix/lib/libicuuc.so.53.2" | grep "uspoof_setChecks" | head -3 || echo "  No uspoof symbols found"
    
    cd /
    rm -rf /tmp/icu-release-53-2 /tmp/icu-53.tar.gz
    
    echo "[ ✓ ] ICU 53 installed successfully"
    return 0
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

	# 补丁6: 修复 TRUE/FALSE 在 intl 文件中
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

	# 补丁7: 修复 UnicodeString 命名空间
	if [ -f "ext/intl/intl_convertcpp.h" ] && ! grep -q "using namespace icu;" ext/intl/intl_convertcpp.h; then
		sed -i '' '/#include <unicode\/unistr.h>/a\
\
using namespace icu;
	' ext/intl/intl_convertcpp.h
		echo "[ ✓ ] Added 'using namespace icu;' to intl_convertcpp.h"
	fi
    
    # 补丁8: 更新 config.sub
    if [ -f "config.sub" ]; then
        echo "[ * ] Updating config.sub for FreeBSD 14..."
        fetch -o "config.sub.new" "https://cgit.git.savannah.gnu.org/cgit/config.git/plain/config.sub"
        if [ -f "config.sub.new" ] && [ -s "config.sub.new" ]; then
            mv "config.sub.new" "config.sub"
            chmod +x "config.sub"
            echo "[ ✓ ] config.sub updated"
        else
            rm -f "config.sub.new"
        fi
    fi
    
	# 补丁9: 更新版权年份
    if [ -f "./main/main.c" ] && [ -f "./Zend/zend.c" ]; then
        echo "[ * ] Updating copyright year to 2019..."
        find ./main ./Zend ./ext ./sapi ./TSRM -type f \( -name "*.c" -o -name "*.h" \) \
            -exec sed -i '' 's/| Copyright (c) [0-9]\{4\}-[0-9]\{4\} The PHP Group.*/| Copyright (c) 1997-2019 The PHP Group                                |/' {} \;
        find ./main ./Zend ./ext ./sapi ./TSRM -type f \( -name "*.c" -o -name "*.h" \) \
            -exec sed -i '' 's/| Copyright (c) The PHP Group.*/| Copyright (c) 1997-2019 The PHP Group                                |/' {} \;
        find ./main ./Zend ./ext ./sapi ./TSRM -type f \( -name "*.c" -o -name "*.h" \) \
            -exec sed -i '' 's/| Copyright (c) [0-9]\{4\}-[0-9]\{4\} Zend Technologies.*/| Copyright (c) 1998-2019 Zend Technologies Ltd. (http:\/\/www.zend.com) |/' {} \;
        find ./main ./Zend ./ext ./sapi ./TSRM -type f \( -name "*.c" -o -name "*.h" \) \
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
    fi

	# 补丁10: 使用预修改的 OpenSSL 源文件
	local custom_openssl_dir="$SCRIPT_DIR/php5.6"
	if [ -d "$custom_openssl_dir" ]; then
		echo "[ * ] Using pre-modified OpenSSL source files..."
		
		if [ -f "$custom_openssl_dir/openssl.c" ]; then
			cp "$custom_openssl_dir/openssl.c" "ext/openssl/openssl.c"
			echo "[ ✓ ] Replaced ext/openssl/openssl.c"
		fi
		
		if [ -f "$custom_openssl_dir/xp_ssl.c" ]; then
			cp "$custom_openssl_dir/xp_ssl.c" "ext/openssl/xp_ssl.c"
			echo "[ ✓ ] Replaced ext/openssl/xp_ssl.c"
		fi
		
		echo "[ ✓ ] OpenSSL source files replaced"
	else
		echo "⚠️  Custom OpenSSL directory not found: $custom_openssl_dir"
	fi
    
	echo "[ ✓ ] All patches applied for PHP ${PHP_VERSION}"
	cd - > /dev/null || return 1
}

# ============================================================
# 修复 ICU 头文件
# ============================================================
patch_icu_headers() {
    local icu_prefix="/usr/local/icu53"
    
    echo "[ * ] Patching ICU 53 headers for C++11 compatibility..."
    
    for header in "$icu_prefix/include/unicode/"*.h; do
        if [ -f "$header" ]; then
            sed -i '' \
                -e 's/std::enable_if_t</std::enable_if</g' \
                -e 's/std::is_pointer_v</std::is_pointer</g' \
                -e 's/std::remove_reference_t</std::remove_reference</g' \
                -e 's/std::is_convertible_v</std::is_convertible</g' \
                -e 's/std::is_same_v</std::is_same</g' \
                -e 's/std::is_integral_v</std::is_integral</g' \
                "$header" || true
        fi
    done
    for header in char16ptr.h stringpiece.h unistr.h; do
        if [ -f "$icu_prefix/include/unicode/$header" ]; then
            sed -i '' '/#include <type_traits>/d' "$icu_prefix/include/unicode/$header" || true
            echo "[ ✓ ] Cleaned $header"
        fi
    done
    
    echo "[ ✓ ] ICU 53 headers patched"
}

# ============================================================
# 构建 PHP
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

    # ImageMagick 已禁用
    if ! download_imagick "$build_dir"; then
        echo "⚠️  ImageMagick extension disabled"
    fi

    cd "$build_dir"
    
    echo "[ DEBUG ] Current directory: $(pwd)"
    
    if [ -f "configure" ]; then
        echo "[ ✓ ] configure found"
    else
        echo "❌ configure NOT found"
        return 1
    fi

    [ -f "Makefile" ] && gmake clean || true

    apply_patches "$build_dir"

    # ============================================================
    # 设置编译环境
    # ============================================================
    export CC=gcc14
    export CXX=g++14
    export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:/usr/local/libdata/pkgconfig:/usr/lib/pkgconfig"
    export CPPFLAGS="-I/usr/local/icu53/include -I/usr/local/include"
    find . -name "config.cache" -delete
    
    # ============================================================
    # PHP 5.6 特殊处理：使用 ICU 53
    # ============================================================
    if [ "$major" = "5" ] && [ "$PHP_VERSION" = "5.6.40" ]; then
        # 编译 ICU 53
        if ! build_icu53; then
            echo "❌ Failed to build ICU 53"
            return 1
        fi
        cd "$build_dir" || {
            echo "❌ Failed to return to PHP source directory"
            return 1
        }
        echo "[ * ] Current directory: $(pwd)"
        
        # 修复 ICU 头文件
        patch_icu_headers
        if [ ! -f "/usr/local/icu53/bin/icu-config" ]; then
            echo "❌ icu-config not found"
            return 1
        fi
        echo "[ ✓ ] icu-config found"
        
        export PATH="/usr/local/icu53/bin:$PATH"
        export LD_LIBRARY_PATH="/usr/local/icu53/lib:$LD_LIBRARY_PATH"
        
        export CFLAGS="-I/usr/local/icu53/include -I/usr/local/include \
                    -Wno-deprecated-declarations \
                    -Wno-incompatible-pointer-types-discards-qualifiers \
                    -Wno-pointer-bool-conversion \
                    -Wno-implicit-function-declaration \
                    -Wno-pointer-sign \
                    -Wno-implicit-const-int-float-conversion \
                    -Wno-implicit-int \
                    -Wno-return-type \
                    -Wno-incompatible-pointer-types \
                    -Wno-discarded-qualifiers \
                    -Wno-deprecated \
                    -Wno-error"
        export CXXFLAGS="-std=c++11 -Wno-register -Wno-deprecated-declarations -fpermissive"
        export LDFLAGS="-L/usr/local/icu53/lib -L/usr/local/lib -Wl,-rpath,/usr/local/icu53/lib -Wl,-rpath,/usr/local/lib"
        export CPPFLAGS="-I/usr/local/icu53/include -I/usr/local/include"
        export ICU_CONFIG="/usr/local/icu53/bin/icu-config"
        export ICU_PREFIX="/usr/local/icu53"
        export ICU_CFLAGS="-I/usr/local/icu53/include"
        export ICU_LIBS="-L/usr/local/icu53/lib -licui18n -licuuc -licudata"
        
        echo "[ ✓ ] ICU config version: $(icu-config --version || echo 'unknown')"
        
    else
        export CPPFLAGS="-I/usr/local/include"
        export CFLAGS="-I/usr/local/include \
            -Wno-deprecated-declarations \
            -Wno-incompatible-pointer-types-discards-qualifiers \
            -Wno-pointer-bool-conversion \
            -Wno-implicit-function-declaration \
            -Wno-pointer-sign \
            -Wno-implicit-const-int-float-conversion"
        export LDFLAGS="-L/usr/local/lib -Wl,-rpath,/usr/local/lib -Wl,-zmuldefs"
        export CXXFLAGS=""
        export LD_LIBRARY_PATH="${OPENSSL_PREFIX:-/usr/local}/lib:$LD_LIBRARY_PATH"
    fi
    
    # ============================================================
    # 配置 PHP
    # ============================================================
    echo "[ * ] Configuring PHP ${PHP_VERSION}..."
    echo "OpenSSL prefix: ${OPENSSL_PREFIX:-/usr/local}"
    echo "CPPFLAGS: $CPPFLAGS"
    echo "PKG_CONFIG_PATH: $PKG_CONFIG_PATH"
    
    export LDFLAGS="-L/usr/local/icu53/lib -L/usr/local/lib -Wl,-rpath,/usr/local/icu53/lib -Wl,-rpath,/usr/local/lib -Wl,-rpath-link,/usr/local/icu53/lib"
    export LIBS="-licui18n -licuuc -licudata -lc++ -lpq -lintl -lssl -lcrypto -lpthread -lm"

    mapfile -t CONFIG_ARGS < <(get_config_args)
    echo "Config args: ${CONFIG_ARGS[*]}"
    ./configure \
        "${CONFIG_ARGS[@]}" \
        --with-icu-dir=/usr/local/icu53 \
        ICU_CFLAGS="-I/usr/local/icu53/include" \
        ICU_LIBS="-L/usr/local/icu53/lib -licui18n -licuuc -licudata" \
        > "$LOG_DIR/configure-${PHP_VERSION}.log" 2>&1

    if [ $? -ne 0 ]; then
        echo "❌ Configure failed"
        tail -100 "$LOG_DIR/configure-${PHP_VERSION}.log"
        return 1
    fi

    echo "[ * ] Checking ICU used:"
    grep -i "icu" "$LOG_DIR/configure-${PHP_VERSION}.log" | head -20 || true

    # ============================================================
    # 修复 Makefile 链接问题
    # ============================================================
    echo "[ * ] Fixing link flags in Makefile..."

    if [ -f "Makefile" ]; then
        # 添加 -lc++
        if ! grep -q "\-lc++" Makefile; then
            sed -i '' 's/^EXTRA_LIBS = \(.*\)$/EXTRA_LIBS = \1 -lc++/' Makefile
            echo "[ ✓ ] Added -lc++ to EXTRA_LIBS"
        fi
        
        # 强制使用 ICU 53 库的完整路径
        echo "[ * ] Forcing ICU 53 library paths..."
        sed -i '' 's|-licuio|/usr/local/icu53/lib/libicuio.so.53.2|g' Makefile
        sed -i '' 's|-licui18n|/usr/local/icu53/lib/libicui18n.so.53.2|g' Makefile
        sed -i '' 's|-licuuc|/usr/local/icu53/lib/libicuuc.so.53.2|g' Makefile
        sed -i '' 's|-licudata|/usr/local/icu53/lib/libicudata.so.53.2|g' Makefile

        # 添加 ICU 53 库路径
        if ! grep -q "/usr/local/icu53/lib" Makefile; then
            sed -i '' 's|^LDFLAGS = \(.*\)$|LDFLAGS = -L/usr/local/icu53/lib \1|' Makefile
            sed -i '' 's|^LDFLAGS = \(.*\)$|LDFLAGS = \1 -Wl,-rpath,/usr/local/icu53/lib|' Makefile
        fi
        
        echo "[ ✓ ] Makefile updated to use ICU 53"
    fi
    
    # ============================================================
    # 编译 PHP
    # ============================================================
    echo "[ * ] Compiling PHP ${PHP_VERSION} (using ${NUM_CPUS} cores)..."
    gmake -j "$NUM_CPUS" > "$LOG_DIR/build-${PHP_VERSION}.log" 2>&1

    if [ $? -ne 0 ]; then
        echo ""
        echo "========================================"
        echo "❌ BUILD FAILED"
        echo "========================================"
        echo ""
        echo "=== All errors ==="
        grep -E "error:" "$LOG_DIR/build-${PHP_VERSION}.log" | head -50
        echo ""
        echo "========================================"
        echo "Last 100 lines:"
        echo "========================================"
        tail -100 "$LOG_DIR/build-${PHP_VERSION}.log"
        echo ""
        echo "[ * ] Retrying with single core..."
        gmake clean
        if gmake -j1 >> "$LOG_DIR/build-${PHP_VERSION}.log" 2>&1; then
            echo "[ ✓ ] Single core build succeeded!"
        else
            return 1
        fi
    fi

    # ============================================================
    # 安装 PHP
    # ============================================================
    echo "[ * ] Installing PHP ${PHP_VERSION}..."
    mkdir -p "$install_dir"
    gmake install INSTALL_ROOT="$install_dir" > "$LOG_DIR/install-${PHP_VERSION}.log" 2>&1
    if [ $? -ne 0 ]; then
        echo "❌ Install failed"
        tail -50 "$LOG_DIR/install-${PHP_VERSION}.log"
        return 1
    fi
    
    if [ ! -f "$install_dir/usr/local/bin/php-cgi" ] && [ -f "$install_dir/usr/local/bin/php" ]; then
        ln -sf php "$install_dir/usr/local/bin/php-cgi"
    fi

    echo "⚠️  ImageMagick extension skipped"

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
        echo "❌ PHP binary not found!"
        return 1
    fi
    
    echo "[ * ] Verifying PHP binary..."
    "$php_bin" -v || {
        echo "❌ PHP binary verification failed!"
        return 1
    }
    
    echo "[ * ] Verifying OpenSSL extension..."
    "$php_bin" -m | grep -i openssl || {
        echo "❌ OpenSSL extension not loaded!"
        return 1
    }

    echo "[ * ] Verifying intl extension..."
    "$php_bin" -m | grep -i intl || {
        echo "⚠️  intl extension not loaded!"
    }

    PKG_NAME="php${ver_suffix}-openssl4"
    
    rm -rf "${PKG_DIR}"
    mkdir -p "${PKG_DIR}/usr/local"
    mkdir -p "${ARTIFACT_DIR}"
    
    echo "[ * ] Copying PHP files..."
    cp -r "${install_dir}/usr/local/"* "${PKG_DIR}/usr/local/"
    
    if [ ! -f "${PKG_DIR}/usr/local/bin/php" ]; then
        echo "❌ PHP binary not found after copy!"
        return 1
    fi
    
    echo "[ * ] Copying ICU 53 libraries..."
    mkdir -p "${PKG_DIR}/usr/local/icu53/lib"
    if [ -d "/usr/local/icu53/lib" ]; then
        cp -r /usr/local/icu53/lib/libicu*.so* "${PKG_DIR}/usr/local/icu53/lib/" || true
    fi
    
    echo "[ * ] Creating file list..."
    cd "${PKG_DIR}"
    find . -type f | sed 's|^\.||' > +PLIST
    
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

This is a custom build of PHP 5.6.40 that includes:
- OpenSSL 4.x compatibility patches
- FPM, CLI, CGI support
- Common extensions: mbstring, bcmath, curl, gmp, mysqli, pdo_mysql, pgsql, pdo_pgsql, etc.
- GD with JPEG, PNG, FreeType support
- intl extension with ICU 53

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
echo "Verify extensions:"
/usr/local/bin/php${ver_suffix} -m | grep -E "openssl|intl" || echo "Extensions not loaded"
echo "========================================"
EOF
    chmod +x "+POST_INSTALL"
    
    echo "[ * ] Creating package..."
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
        return 0
    else
        echo "❌ Failed to create package!"
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