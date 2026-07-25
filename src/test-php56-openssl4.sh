#!/bin/bash
# src/test-php56-openssl4.sh
# TEST: PHP 5.6.40 with OpenSSL 4.x - Build and Test

set -e

# ============================================================
# 配置
# ============================================================
PHP_VERSION="5.6.40"
OPENSSL_VERSION="${OPENSSL_VERSION:-4.x}"
OPENSSL_PREFIX="${OPENSSL_PREFIX:-/usr/local}"
BUILD_DIR="/tmp/php-build-test"
ARCHIVE_DIR="$BUILD_DIR/archive"
LOG_DIR="$BUILD_DIR/logs"
NUM_CPUS=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
ARTIFACT_DIR="${ARTIFACT_DIR:-/home/runner/work/hestiacp-freebsd/hestiacp-freebsd/artifacts-test}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p "$BUILD_DIR" "$ARCHIVE_DIR" "$LOG_DIR" "$ARTIFACT_DIR"

echo "========================================"
echo "TEST: PHP ${PHP_VERSION} with OpenSSL ${OPENSSL_VERSION}"
echo "========================================"
echo "OpenSSL prefix: ${OPENSSL_PREFIX}"
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
# 获取配置参数（强制使用 OpenSSL 4.x）
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
        "--with-mysqli=mysqlnd"
        "--with-pdo-mysql=mysqlnd"
        "--with-iconv=/usr/local"
        "--with-openssl=${OPENSSL_PREFIX:-/usr/local}"
    )

    printf "%s\n" "${args[@]}"
}

