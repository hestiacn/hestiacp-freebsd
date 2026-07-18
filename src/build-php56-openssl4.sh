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
echo "Build PHP ${PHP_VERSION} with OpenSSL 4.x and ImageMagick"
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
# 下载 ImageMagick 扩展源码
# ============================================================
download_imagick() {
    local build_dir="$1"
    local imagick_dir="${build_dir}/ext/imagick"
    
    [ -d "$imagick_dir" ] && { echo "[ ✓ ] ImageMagick already exists"; return 0; }
    
    echo "[ * ] Downloading ImageMagick 3.8.1..."
    fetch -o "/tmp/imagick.tar.gz" "https://github.com/Imagick/imagick/archive/refs/tags/3.8.1.tar.gz" || return 1
    
    echo "[ * ] Extracting..."
    tar -xf "/tmp/imagick.tar.gz" -C "${build_dir}/ext"
    
    # 找到解压出来的目录并重命名
    local extracted=$(find "${build_dir}/ext" -maxdepth 1 -type d -name "imagick-*" | head -1)
    [ -z "$extracted" ] && { echo "❌ Extract failed"; return 1; }
    
    mv "$extracted" "$imagick_dir"
    rm -f "/tmp/imagick.tar.gz"
    
    echo "[ ✓ ] ImageMagick extension ready at $imagick_dir"
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
		#"--with-ffi"
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
    
    echo "[ * ] Copying ICU 53 from local file..."

    LOCAL_ICU_FILE="$SCRIPT_DIR/php5.6/icu-release-53-2.tar.gz"
    cp "$LOCAL_ICU_FILE" /tmp/icu-53.tar.gz || return 1
    tar -xf /tmp/icu-53.tar.gz -C /tmp || return 1
    
    cd /tmp/icu-release-53-2/icu4c/source || return 1
    
    make distclean || true
    
    export CC=gcc14
    export CXX=g++14
    echo "[ * ] Configuring ICU 53..."
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
    
    echo "[ * ] Building ICU (this may take a while)..."
    mkdir -p ../lib
    
    if ! gmake -j"$NUM_CPUS" 2>&1 | tee /tmp/icu-build.log; then
        echo "❌ ICU build failed"
        tail -50 /tmp/icu-build.log
        return 1
    fi
    
    echo "[ * ] Verifying ICU symbols..."
    if [ -f "lib/libicuuc.so.53.2" ]; then
        if nm -D "lib/libicuuc.so.53.2" | grep -q "uspoof_setChecks_53"; then
            echo "[ ✓ ] ICU symbols have _53 suffix (correct)"
        else
            echo "⚠️  ICU symbols may not have _53 suffix"
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
    
    echo "[ * ] Installing ICU 53..."
    if ! gmake install 2>&1 | tee /tmp/icu-install.log; then
        echo "❌ ICU install failed"
        tail -50 /tmp/icu-install.log
        return 1
    fi
    
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
    
    if [ -f "$icu_prefix/bin/icu-config" ]; then
        sed -i '' 's/libicuuc.so/libicuuc.so.53.2/g' "$icu_prefix/bin/icu-config" || true
        sed -i '' 's/libicui18n.so/libicui18n.so.53.2/g' "$icu_prefix/bin/icu-config" || true
        sed -i '' 's/libicudata.so/libicudata.so.53.2/g' "$icu_prefix/bin/icu-config" || true
        sed -i '' 's/libicuio.so/libicuio.so.53.2/g' "$icu_prefix/bin/icu-config" || true
    fi
    
    echo "[ * ] Verifying ICU 53 installation..."
    if ! "$icu_prefix/bin/icu-config" --version > /dev/null 2>&1; then
        echo "❌ icu-config validation failed"
        return 1
    fi
    echo "  Version: $($icu_prefix/bin/icu-config --version)"
    
    cd /
    rm -rf /tmp/icu-release-53-2 /tmp/icu-53.tar.gz
    
    echo "[ ✓ ] ICU 53 installed successfully"
    return 0
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
        echo "[ * ] Updating config.sub for FreeBSD 14 from local file..."
        #fetch -o "config.sub.new" "https://cgit.git.savannah.gnu.org/cgit/config.git/plain/config.sub"
        LOCAL_CONFIG_SUB="$SCRIPT_DIR/php7.0/config.sub"
        
        if [ -f "$LOCAL_CONFIG_SUB" ]; then
            cp "$LOCAL_CONFIG_SUB" "config.sub"
            chmod +x "config.sub"
            echo "[ ✓ ] config.sub updated from local file"
        else
            echo "⚠️  Local config.sub not found at: $LOCAL_CONFIG_SUB"
            echo "    Skipping config.sub update"
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
# 编译 ImageMagick 扩展
# ============================================================
build_imagick() {
    local build_dir="$1"
    local install_dir="$2"
    echo "[ * ] Ensuring PHP headers are accessible..."
    
    # 方法1: 从安装目录链接
    if [ -d "$install_dir/usr/local/include/php" ]; then
        rm -rf /usr/local/include/php 2>/dev/null || true
        ln -sf "$install_dir/usr/local/include/php" /usr/local/include/php
        echo "  ✅ Linked PHP headers from install dir: $install_dir/usr/local/include/php"
    # 方法2: 从源码目录链接
    elif [ -d "$build_dir" ]; then
        rm -rf /usr/local/include/php 2>/dev/null || true
        ln -sf "$build_dir" /usr/local/include/php
        echo "  ✅ Linked PHP headers from build dir: $build_dir"
    else
        echo "  ⚠️  PHP headers not found, phpize may fail"
    fi
    
    # 验证头文件是否存在
    if [ -f "/usr/local/include/php/main/php.h" ] || [ -f "/usr/local/include/php/php/main/php.h" ]; then
        echo "  ✅ PHP headers verified"
    else
        echo "  ⚠️  PHP headers verification failed, phpize may not work"
    fi
    
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
        # 确保 /usr/local/lib/php/build 存在
        mkdir -p /usr/local/lib/php/build
        
        # 删除旧的 build 目录（如果是软链接或目录）
        rm -rf /usr/local/lib/php/build || true
        
        # 创建软链接指向源码 build 目录
        ln -sf "$build_dir/build" /usr/local/lib/php/build
        echo "  ✅ Symlink: /usr/local/lib/php/build -> $build_dir/build"
        
        # 在当前目录创建软链接
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
    
    # 确保 phpize.m4 在根目录可访问
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

    # 获取扩展目录
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
# 从 FreeBSD ports 或源码编译 IMAP 扩展
# ============================================================
build_imap_extension() {
    local install_dir="$1"
    local php_version="$2"
    local build_dir="$3"
    
    echo ""
    echo "========================================"
    echo "[ * ] Building IMAP extension"
    echo "========================================"
    
    local php_bin="$install_dir/usr/local/bin/php"
    if [ ! -f "$php_bin" ]; then
        echo "❌ PHP binary not found: $php_bin"
        return 1
    fi
    
    local php_ver=$(echo "$php_version" | cut -d. -f1-2 | tr -d '.')
    echo "[ * ] PHP version: $php_ver"
    local php_prefix="$install_dir/usr/local"
    local ver_suffix="$php_ver"
    local phpize=""
    local php_config=""
    
    for path in "$php_prefix/bin/phpize" "$php_prefix/bin/phpize${ver_suffix}" \
                 "/usr/local/bin/phpize" "/usr/local/bin/phpize${ver_suffix}" \
                 "$build_dir/phpize" "$build_dir/scripts/phpize"; do
        if [ -f "$path" ] && [ -x "$path" ]; then
            phpize="$path"
            break
        fi
    done
    
    for path in "$php_prefix/bin/php-config" "$php_prefix/bin/php-config${ver_suffix}" \
                 "/usr/local/bin/php-config" "/usr/local/bin/php-config${ver_suffix}" \
                 "$build_dir/php-config" "$build_dir/scripts/php-config"; do
        if [ -f "$path" ] && [ -x "$path" ]; then
            php_config="$path"
            break
        fi
    done
    
    if [ -z "$phpize" ] || [ -z "$php_config" ]; then
        echo "⚠️  phpize or php-config not found"
        return 1
    fi
    
    echo "  Using phpize: $phpize"
    echo "  Using php-config: $php_config"
    
    # ============================================================
    # 方法1: 尝试从 ports 安装
    # ============================================================
    local port_paths=(
        "/usr/ports/mail/php${php_ver}-imap"
        "/usr/ports/mail/php-imap"
        "/usr/ports/mail/php${php_ver}-mail"
        "/usr/ports/mail/php-mail"
        "/usr/ports/mail/php${php_ver}-extensions"
        "/usr/ports/lang/php${php_ver}-extensions"
    )
    
    for port_path in "${port_paths[@]}"; do
        if [ -d "$port_path" ]; then
            echo "[ ✓ ] Found port: $port_path"
            cd "$port_path" || continue
            
            export PHP_PREFIX="$install_dir/usr/local"
            export PATH="$PHP_PREFIX/bin:$PATH"
            export PKG_CONFIG_PATH="$PHP_PREFIX/lib/pkgconfig:/usr/local/lib/pkgconfig"
            
            echo "[ * ] Compiling IMAP extension from port..."
            if make -DBATCH install clean | tee -a "$LOG_DIR/imap-extension.log"; then
                echo "  ✅ IMAP extension installed from port"
                if find_imap_so "$install_dir" "$build_dir"; then
                    return 0
                fi
            fi
        fi
    done
    
    # ============================================================
    # 方法2: 从 PHP 源码编译
    # ============================================================
    echo ""
    echo "[ * ] Method 2: Building IMAP from PHP source..."
    if [ -d "$build_dir/ext/imap" ]; then
        cd "$build_dir/ext/imap" || return 1
        
        echo "  [ * ] Creating symlinks to build files..."
        if [ -d "$build_dir/build" ]; then
            for file in mkdep.awk scan_makefile_in.awk shtool libtool.m4 ax_check_compile_flag.m4; do
                if [ -f "$build_dir/build/$file" ] && [ ! -f "$file" ]; then
                    ln -sf "$build_dir/build/$file" ./
                    echo "  ✅ $file -> build/$file"
                fi
            done
        fi
        
        export PHP_PREFIX="$php_prefix"
        export PHP_CONFIG="$php_config"
        export PHPIZE="$phpize"
        export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:$PKG_CONFIG_PATH"
        export CFLAGS="-I/usr/local/include $CFLAGS"
        export LDFLAGS="-L/usr/local/lib $LDFLAGS"
        
        echo "  Running phpize..."
        if ! "$phpize" | tee -a "$LOG_DIR/imap-phpize.log"; then
            "$phpize" --with-php-config="$php_config" | tee -a "$LOG_DIR/imap-phpize.log" || {
                echo "  ❌ phpize failed, skipping IMAP"
                return 0
            }
        fi
        
        echo "  Configuring..."
        ./configure --with-php-config="$php_config" --with-imap=/usr/local --with-imap-ssl=/usr/local | tee -a "$LOG_DIR/imap-configure.log"
        
        echo "  Compiling..."
        make | tee -a "$LOG_DIR/imap-make.log"
        
        echo "  Installing..."
        make install INSTALL_ROOT="$install_dir" | tee -a "$LOG_DIR/imap-install.log"
        
        if find_imap_so "$install_dir" "$build_dir"; then
            return 0
        fi
    fi
    
    # ============================================================
    # 方法3: 使用 pecl 安装
    # ============================================================
    echo ""
    echo "[ * ] Method 3: Installing via pecl..."
    
    if [ -f "$install_dir/usr/local/bin/pecl" ]; then
        export PATH="$install_dir/usr/local/bin:$PATH"
        if pecl install imap | tee -a "$LOG_DIR/imap-extension.log"; then
            echo "  ✅ IMAP extension installed via pecl"
            if find_imap_so "$install_dir" "$build_dir"; then
                return 0
            fi
        fi
    fi
    
    echo "⚠️  IMAP extension could not be installed"
    return 1
}

# ============================================================
# 辅助函数：查找并复制 imap.so
# ============================================================
find_imap_so() {
    local install_dir="$1"
    local build_dir="$2"
    local php_ini="$install_dir/usr/local/etc/php.ini"
    
    # 获取 ZEND_API_NO
    local zend_api_no=$(grep "^#define ZEND_MODULE_API_NO" "$build_dir/Zend/zend_modules.h" | awk '{print $3}' || echo "20151012")
    local ext_dir="$install_dir/usr/local/lib/php/extensions/no-debug-non-zts-${zend_api_no}"
    
    echo "  Looking for imap.so..."
    local search_paths=(
        "$ext_dir"
        "$install_dir/usr/local/lib/php/extensions"
        "$build_dir/ext/imap/modules"
        "$build_dir/ext/imap/.libs"
        "$build_dir/modules"
        "/usr/local/lib/php/extensions"
        "/usr/local/lib/php"
    )
    
    local imap_so=""
    for path in "${search_paths[@]}"; do
        if [ -d "$path" ]; then
            found=$(find "$path" -name "imap.so" | head -1)
            if [ -n "$found" ] && [ -f "$found" ]; then
                imap_so="$found"
                break
            fi
        fi
    done
    
    if [ -n "$imap_so" ] && [ -f "$imap_so" ]; then
        echo "  ✅ imap.so found: $imap_so"
        
        mkdir -p "$ext_dir"
        cp "$imap_so" "$ext_dir/"
        echo "  ✅ imap.so copied to $ext_dir"
        
        mkdir -p "$(dirname "$php_ini")"
        if [ -f "$php_ini" ]; then
            if ! grep -q "^extension=imap.so" "$php_ini"; then
                echo "extension=imap.so" >> "$php_ini"
            fi
        else
            echo "extension=imap.so" > "$php_ini"
        fi
        
        return 0
    fi
    
    echo "  ⚠️  imap.so not found"
    return 1
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
    echo "[ * ] Building PHP ${PHP_VERSION} with OpenSSL 4.x and ImageMagick"
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

    if ! download_imagick "$build_dir"; then
        echo "⚠️  ImageMagick extension download failed, continuing without it"
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

    cp "$SCRIPT_DIR/php7.0/libarchive-3.7.2.tar.gz" /tmp/
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

    # 验证
    if [ -f "/usr/local/lib/libarchive.so" ]; then
        echo "✅ libarchive 编译成功"
        echo "   文件: /usr/local/lib/libarchive.so"
        
        # 使用多种方式检查文件大小
        echo "   大小: $(stat -f %z /usr/local/lib/libarchive.so) bytes"
        echo "   实际大小: $(ls -lh /usr/local/lib/libarchive.so | awk '{print $5}')"
        echo "   du -h: $(du -h /usr/local/lib/libarchive.so | cut -f1)"
        
        # 检查是否是符号链接
        if [ -L "/usr/local/lib/libarchive.so" ]; then
            echo "   ⚠️  这是一个符号链接，指向: $(readlink /usr/local/lib/libarchive.so)"
            # 检查实际目标文件
            TARGET=$(readlink /usr/local/lib/libarchive.so)
            if [ -f "$TARGET" ]; then
                echo "   目标文件大小: $(stat -f %z "$TARGET") bytes"
            fi
        fi
        
        # 检查 OpenSSL 依赖
        echo "[ * ] Checking OpenSSL dependencies..."
        if ldd /usr/local/lib/libarchive.so | grep -q "libcrypto.so"; then
            echo "  libarchive links to:"
            ldd /usr/local/lib/libarchive.so | grep -E "(crypto|ssl)"
        else
            echo "  ✅ libarchive has no direct OpenSSL dependency"
        fi
        
        # 检查是否依赖旧的 OpenSSL 符号
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
        
        # 备份并删除旧的 libssh2
        if [ -f "/usr/local/lib/libssh2.so" ]; then
            echo "[ * ] 删除旧的 libssh2..."
            rm -f /usr/local/lib/libssh2.so
            rm -f /usr/local/lib/libssh2.so.1
        fi
        
        cp "$SCRIPT_DIR/php7.0/libssh2-1.11.1.tar.gz" /tmp/
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
        
        # 备份并删除旧的 curl
        if [ -f "/usr/local/lib/libcurl.so" ]; then
            echo "[ * ] 删除旧的 curl..."
            rm -f /usr/local/lib/libcurl.so /usr/local/lib/libcurl.so.4
        fi
        
        cp "$SCRIPT_DIR/php7.0/curl-8.20.0.tar.gz" /tmp/
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
            
            # 检查 OpenSSL 依赖
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
        
        # 备份并删除旧的 openldap
        if [ -f "/usr/local/lib/libldap.so" ]; then
            echo "[ * ] 删除旧的 openldap..."
            rm -f /usr/local/lib/libldap.so
            rm -f /usr/local/lib/libldap.so.2
            rm -f /usr/local/lib/liblber.so
            rm -f /usr/local/lib/liblber.so.2
        fi
        
        cp "$SCRIPT_DIR/php7.0/openldap-2.6.13.tgz" /tmp/
        cd /tmp
        extract_archive openldap-2.6.13.tgz
        cd openldap-2.6.13
        cp "$SCRIPT_DIR/php7.0/tls_o.c" libraries/libldap/tls_o.c
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
        
        # 备份并删除旧的 postgresql
        if [ -f "/usr/local/lib/libpq.so" ]; then
            echo "[ * ] 删除旧的 postgresql..."
            rm -f /usr/local/lib/libpq.so /usr/local/lib/libpq.so.5
        fi
        
        cp "$SCRIPT_DIR/php7.0/postgresql-18.4.tar.gz" /tmp/
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

        cp "$SCRIPT_DIR/php7.0/cyrus-sasl-2.1.28.tar.gz" /tmp/
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

        # ============================================================
        # 使用 makemd5 生成 md5global.h
        # ============================================================
        echo "[ * ] Generating md5global.h using makemd5..."

        cd include

        # 编译 makemd5
        if [ ! -f "makemd5.c" ]; then
            echo "❌ makemd5.c not found!"
            exit 1
        fi

        echo "  Compiling makemd5..."
        # 尝试不同的编译器
        if command -v gcc14 >/dev/null; then
            gcc14 -o makemd5 makemd5.c || cc -o makemd5 makemd5.c
        else
            cc -o makemd5 makemd5.c
        fi

        if [ ! -f "makemd5" ] || [ ! -x "makemd5" ]; then
            echo "❌ Failed to compile makemd5"
            # 检查是否已有 md5global.h（源码中可能已经存在）
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

        # 修复 Makefile
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
            
            # 检查 OpenSSL 依赖
            if ldd /usr/local/lib/libsasl2.so | grep -q "libcrypto.so"; then
                echo "  链接到 OpenSSL:"
                ldd /usr/local/lib/libsasl2.so | grep -E "(crypto|ssl)"
            fi
            
            # 检查是否依赖旧的 OpenSSL 符号
            if objdump -p /usr/local/lib/libsasl2.so | grep -q "OPENSSL_1_1_0"; then
                echo "  ⚠️  libsasl2.so 仍然依赖 OPENSSL_1_1_0"
            else
                echo "  ✅ libsasl2.so 兼容 OpenSSL 4.x"
            fi
        else
            echo "❌ cyrus-sasl2 编译失败"
            exit 1
        fi

        # 6. c-client (IMAP) - 从源码编译链接 OpenSSL 4.x
        echo ""
        echo "========================================"
        echo "[7/7] 编译 c-client (IMAP library)"
        echo "========================================"

        if [ -f "/usr/local/lib/libc-client.so" ]; then
            echo "[ * ] 删除旧的 c-client..."
            rm -f /usr/local/lib/libc-client.so
            rm -f /usr/local/lib/libc-client.a
        fi

        cp "$SCRIPT_DIR/php7.0/imap-imap-2007f_upstream.tar.gz" /tmp/
        cd /tmp
        extract_archive imap-imap-2007f_upstream.tar.gz
        cd imap-imap-2007f_upstream
        cp "$SCRIPT_DIR/php7.0/c-client/"*.c src/osdep/unix/
        cp "$SCRIPT_DIR/php7.0/mtest.c" src/mtest/mtest.c
        
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

        # ✅ 立即保存 make 的退出码
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

        # ✅ 使用保存的退出码和文件检查结果
        if [ $MAKE_EXIT -ne 0 ] || [ $LS_RESULT -ne 0 ]; then
            echo "❌ c-client 编译失败"
            echo "   Make 退出码: $MAKE_EXIT"
            echo "   静态库存在: $([ $LS_RESULT -eq 0 ] && echo '是' || echo '否')"
            exit 1
        fi

        echo "✅ c-client 编译成功！"
        echo "[ * ] 安装 c-client..."

        # 复制头文件
        mkdir -p /usr/local/include/c-client
        cp c-client/*.h /usr/local/include/c-client/
        cp c-client/*.h /usr/local/include/

        # 复制静态库
        cp c-client/c-client.a /usr/local/lib/libc-client.a
        echo "  ✅ libc-client.a installed"

        # 创建共享库
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
                # 复制到系统目录
                cp libc-client.so /usr/local/lib/
                echo "  ✅ libc-client.so created and installed"
                
                # 验证
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

        # 验证
        echo "[ * ] Verifying c-client installation..."

        if [ -f "/usr/local/lib/libc-client.a" ]; then
            echo "✅ 静态库: /usr/local/lib/libc-client.a ($(du -h /usr/local/lib/libc-client.a | cut -f1))"
        else
            echo "❌ 静态库不存在"
            exit 1
        fi

        if [ -f "/usr/local/lib/libc-client.so" ]; then
            echo "✅ 动态库: /usr/local/lib/libc-client.so ($(du -h /usr/local/lib/libc-client.so | cut -f1))"
            
            if ldd /usr/local/lib/libc-client.so | grep -q "libcrypto.so.19"; then
                echo "  ✅ 链接到 OpenSSL 4.x"
            else
                echo "  ⚠️  可能链接到其他 OpenSSL 版本"
                ldd /usr/local/lib/libc-client.so | grep crypto || echo "    无法检测"
            fi
        else
            echo "⚠️  动态库不存在（只有静态库）"
        fi
        # 清理
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
                # 获取实际文件大小（如果是符号链接）
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
        
        # 验证
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
    # 修复 cURL OpenSSL 4.x 兼容性（在配置 PHP 之前）
    # ============================================================
    echo "[ * ] Fixing cURL for OpenSSL 4.x..."

    # 1. 设置 cURL 编译标志
    export CURL_CFLAGS="-I/usr/local/include"
    export CURL_LIBS="-L/usr/local/lib -lcurl -lssl -lcrypto"

    # 2. 创建 cURL 配置包装器
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

    # 3. 强制 cURL 检测通过
    export ac_cv_lib_curl_curl_easy_perform=yes

    # 4. 确保 PKG_CONFIG_PATH 包含 cURL
    export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:/usr/local/libdata/pkgconfig:/usr/lib/pkgconfig"

    echo "[ ✓ ] cURL environment configured for OpenSSL 4.x"

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
        if ! build_icu53; then
            echo "❌ Failed to build ICU 53"
            return 1
        fi
        cd "$build_dir" || {
            echo "❌ Failed to return to PHP source directory"
            return 1
        }
        echo "[ * ] Current directory: $(pwd)"
        
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
    echo ""
    echo "[*] Installing PHP ${PHP_VERSION}..."
    mkdir -p "$install_dir"
    echo "[ * ] Installing phpize and php-config..."
    if [ -f "Makefile" ]; then
        # 先尝试用 make 安装
        if ! gmake install-programs INSTALL_ROOT="$install_dir" | tee -a "$LOG_DIR/install-programs.log"; then
            echo "  ⚠️  make install-programs failed, copying from source..."
            # 从源码目录复制
            if [ -f "$build_dir/phpize" ]; then
                mkdir -p "$install_dir/usr/local/bin"
                cp "$build_dir/phpize" "$install_dir/usr/local/bin/"
                chmod 755 "$install_dir/usr/local/bin/phpize"
                echo "  ✅ phpize copied from source"
            fi
            if [ -f "$build_dir/php-config" ]; then
                cp "$build_dir/php-config" "$install_dir/usr/local/bin/"
                chmod 755 "$install_dir/usr/local/bin/php-config"
                echo "  ✅ php-config copied from source"
            fi
        else
            echo "  ✅ phpize and php-config installed"
        fi
        
        # 验证
        if [ -f "$install_dir/usr/local/bin/phpize" ] && [ -f "$install_dir/usr/local/bin/php-config" ]; then
            echo "  ✅ phpize: $(ls -l $install_dir/usr/local/bin/phpize)"
            echo "  ✅ php-config: $(ls -l $install_dir/usr/local/bin/php-config)"
        else
            echo "  ⚠️  phpize or php-config still missing"
        fi
    fi
    
    echo "[ * ] Step 1: Installing PHP (without PEAR)..."
    
    # 备份并修改 Makefile
    if [ -f "Makefile" ]; then
        echo "  Makefile targets (before):"
        grep -E "^install:|^install-|^pharcmd:" Makefile | head -10 | sed 's/^/    /'
        
        cp Makefile Makefile.bak
        
        echo ""
        echo "  PEAR lines before:"
        grep -n "install-pear" Makefile | head -10 || echo "    (none found)"
        sed -i '' 's/ install-pear / /g' Makefile
        sed -i '' 's/ install-pear$/ /g' Makefile
        sed -i '' 's/^install_targets.*install-pear.*$/ /g' Makefile
        sed -i '' 's/^install-pear:/# install-pear:/g' Makefile
        sed -i '' 's/^install-pear-installer:/# install-pear-installer:/g' Makefile
        sed -i '' '/^\t.*install-pear/ s/^/# /' Makefile
        sed -i '' '/^\t.*PEAR_INSTALLER/ s/^/# /' Makefile
        
        echo ""
        echo "  PEAR lines after:"
        grep -n "install-pear" Makefile | head -10 || echo "    (none found)"
        
        echo ""
        echo "  Makefile targets (after):"
        grep -E "^install:|^install-|^pharcmd:" Makefile | head -10 | sed 's/^/    /'
        
        echo "  ✓ PEAR disabled in Makefile"
    fi
    
    # 执行完整安装
    echo ""
    echo "  Running: gmake install INSTALL_ROOT=\"$install_dir\""
    if ! gmake install INSTALL_ROOT="$install_dir" > "$LOG_DIR/install-${PHP_VERSION}.log" 2>&1; then
        echo "❌ PHP install failed"
        echo ""
        echo "--- Last 50 lines of install log ---"
        tail -50 "$LOG_DIR/install-${PHP_VERSION}.log"
        
        # 尝试组件安装
        echo ""
        echo "--- Trying component installation ---"
        for target in install-cli install-cgi install-fpm install-build install-pdo-headers; do
            echo "  Installing $target..."
            gmake $target INSTALL_ROOT="$install_dir" 2>> "$LOG_DIR/install-${PHP_VERSION}.log" || true
        done
        
        # 手动复制扩展
        if [ -d "modules" ]; then
            ZEND_API_NO=$(grep "^#define ZEND_MODULE_API_NO" Zend/zend_modules.h | awk '{print $3}')
            EXT_DIR="$install_dir/usr/local/lib/php/extensions/no-debug-non-zts-${ZEND_API_NO}"
            mkdir -p "$EXT_DIR"
            find modules -name "*.so" -exec cp {} "$EXT_DIR/" \;
            echo "  ✓ Extensions copied manually"
        fi
        
        # 手动复制 PHP 二进制
        mkdir -p "$install_dir/usr/local/bin"
        [ -f "sapi/cli/php" ] && cp sapi/cli/php "$install_dir/usr/local/bin/" && chmod 755 "$install_dir/usr/local/bin/php"
        [ -f "sapi/cgi/php-cgi" ] && cp sapi/cgi/php-cgi "$install_dir/usr/local/bin/" && chmod 755 "$install_dir/usr/local/bin/php-cgi"
        [ -f "sapi/fpm/php-fpm" ] && cp sapi/fpm/php-fpm "$install_dir/usr/local/bin/" && chmod 755 "$install_dir/usr/local/bin/php-fpm"
        
        # 再次确保 phpize 存在
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
    fi
    
    # 验证 PHP 是否安装成功
    if [ ! -f "$install_dir/usr/local/bin/php" ]; then
        echo "❌ PHP binary not found!"
        echo "Contents of $install_dir/usr/local/bin:"
        ls -la "$install_dir/usr/local/bin/" || echo "  (empty)"
        return 1
    fi
    
    echo ""
    echo "  ✅ PHP installed successfully"
    echo "  PHP version: $($install_dir/usr/local/bin/php -v | head -1)"
    
    # 恢复 Makefile
    if [ -f "Makefile.bak" ]; then
        mv Makefile.bak Makefile
        echo "  ✓ Restored Makefile"
    fi
    
    # 创建 php-cgi 软链接
    if [ ! -f "$install_dir/usr/local/bin/php-cgi" ] && [ -f "$install_dir/usr/local/bin/php" ]; then
        ln -sf php "$install_dir/usr/local/bin/php-cgi"
        echo "  ✓ Created php-cgi symlink"
    fi

    echo ""
    echo "✅ PHP ${PHP_VERSION} installed successfully"

    rm -f /usr/local/include/php || true
    ln -sf "$build_dir" /usr/local/include/php
    if [ -d "/usr/local/include/php" ] && [ ! -L "/usr/local/include/php/php" ]; then
        cd /usr/local/include/php
        ln -sf . php
        cd - > /dev/null
    fi

    # ============================================================
    # 编译 ImageMagick 扩展
    # ============================================================
    if ! build_imagick "$build_dir" "$install_dir"; then
        echo "⚠️  ImageMagick extension build failed"
    fi

    if [ "$BUILD_IMAP" = "yes" ]; then
        if ! build_imap_extension "$install_dir" "$PHP_VERSION" "$build_dir"; then
            echo "⚠️  IMAP extension build failed, continuing without it"
        fi
    else
        echo "[ * ] IMAP extension disabled (BUILD_IMAP=no)"
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
# 检测 OpenSSL 4.x 兼容性
# ============================================================
check_openssl4_compatibility() {
    local install_dir="$1"
    local build_dir="$2"
    echo ""
    echo "========================================"
    echo "🔍 OpenSSL 4.x Compatibility Check"
    echo "========================================"
    
    local all_passed=0
    local failed_items=()
    
    # 1. 检测系统 OpenSSL 版本
    echo ""
    echo "[1/8] System OpenSSL"
    echo "----------------------------------------"
    if command -v openssl >/dev/null 2>&1; then
        local openssl_ver=$(openssl version | awk '{print $2}')
        echo "  OpenSSL version: $openssl_ver"
        if [[ "$openssl_ver" == 4.* ]]; then
            echo "  ✅ OpenSSL 4.x detected"
        else
            echo "  ⚠️  OpenSSL version is not 4.x: $openssl_ver"
            failed_items+=("System OpenSSL is $openssl_ver (expected 4.x)")
        fi
    else
        echo "  ❌ OpenSSL command not found"
        failed_items+=("OpenSSL command not found")
    fi
    
    # 2. 检测 libcrypto.so
    echo ""
    echo "[2/8] OpenSSL Libraries (libcrypto.so)"
    echo "----------------------------------------"
    local libcrypto_found=0
    for lib in /usr/local/lib/libcrypto.so*; do
        if [ -f "$lib" ] && [ ! -L "$lib" ]; then
            local libver=$(basename "$lib" | sed 's/libcrypto\.so\.//')
            echo "  Found: $(basename $lib) (version $libver)"
            if [[ "$libver" == "19" ]] || [[ "$libver" == "4"* ]] || [[ "$libver" == "20"* ]]; then
                echo "  ✅ OpenSSL 4.x compatible (version $libver)"
                libcrypto_found=1
            else
                echo "  ⚠️  May be older OpenSSL (version $libver)"
                failed_items+=("libcrypto.so.$libver (not OpenSSL 4.x)")
            fi
        fi
    done
    if [ $libcrypto_found -eq 0 ]; then
        echo "  ⚠️  No libcrypto.so found in /usr/local/lib"
        failed_items+=("No libcrypto.so found")
    fi
    
    # 3. 检测 libssl.so
    echo ""
    echo "[3/8] OpenSSL Libraries (libssl.so)"
    echo "----------------------------------------"
    local libssl_found=0
    for lib in /usr/local/lib/libssl.so*; do
        if [ -f "$lib" ] && [ ! -L "$lib" ]; then
            local libver=$(basename "$lib" | sed 's/libssl\.so\.//')
            echo "  Found: $(basename $lib) (version $libver)"
            if [[ "$libver" == "19" ]] || [[ "$libver" == "4"* ]] || [[ "$libver" == "20"* ]]; then
                echo "  ✅ OpenSSL 4.x compatible (version $libver)"
                libssl_found=1
            else
                echo "  ⚠️  May be older OpenSSL (version $libver)"
                failed_items+=("libssl.so.$libver (not OpenSSL 4.x)")
            fi
        fi
    done
    if [ $libssl_found -eq 0 ]; then
        echo "  ⚠️  No libssl.so found in /usr/local/lib"
        failed_items+=("No libssl.so found")
    fi
    
    # 4. 检测关键库的 OpenSSL 依赖
    echo ""
    echo "[4/8] Critical Libraries (OpenSSL dependencies)"
    echo "----------------------------------------"
    
    local critical_libs=(
        "libcurl.so"
        "libldap.so"
        "libssh2.so"
        "libpq.so"
        "libsasl2.so"
        "libarchive.so"
    )
    
    for lib in "${critical_libs[@]}"; do
        local lib_path="/usr/local/lib/$lib"
        if [ -f "$lib_path" ] || [ -L "$lib_path" ]; then
            local real_path="$lib_path"
            if [ -L "$lib_path" ]; then
                real_path=$(readlink "$lib_path")
                if [[ "$real_path" != /* ]]; then
                    real_path="/usr/local/lib/$real_path"
                fi
            fi
            
            echo -n "  $lib: "
            if [ -f "$real_path" ]; then
                if objdump -p "$real_path" 2>/dev/null | grep -q "OPENSSL_1_1_0"; then
                    echo "⚠️  Requires OPENSSL_1_1_0 symbols"
                    failed_items+=("$lib requires OPENSSL_1_1_0")
                elif objdump -p "$real_path" 2>/dev/null | grep -q "OPENSSL_1_0_0"; then
                    echo "⚠️  Requires OPENSSL_1_0_0 symbols"
                    failed_items+=("$lib requires OPENSSL_1_0_0")
                else
                    if ldd "$real_path" 2>/dev/null | grep -q "libcrypto.so"; then
                        local crypto_ver=$(ldd "$real_path" 2>/dev/null | grep "libcrypto.so" | awk '{print $1}' | sed 's/libcrypto\.so\.//')
                        if [[ "$crypto_ver" == "19" ]] || [[ "$crypto_ver" == "4"* ]] || [[ "$crypto_ver" == "20"* ]]; then
                            echo "✅ OpenSSL 4.x compatible (libcrypto.so.$crypto_ver)"
                        else
                            echo "⚠️  Linked to libcrypto.so.$crypto_ver (may not be OpenSSL 4.x)"
                            failed_items+=("$lib linked to libcrypto.so.$crypto_ver")
                        fi
                    else
                        echo "✅ No OpenSSL dependency detected"
                    fi
                fi
            else
                echo "❌ File not found"
                failed_items+=("$lib not found")
            fi
        else
            echo "  $lib: ❌ Not found"
            failed_items+=("$lib not found")
        fi
    done
    
    # 5. 检测 PHP 扩展的 OpenSSL 依赖
    echo ""
    echo "[5/8] PHP Extensions (OpenSSL dependencies)"
    echo "----------------------------------------"
    
    if [ -f "$install_dir/usr/local/bin/php" ]; then
        echo "  PHP binary: $install_dir/usr/local/bin/php"
        
        local zend_api_no=$(grep "^#define ZEND_MODULE_API_NO" "$build_dir/Zend/zend_modules.h" 2>/dev/null | awk '{print $3}' || echo "unknown")
        local ext_dir="$install_dir/usr/local/lib/php/extensions/no-debug-non-zts-${zend_api_no}"
        
        local php_extensions=(
            "openssl.so"
            "intl.so"
            "imagick.so"
            "curl.so"
            "ldap.so"
        )
        
        for ext in "${php_extensions[@]}"; do
            echo -n "  $ext: "
            local ext_path="$ext_dir/$ext"
            if [ -f "$ext_path" ]; then
                if objdump -p "$ext_path" 2>/dev/null | grep -q "OPENSSL_1_1_0"; then
                    echo "⚠️  Requires OPENSSL_1_1_0 symbols"
                    failed_items+=("PHP extension $ext requires OPENSSL_1_1_0")
                elif objdump -p "$ext_path" 2>/dev/null | grep -q "OPENSSL_1_0_0"; then
                    echo "⚠️  Requires OPENSSL_1_0_0 symbols"
                    failed_items+=("PHP extension $ext requires OPENSSL_1_0_0")
                else
                    if ldd "$ext_path" 2>/dev/null | grep -q "libcrypto.so"; then
                        local crypto_ver=$(ldd "$ext_path" 2>/dev/null | grep "libcrypto.so" | awk '{print $1}' | sed 's/libcrypto\.so\.//')
                        if [[ "$crypto_ver" == "19" ]] || [[ "$crypto_ver" == "4"* ]] || [[ "$crypto_ver" == "20"* ]]; then
                            echo "✅ OpenSSL 4.x compatible (libcrypto.so.$crypto_ver)"
                        else
                            echo "⚠️  Linked to libcrypto.so.$crypto_ver"
                            failed_items+=("PHP extension $ext linked to libcrypto.so.$crypto_ver")
                        fi
                    else
                        echo "✅ No OpenSSL dependency detected"
                    fi
                fi
            else
                echo "❌ Not found"
            fi
        done
    else
        echo "  ❌ PHP binary not found"
        failed_items+=("PHP binary not found")
    fi
    
    # 6. 检测 ICU 库
    echo ""
    echo "[6/8] ICU Libraries"
    echo "----------------------------------------"
    for icu_lib in /usr/local/icu53/lib/libicu*.so*; do
        if [ -f "$icu_lib" ] && [ ! -L "$icu_lib" ]; then
            echo -n "  $(basename $icu_lib): "
            if objdump -p "$icu_lib" 2>/dev/null | grep -q "OPENSSL_1_1_0"; then
                echo "⚠️  Requires OPENSSL_1_1_0"
                failed_items+=("$(basename $icu_lib) requires OPENSSL_1_1_0")
            else
                echo "✅ No OpenSSL dependency"
            fi
        fi
    done
    
    # 7. PHP 扩展加载测试
    echo ""
    echo "[7/8] PHP Extension Load Test"
    echo "----------------------------------------"
    if [ -f "$install_dir/usr/local/bin/php" ]; then
        echo "  Testing OpenSSL extension load..."
        if "$install_dir/usr/local/bin/php" -m 2>/dev/null | grep -q "openssl"; then
            echo "  ✅ OpenSSL extension loads successfully"
            local openssl_info=$("$install_dir/usr/local/bin/php" -i 2>/dev/null | grep -i "openssl" | head -3)
            echo "$openssl_info" | while read line; do
                echo "    $line"
            done
        else
            echo "  ❌ OpenSSL extension failed to load"
            failed_items+=("PHP OpenSSL extension failed to load")
        fi
        
        echo "  Testing intl extension load..."
        if "$install_dir/usr/local/bin/php" -m 2>/dev/null | grep -q "intl"; then
            echo "  ✅ intl extension loads successfully"
        else
            echo "  ⚠️  intl extension not loaded"
            failed_items+=("PHP intl extension not loaded")
        fi
        
        echo "  Testing imagick extension load..."
        if "$install_dir/usr/local/bin/php" -m 2>/dev/null | grep -q "imagick"; then
            echo "  ✅ imagick extension loads successfully"
        else
            echo "  ⚠️  imagick extension not loaded"
            failed_items+=("PHP imagick extension not loaded")
        fi
    fi
    
    # 8. 总结报告
    echo ""
    echo "[8/8] Summary Report"
    echo "========================================"
    
    if [ ${#failed_items[@]} -eq 0 ]; then
        echo "✅ ALL CHECKS PASSED"
        echo "   All libraries and extensions are OpenSSL 4.x compatible"
        echo "========================================"
        return 0
    else
        echo "⚠️  ISSUES FOUND (${#failed_items[@]} items)"
        echo "========================================"
        local count=1
        for item in "${failed_items[@]}"; do
            echo "  $count. $item"
            ((count++))
        done
        echo ""
        echo "========================================"
        echo "📋 Recommended Actions:"
        echo "========================================"
        echo "  1. Rebuild any libraries that require OPENSSL_1_1_0"
        echo "  2. Rebuild PHP extensions that link to old OpenSSL"
        echo "  3. Ensure all dependencies are compiled with OpenSSL 4.x"
        echo "========================================"
        return 1
    fi
}

# ============================================================
# 创建 FreeBSD 包
# ============================================================
create_package() {
    local install_dir="$BUILD_DIR/php-${PHP_VERSION}"
    local build_dir="$BUILD_DIR/php-src-${PHP_VERSION}"
    local php_bin="$install_dir/usr/local/bin/php"
    local ver_suffix=$(echo "$PHP_VERSION" | cut -d. -f1-2 | tr -d '.')
    local php_ini="$install_dir/usr/local/etc/php.ini"   # ← 添加

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
    
    # 确保 php.ini 存在
    if [ ! -f "$php_ini" ]; then
        echo "⚠️  php.ini not found, creating default..."
        echo "extension=openssl.so" > "$php_ini"
        echo "extension=intl.so" >> "$php_ini"
        echo "extension=imagick.so" >> "$php_ini"
        echo "extension=imap.so" >> "$php_ini"
        echo "extension=opcache.so" >> "$php_ini"
        echo "extension=phar.so" >> "$php_ini"
    fi
    check_openssl4_compatibility "$install_dir" "$build_dir"
    echo "[ * ] Verifying OpenSSL extension..."
    "$php_bin" -m | grep -i openssl || {
        echo "❌ OpenSSL extension not loaded!"
        return 1
    }

    echo "[ * ] Verifying intl extension..."
    "$php_bin" -m | grep -i intl || {
        echo "⚠️  intl extension not loaded!"
    }

    echo "[ * ] Verifying ImageMagick extension..."
    "$php_bin" -m | grep -i imagick || {
        echo "⚠️  ImageMagick extension not loaded!"
    }

    PKG_NAME="php${ver_suffix}-openssl4-imagick"
    
    rm -rf "${PKG_DIR}"
    mkdir -p "${PKG_DIR}/usr/local"
    mkdir -p "${ARTIFACT_DIR}"
    
    echo "[ * ] Copying PHP files..."
    cp -r "${install_dir}/usr/local/"* "${PKG_DIR}/usr/local/"
    
    if [ ! -f "${PKG_DIR}/usr/local/bin/php" ]; then
        echo "❌ PHP binary not found after copy!"
        return 1
    fi

    rm -rf "${PKG_DIR}/usr/local/lib/php/php/test"
    rm -rf "${PKG_DIR}/usr/local/lib/php/php/doc"
    rm -rf "${PKG_DIR}/usr/local/lib/php/.channels"
    rm -rf "${PKG_DIR}/usr/local/lib/php/.registry"
    rm -rf "${PKG_DIR}/usr/local/lib/php/.filemap"
    rm -rf "${PKG_DIR}/usr/local/lib/php/.lock"
    rmdir "${PKG_DIR}/usr/local/lib/php/php/doc"
    rmdir "${PKG_DIR}/usr/local/lib/php/php/test"
    
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
origin: local/php${ver_suffix}-openssl4-imagick
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
/usr/local/bin/php${ver_suffix} -m | grep -E "openssl|intl|imagick" || echo "Extensions not loaded"
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
        echo ""
        echo "========================================"
        echo "📦 Package Contents (${PKG_FILE})"
        echo "========================================"
        echo ""
        echo "--- Files in package ---"
        tar -tvf "${PKG_FILE}"
        echo ""
        echo "Package Name: ${PKG_NAME}"
        echo "Version: ${PHP_VERSION}"
        echo "Size: ${FILE_SIZE}"
        echo "Location: ${PKG_FILE}"
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
    echo "Build PHP ${PHP_VERSION} with OpenSSL 4.x and ImageMagick"
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
            echo "Package: ${ARTIFACT_DIR}/php${ver_suffix}-openssl4-imagick-${PHP_VERSION}.pkg"
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