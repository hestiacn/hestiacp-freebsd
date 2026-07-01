#!/bin/bash
# src/build-php70-openssl4.sh
# Build PHP 7.0.33 with OpenSSL 4.x and ImageMagick and create package

set -e

# ============================================================
# 配置
# ============================================================
PHP_VERSION="7.0.33"
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
		"--with-icu-dir=/usr/local/icu56"
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
# 编译和安装 ICU 56（用于 PHP 7.0+）
# ============================================================
build_icu56() {
    local icu_prefix="/usr/local/icu56"
    
    if [ -d "$icu_prefix" ] && [ -f "$icu_prefix/lib/libicuuc.so.56.2" ]; then
        echo "[ ✓ ] ICU 56 already installed at $icu_prefix"
        return 0
    fi
    
    echo "[ * ] Building ICU 56 for PHP 7.0 compatibility..."
    rm -rf "$icu_prefix"
    
    echo "[ * ] Downloading ICU 56..."
    fetch -o /tmp/icu-56.tar.gz \
        "https://github.com/unicode-org/icu/archive/refs/tags/release-56-2.tar.gz" || return 1
    tar -xf /tmp/icu-56.tar.gz -C /tmp || return 1
    
    cd /tmp/icu-release-56-2/icu4c/source || return 1
    
    make distclean || true
    
    export CC=gcc14
    export CXX=g++14
    
    echo "[ * ] Configuring ICU 56..."
    ./configure \
        --prefix="$icu_prefix" \
        --enable-shared=yes \
        --enable-static=yes \
        --disable-debug \
        --enable-release \
        --with-library-bits=64 \
        CFLAGS="-O2 -pipe -fstack-protector-strong -fno-strict-aliasing" \
        CXXFLAGS="-O2 -pipe -fstack-protector-strong -fno-strict-aliasing -std=c++11" \
        LDFLAGS="-lpthread -lm"
    
    if [ $? -ne 0 ]; then
        echo "❌ ICU configure failed"
        tail -50 config.log
        return 1
    fi
    
    echo "[ * ] Building ICU 56 (this may take a while)..."
    mkdir -p ../lib
    
    if ! gmake -j"$NUM_CPUS" 2>&1 | tee /tmp/icu56-build.log; then
        echo "❌ ICU build failed"
        tail -50 /tmp/icu56-build.log
        return 1
    fi
    
    echo "[ * ] Installing ICU 56..."
    if ! gmake install 2>&1 | tee /tmp/icu56-install.log; then
        echo "❌ ICU install failed"
        tail -50 /tmp/icu56-install.log
        return 1
    fi
    
    # 创建符号链接
    echo "[ * ] Creating ICU 56 library symlinks..."
    cd "$icu_prefix/lib"
    for lib in libicuuc libicui18n libicudata libicuio; do
        if [ -f "${lib}.so.56.2" ]; then
            [ ! -f "${lib}.so" ] && ln -sf "${lib}.so.56.2" "${lib}.so"
            [ ! -f "${lib}.so.56" ] && ln -sf "${lib}.so.56.2" "${lib}.so.56"
            echo "  ✓ Created ${lib} links"
        fi
    done
    cd -
    
    # 创建 icu-config（ICU 56 可能已生成，如果没有则手动创建）
    if [ ! -f "$icu_prefix/bin/icu-config" ]; then
        echo "[ * ] Creating icu-config wrapper for ICU 56..."
        cat > "$icu_prefix/bin/icu-config" << 'EOF'
#!/bin/sh
prefix=/usr/local/icu56
exec_prefix=${prefix}
libdir=${exec_prefix}/lib
includedir=${prefix}/include
version=56.2

case "$1" in
    --version)
        echo "$version"
        ;;
    --cc)
        echo "gcc14"
        ;;
    --cxx)
        echo "g++14"
        ;;
    --cppflags|--cflags)
        echo "-I${includedir}"
        ;;
    --ldflags|--ldflags-libsonly)
        echo "-L${libdir} -Wl,-rpath,${libdir}"
        ;;
    --libs)
        echo "-L${libdir} -licui18n -licuuc -licudata"
        ;;
    --libs-icuio)
        echo "-L${libdir} -licuio -licui18n -licuuc -licudata"
        ;;
    *)
        echo "ICU ${version}"
        ;;