# ============================================================
# 扫描 OpenSSL 4.x 兼容性问题（改进版）
# ============================================================
scan_openssl_compatibility() {
    local build_dir=$1
    local report_file="$LOG_DIR/openssl4-scan-report.txt"
    
    echo "[ * ] Scanning OpenSSL 4.x compatibility issues..."
    
    cd "$build_dir" || return 1
    
    if [ ! -f "ext/openssl/openssl.c" ]; then
        echo "❌ ext/openssl/openssl.c not found!"
        return 1
    fi
    
    # ============================================================
    # 1. 从 OpenSSL 4.x 头文件提取所有可用函数
    # ============================================================
    echo "[ * ] Extracting OpenSSL 4.x available functions..."
    
    local openssl_headers="${OPENSSL_PREFIX}/include/openssl"
    if [ ! -d "$openssl_headers" ]; then
        openssl_headers="/usr/include/openssl"
    fi
    
    local available_functions_file="$LOG_DIR/openssl4-available-functions.txt"
    > "$available_functions_file"
    
    if [ -d "$openssl_headers" ]; then
        for header in "$openssl_headers"/*.h; do
            if [ -f "$header" ]; then
                # 提取函数声明
                grep -E '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]+\*?[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\([^;]*\);' "$header" 2>/dev/null | \
                    sed -E 's/.*[[:space:]]+\*?([A-Za-z_][A-Za-z0-9_]*)\(.*/\1/' >> "$available_functions_file" 2>/dev/null || true
                
                # 提取函数宏（如 EVP_sha1, EVP_md5 等）
                grep -E '^#define[[:space:]]+(EVP_|SSL_|X509_|RSA_|DSA_|DH_|EC_|PEM_|ASN1_|BN_|OBJ_|ERR_|CRYPTO_|OPENSSL_)[A-Za-z0-9_]*[[:space:]]+' "$header" 2>/dev/null | \
                    awk '{print $2}' >> "$available_functions_file" 2>/dev/null || true
            fi
        done
        
        sort -u "$available_functions_file" -o "$available_functions_file"
        echo "Total available functions: $(wc -l < "$available_functions_file")"
    else
        echo "⚠️  OpenSSL headers not found at $openssl_headers"
    fi
    
    # ============================================================
    # 2. 提取 PHP 5.6 openssl.c 中使用的 OpenSSL 函数（改进版）
    # ============================================================
    echo "[ * ] Extracting PHP 5.6 openssl.c used functions..."
    
    local used_functions_file="$LOG_DIR/php56-used-functions.txt"
    > "$used_functions_file"
    
    if [ -f "ext/openssl/openssl.c" ]; then
        # 只提取函数调用（函数名后跟 '('）
        grep -oE '\b(EVP_|X509_|SSL_|RSA_|DSA_|DH_|EC_|PEM_|ASN1_|BN_|OBJ_|ERR_|CRYPTO_|OPENSSL_|TLS_|PKCS)[A-Za-z0-9_]*[[:space:]]*\(' \
            "ext/openssl/openssl.c" 2>/dev/null | \
            sed 's/[[:space:]]*(//' | sort -u >> "$used_functions_file"
        
        if [ -f "ext/openssl/xp_ssl.c" ]; then
            grep -oE '\b(EVP_|X509_|SSL_|RSA_|DSA_|DH_|EC_|PEM_|ASN1_|BN_|OBJ_|ERR_|CRYPTO_|OPENSSL_|TLS_|PKCS)[A-Za-z0-9_]*[[:space:]]*\(' \
                "ext/openssl/xp_ssl.c" 2>/dev/null | \
                sed 's/[[:space:]]*(//' | sort -u >> "$used_functions_file"
        fi
        
        sort -u "$used_functions_file" -o "$used_functions_file"
        echo "Total used functions: $(wc -l < "$used_functions_file")"
    fi
    
    # ============================================================
    # 3. 定义 OpenSSL 4.x 中已知存在的函数（白名单）
    # ============================================================
    local known_existing="$LOG_DIR/known-existing-functions.txt"
    cat > "$known_existing" << 'EOF'
RSA_free
RSA_new
RSA_get0_key
RSA_get0_factors
RSA_get0_crt_params
RSA_set0_key
RSA_set0_factors
RSA_set0_crt_params
RSA_private_decrypt
RSA_private_encrypt
RSA_public_decrypt
RSA_public_encrypt
SSL_CTX_new
SSL_CTX_free
SSL_CTX_set_cipher_list
SSL_CTX_set_verify
SSL_CTX_load_verify_locations
SSL_CTX_set_default_verify_paths
SSL_CTX_use_certificate_chain_file
SSL_CTX_use_PrivateKey_file
SSL_CTX_check_private_key
SSL_CTX_set_tmp_rsa
SSL_CTX_set_tmp_dh
SSL_CTX_set_tmp_ecdh
SSL_CTX_get_cert_store
SSL_CTX_set_client_CA_list
SSL_CTX_set_cert_verify_callback
SSL_CTX_set_tlsext_servername_callback
SSL_new
SSL_free
SSL_set_fd
SSL_connect
SSL_accept
SSL_read
SSL_write
SSL_peek
SSL_pending
SSL_get_error
SSL_get_current_cipher
SSL_get_verify_result
SSL_get_peer_certificate
SSL_get_certificate
SSL_get_privatekey
SSL_get_servername
SSL_set_tlsext_host_name
SSL_get_mode
SSL_set_mode
SSL_get_ex_data
SSL_set_ex_data
SSL_copy_session_id
SSL_shutdown
SSL_version
SSL_CIPHER_get_name
SSL_CIPHER_get_bits
SSL_CIPHER_get_version
EVP_PKEY_new
EVP_PKEY_free
EVP_PKEY_assign_RSA
EVP_PKEY_assign_DSA
EVP_PKEY_assign_DH
EVP_PKEY_get0_RSA
EVP_PKEY_get0_DSA
EVP_PKEY_get0_DH
EVP_PKEY_get0_EC_KEY
EVP_PKEY_get1_EC_KEY
EVP_PKEY_id
EVP_PKEY_bits
EVP_PKEY_size
EVP_MD_CTX_new
EVP_MD_CTX_free
EVP_MD_CTX_cleanup
EVP_DigestInit
EVP_DigestInit_ex
EVP_DigestUpdate
EVP_DigestFinal
EVP_DigestFinal_ex
EVP_SignInit
EVP_SignUpdate
EVP_SignFinal
EVP_VerifyInit
EVP_VerifyUpdate
EVP_VerifyFinal
EVP_EncryptInit
EVP_EncryptInit_ex
EVP_EncryptUpdate
EVP_EncryptFinal
EVP_EncryptFinal_ex
EVP_DecryptInit
EVP_DecryptInit_ex
EVP_DecryptUpdate
EVP_DecryptFinal
EVP_DecryptFinal_ex
EVP_SealInit
EVP_SealUpdate
EVP_SealFinal
EVP_OpenInit
EVP_OpenUpdate
EVP_OpenFinal
EVP_CIPHER_CTX_new
EVP_CIPHER_CTX_free
EVP_CIPHER_CTX_cleanup
EVP_CIPHER_CTX_set_key_length
EVP_CIPHER_CTX_set_padding
EVP_CIPHER_block_size
EVP_CIPHER_key_length
EVP_CIPHER_iv_length
EVP_get_cipherbyname
EVP_get_digestbyname
EVP_sha1
EVP_sha224
EVP_sha256
EVP_sha384
EVP_sha512
EVP_md5
EVP_md4
EVP_ripemd160
EVP_aes_128_cbc
EVP_aes_192_cbc
EVP_aes_256_cbc
EVP_des_cbc
EVP_des_ede3_cbc
EVP_rc4
EVP_rc2_cbc
EVP_rc2_40_cbc
EVP_rc2_64_cbc
OPENSSL_init_ssl
OPENSSL_init_crypto
EOF

    # ============================================================
    # 4. 对比：找出缺失的函数
    # ============================================================
    echo "[ * ] Comparing functions..."
    
    local missing_functions_file="$LOG_DIR/openssl4-missing-functions.txt"
    > "$missing_functions_file"
    
    if [ -f "$available_functions_file" ] && [ -f "$used_functions_file" ]; then
        # 过滤掉白名单中的函数
        comm -23 <(sort "$used_functions_file") <(sort "$available_functions_file") | \
            grep -v -F -f "$known_existing" > "$missing_functions_file"
        
        local missing_count=$(wc -l < "$missing_functions_file")
        echo ""
        echo "========================================"
        echo "OpenSSL 4.x Compatibility Scan Report"
        echo "========================================"
        echo "PHP Version: ${PHP_VERSION}"
        echo "Available functions in OpenSSL 4.x: $(wc -l < "$available_functions_file")"
        echo "Used functions in PHP 5.6: $(wc -l < "$used_functions_file")"
        echo "MISSING functions (need to fix): $missing_count"
        echo "========================================"
        
        {
            echo "========================================"
            echo "OpenSSL 4.x Compatibility Scan Report"
            echo "========================================"
            echo "PHP Version: ${PHP_VERSION}"
            echo "Scan Date: $(date)"
            echo ""
            echo "Available functions in OpenSSL 4.x: $(wc -l < "$available_functions_file")"
            echo "Used functions in PHP 5.6: $(wc -l < "$used_functions_file")"
            echo "MISSING functions (need to fix): $missing_count"
            echo ""
            echo "========================================"
            echo "MISSING FUNCTIONS (not found in OpenSSL 4.x)"
            echo "========================================"
            echo ""
            
            if [ "$missing_count" -gt 0 ]; then
                echo "These functions are used by PHP 5.6 but NOT available in OpenSSL 4.x:"
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
                        RSA_generate_key)
                            echo "  $func → Use RSA_generate_key_ex() or EVP_PKEY_keygen() instead"
                            ;;
                        DSA_generate_key)
                            echo "  $func → Use EVP_PKEY_keygen() instead"
                            ;;
                        DH_generate_key)
                            echo "  $func → Use EVP_PKEY_keygen() instead"
                            ;;
                        SSL_library_init)
                            echo "  $func → Use OPENSSL_init_ssl() instead"
                            ;;
                        OpenSSL_add_all_ciphers|OpenSSL_add_all_digests|OpenSSL_add_all_algorithms)
                            echo "  $func → Use OPENSSL_init_crypto() instead"
                            ;;
                        ERR_free_strings)
                            echo "  $func → No longer needed in OpenSSL 4.x"
                            ;;
                        CRYPTO_set_locking_callback)
                            echo "  $func → No longer needed in OpenSSL 4.x (locking is handled internally)"
                            ;;
                        *)
                            echo "  $func → Check OpenSSL 4.x documentation"
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

    cd "$build_dir" || return 1

    echo "[ * ] Applying patches for PHP ${PHP_VERSION} with OpenSSL ${OPENSSL_VERSION}..."

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
    
    if [ -f "ext/zlib/zlib.c" ]; then
        if grep -q "ZEND_MODULE_GLOBALS_CTOR_N(zlib)" ext/zlib/zlib.c 2>/dev/null; then
            sed -i '' 's/ZEND_MODULE_GLOBALS_CTOR_N(zlib),/NULL,/' ext/zlib/zlib.c
            echo "[ ✓ ] Patch 4: zlib.c globals_ctor set to NULL"
        fi
    fi

    if [ -f "ext/dom/dom_iterators.c" ]; then
        if grep -q "itemHashScanner (void \*payload, void \*data, xmlChar \*name)" ext/dom/dom_iterators.c 2>/dev/null; then
            sed -i '' 's/itemHashScanner (void \*payload, void \*data, xmlChar \*name)/itemHashScanner (void *payload, void *data, const xmlChar *name)/' ext/dom/dom_iterators.c
            echo "[ ✓ ] Patch 5: dom_iterators.c itemHashScanner const fix"
        fi
    fi
    # ============================================================
    # 补丁4: 直接替换 OpenSSL 源文件（使用预修改的文件）
    # ============================================================
    local custom_openssl_dir="$SCRIPT_DIR/php5.6"
    if [ -d "$custom_openssl_dir" ]; then
        echo "[ * ] Using pre-modified OpenSSL source files..."
        
        # 复制 openssl.c
        if [ -f "$custom_openssl_dir/openssl.c" ]; then
            cp "$custom_openssl_dir/openssl.c" "ext/openssl/openssl.c"
            echo "[ ✓ ] Replaced ext/openssl/openssl.c"
        else
            echo "⚠️  openssl.c not found in $custom_openssl_dir"
        fi
        
        # 复制 xp_ssl.c
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

    # ============================================================
    # 扫描 OpenSSL 4.x 兼容性问题
    # ============================================================
    scan_openssl_compatibility "$build_dir"

    echo "[ ✓ ] All patches applied for PHP ${PHP_VERSION}"
    cd - > /dev/null || return 1
}

