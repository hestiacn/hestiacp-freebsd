#!/bin/bash
# src/test-php72-openssl4.sh
# TEST: PHP 7.2.34 with OpenSSL 4.0.1

set -e

# ============================================================
# 配置
# ============================================================
PHP_VERSION="7.2.34"
BUILD_DIR="/tmp/php-build-test"
ARCHIVE_DIR="$BUILD_DIR/archive"
LOG_DIR="$BUILD_DIR/logs"
NUM_CPUS=$(sysctl -n hw.ncpu || echo 4)
ARTIFACT_DIR="${ARTIFACT_DIR:-/home/runner/work/hestiacp-freebsd/hestiacp-freebsd/artifacts-test}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# OpenSSL 4.0.1 路径
OPENSSL40_PREFIX="/usr/local"
OPENSSL40_INCLUDE="${OPENSSL40_PREFIX}/include/openssl"
OPENSSL40_LIB="${OPENSSL40_PREFIX}/lib"

mkdir -p "$BUILD_DIR" "$ARCHIVE_DIR" "$LOG_DIR" "$ARTIFACT_DIR"

echo "========================================"
echo "TEST: PHP ${PHP_VERSION} with OpenSSL 4.0.1"
echo "========================================"
echo "OpenSSL prefix: ${OPENSSL40_PREFIX}"
echo "OpenSSL include: ${OPENSSL40_INCLUDE}"
echo "OpenSSL lib: ${OPENSSL40_LIB}"
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
# 获取配置参数（强制使用 OpenSSL 4.0.1）
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
		"--with-openssl=${OPENSSL40_PREFIX}"
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