esac
EOF
        chmod +x "$icu_prefix/bin/icu-config"
        echo "[ ✓ ] icu-config wrapper created"
    fi
    
    # 验证
    echo "[ * ] Verifying ICU 56 installation..."
    if [ -f "$icu_prefix/bin/icu-config" ]; then
        echo "  Version: $($icu_prefix/bin/icu-config --version || echo '56.2')"
    fi
    
    cd /
    rm -rf /tmp/icu-release-56-2 /tmp/icu-56.tar.gz
    
    echo "[ ✓ ] ICU 56 installed successfully"
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

	# 补丁4: dom_iterators.c xmlHashScanner const 限定符
	if [ -f "ext/dom/dom_iterators.c" ]; then
		sed -i '' 's/static void itemHashScanner (void \*payload, void \*data, xmlChar \*name)/static void itemHashScanner (void *payload, void *data, const xmlChar *name)/' ext/dom/dom_iterators.c
		echo "[ ✓ ] Patch 4: dom_iterators.c xmlHashScanner const qualifier added"
	fi

	# 补丁5: 更新 config.sub
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

	# 补丁6: 更新版权年份
	if [ -f "./main/main.c" ] && [ -f "./Zend/zend.c" ]; then
		echo "[ * ] Updating copyright year to 2018..."
		find ./main ./Zend ./ext ./sapi ./TSRM -type f \( -name "*.c" -o -name "*.h" \) \
			-exec sed -i '' 's/| Copyright (c) [0-9]\{4\}-[0-9]\{4\} The PHP Group.*/| Copyright (c) 1997-2018 The PHP Group                                |/' {} \;
		find ./main ./Zend ./ext ./sapi ./TSRM -type f \( -name "*.c" -o -name "*.h" \) \
			-exec sed -i '' 's/| Copyright (c) The PHP Group.*/| Copyright (c) 1997-2018 The PHP Group                                |/' {} \;
		find ./main ./Zend ./ext ./sapi ./TSRM -type f \( -name "*.c" -o -name "*.h" \) \
			-exec sed -i '' 's/| Copyright (c) [0-9]\{4\}-[0-9]\{4\} Zend Technologies.*/| Copyright (c) 1998-2018 Zend Technologies Ltd. (http:\/\/www.zend.com) |/' {} \;
		find ./main ./Zend ./ext ./sapi ./TSRM -type f \( -name "*.c" -o -name "*.h" \) \
			-exec sed -i '' 's/| Copyright (c) Zend Technologies.*/| Copyright (c) 1998-2018 Zend Technologies Ltd. (http:\/\/www.zend.com) |/' {} \;
		for file in sapi/cli/php_cli.c sapi/fpm/fpm/fpm_main.c sapi/cgi/cgi_main.c sapi/litespeed/lsapi_main.c sapi/phpdbg/phpdbg.c; do
		if [ -f "$file" ]; then
			sed -i '' 's/Copyright (c) [0-9]\{4\}-[0-9]\{4\} The PHP Group/Copyright (c) 1997-2018 The PHP Group/g' "$file"
			sed -i '' 's/Copyright (c) The PHP Group/Copyright (c) 1997-2018 The PHP Group/g' "$file"
		fi
		done
		sed -i '' 's/#define ZEND_CORE_VERSION_INFO.*"Zend Engine v" ZEND_VERSION ", Copyright (c) [0-9]\{4\}-[0-9]\{4\} Zend Technologies\\n".*/#define ZEND_CORE_VERSION_INFO\t"Zend Engine v" ZEND_VERSION ", Copyright (c) 1998-2018 Zend Technologies\\n"/' ./Zend/zend.c
		sed -i '' 's/#define ZEND_CORE_VERSION_INFO.*"Zend Engine v" ZEND_VERSION ", Copyright (c) Zend Technologies\\n".*/#define ZEND_CORE_VERSION_INFO\t"Zend Engine v" ZEND_VERSION ", Copyright (c) 1998-2018 Zend Technologies\\n"/' ./Zend/zend.c
		echo "[ ✓ ] Copyright updated to 2018"
        grep "Copyright" ./main/main.c || true
        grep "Copyright" ./Zend/zend.c || true
    fi

	# 补丁7: 修复 intl 头文件中的 UnicodeString 命名空间问题
	if [ -f "ext/intl/intl_convertcpp.h" ]; then
		if ! grep -q "using namespace icu;" ext/intl/intl_convertcpp.h; then
			sed -i '' '/#include <unicode\/unistr.h>/a\
\
using namespace icu;
			' ext/intl/intl_convertcpp.h
			echo "[ ✓ ] Patch 7: Added 'using namespace icu;' to intl_convertcpp.h"
		fi
	fi

	# 补丁8: 修复 intl 文件中 TRUE/FALSE 未定义问题
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

	# 补丁9: 使用预修改的 OpenSSL 源文件
	local custom_openssl_dir="$SCRIPT_DIR/php7.0"
	if [ -d "$custom_openssl_dir" ]; then
		echo "[ * ] Using pre-modified OpenSSL 4.x source files..."
		
		if [ -f "$custom_openssl_dir/openssl.c" ]; then
			cp "$custom_openssl_dir/openssl.c" "ext/openssl/openssl.c"
			echo "[ ✓ ] Replaced ext/openssl/openssl.c with OpenSSL 4.x compatible version"
		else
			echo "⚠️  openssl.c not found in $custom_openssl_dir"
		fi
		
		if [ -f "$custom_openssl_dir/xp_ssl.c" ]; then
			cp "$custom_openssl_dir/xp_ssl.c" "ext/openssl/xp_ssl.c"
			echo "[ ✓ ] Replaced ext/openssl/xp_ssl.c with OpenSSL 4.x compatible version"
		else
			echo "⚠️  xp_ssl.c not found in $custom_openssl_dir"
		fi
		
		echo "[ ✓ ] OpenSSL 4.x source files replaced"
	else
		echo "⚠️  Custom OpenSSL directory not found: $custom_openssl_dir"
		echo "    Skipping OpenSSL source replacement"
	fi
    
    # 补丁10: 修复 readdir_r 函数
    if [ -f "main/reentrancy.c" ]; then
        echo "[ * ] Fixing readdir_r for FreeBSD 14..."
        sed -i '' 's/readdir_r(dirp, entry);/readdir_r(dirp, entry, \&entry);/' main/reentrancy.c
        echo "[ ✓ ] Fixed readdir_r in reentrancy.c"
    fi

    # 补丁11: 修复 intl 扩展的 ICU 命名空间问题
    echo "[ * ] Fixing ICU namespace in intl extension..."
    
    # 11a: 修复 calendar_class.h
    if [ -f "ext/intl/calendar/calendar_class.h" ]; then
        sed -i '' 's/icu::Calendar\*/void*/g' ext/intl/calendar/calendar_class.h
        sed -i '' 's/icu::TimeZone\*/void*/g' ext/intl/calendar/calendar_class.h
        sed -i '' '/^using namespace icu;/d' ext/intl/calendar/calendar_class.h
        echo "[ ✓ ] Fixed calendar_class.h"
    fi
    
    # 11b: 修复所有 intl 源文件
    for file in $(find ext/intl -type f \( -name "*.c" -o -name "*.cpp" -o -name "*.h" \)); do
        if [ -f "$file" ]; then
            sed -i '' 's/icu::Calendar\*/void*/g' "$file"
            sed -i '' 's/icu::TimeZone\*/void*/g' "$file"
            sed -i '' 's/icu::StringEnumeration\*/void*/g' "$file"
            sed -i '' 's/icu::/void /g' "$file" || true
            sed -i '' '/^using namespace icu;/d' "$file"
        fi
    done
    echo "[ ✓ ] ICU namespace fixes applied"

    # 补丁12: 修复 grapheme_util.h 的内联函数声明
    if [ -f "ext/intl/grapheme/grapheme_util.h" ]; then
        echo "[ * ] Fixing grapheme_util.h..."
        cat >> "ext/intl/grapheme/grapheme_util.h" << 'EOF'