# ============================================================
# 运行 PHP 测试
# ============================================================
run_php_tests() {
    local install_dir="$1"
    local php_bin="$install_dir/usr/local/hestia/php/bin/php"
    
    echo ""
    echo "========================================"
    echo "[ * ] Running PHP tests with OpenSSL ${OPENSSL_VERSION}..."
    echo "========================================"
    
    if [ ! -f "$php_bin" ]; then
        echo "❌ PHP binary not found at $php_bin"
        return 1
    fi
    
    echo "PHP version:"
    "$php_bin" -v
    echo ""
    
    echo "[ * ] Testing basic PHP functionality..."
    
    # 测试1: PHP info
    echo "Test 1: php -i"
    "$php_bin" -i | head -20
    echo ""
    
    # 测试2: 简单 PHP 脚本
    echo "Test 2: Simple PHP script"
    "$php_bin" -r 'echo "PHP works!\n"; echo "OpenSSL version: " . OPENSSL_VERSION_TEXT . "\n";'
    echo ""
    
    # 测试3: OpenSSL 扩展加载
    echo "Test 3: OpenSSL extension"
    "$php_bin" -m | grep -i openssl || echo "⚠️  OpenSSL module not found in module list"
    echo ""
    
    # 测试4: 基本 OpenSSL 函数
    echo "Test 4: Basic OpenSSL functions"
    "$php_bin" -r '
        echo "openssl_open(): " . (function_exists("openssl_open") ? "✅" : "❌") . "\n";
        echo "openssl_encrypt(): " . (function_exists("openssl_encrypt") ? "✅" : "❌") . "\n";
        echo "openssl_decrypt(): " . (function_exists("openssl_decrypt") ? "✅" : "❌") . "\n";
        echo "openssl_sign(): " . (function_exists("openssl_sign") ? "✅" : "❌") . "\n";
        echo "openssl_verify(): " . (function_exists("openssl_verify") ? "✅" : "❌") . "\n";
        echo "openssl_pkey_new(): " . (function_exists("openssl_pkey_new") ? "✅" : "❌") . "\n";
        echo "openssl_x509_read(): " . (function_exists("openssl_x509_read") ? "✅" : "❌") . "\n";
    '
    echo ""
    
    # 测试5: OpenSSL 版本信息
    echo "Test 5: OpenSSL version from PHP"
    "$php_bin" -r 'echo "PHP OpenSSL: " . OPENSSL_VERSION_TEXT . "\n";'
    echo ""
    
    # 测试6: 加密解密测试
    echo "Test 6: Encrypt/Decrypt test"
    "$php_bin" -r '
        $data = "Hello OpenSSL 4.0!";
        $method = "AES-256-CBC";
        $password = "test_password";
        $iv = openssl_random_pseudo_bytes(openssl_cipher_iv_length($method));
        $encrypted = openssl_encrypt($data, $method, $password, 0, $iv);
        $decrypted = openssl_decrypt($encrypted, $method, $password, 0, $iv);
        echo "Original: $data\n";
        echo "Encrypted: $encrypted\n";
        echo "Decrypted: $decrypted\n";
        echo "Test: " . ($data === $decrypted ? "✅ PASSED" : "❌ FAILED") . "\n";
    '
    echo ""
    
    echo "========================================"
    echo "✅ PHP tests completed!"
    echo "========================================"
}