# ============================================================
# 扫描 OpenSSL 4.0.x 兼容性问题
# ============================================================
scan_openssl_compatibility() {
    local build_dir=$1
    local report_file="$LOG_DIR/openssl4-scan-report.txt"
    
    echo "[ * ] Scanning OpenSSL 4.0.x compatibility issues..."
    
    cd "$build_dir" || return 1
    
    if [ ! -f "ext/openssl/openssl.c" ]; then
        echo "❌ ext/openssl/openssl.c not found!"
        return 1
    fi
    
    # ============================================================
    # 1. 从 OpenSSL 4.0.x 头文件提取所有可用函数
    # ============================================================
    echo "[ * ] Extracting OpenSSL 4.0.x available functions..."
    
    local openssl_headers="${OPENSSL40_INCLUDE}"
    
    local available_functions_file="$LOG_DIR/openssl4-available-functions.txt"
    > "$available_functions_file"
    
    if [ -d "$openssl_headers" ]; then
        for header in "$openssl_headers"/*.h; do
            if [ -f "$header" ]; then
                grep -E '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]+\*?[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\([^;]*\)' "$header" | \
                    sed -E 's/.*[[:space:]]+\*?([A-Za-z_][A-Za-z0-9_]*)\(.*/\1/' >> "$available_functions_file" || true
            fi
        done
        
        sort -u "$available_functions_file" -o "$available_functions_file"
        echo "Total available functions: $(wc -l < "$available_functions_file")"
    else
        echo "⚠️  OpenSSL headers not found at $openssl_headers"
    fi
    
    # ============================================================
    # 2. 提取 PHP 7.0 openssl.c 中使用的 OpenSSL 函数
    # ============================================================
    echo "[ * ] Extracting PHP 7.0 openssl.c used functions..."
    
    local used_functions_file="$LOG_DIR/php72-used-functions.txt"
    > "$used_functions_file"
    
    if [ -f "ext/openssl/openssl.c" ]; then
        grep -oE '\b(EVP_|X509_|SSL_|RSA_|DSA_|DH_|EC_|PEM_|ASN1_|BN_|OBJ_|ERR_|CRYPTO_|OPENSSL_)[A-Za-z0-9_]*[[:space:]]*\(' \
            "ext/openssl/openssl.c" | \
            sed 's/[[:space:]]*(//' | sort -u > "$used_functions_file"
        
        if [ -f "ext/openssl/xp_ssl.c" ]; then
            grep -oE '\b(EVP_|X509_|SSL_|RSA_|DSA_|DH_|EC_|PEM_|ASN1_|BN_|OBJ_|ERR_|CRYPTO_|OPENSSL_)[A-Za-z0-9_]*[[:space:]]*\(' \
                "ext/openssl/xp_ssl.c" | \
                sed 's/[[:space:]]*(//' | sort -u >> "$used_functions_file"
        fi
        
        sort -u "$used_functions_file" -o "$used_functions_file"
        echo "Total used functions: $(wc -l < "$used_functions_file")"
    fi
    
    # ============================================================
    # 3. 对比：找出缺失的函数
    # ============================================================
    echo "[ * ] Comparing functions..."
    
    local missing_functions_file="$LOG_DIR/openssl4-missing-functions.txt"
    > "$missing_functions_file"
    
    if [ -f "$available_functions_file" ] && [ -f "$used_functions_file" ]; then
        comm -23 <(sort "$used_functions_file") <(sort "$available_functions_file") > "$missing_functions_file"
        
        local missing_count=$(wc -l < "$missing_functions_file")
        echo ""
        echo "========================================"
        echo "OpenSSL 4.0.x Compatibility Scan Report"
        echo "========================================"
        echo "PHP Version: ${PHP_VERSION}"
        echo "Available functions in OpenSSL 4.0.x: $(wc -l < "$available_functions_file")"
        echo "Used functions in PHP 7.0: $(wc -l < "$used_functions_file")"
        echo "MISSING functions (need to fix): $missing_count"
        echo "========================================"
        
        {
            echo "========================================"
            echo "OpenSSL 4.0.x Compatibility Scan Report"
            echo "========================================"
            echo "PHP Version: ${PHP_VERSION}"
            echo "Scan Date: $(date)"
            echo ""
            echo "Available functions in OpenSSL 4.0.x: $(wc -l < "$available_functions_file")"
            echo "Used functions in PHP 7.0: $(wc -l < "$used_functions_file")"
            echo "MISSING functions: $missing_count"
            echo ""
            echo "========================================"
            echo "MISSING FUNCTIONS (not found in OpenSSL 4.0.x)"
            echo "========================================"
            echo ""
            
            if [ "$missing_count" -gt 0 ]; then
                echo "These functions are used by PHP 7.0 but NOT available in OpenSSL 4.0.x:"
                echo ""
                cat "$missing_functions_file"
                echo ""
                echo "========================================"
                echo "FIX SUGGESTIONS"
                echo "========================================"
                echo ""
                
                while read -r func; do
                    case "$func" in
                        EVP_dss1)
                            echo "  $func → Replace with EVP_sha1()"
                            ;;
                        SSLv2_client_method|SSLv2_server_method)
                            echo "  $func → SSLv2 is removed, remove SSLv2 support"
                            ;;
                        RSA_generate_key|DSA_generate_key|DH_generate_key)
                            echo "  $func → Use EVP_PKEY_keygen() instead"
                            ;;
                        SSL_library_init)
                            echo "  $func → Use OPENSSL_init_ssl() instead"
                            ;;
                        OpenSSL_add_all_ciphers|OpenSSL_add_all_digests|OpenSSL_add_all_algorithms)
                            echo "  $func → Use OPENSSL_init_crypto() instead"
                            ;;
                        ERR_free_strings)
                            echo "  $func → No longer needed in OpenSSL 4.0.x"
                            ;;
                        *)
                            echo "  $func → Check OpenSSL 4.0.x documentation"
                            ;;
                    esac
                done < "$missing_functions_file"
            else
                echo "✅ No missing functions found!"
            fi
        } > "$report_file"
        
        echo ""
        echo "========================================"
        echo "Scan Summary:"
        echo "========================================"
        echo "Missing functions: $missing_count"
        echo "Full report: $report_file"
        echo "========================================"
        
        if [ "$missing_count" -gt 0 ]; then
            echo ""
            echo "Missing functions (need to fix):"
            cat "$missing_functions_file"
        fi
        
    else
        echo "❌ Cannot compare: missing function lists"
        return 1
    fi
    
    cd - > /dev/null || return 1
}