/* Workaround for missing grapheme_memrchr_grapheme implementation */
static inline void *grapheme_memrchr_grapheme(const void *s, int c, int32_t n) {
    const unsigned char *p = (const unsigned char *)s;
    const unsigned char *end = p + n;
    while (end > p) {
        end--;
        if (*end == (unsigned char)c) {
            return (void *)end;
        }
    }
    return NULL;
}
EOF
        echo "[ ✓ ] Fixed grapheme_util.h"
    fi

    # 补丁13: 修复 soap 扩展中的 const 警告
    if [ -f "ext/soap/php_sdl.c" ]; then
        sed -i '' 's/xmlErrorPtr xmlErrorPtr = xmlGetLastError();/const xmlError *xmlErrorPtr = xmlGetLastError();/' ext/soap/php_sdl.c
        echo "[ ✓ ] Fixed soap const warning"
    fi
	
	# 补丁14: 修复 main/streams/cast.c 中的函数指针类型
    if [ -f "main/streams/cast.c" ]; then
        echo "[ * ] Fixing stream_cookie_seeker for FreeBSD 14..."
        cp main/streams/cast.c main/streams/cast.c.bak
        perl -pi -e 's/static int stream_cookie_seeker\(void \*cookie, zend_off_t position, int whence\)/static int stream_cookie_seeker(void *cookie, off64_t *position, int whence)/' main/streams/cast.c
        perl -pi -e 's/return php_stream_seek\(\(php_stream \*\)cookie, position, whence\);/return php_stream_seek((php_stream *)cookie, *position, whence);/' main/streams/cast.c
        if grep -q "off64_t \*position" main/streams/cast.c; then
            echo "[ ✓ ] Fixed stream_cookie_seeker in cast.c"
        else
            echo "⚠️  Patch may not have applied correctly"
            mv main/streams/cast.c.bak main/streams/cast.c
            return 1
        fi
        rm -f main/streams/cast.c.bak
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
    
    # 设置环境变量
    export PHP_PREFIX="$php_prefix"
    export PHP_CONFIG="$php_config"
    export PHPIZE="$phpize"
    export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:$PKG_CONFIG_PATH"
    export CFLAGS="-I/usr/local/include $CFLAGS"
    export LDFLAGS="-L/usr/local/lib $LDFLAGS"
    
    # 创建必要的符号链接
    if [ -d "$php_prefix/lib/php/build" ] && [ ! -d "/usr/local/lib/php/build" ]; then
        mkdir -p /usr/local/lib/php
        ln -sf "$php_prefix/lib/php/build" /usr/local/lib/php/build
    fi
    
    if [ -d "$php_prefix/include/php" ] && [ ! -L "/usr/local/include/php" ]; then
        mkdir -p /usr/local/include
        rm -f /usr/local/include/php
        ln -sf "$php_prefix/include/php" /usr/local/include/php
    fi
    
    # 创建 php -> . 的软链接（解决路径问题）
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
    
    # 获取扩展目录
    local zend_api_no=$(grep "^#define ZEND_MODULE_API_NO" "$build_dir/Zend/zend_modules.h" | awk '{print $3}')
    local ext_dir="$install_dir/usr/local/lib/php/extensions/no-debug-non-zts-${zend_api_no}"
    
    # 验证安装
    if [ -f "$ext_dir/imagick.so" ]; then
        echo "[ ✓ ] ImageMagick extension installed to $ext_dir/imagick.so"
        
        # 创建 php.ini 启用 imagick
        local php_ini_dir="$install_dir/usr/local/etc"
        mkdir -p "$php_ini_dir"
        if [ -f "$php_ini_dir/php.ini" ]; then
            if ! grep -q "^extension=imagick.so" "$php_ini_dir/php.ini"; then
                echo "extension=imagick.so" >> "$php_ini_dir/php.ini"
                echo "[ ✓ ] ImageMagick extension enabled in php.ini"
            else
                echo "[ ✓ ] ImageMagick already enabled in php.ini"
            fi
        else
            echo "extension=imagick.so" > "$php_ini_dir/php.ini"
            echo "[ ✓ ] Created php.ini with ImageMagick extension"
        fi
    else
        echo "⚠️  ImageMagick extension not found in expected location"
        find "$install_dir" -name "imagick.so" || echo "  Not found anywhere"
    fi
    
    cd - > /dev/null
    echo "[ ✓ ] ImageMagick extension build complete"
    return 0
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

	# 下载 ImageMagick 扩展
	if ! download_imagick "$build_dir"; then
		echo "⚠️  ImageMagick extension download failed, continuing without it"
	fi

	cd "$build_dir" || return 1
	
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
	# PHP 7.0 特殊处理：使用 ICU 56
	# ============================================================
	if [ "$major" = "7" ] && [ "$PHP_VERSION" = "7.0.33" ]; then
		# 编译 ICU 56
		if ! build_icu56; then
			echo "❌ Failed to build ICU 56"
			return 1
		fi
		
		cd "$build_dir" || {
			echo "❌ Failed to return to PHP source directory"
			return 1
		}
		echo "[ * ] Current directory: $(pwd)"
		
		if [ ! -f "/usr/local/icu56/bin/icu-config" ]; then
			echo "❌ icu-config not found at /usr/local/icu56/bin/icu-config"
			return 1
		fi
		echo "[ ✓ ] icu-config found"
		
		export PATH="/usr/local/icu56/bin:$PATH"
		
		export CFLAGS="-I/usr/local/icu56/include -I/usr/local/include \
			-Wno-deprecated-declarations \
			-Wno-incompatible-pointer-types-discards-qualifiers \
			-Wno-implicit-function-declaration \
			-Wno-pointer-sign"
		export CXXFLAGS="-std=c++11 -Wno-register -Wno-deprecated-declarations -fpermissive"
		export LDFLAGS="-L/usr/local/icu56/lib -L/usr/local/lib -Wl,-rpath,/usr/local/icu56/lib -Wl,-rpath,/usr/local/lib"
		export CPPFLAGS="-I/usr/local/icu56/include -I/usr/local/include"
		export ICU_CONFIG="/usr/local/icu56/bin/icu-config"
		export ICU_PREFIX="/usr/local/icu56"
		export ICU_CFLAGS="-I/usr/local/icu56/include"
		export ICU_LIBS="-L/usr/local/icu56/lib -licui18n -licuuc -licudata"
		
		echo "[ ✓ ] ICU config version: $(icu-config --version || echo '56.2')"
	fi
	
	# ============================================================
	# 设置编译环境（包括 OpenSSL 4.x 修复）
	# ============================================================
	export CC=gcc14
	export CXX=g++14
	export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:/usr/local/libdata/pkgconfig:/usr/lib/pkgconfig"
	
	# 设置 OpenSSL 4.x 环境变量（修复 phar 生成时的段错误）
	echo "[ * ] Setting OpenSSL 4.x environment..."
	export LD_PRELOAD="/usr/local/lib/libssl.so.30:/usr/local/lib/libcrypto.so.30"
	export LD_LIBRARY_PATH="/usr/local/icu56/lib:/usr/local/lib:/usr/lib"
	echo "[ ✓ ] OpenSSL 4.x environment set"
	
	find . -name "config.cache" -delete
	
	# ============================================================
	# 配置 PHP
	# ============================================================
	echo "[ * ] Configuring PHP ${PHP_VERSION}..."
	echo "OpenSSL prefix: ${OPENSSL_PREFIX:-/usr/local}"
	echo "CFLAGS: $CFLAGS"
	echo "LDFLAGS: $LDFLAGS"

	mapfile -t CONFIG_ARGS < <(get_config_args)
	echo "Config args: ${CONFIG_ARGS[*]}"

	./configure \
		"${CONFIG_ARGS[@]}" \
		--with-icu-dir=/usr/local/icu56 \
		ICU_CFLAGS="-I/usr/local/icu56/include" \
		ICU_LIBS="-L/usr/local/icu56/lib -licui18n -licuuc -licudata" \
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
		
		# 强制使用 ICU 56 库的完整路径
		echo "[ * ] Forcing ICU 56 library paths..."
		sed -i '' 's|-licuio|/usr/local/icu56/lib/libicuio.so.56.2|g' Makefile
		sed -i '' 's|-licui18n|/usr/local/icu56/lib/libicui18n.so.56.2|g' Makefile
		sed -i '' 's|-licuuc|/usr/local/icu56/lib/libicuuc.so.56.2|g' Makefile
		sed -i '' 's|-licudata|/usr/local/icu56/lib/libicudata.so.56.2|g' Makefile

		# 添加 ICU 56 库路径
		if ! grep -q "/usr/local/icu56/lib" Makefile; then
			sed -i '' 's|^LDFLAGS = \(.*\)$|LDFLAGS = -L/usr/local/icu56/lib \1|' Makefile
			sed -i '' 's|^LDFLAGS = \(.*\)$|LDFLAGS = \1 -Wl,-rpath,/usr/local/icu56/lib|' Makefile
		fi
		
		echo "[ ✓ ] Makefile updated to use ICU 56"
	fi
	
	echo "[ * ] Fixing zend_sprintf linkage issue..."
	if [ -f "main/php_config.h" ]; then
		sed -i '' 's/^int zend_sprintf(/\/\/ int zend_sprintf(/' main/php_config.h
		echo "[ ✓ ] Fixed zend_sprintf in php_config.h"
	fi

	# ============================================================
	# 确保 phar.phar 存在（源码包中默认没有此文件）
	# ============================================================
	echo "[ * ] Ensuring phar.phar exists..."
	if [ -f "ext/phar/phar.phar" ]; then
		echo "[ ✓ ] phar.phar exists"
	else
		echo "[ * ] Creating phar.phar placeholder..."
		echo "<?php __HALT_COMPILER(); ?>" > "ext/phar/phar.phar"
		chmod 444 "ext/phar/phar.phar"
		echo "[ ✓ ] phar.phar placeholder created"
	fi

	# ============================================================
	# 编译 PHP
	# ============================================================
	echo "[ * ] Compiling PHP ${PHP_VERSION} (using ${NUM_CPUS} cores)..."
	gmake -j "$NUM_CPUS" > "$LOG_DIR/build-${PHP_VERSION}.log"

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
		if gmake -j1 >> "$LOG_DIR/build-${PHP_VERSION}.log"; then
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

	# ============================================================
	# 编译 ImageMagick 扩展
	# ============================================================
	if ! build_imagick "$build_dir" "$install_dir"; then
		echo "⚠️  ImageMagick extension build failed"
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

	echo "[ * ] Verifying ImageMagick extension..."
	"$php_bin" -m | grep -i imagick || {
		echo "⚠️  ImageMagick extension not loaded!"
	}

	PKG_NAME="php${ver_suffix}-openssl4-icu56"
	
	rm -rf "${PKG_DIR}"
	mkdir -p "${PKG_DIR}/usr/local"
	mkdir -p "${ARTIFACT_DIR}"
	
	echo "[ * ] Copying PHP files..."
	cp -r "${install_dir}/usr/local/"* "${PKG_DIR}/usr/local/"
	
	if [ ! -f "${PKG_DIR}/usr/local/bin/php" ]; then
		echo "❌ PHP binary not found after copy!"
		return 1
	fi
	
	echo "[ * ] Copying ICU 56 libraries..."
	mkdir -p "${PKG_DIR}/usr/local/icu56/lib"
	if [ -d "/usr/local/icu56/lib" ]; then
		cp -r /usr/local/icu56/lib/libicu*.so* "${PKG_DIR}/usr/local/icu56/lib/" || true
	fi
	
	echo "[ * ] Creating file list..."
	cd "${PKG_DIR}"
	find . -type f | sed 's|^\.||' > +PLIST
	
	echo "[ * ] Creating package metadata..."
	cat > "+MANIFEST" << EOF
name: ${PKG_NAME}
version: ${PHP_VERSION}
origin: local/php${ver_suffix}-openssl4-icu56
comment: PHP ${PHP_VERSION} with OpenSSL 4.x, ICU 56 and ImageMagick support
categories: [www, lang]
maintainer: build@hestiacp.com
www: https://github.com/hestiacp/hestiacp-freebsd
prefix: /usr/local
desc: <<EOD
PHP ${PHP_VERSION} compiled with OpenSSL 4.x support.

This is a custom build of PHP 7.0.33 that includes:
- OpenSSL 4.x compatibility patches
- ImageMagick extension (imagick)
- intl extension with ICU 56 (C++11 compatible)
- FPM, CLI, CGI support
- Common extensions: mbstring, bcmath, curl, gmp, mysqli, pdo_mysql, pgsql, pdo_pgsql, etc.
- GD with JPEG, PNG, FreeType support

IMPORTANT: PHP 7.0 is end-of-life. Use at your own risk.
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
			echo "Package: ${ARTIFACT_DIR}/php${ver_suffix}-openssl4-icu56-${PHP_VERSION}.pkg"
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