# ============================================================
# 构建 PHP
# ============================================================
build_php() {
    local build_dir="$BUILD_DIR/php-src-${PHP_VERSION}"
    local install_dir="$BUILD_DIR/php-${PHP_VERSION}"

    echo ""
    echo "========================================"
    echo "[ * ] Building PHP ${PHP_VERSION} with OpenSSL ${OPENSSL_VERSION}"
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

    echo "[ * ] Configuring PHP ${PHP_VERSION}..."
    echo "OpenSSL prefix: ${OPENSSL_PREFIX}"
    echo "CFLAGS: $CFLAGS"
    echo "LDFLAGS: $LDFLAGS"

    export CFLAGS="$CFLAGS"
    export LDFLAGS="$LDFLAGS"
    export PKG_CONFIG_PATH="$PKG_CONFIG_PATH"
    export CPPFLAGS="$CFLAGS"
    export LD_LIBRARY_PATH="${OPENSSL_PREFIX}/lib"

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

    if [ -f "$install_dir/usr/local/hestia/php/bin/php" ]; then
        echo "✅ PHP ${PHP_VERSION} with OpenSSL ${OPENSSL_VERSION} built successfully!"
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
    echo "TEST: PHP 5.6.40 with OpenSSL ${OPENSSL_VERSION}"
    echo "========================================"
    echo "Start time: $(date)"
    echo ""

    if build_php; then
        echo ""
        echo "========================================"
        echo "✅ BUILD SUCCESSFUL"
        echo "========================================"
        
        # 运行测试
        run_php_tests "$BUILD_DIR/php-${PHP_VERSION}"
        
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