# ============================================================
# 应用补丁
# ============================================================
apply_patches() {
    local build_dir=$1
    local custom_openssl_dir="$SCRIPT_DIR/php7.2"

    cd "$build_dir" || return 1

    echo "[ * ] Applying patches for PHP ${PHP_VERSION}..."

    # 补丁1: libxml2 ATTRIBUTE_UNUSED
    if [ -f "ext/libxml/libxml.c" ]; then
        if grep -q "int compression ATTRIBUTE_UNUSED)" ext/libxml/libxml.c 2>/dev/null; then
            sed -i.bak 's/int compression ATTRIBUTE_UNUSED)/int compression)/' ext/libxml/libxml.c
            echo "[ ✓ ] Patch 1: libxml.c ATTRIBUTE_UNUSED removed"
        fi
    fi

    # 补丁2: libxml2 xmlSetStructuredErrorFunc
    if [ -f "ext/libxml/libxml.c" ]; then
        if grep -q "xmlSetStructuredErrorFunc(NULL, php_libxml_structured_error_handler);" ext/libxml/libxml.c 2>/dev/null; then
            sed -i.bak 's/xmlSetStructuredErrorFunc(NULL, php_libxml_structured_error_handler);/xmlSetStructuredErrorFunc(NULL, (xmlStructuredErrorFunc)php_libxml_structured_error_handler);/' ext/libxml/libxml.c
            echo "[ ✓ ] Patch 2: libxml.c xmlSetStructuredErrorFunc cast"
        fi
    fi

    # 补丁3: libxml2 xmlGetLastError
    if [ -f "ext/libxml/libxml.c" ]; then
        if grep -q "error = xmlGetLastError();" ext/libxml/libxml.c 2>/dev/null; then
            sed -i.bak 's/error = xmlGetLastError();/error = (xmlErrorPtr)xmlGetLastError();/' ext/libxml/libxml.c
            echo "[ ✓ ] Patch 3: libxml.c xmlGetLastError cast"
        fi
    fi
    
    # 在 apply_patches() 中，复制 openssl.c 之前或之后
    if [ -f "ext/openssl/php_openssl.h" ]; then
    sed -i '' -e '/^#define PHP_OPENSSL_H$/a\
#ifndef ERR_NUM_ERRORS\
#define ERR_NUM_ERRORS 128\
#endif
' "ext/openssl/php_openssl.h"
    echo "[ ✓ ] Added ERR_NUM_ERRORS definition to php_openssl.h"
    fi

    # ============================================================
    # 补丁5: 替换 OpenSSL 源文件（使用预修改的文件）
    # ============================================================
    echo "[ * ] Checking for pre-modified OpenSSL source files in: $custom_openssl_dir"
    
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
        
        echo "[ ✓ ] OpenSSL source files replacement complete"
    else
        echo "⚠️  Custom OpenSSL directory not found: $custom_openssl_dir"
        echo "    Skipping OpenSSL source replacement"
    fi

    # ============================================================
    # 扫描 OpenSSL 4.0.x 兼容性问题
    # ============================================================
    scan_openssl_compatibility "$build_dir"

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
    echo "[ * ] Building PHP ${PHP_VERSION} with OpenSSL 4.0.1"
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

    # 设置编译标志 - 使用 OpenSSL 4.0.1
    export CFLAGS="-I${OPENSSL40_INCLUDE} -I/usr/include -I/usr/local/include \
        -Wno-deprecated-declarations \
        -Wno-incompatible-pointer-types-discards-qualifiers \
        -Wno-pointer-bool-conversion \
        -Wno-implicit-function-declaration \
        -Wno-pointer-sign \
        -Wno-implicit-const-int-float-conversion"
    export LDFLAGS="-L${OPENSSL40_LIB} -L/usr/lib -L/usr/local/lib"
    export PKG_CONFIG_PATH="${OPENSSL40_LIB}/pkgconfig:/usr/local/lib/pkgconfig"
    export CPPFLAGS="$CFLAGS"
    export LD_LIBRARY_PATH="${OPENSSL40_LIB}:${OPENSSL_PREFIX:-/usr}/lib"

    echo "[ * ] Configuring PHP ${PHP_VERSION}..."
    echo "OpenSSL prefix: ${OPENSSL40_PREFIX}"
    echo "OpenSSL include: ${OPENSSL40_INCLUDE}"
    echo "OpenSSL lib: ${OPENSSL40_LIB}"
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
        echo "❌ BUILD FAILED - Errors to fix:"
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

    if [ -f "$install_dir/usr/local/bin/php" ]; then
        echo "✅ PHP ${PHP_VERSION} with OpenSSL 4.0.1 built successfully!"
        "$install_dir/usr/local/bin/php" -v
        return 0
    else
        echo "❌ PHP binary not found!"
        return 1
    fi
}

# ============================================================
# 主函数
# ============================================================
main() {
    echo ""
    echo "========================================"
    echo "TEST: PHP 7.2.34 with OpenSSL 4.0.1"
    echo "========================================"
    echo "Start time: $(date)"
    echo ""

    if build_php; then
        echo ""
        echo "========================================"
        echo "✅ TEST PASSED"
        echo "========================================"
        exit 0
    else
        echo ""
        echo "========================================"
        echo "❌ TEST FAILED"
        echo "========================================"
        echo ""
        echo "Check the scan report: $LOG_DIR/openssl4-scan-report.txt"
        echo "Check the build log: $LOG_DIR/build-${PHP_VERSION}.log"
        exit 1
    fi
}

main "$@"