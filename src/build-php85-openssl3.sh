#!/bin/bash
# src/build-php85-openssl4-test.sh
# Build PHP 8.5.7 with OpenSSL 4.x - NO PATCHES, TEST BUILD

set -e

# ============================================================
# 配置
# ============================================================
PHP_VERSION="8.5.7"
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
echo "NO PATCHES - Test Build"
echo "========================================"
echo "OpenSSL prefix: ${OPENSSL_PREFIX:-/usr/local}"
echo "OpenSSL version: $(/usr/local/bin/openssl version || echo 'unknown')"
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

    printf "%s\n" "${args[@]}"
}

# ============================================================
# 构建 PHP（无补丁）
# ============================================================
build_php() {
    local build_dir="$BUILD_DIR/php-src-${PHP_VERSION}"
    local install_dir="$BUILD_DIR/php-${PHP_VERSION}"

    echo ""
    echo "========================================"
    echo "[ * ] Building PHP ${PHP_VERSION} with OpenSSL 4.x"
    echo "[ * ] NO PATCHES - Testing original source"
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

    # ============================================================
    # ⚠️ 重要: 不应用任何补丁，不替换任何文件
    # ============================================================
    echo "[ * ] ⚠️  NO PATCHES will be applied"
    echo "[ * ] ⚠️  NO FILE REPLACEMENTS"

    # 设置编译标志（OpenSSL 4.x 路径）
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

    ./configure "${CONFIG_ARGS[@]}" > "$LOG_DIR/configure-${PHP_VERSION}.log" 2>&1
    if [ $? -ne 0 ]; then
        echo "❌ Configure failed"
        echo ""
        echo "=== Last 50 lines of configure log ==="
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
        echo "=== Compilation errors ==="
        grep -E "^.*\.[c]:[0-9]+:[0-9]+: error:" "$LOG_DIR/build-${PHP_VERSION}.log" | head -30
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

    if [ -f "$install_dir/usr/local/bin/php" ]; then
        echo "✅ PHP ${PHP_VERSION} with OpenSSL 4.x built successfully!"
        "$install_dir/usr/local/bin/php" -v
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
    PKG_NAME="php${ver_suffix}-openssl4-test"

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
origin: local/php${ver_suffix}-openssl4-test
comment: PHP ${PHP_VERSION} with OpenSSL 4.x support (NO PATCHES - TEST)
categories: [www, lang]
maintainer: build@hestiacp.com
www: https://github.com/hestiacp/hestiacp-freebsd
prefix: /usr/local
desc: <<EOD
PHP ${PHP_VERSION} compiled with OpenSSL 4.x support.

⚠️  TEST BUILD - NO PATCHES APPLIED ⚠️

This is a test build to verify if PHP 8.5.7 compiles
with OpenSSL 4.x without any patches.
EOD
EOF

    # 创建安装后脚本
    cat > "+POST_INSTALL" << 'EOF'
#!/bin/sh
echo "========================================"
echo "PHP 8.5.7 with OpenSSL 4.x installed"
echo "⚠️  TEST BUILD - NO PATCHES"
echo "========================================"
echo "Location: /usr/local"
echo "Binary:   /usr/local/bin/php85"
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
    echo "Build PHP 8.5.7 with OpenSSL 4.x"
    echo "⚠️  NO PATCHES - TEST BUILD"
    echo "========================================"
    echo "Start time: $(date)"
    echo ""

    if build_php; then
        echo ""
        echo "========================================"
        echo "✅ BUILD SUCCESSFUL (NO PATCHES!)"
        echo "========================================"
        echo ""
        echo "PHP binary: $BUILD_DIR/php-${PHP_VERSION}/usr/local/bin/php"

        if create_package; then
            echo ""
            echo "========================================"
            echo "✅ ALL COMPLETED"
            echo "========================================"
            local ver_suffix=$(echo "$PHP_VERSION" | cut -d. -f1-2 | tr -d '.')
            echo "Package: ${ARTIFACT_DIR}/php${ver_suffix}-openssl4-test-${PHP_VERSION}.pkg"
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