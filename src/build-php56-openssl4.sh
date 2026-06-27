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
		#"--enable-dtrace"
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
        "--with-icu=/usr/local/icu53"
        "--with-icu-dir=/usr/local/icu53"
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
# 编译和安装 ICU 53
# ============================================================
build_icu53() {
    local icu_prefix="/usr/local/icu53"
    
    if [ -d "$icu_prefix" ] && [ -f "$icu_prefix/lib/libicuuc.so.53.2" ]; then
        echo "[ ✓ ] ICU 53 already installed at $icu_prefix"
        return 0
    fi
    
    echo "[ * ] Building ICU 53 for PHP 5.6 compatibility..."
    rm -rf "$icu_prefix"
    
    # 下载和解压
    echo "[ * ] Downloading ICU 53..."
    fetch -o /tmp/icu-53.tar.gz \
        "https://codeload.github.com/unicode-org/icu/tar.gz/refs/tags/release-53-2" || return 1
    tar -xf /tmp/icu-53.tar.gz -C /tmp || return 1
    
    cd /tmp/icu-release-53-2/icu4c/source || return 1
    
    make distclean || true
    
    export CC=gcc12
    export CXX=g++12
    
    # 配置 ICU
    echo "[ * ] Configuring ICU 53..."
    ./configure \
        --prefix="$icu_prefix" \
        --enable-shared=yes \
        --enable-static=yes \
        --disable-renaming \
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
    
    # 修复 Makefile 中的链接顺序
    find . -name "Makefile" -exec sed -i '' 's/-lpthread -lm/-lm -lpthread/g' {} \;
    
    # ✅ 简单方法：直接 make（让 make 自己处理依赖）
    echo "[ * ] Building ICU with parallel make..."
    mkdir -p ../lib
    
    # 尝试并行编译
    if ! gmake -j"$NUM_CPUS" 2>&1 | tee /tmp/icu-build.log; then
        echo "⚠️  Parallel build failed, trying single core..."
        if ! gmake -j1 2>&1 | tee -a /tmp/icu-build.log; then
            echo "❌ ICU build failed"
            tail -100 /tmp/icu-build.log
            return 1
        fi
    fi
    
    # 安装
    echo "[ * ] Installing ICU 53..."
    gmake install
    
    # 创建符号链接
    echo "[ * ] Creating ICU library symlinks..."
    cd "$icu_prefix/lib"
    for lib in libicuuc libicui18n libicudata; do
        if [ -f "${lib}.so.53.2" ]; then
            ln -sf "${lib}.so.53.2" "${lib}.so.53" || true
            ln -sf "${lib}.so.53.2" "${lib}.so" || true
        fi
    done
    cd -
    
    # 清理
    cd /
    rm -rf /tmp/icu-release-53-2 /tmp/icu-53.tar.gz
    
    # 验证
    if [ -f "$icu_prefix/lib/libicuuc.so.53.2" ] && \
       [ -f "$icu_prefix/lib/libicui18n.so.53.2" ] && \
       [ -f "$icu_prefix/lib/libicudata.so.53.2" ]; then
        echo "[ ✓ ] ICU 53 installed successfully"
        return 0
    else
        echo "❌ ICU 53 installation verification failed!"
        return 1
    fi
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
    
    # 补丁8: 更新 config.sub 以支持 FreeBSD 14
    if [ -f "config.sub" ]; then
        echo "[ * ] Updating config.sub for FreeBSD 14..."
        fetch -o "config.sub.new" "https://cgit.git.savannah.gnu.org/cgit/config.git/plain/config.sub"
        if [ -f "config.sub.new" ] && [ -s "config.sub.new" ]; then
            mv "config.sub.new" "config.sub"
            chmod +x "config.sub"
            echo "[ ✓ ] config.sub updated"
        else
            echo "⚠️  Failed to update config.sub, using existing"
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
        echo "    Skipping OpenSSL source replacement"
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

    # 下载 ImageMagick 扩展
    if ! download_imagick "$build_dir"; then
        echo "⚠️  ImageMagick extension download failed, continuing without it"
    fi

    cd "$build_dir"
    
    echo "[ DEBUG ] Current directory: $(pwd)"
    echo "[ DEBUG ] Build directory: $build_dir"
    echo "[ DEBUG ] Directory contents:"
    ls -la 
    
    # 检查 configure 是否存在
    if [ -f "configure" ]; then
        echo "[ ✓ ] configure found"
    else
        echo "❌ configure NOT found in $(pwd)"
        echo "Looking for configure in subdirectories..."
        find . -name "configure" -type f
        return 1
    fi

    [ -f "Makefile" ] && gmake clean || true

    apply_patches "$build_dir"

    # ============================================================
    # 设置编译环境
    # ============================================================
    export CC=gcc12
    export CXX=g++12
    export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:/usr/local/lib/pkgconfig"
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
        mkdir -p /usr/local/icu53/bin
        ICU_CONFIG_SRC=$(find /tmp -path "*/icu-release-53-2/*/icu-config" -type f)
        if [ -n "$ICU_CONFIG_SRC" ]; then
            cp "$ICU_CONFIG_SRC" /usr/local/icu53/bin/icu-config
            chmod +x /usr/local/icu53/bin/icu-config
            echo "[ ✓ ] Copied icu-config from source"
        else
            echo "⚠️  icu-config not found in source, skipping"
        fi
        
        # ✅ 设置环境变量（关键修复）
        export PATH="/usr/local/icu53/bin:$PATH"
        export LD_LIBRARY_PATH="/usr/local/icu53/lib:$LD_LIBRARY_PATH"
        
        # ✅ CFLAGS 包含 ICU 头文件
        export CFLAGS="-I/usr/local/icu53/include -I/usr/local/include \
            -Wno-deprecated-declarations \
            -Wno-incompatible-pointer-types-discards-qualifiers \
            -Wno-pointer-bool-conversion \
            -Wno-implicit-function-declaration \
            -Wno-pointer-sign \
            -Wno-implicit-const-int-float-conversion"
        export CXXFLAGS="-std=c++11 -Wno-register -Wno-deprecated-declarations -fpermissive"
        export LDFLAGS="-L/usr/local/icu53/lib -Wl,-rpath,/usr/local/icu53/lib -licuuc -licui18n -licudata -lc++ -lpq -lintl"
        export CPPFLAGS="-I/usr/local/icu53/include -I/usr/local/include"
        export ICU_CONFIG="/usr/local/icu53/bin/icu-config"
        export ICU_PREFIX="/usr/local/icu53"
        export ICU_LIBS="-licuuc -licui18n -licudata"
        export ICU_CFLAGS="-I/usr/local/icu53/include"
        export ICU_LDFLAGS="-L/usr/local/icu53/lib"
        
        echo "[ ✓ ] ICU config version: $(icu-config --version || echo 'unknown')"
        echo "[ ✓ ] ICU libs: $(icu-config --ldflags || echo 'unknown')"
        echo "[ * ] Debugging ICU libraries..."
        echo "ICU libs:"
        find /usr/local/icu53/lib -name "*.so*" -exec ls -la {} \; | head -10
        
        echo "ICU symbols in libicuuc:"
        nm -D /usr/local/icu53/lib/libicuuc.so.53.2 | grep -E "uloc_getDefault|u_cleanup" | head -5 || echo "Cannot check symbols"
        
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
    echo "CFLAGS: $CFLAGS"
    echo "LDFLAGS: $LDFLAGS"
    echo "CPPFLAGS: $CPPFLAGS"
    echo "CXXFLAGS: $CXXFLAGS"

    mapfile -t CONFIG_ARGS < <(get_config_args)
    echo "Config args: ${CONFIG_ARGS[*]}"

    export LIBS="-licui18n -licuuc -licudata -lc++ -lpq -lintl -lpthread -lm"
    ./configure "${CONFIG_ARGS[@]}" LIBS="$LIBS" > "$LOG_DIR/configure-${PHP_VERSION}.log"
    if [ $? -ne 0 ]; then
        echo "❌ Configure failed"
        tail -50 "$LOG_DIR/configure-${PHP_VERSION}.log"
        return 1
    fi

    # 验证使用的 ICU
    echo "[ * ] Checking ICU used:"
    grep -i "icu" "$LOG_DIR/configure-${PHP_VERSION}.log" | head -20 || true

    # ============================================================
    # ✅ 修复 Makefile 链接问题
    # ============================================================
    echo "[ * ] Fixing link flags in Makefile..."

    if [ -f "Makefile" ]; then
        echo "[ * ] Before modification:"
        grep -E "^(EXTRA_LIBS|LDFLAGS|LIBS) =" Makefile | head -3 || echo "No variables found"
        sed -i '' 's/^EXTRA_LIBS = .*/EXTRA_LIBS = -licuuc -licui18n -licudata -lc++ -lpq -lintl -lpthread -lm/' Makefile
        sed -i '' 's|^LDFLAGS = .*|LDFLAGS = -L/usr/local/icu53/lib -Wl,-rpath,/usr/local/icu53/lib -licuuc -licui18n -licudata -lc++ -lpq -lintl|' Makefile
        if ! grep -q "libicuuc.*libicui18n" Makefile; then
            echo 'LIBS = -licui18n -licuuc -licudata -lpthread -lm' >> Makefile
        fi
        
        echo "[ * ] After modification:"
        grep -E "^(EXTRA_LIBS|LDFLAGS|LIBS) =" Makefile | tail -3
        
        echo "[ ✓ ] ICU libraries successfully added to Makefile"
    else
        echo "❌ Makefile not found!"
        return 1
    fi
    
    # ============================================================
    # 编译 PHP
    # ============================================================
    echo "[ * ] Compiling PHP ${PHP_VERSION} (using ${NUM_CPUS} cores)..."
    gmake -j "$NUM_CPUS" LIBS="$LIBS" > "$LOG_DIR/build-${PHP_VERSION}.log"

    if [ $? -ne 0 ]; then
        echo ""
        echo "========================================"
        echo "❌ BUILD FAILED"
        echo "========================================"
        echo ""
        echo "=== ICU related errors ==="
        grep -E "undefined reference.*icu|undefined reference.*ucol|undefined reference.*unum|undefined reference.*udat" "$LOG_DIR/build-${PHP_VERSION}.log" | head -30
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
        if gmake -j1 LIBS="$LIBS" >> "$LOG_DIR/build-${PHP_VERSION}.log"; then
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
    gmake install INSTALL_ROOT="$install_dir" > "$LOG_DIR/install-${PHP_VERSION}.log"
    if [ $? -ne 0 ]; then
        echo "❌ Install failed"
        tail -50 "$LOG_DIR/install-${PHP_VERSION}.log"
        return 1
    fi
    
    if [ ! -f "$install_dir/usr/local/bin/php-cgi" ] && [ -f "$install_dir/usr/local/bin/php" ]; then
        echo "[ * ] Creating php-cgi symlink from php binary..."
        ln -sf php "$install_dir/usr/local/bin/php-cgi"
        echo "[ ✓ ] php-cgi -> php symlink created"
    fi

	# ============================================================
	# 编译 ImageMagick 扩展
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
            if [ -d "$php_prefix/include/php" ] && [ ! -d "/usr/local/include/php" ]; then
                echo "[ * ] Linking PHP headers to /usr/local/include/php..."
                mkdir -p /usr/local/include
                ln -sf "$php_prefix/include/php" /usr/local/include/php
            fi
            
            if [ -L "/usr/local/include/php" ] && [ ! -d "/usr/local/include/php/main" ]; then
                rm -f /usr/local/include/php
                ln -sf "$php_prefix/include/php" /usr/local/include/php
            fi
            
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

    # 检查 PHP 二进制文件
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

	# 验证 ImageMagick 扩展
	echo "[ * ] Verifying ImageMagick extension..."
	PHP_SRC_DIR="$BUILD_DIR/php-src-${PHP_VERSION}"
	ZEND_API_NO=$(grep "^#define ZEND_MODULE_API_NO" "$PHP_SRC_DIR/Zend/zend_modules.h" | awk '{print $3}')
	EXTENSION_DIR="$install_dir/usr/local/lib/php/extensions/no-debug-non-zts-${ZEND_API_NO}"

	if [ -f "$EXTENSION_DIR/imagick.so" ]; then
		echo "✅ ImageMagick extension found"
		"$php_bin" -d extension_dir="$EXTENSION_DIR" -d extension=imagick.so -r '
			$imagick_loaded = extension_loaded("imagick");
			echo "PHP Version: " . PHP_VERSION . "\n";
			echo "OpenSSL Version: " . OPENSSL_VERSION_TEXT . "\n";
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
		echo "  Files in PKG_DIR:"
		find "${PKG_DIR}" -type f | head -10
		return 1
	fi
	
	echo "[ ✓ ] Files copied successfully"

    echo "[ * ] Copying ICU 53 libraries..."
    mkdir -p "${PKG_DIR}/usr/local/icu53/lib"
    if [ -d "/usr/local/icu53/lib" ]; then
        cp -r /usr/local/icu53/lib/libicu*.so* "${PKG_DIR}/usr/local/icu53/lib/" || true
        echo "[ ✓ ] ICU libraries copied"
    fi
	
	# 创建 PLIST
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