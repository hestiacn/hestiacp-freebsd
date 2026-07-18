#!/bin/bash
# src/build-php84-openssl3.sh
# Build PHP 8.4.8 with OpenSSL 3.x and create package

set -e

# ============================================================
# 配置
# ============================================================
PHP_VERSION="8.4.8"
BUILD_DIR="/tmp/php-build-test"
ARCHIVE_DIR="$BUILD_DIR/archive"
PKG_DIR="$BUILD_DIR/pkg"
LOG_DIR="$BUILD_DIR/logs"
ARTIFACT_DIR="${ARTIFACT_DIR:-/home/runner/work/hestiacp-freebsd/hestiacp-freebsd/artifacts}"
NUM_CPUS=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 创建所有需要的目录
mkdir -p "$BUILD_DIR" "$ARCHIVE_DIR" "$LOG_DIR" "$PKG_DIR" "$ARTIFACT_DIR"

echo "========================================"
echo "Build PHP ${PHP_VERSION} with OpenSSL 3.x"
echo "========================================"
echo "OpenSSL prefix: ${OPENSSL_PREFIX:-/usr}"
echo "OpenSSL version: $(openssl version 2>/dev/null || echo 'unknown')"
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
# 获取配置参数
# ============================================================
get_config_args() {
    local args=(
        "--prefix=/usr/local/hestia/php"
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
        "--enable-shared=no"
        "--disable-shared"
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
        "--with-openssl=${OPENSSL_PREFIX:-/usr}"
        "--disable-dom"
        "--disable-xmlreader"
        "--disable-xmlwriter"
        "--disable-simplexml"
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

    # 补丁4: 修复 zlib 函数指针类型不匹配（保留逗号）
    if [ -f "ext/zlib/zlib.c" ]; then
        if grep -q "ZEND_MODULE_GLOBALS_CTOR_N(zlib)" ext/zlib/zlib.c 2>/dev/null; then
            sed -i '' 's/ZEND_MODULE_GLOBALS_CTOR_N(zlib),/NULL,/' ext/zlib/zlib.c
            echo "[ ✓ ] Patch 4: zlib.c globals_ctor set to NULL"
        fi
    fi

    # ============================================================
    # 补丁5: 替换 OpenSSL 源文件（使用预修改的文件）
    # ============================================================
    local custom_openssl_dir="$SCRIPT_DIR/php8.4"
    if [ -d "$custom_openssl_dir" ]; then
        echo "[ * ] Using pre-modified OpenSSL source files..."
        
        if [ -f "$custom_openssl_dir/openssl.c" ]; then
            cp "$custom_openssl_dir/openssl.c" "ext/openssl/openssl.c"
            echo "[ ✓ ] Replaced ext/openssl/openssl.c with pre-modified version"
        else
            echo "⚠️  openssl.c not found in $custom_openssl_dir"
        fi
        
        if [ -f "$custom_openssl_dir/xp_ssl.c" ]; then
            cp "$custom_openssl_dir/xp_ssl.c" "ext/openssl/xp_ssl.c"
            echo "[ ✓ ] Replaced ext/openssl/xp_ssl.c with pre-modified version"
        else
            echo "⚠️  xp_ssl.c not found in $custom_openssl_dir"
        fi
        
        echo "[ ✓ ] OpenSSL source files replaced"
    else
        echo "⚠️  Custom OpenSSL directory not found: $custom_openssl_dir"
        echo "    Skipping OpenSSL source replacement"
    fi

    # ============================================================
    # 补丁6: 强制使用内置 xxHash（避免系统头文件冲突）
    # ============================================================
    if [ -f "ext/hash/hash_xxhash.c" ]; then
        if grep -q '#include <xxhash.h>' ext/hash/hash_xxhash.c 2>/dev/null; then
            sed -i '' 's|#include <xxhash.h>|#include "xxhash.h"|' ext/hash/hash_xxhash.c
            echo "[ ✓ ] hash_xxhash.c now uses bundled xxHash"
        fi
        
        if grep -q 'ctx->s.memsize < 16' ext/hash/hash_xxhash.c 2>/dev/null; then
            sed -i '' 's/&& ctx->s.memsize < 16)/\&\& 1)/' ext/hash/hash_xxhash.c
            sed -i '' 's/&& ctx->s.memsize < 32)/\&\& 1)/' ext/hash/hash_xxhash.c
            echo "[ ✓ ] xxHash memsize checks disabled"
        fi
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
    echo "[ * ] Building PHP ${PHP_VERSION} with OpenSSL 3.x"
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

    [ -f "Makefile" ] && gmake clean 2>/dev/null || true

    if [ -f "buildconf" ]; then
        echo "[ * ] Running buildconf..."
        ./buildconf --force | tee "$LOG_DIR/buildconf-${PHP_VERSION}.log"
    fi

    apply_patches "$build_dir"

    # 设置编译标志（抑制警告）
    export CFLAGS="-I/usr/include -I/usr/local/include \
        -Wno-deprecated-declarations \
        -Wno-incompatible-pointer-types-discards-qualifiers \
        -Wno-pointer-bool-conversion \
        -Wno-implicit-function-declaration \
        -Wno-pointer-sign \
        -Wno-implicit-const-int-float-conversion"
    export LDFLAGS="-L/usr/lib -L/usr/local/lib"
    export PKG_CONFIG_PATH="$PKG_CONFIG_PATH"
    export CPPFLAGS="$CFLAGS"
    export LD_LIBRARY_PATH="${OPENSSL_PREFIX:-/usr}/lib"

    echo "[ * ] Configuring PHP ${PHP_VERSION}..."
    echo "OpenSSL prefix: ${OPENSSL_PREFIX:-/usr}"
    echo "CFLAGS: $CFLAGS"
    echo "LDFLAGS: $LDFLAGS"

    mapfile -t CONFIG_ARGS < <(get_config_args)
    echo "Config args: ${CONFIG_ARGS[*]}"

    ./configure "${CONFIG_ARGS[@]}" > "$LOG_DIR/configure-${PHP_VERSION}.log" 2>&1
    if [ $? -ne 0 ]; then
        echo "❌ Configure failed"
        tail -50 "$LOG_DIR/configure-${PHP_VERSION}.log"
        return 1
    fi

    echo "[ * ] Compiling PHP ${PHP_VERSION} (using ${NUM_CPUS} cores)..."
    gmake -j "$NUM_CPUS" > "$LOG_DIR/build-${PHP_VERSION}.log" 2>&1

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
    gmake install INSTALL_ROOT="$install_dir" > "$LOG_DIR/install-${PHP_VERSION}.log" 2>&1
    if [ $? -ne 0 ]; then
        echo "❌ Install failed"
        tail -50 "$LOG_DIR/install-${PHP_VERSION}.log"
        return 1
    fi

    if [ -f "$install_dir/usr/local/hestia/php/bin/php" ]; then
        echo "✅ PHP ${PHP_VERSION} with OpenSSL 3.x built successfully!"
        "$install_dir/usr/local/hestia/php/bin/php" -v
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
    local php_bin="$install_dir/usr/local/hestia/php/bin/php"
    
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
    PKG_NAME="php84-openssl3"
    
    rm -rf "${PKG_DIR}"
    mkdir -p "${PKG_DIR}/usr/local/hestia"
    mkdir -p "${ARTIFACT_DIR}"
    
    echo "[ * ] Copying PHP files to ${PKG_DIR}..."
    cp -r "${install_dir}/usr/local/hestia/php" "${PKG_DIR}/usr/local/hestia/"
    
    # 验证复制
    if [ ! -f "${PKG_DIR}/usr/local/hestia/php/bin/php" ]; then
        echo "❌ PHP binary not found after copy!"
        return 1
    fi
    
    # 创建 PLIST（列出所有文件）
    echo "[ * ] Creating file list..."
    cd "${PKG_DIR}"
    find . -type f | sed 's|^\.||' > +PLIST
    
    # 创建 MANIFEST
    echo "[ * ] Creating package metadata..."
    cat > "+MANIFEST" << EOF
name: ${PKG_NAME}
version: ${PHP_VERSION}
origin: local/php84-openssl3
comment: PHP ${PHP_VERSION} with OpenSSL 3.x support
categories: [www, lang]
maintainer: build@hestiacp.com
www: https://github.com/hestiacp/hestiacp-freebsd
prefix: /usr/local
desc: <<EOD
PHP ${PHP_VERSION} compiled with OpenSSL 3.x support.

This is a custom build of PHP 8.4.8 that includes:
- OpenSSL 3.x compatibility patches
- FPM, CLI, CGI support
- Common extensions: mbstring, bcmath, curl, gmp, mysqli, pdo_mysql, pgsql, pdo_pgsql, etc.
- JIT support

IMPORTANT: PHP 8.4 is the latest stable version.
EOD
EOF
    
    # 创建安装后脚本
    cat > "+POST_INSTALL" << 'EOF'
#!/bin/sh
echo "========================================"
echo "PHP 8.4.8 with OpenSSL 3.x installed"
echo "========================================"
echo "Location: /usr/local/hestia/php"
echo "Binary:   /usr/local/hestia/php/bin/php"
echo ""
echo "To add to PATH:"
echo "  export PATH=/usr/local/hestia/php/bin:\$PATH"
echo "========================================"
EOF
    chmod +x "+POST_INSTALL"
    
    # 创建包（使用正确的参数）
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
        pkg info -l "${PKG_FILE}" 2>/dev/null || tar -tf "${PKG_FILE}" 2>/dev/null || {
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
    echo "Build PHP 8.4.8 with OpenSSL 3.x"
    echo "========================================"
    echo "Start time: $(date)"
    echo ""

    if build_php; then
        echo ""
        echo "========================================"
        echo "✅ BUILD SUCCESSFUL"
        echo "========================================"
        echo ""
        echo "PHP binary: $BUILD_DIR/php-${PHP_VERSION}/usr/local/hestia/php/bin/php"
        
        # 创建包
        if create_package; then
            echo ""
            echo "========================================"
            echo "✅ ALL COMPLETED"
            echo "========================================"
            echo "Package: ${ARTIFACT_DIR}/php84-openssl3-${PHP_VERSION}.pkg"
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