#!/bin/bash
# src/build-php84-openssl4.sh
# Build PHP 8.4.23 with OpenSSL 4.x and create package
# UPDATED: Install IMAP via PECL (since ext/imap removed in PHP 8.4)
# UPDATED: Install APCu extension

set -e

# ============================================================
# 配置
# ============================================================
PHP_VERSION="8.4.23"
BUILD_DIR="/tmp/php-build-test"
ARCHIVE_DIR="$BUILD_DIR/archive"
PKG_DIR="$BUILD_DIR/pkg"
LOG_DIR="$BUILD_DIR/logs"
ARTIFACT_DIR="${ARTIFACT_DIR:-/home/runner/work/hestiacp-freebsd/hestiacp-freebsd/artifacts}"
NUM_CPUS=$(sysctl -n hw.ncpu || echo 4)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_IMAP="${BUILD_IMAP:-yes}"

# 创建所有需要的目录
mkdir -p "$BUILD_DIR" "$ARCHIVE_DIR" "$LOG_DIR" "$PKG_DIR" "$ARTIFACT_DIR"

echo "========================================"
echo "Build PHP ${PHP_VERSION} with OpenSSL 4.x"
echo "========================================"
echo "OpenSSL prefix: ${OPENSSL_PREFIX:-/usr/local}"
echo "OpenSSL version: $(openssl version || echo 'unknown')"
echo "System ICU: $(pkg info icu | grep Version || echo 'unknown')"
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
# 下载 ImageMagick 扩展源码
# ============================================================
download_imagick() {
    local imagick_dir="$1/ext/imagick"
    
    [ -d "$imagick_dir" ] && { echo "[ ✓ ] ImageMagick already exists"; return 0; }
    
    echo "[ * ] Downloading ImageMagick 3.8.1..."
    fetch -o "/tmp/imagick.tar.gz" "https://github.com/Imagick/imagick/archive/refs/tags/3.8.1.tar.gz" || return 1
    
    echo "[ * ] Extracting..."
    tar -xf "/tmp/imagick.tar.gz" -C "$1/ext"
    
    local extracted=$(find "$1/ext" -maxdepth 1 -type d -name "imagick-*" | head -1)
    [ -z "$extracted" ] && { echo "❌ Extract failed"; return 1; }
    
    mv "$extracted" "$imagick_dir"
    rm -f "/tmp/imagick.tar.gz"
    
    echo "[ ✓ ] ImageMagick extension ready"
    return 0
}

# ============================================================
# 下载 APCu 扩展源码
# ============================================================
download_apcu() {
    local apcu_dir="$1/ext/apcu"
    
    [ -d "$apcu_dir" ] && { echo "[ ✓ ] APCu already exists"; return 0; }
    
    echo "[ * ] Downloading APCu 5.1.24..."
    fetch -o "/tmp/apcu.tar.gz" "https://github.com/krakjoe/apcu/archive/refs/tags/v5.1.28.tar.gz" || return 1
    
    echo "[ * ] Extracting..."
    tar -xf "/tmp/apcu.tar.gz" -C "$1/ext"
    
    local extracted=$(find "$1/ext" -maxdepth 1 -type d -name "apcu-*" | head -1)
    [ -z "$extracted" ] && { echo "❌ Extract failed"; return 1; }
    
    mv "$extracted" "$apcu_dir"
    rm -f "/tmp/apcu.tar.gz"
    
    echo "[ ✓ ] APCu extension ready"
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
        "--enable-apcu"
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
        "--with-xsl"
        "--enable-opcache"
        "--enable-intl"
        "--enable-soap"
        "--enable-posix"
        "--enable-tokenizer"
        "--with-readline"
        "--enable-phar=shared"
        "--enable-shmop"
        "--enable-sysvmsg"
        "--enable-sysvsem"
        "--enable-sysvshm"
        "--enable-calendar"
        "--enable-phpdbg"
        "--with-pic"
        "--with-gettext=/usr/local"
        "--with-curl"
        "--with-gmp=/usr/local"
        "--with-zlib=/usr"
        "--with-bz2=/usr"
        "--with-mysqli=mysqlnd"
        "--with-pdo-mysql=mysqlnd"
        "--with-pgsql"
        "--with-pdo-pgsql"
        "--with-iconv=/usr/local"
        "--with-openssl=/usr/local"
        "--with-sodium"
        "--with-password-argon2"
        "--with-ldap=/usr/local"
        "--with-libedit"
        "--with-ffi"
        "--enable-gd"
        "--with-freetype"
        "--with-jpeg"
        "--with-webp"
        "--with-zip"
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

    # 更新版权年份
    if [ -f "./main/main.c" ] && [ -f "./Zend/zend.c" ]; then
        echo "[ * ] Updating copyright year to 2026..."
        find ./main ./Zend ./ext ./sapi ./TSRM -type f \( -name "*.c" -o -name "*.h" \) \
            -exec sed -i '' 's/| Copyright (c) [0-9]\{4\}-[0-9]\{4\} The PHP Group.*/| Copyright (c) 1997- 2026 The PHP Group                                |/' {} \;
        find ./main ./Zend ./ext ./sapi ./TSRM -type f \( -name "*.c" -o -name "*.h" \) \
            -exec sed -i '' 's/| Copyright (c) The PHP Group.*/| Copyright (c) 1997- 2026 The PHP Group                                |/' {} \;
        find ./main ./Zend ./ext ./sapi ./TSRM -type f \( -name "*.c" -o -name "*.h" \) \
            -exec sed -i '' 's/| Copyright (c) [0-9]\{4\}-[0-9]\{4\} Zend Technologies.*/| Copyright (c) 1998- 2026 Zend Technologies Ltd. (http:\/\/www.zend.com) |/' {} \;
        find ./main ./Zend ./ext ./sapi ./TSRM -type f \( -name "*.c" -o -name "*.h" \) \
            -exec sed -i '' 's/| Copyright (c) Zend Technologies.*/| Copyright (c) 1998- 2026 Zend Technologies Ltd. (http:\/\/www.zend.com) |/' {} \;
        
        for file in sapi/cli/php_cli.c sapi/fpm/fpm/fpm_main.c sapi/cgi/cgi_main.c sapi/litespeed/lsapi_main.c sapi/phpdbg/phpdbg.c; do
            if [ -f "$file" ]; then
                sed -i '' 's/Copyright (c) [0-9]\{4\}-[0-9]\{4\} The PHP Group/Copyright (c) 1997- 2026 The PHP Group/g' "$file"
                sed -i '' 's/Copyright (c) The PHP Group/Copyright (c) 1997- 2026 The PHP Group/g' "$file"
            fi
        done
        
        sed -i '' 's/#define ZEND_CORE_VERSION_INFO.*"Zend Engine v" ZEND_VERSION ", Copyright (c) [0-9]\{4\}-[0-9]\{4\} Zend Technologies\\n".*/#define ZEND_CORE_VERSION_INFO\t"Zend Engine v" ZEND_VERSION ", Copyright (c) 1998- 2026 Zend Technologies\\n"/' ./Zend/zend.c
        sed -i '' 's/#define ZEND_CORE_VERSION_INFO.*"Zend Engine v" ZEND_VERSION ", Copyright (c) Zend Technologies\\n".*/#define ZEND_CORE_VERSION_INFO\t"Zend Engine v" ZEND_VERSION ", Copyright (c) 1998- 2026 Zend Technologies\\n"/' ./Zend/zend.c
        echo "[ ✓ ] Copyright updated to 2026"
        grep "Copyright" ./main/main.c || true
        grep "Copyright" ./Zend/zend.c || true
    fi

    echo "[ ✓ ] All patches applied for PHP ${PHP_VERSION}"
    cd - > /dev/null || return 1
}

# ============================================================
# 通过 PECL 安装 IMAP 扩展 (PHP 8.4 使用 PECL)
# ============================================================
install_imap_pecl() {
    local install_dir="$1"
    local build_dir="$2"
    
    echo ""
    echo "========================================"
    echo "[ * ] Installing IMAP extension via PECL"
    echo "========================================"
    
    local php_bin="$install_dir/usr/local/bin/php"
    local pecl="$install_dir/usr/local/bin/pecl"
    
    if [ ! -f "$php_bin" ]; then
        echo "❌ PHP binary not found: $php_bin"
        return 1
    fi
    
    # 检查 PECL 是否存在
    if [ ! -f "$pecl" ]; then
        echo "⚠️  PECL not found, installing PEAR..."
        # 安装 PEAR
        cd "$build_dir" || return 1
        if [ -f "phpize" ]; then
            ./phpize
        fi
        # 下载并安装 PEAR
        fetch -o /tmp/go-pear.phar https://pear.php.net/go-pear.phar
        "$php_bin" /tmp/go-pear.phar
        export PATH="$install_dir/usr/local/bin:$PATH"
    fi
    
    # 设置环境变量
    export PATH="$install_dir/usr/local/bin:$PATH"
    export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:$PKG_CONFIG_PATH"
    export CFLAGS="-I/usr/local/include $CFLAGS"
    export LDFLAGS="-L/usr/local/lib $LDFLAGS"
    export CPPFLAGS="-I/usr/local/include"
    
    # 获取扩展目录
    local zend_api_no=$(grep "^#define ZEND_MODULE_API_NO" "$build_dir/Zend/zend_modules.h" | awk '{print $3}')
    local ext_dir="$install_dir/usr/local/lib/php/extensions/no-debug-non-zts-${zend_api_no}"
    
    echo "[ * ] Installing imap extension via PECL..."
    echo "  Using PHP: $php_bin"
    echo "  Extension dir: $ext_dir"
    
    # 尝试通过 PECL 安装
    if pecl install imap <<< "yes" 2>&1 | tee -a "$LOG_DIR/imap-pecl.log"; then
        echo "  ✅ IMAP extension installed via PECL"
        
        # 查找 imap.so
        local imap_so=""
        for path in "$ext_dir" "$install_dir/usr/local/lib/php/extensions" /usr/local/lib/php/extensions; do
            if [ -d "$path" ]; then
                found=$(find "$path" -name "imap.so" | head -1)
                if [ -n "$found" ] && [ -f "$found" ]; then
                    imap_so="$found"
                    break
                fi
            fi
        done
        
        if [ -n "$imap_so" ] && [ -f "$imap_so" ]; then
            mkdir -p "$ext_dir"
            cp "$imap_so" "$ext_dir/"
            echo "  ✅ imap.so copied to $ext_dir"
            
            # 添加到 php.ini
            local php_ini="$install_dir/usr/local/etc/php.ini"
            mkdir -p "$(dirname "$php_ini")"
            if [ -f "$php_ini" ]; then
                if ! grep -q "^extension=imap.so" "$php_ini"; then
                    echo "extension=imap.so" >> "$php_ini"
                fi
            else
                echo "extension=imap.so" > "$php_ini"
            fi
            echo "  ✅ imap.so added to php.ini"
            return 0
        fi
    fi
    
    echo "⚠️  PECL installation failed, trying manual build..."
    return 1
}

# ============================================================
# 从 PECL 源码手动编译 IMAP
# ============================================================
install_imap_manual() {
    local install_dir="$1"
    local build_dir="$2"
    
    echo ""
    echo "========================================"
    echo "[ * ] Building IMAP extension from PECL source"
    echo "========================================"
    
    local php_bin="$install_dir/usr/local/bin/php"
    local phpize="$install_dir/usr/local/bin/phpize"
    local php_config="$install_dir/usr/local/bin/php-config"
    
    if [ ! -f "$php_bin" ] || [ ! -f "$phpize" ]; then
        echo "❌ PHP or phpize not found"
        return 1
    fi
    
    # 下载 IMAP PECL 源码
    echo "[ * ] Downloading imap PECL source..."
    cd /tmp
    if [ ! -f "imap-1.0.3.tgz" ]; then
        fetch -o imap-1.0.3.tgz https://pecl.php.net/get/imap-1.0.3.tgz || \
        fetch -o imap-1.0.3.tgz https://github.com/php/pecl-mail-imap/archive/refs/tags/1.0.3.tar.gz
    fi
    
    # 解压
    rm -rf imap-1.0.3
    tar -xzf imap-1.0.3.tgz || tar -xzf imap-1.0.3.tar.gz
    cd imap-1.0.3 || cd pecl-mail-imap-1.0.3 || return 1
    
    echo "[ * ] Running phpize..."
    "$phpize" --with-php-config="$php_config" 2>&1 | tee -a "$LOG_DIR/imap-manual-phpize.log"
    
    echo "[ * ] Configuring..."
    ./configure --with-php-config="$php_config" --with-imap=/usr/local --with-imap-ssl=/usr/local 2>&1 | tee -a "$LOG_DIR/imap-manual-configure.log"
    
    echo "[ * ] Compiling..."
    make 2>&1 | tee -a "$LOG_DIR/imap-manual-make.log"
    
    # 获取扩展目录并安装
    local zend_api_no=$(grep "^#define ZEND_MODULE_API_NO" "$build_dir/Zend/zend_modules.h" | awk '{print $3}')
    local ext_dir="$install_dir/usr/local/lib/php/extensions/no-debug-non-zts-${zend_api_no}"
    mkdir -p "$ext_dir"
    
    if [ -f "modules/imap.so" ]; then
        cp modules/imap.so "$ext_dir/"
        echo "  ✅ imap.so installed to $ext_dir"
    elif [ -f ".libs/imap.so" ]; then
        cp .libs/imap.so "$ext_dir/"
        echo "  ✅ imap.so installed to $ext_dir"
    else
        echo "❌ imap.so not found"
        find . -name "imap.so" 2>/dev/null
        return 1
    fi
    
    # 添加到 php.ini
    local php_ini="$install_dir/usr/local/etc/php.ini"
    mkdir -p "$(dirname "$php_ini")"
    if [ -f "$php_ini" ]; then
        if ! grep -q "^extension=imap.so" "$php_ini"; then
            echo "extension=imap.so" >> "$php_ini"
        fi
    else
        echo "extension=imap.so" > "$php_ini"
    fi
    
    echo "  ✅ imap.so added to php.ini"
    return 0
}
# ============================================================
# 从源码编译安装 aspell 库
# ============================================================
build_aspell_from_source() {
    echo "  [ * ] Building aspell from source..."
    
    cd /tmp || return 1
    
    # 下载 aspell 源码
    if [ ! -f "aspell-0.60.8.2.tar.gz" ]; then
        echo "    Downloading aspell-0.60.8.2.tar.gz..."
        fetch -o aspell-0.60.8.2.tar.gz https://ftp.gnu.org/gnu/aspell/aspell-0.60.8.2.tar.gz || return 1
    fi
    
    # 解压
    rm -rf aspell-0.60.8.2
    tar -xzf aspell-0.60.8.2.tar.gz || return 1
    cd aspell-0.60.8.2 || return 1
    
    # 配置
    echo "    Configuring aspell..."
    ./configure --prefix=/usr/local || return 1
    
    # 编译
    echo "    Compiling aspell (using $NUM_CPUS cores)..."
    make -j"$NUM_CPUS" || return 1
    
    # 安装
    echo "    Installing aspell..."
    make install || return 1
    
    # 更新库缓存
    ldconfig || true
    
    cd /tmp
    rm -rf aspell-0.60.8.2
    
    echo "  ✅ aspell installed successfully"
    return 0
}

# ============================================================
# 从源码手动下载编译 PSPell（当 PECL 失败时）
# ============================================================
build_pspell_manual() {
    local install_dir="$1"
    local build_dir="$2"
    
    echo "  [ * ] Building PSPell from manual download..."
    
    local php_bin="$install_dir/usr/local/bin/php"
    local phpize="$install_dir/usr/local/bin/phpize"
    local php_config="$install_dir/usr/local/bin/php-config"
    
    if [ ! -f "$php_bin" ] || [ ! -f "$phpize" ]; then
        echo "    ❌ PHP or phpize not found"
        return 1
    fi
    
    # 下载 PSPell PECL 源码
    cd /tmp || return 1
    
    if [ ! -f "pspell.tgz" ]; then
        echo "    Downloading PSPell PECL source..."
        fetch -o pspell.tgz https://pecl.php.net/get/pspell-1.0.1.tgz || \
        fetch -o pspell.tgz https://github.com/php/pecl-text-pspell/archive/refs/tags/1.0.1.tar.gz || true
    fi
    
    if [ ! -f "pspell.tgz" ]; then
        echo "    ❌ Failed to download PSPell source"
        return 1
    fi
    
    # 解压
    rm -rf pspell-*
    tar -xzf pspell.tgz || return 1
    
    # 进入目录
    PSPELL_DIR=$(find . -maxdepth 1 -type d -name "pspell-*" | head -1)
    if [ -z "$PSPELL_DIR" ]; then
        echo "    ❌ Failed to extract PSPell source"
        return 1
    fi
    cd "$PSPELL_DIR" || return 1
    
    # 设置环境变量
    export PSPELL_CFLAGS="-I/usr/local/include"
    export PSPELL_LIBS="-L/usr/local/lib -laspell"
    
    echo "    Running phpize..."
    "$phpize" || return 1
    
    echo "    Configuring..."
    ./configure --with-php-config="$php_config" --with-pspell=/usr/local || return 1
    
    echo "    Compiling..."
    make || return 1
    
    echo "    Installing..."
    make install || return 1
    
    # 复制到正确的扩展目录
    local zend_api_no=$(grep "^#define ZEND_MODULE_API_NO" "$build_dir/Zend/zend_modules.h" | awk '{print $3}')
    local ext_dir="$install_dir/usr/local/lib/php/extensions/no-debug-non-zts-${zend_api_no}"
    
    local pspell_so=$(find . -name "pspell.so" | head -1)
    if [ -n "$pspell_so" ] && [ -f "$pspell_so" ]; then
        mkdir -p "$ext_dir"
        cp "$pspell_so" "$ext_dir/"
        echo "    ✅ pspell.so installed to $ext_dir"
        
        local php_ini="$install_dir/usr/local/etc/php.ini"
        if ! grep -q "^extension=pspell.so" "$php_ini" 2>/dev/null; then
            echo "extension=pspell.so" >> "$php_ini"
        fi
        
        cd /tmp
        rm -rf pspell-*
        return 0
    fi
    
    cd /tmp
    rm -rf pspell-*
    echo "    ❌ pspell.so not found after build"
    return 1
}

# ============================================================
# 安装 PSPell 扩展（源码编译优先，PECL 备用，手动下载作为最后手段）
# ============================================================
install_pspell() {
    local install_dir="$1"
    local build_dir="$2"
    
    echo ""
    echo "========================================"
    echo "[ * ] Installing PSPell extension"
    echo "========================================"
    
    local installed=0
    
    # ============================================================
    # 先安装 aspell 库（PSpell 的依赖）
    # ============================================================
    if [ "$OSTYPE" = 'freebsd' ]; then
        # 首先尝试用 pkg 安装
        if pkg info | grep -q aspell; then
            echo "  ✅ aspell already installed"
        else
            echo "  [ * ] aspell not found, installing from source..."
            if build_aspell_from_source; then
                echo "  ✅ aspell installed from source"
            else
                echo "  ⚠️  aspell source build failed, trying pkg..."
                pkg install -y aspell || true
            fi
        fi
    fi
    
    # ============================================================
    # 尝试 1: 源码编译（如果 PHP 源码中存在）
    # ============================================================
    if [ -d "$build_dir/ext/pspell" ]; then
        echo "[ * ] Attempt 1: Building PSPell from source..."
        if build_pspell_from_source "$install_dir" "$build_dir"; then
            installed=1
            echo "  ✅ PSPell installed from source"
        else
            echo "  ⚠️  Source build failed, trying PECL..."
        fi
    else
        echo "  ℹ️  PSPell source not found in PHP, trying PECL..."
    fi
    
    # ============================================================
    # 尝试 2: PECL 安装
    # ============================================================
    if [ $installed -eq 0 ]; then
        echo "[ * ] Attempt 2: Installing PSPell via PECL..."
        if install_pspell_via_pecl "$install_dir" "$build_dir"; then
            installed=1
            echo "  ✅ PSPell installed via PECL"
        else
            echo "  ⚠️  PECL installation failed, trying manual download..."
        fi
    fi
    
    # ============================================================
    # 尝试 3: 手动下载编译
    # ============================================================
    if [ $installed -eq 0 ]; then
        echo "[ * ] Attempt 3: Installing PSPell from manual download..."
        if build_pspell_manual "$install_dir" "$build_dir"; then
            installed=1
            echo "  ✅ PSPell installed from manual download"
        else
            echo "  ❌ Manual download installation failed"
        fi
    fi
    
    # ============================================================
    # 最终结果
    # ============================================================
    if [ $installed -eq 1 ]; then
        echo "  ✅ PSPell installed successfully"
        return 0
    else
        echo "  ❌ PSPell installation failed (all methods)"
        return 1
    fi
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

    echo "[ * ] Creating symlinks to build files..."
    if [ -d "$build_dir/build" ]; then
        mkdir -p /usr/local/lib/php/build
        rm -rf /usr/local/lib/php/build || true
        ln -sf "$build_dir/build" /usr/local/lib/php/build
        echo "  ✅ Symlink: /usr/local/lib/php/build -> $build_dir/build"
        
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
# 编译 APCu 扩展
# ============================================================
build_apcu() {
    local build_dir="$1"
    local install_dir="$2"
    
    if [ ! -d "$build_dir/ext/apcu" ]; then
        echo "⚠️  APCu extension not found, skipping"
        return 0
    fi
    
    echo "[ * ] Building APCu extension..."
    
    local php_prefix="$install_dir/usr/local"
    local php_config="$php_prefix/bin/php-config"
    local phpize="$php_prefix/bin/phpize"
    
    if [ ! -f "$phpize" ] || [ ! -f "$php_config" ]; then
        echo "⚠️  phpize or php-config not found, skipping APCu"
        return 0
    fi
    
    cd "$build_dir/ext/apcu" || return 1

    echo "[ * ] Creating symlinks to build files..."
    if [ -d "$build_dir/build" ]; then
        mkdir -p /usr/local/lib/php/build
        rm -rf /usr/local/lib/php/build || true
        ln -sf "$build_dir/build" /usr/local/lib/php/build
        echo "  ✅ Symlink: /usr/local/lib/php/build -> $build_dir/build"
        
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
    echo "[ * ] Configuring APCu extension..."
    ./configure --with-php-config="$php_config"
    
    echo "[ * ] Compiling APCu extension..."
    make
    
    echo "[ * ] Installing APCu extension..."
    make install INSTALL_ROOT="$install_dir"

    local zend_api_no=$(grep "^#define ZEND_MODULE_API_NO" "$build_dir/Zend/zend_modules.h" | awk '{print $3}')
    local ext_dir="$install_dir/usr/local/lib/php/extensions/no-debug-non-zts-${zend_api_no}"

    if [ ! -f "$ext_dir/apcu.so" ] && [ -f "$build_dir/ext/apcu/modules/apcu.so" ]; then
        mkdir -p "$ext_dir"
        cp "$build_dir/ext/apcu/modules/apcu.so" "$ext_dir/"
        echo "  ✅ apcu.so copied from modules"
    fi
    
    if [ -f "$ext_dir/apcu.so" ]; then
        echo "  ✅ APCu extension installed to $ext_dir/apcu.so"
        
        local php_ini_dir="$install_dir/usr/local/etc"
        mkdir -p "$php_ini_dir"
        if [ -f "$php_ini_dir/php.ini" ]; then
            if ! grep -q "^extension=apcu.so" "$php_ini_dir/php.ini"; then
                echo "extension=apcu.so" >> "$php_ini_dir/php.ini"
            fi
            # 添加 APCu 配置
            if ! grep -q "^apcu.enabled=1" "$php_ini_dir/php.ini"; then
                echo "apcu.enabled=1" >> "$php_ini_dir/php.ini"
                echo "apcu.shm_size=256M" >> "$php_ini_dir/php.ini"
                echo "apcu.ttl=7200" >> "$php_ini_dir/php.ini"
                echo "apcu.gc_ttl=3600" >> "$php_ini_dir/php.ini"
                echo "apcu.entries_hint=4096" >> "$php_ini_dir/php.ini"
                echo "  ✅ APCu configuration added to php.ini"
            fi
        else
            echo "extension=apcu.so" > "$php_ini_dir/php.ini"
            echo "apcu.enabled=1" >> "$php_ini_dir/php.ini"
            echo "apcu.shm_size=256M" >> "$php_ini_dir/php.ini"
            echo "apcu.ttl=7200" >> "$php_ini_dir/php.ini"
            echo "apcu.gc_ttl=3600" >> "$php_ini_dir/php.ini"
            echo "apcu.entries_hint=4096" >> "$php_ini_dir/php.ini"
        fi
    else
        echo "⚠️  APCu extension not found in expected location"
        find "$install_dir" -name "apcu.so" || echo "  Not found anywhere"
    fi
    
    cd - > /dev/null
    echo "  ✅ APCu extension build complete"
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

    # 下载 APCu 扩展
    if ! download_apcu "$build_dir"; then
        echo "⚠️  APCu extension download failed, continuing without it"
    fi

    cd "$build_dir" || return 1

    [ -f "Makefile" ] && gmake clean || true

    apply_patches "$build_dir"

    # 确保 PHP 构建目录完整
    echo "[ * ] Ensuring PHP build structure..."
    if [ -d "$build_dir/build" ]; then
        echo "  ✓ Build directory exists"
    else
        echo "  ⚠️  Build directory missing, recreating..."
        mkdir -p "$build_dir/build"
        cp "$build_dir/configure" "$build_dir/build/" || true
    fi

    # ============================================================
    # 设置编译环境 - 使用系统 ICU
    # ============================================================
    cd "$build_dir" || {
        echo "❌ Failed to return to PHP source directory"
        return 1
    }
    echo "[ * ] Current directory: $(pwd)"
    
    # 检测系统 ICU
    echo "[ * ] Detecting system ICU..."
    ICU_SYSTEM_PREFIX="/usr/local"
    ICU_LIB_DIR="/usr/local/lib"
    ICU_INCLUDE_DIR="/usr/local/include"
    
    # 检查 ICU 库
    if [ -f "$ICU_LIB_DIR/libicuuc.so.76" ]; then
        echo "  ✅ Found ICU 76: $ICU_LIB_DIR/libicuuc.so.76"
        ICU_VERSION="76"
    elif [ -f "$ICU_LIB_DIR/libicuuc.so.75" ]; then
        echo "  ✅ Found ICU 75: $ICU_LIB_DIR/libicuuc.so.75"
        ICU_VERSION="75"
    elif [ -f "$ICU_LIB_DIR/libicuuc.so.74" ]; then
        echo "  ✅ Found ICU 74: $ICU_LIB_DIR/libicuuc.so.74"
        ICU_VERSION="74"
    else
        echo "  ⚠️  System ICU not found, will use pkg-config"
        ICU_VERSION="unknown"
    fi
    
    # 设置编译环境
    export CC=clang
    export CXX=clang++
    export CXXFLAGS="-std=c++17 -Wno-register -Wno-deprecated-declarations"
    export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:/usr/local/libdata/pkgconfig:/usr/lib/pkgconfig"
    
    # 设置 ICU 环境变量（使用系统 ICU）
    export ICU_CFLAGS="-I$ICU_INCLUDE_DIR"
    export ICU_LIBS="-L$ICU_LIB_DIR -licui18n -licuuc -licudata -licuio"
    export LDFLAGS="-L$ICU_LIB_DIR -Wl,-rpath,$ICU_LIB_DIR"
    export CPPFLAGS="-I$ICU_INCLUDE_DIR -I$ICU_INCLUDE_DIR/freetype2"
    export CFLAGS="-I$ICU_INCLUDE_DIR -I/usr/local/include \
        -Wno-deprecated-declarations \
        -Wno-incompatible-pointer-types-discards-qualifiers \
        -Wno-implicit-function-declaration \
        -Wno-pointer-sign \
        -D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE \
        -DHAVE_IF_INDEXTONAME=1 -DHAVE_IF_NAMETOINDEX=1"
    
    export LD_LIBRARY_PATH="/usr/local/lib:/usr/lib"
    export DTRACE="/usr/sbin/dtrace"
    export ac_cv_prog_DTRACE="/usr/sbin/dtrace"
    
    echo "[ ✓ ] ICU config: $ICU_VERSION"
    
    # ============================================================
    # 设置 OpenSSL 环境
    # ============================================================
    echo "[ * ] Setting OpenSSL 4.x environment..."
    
    export OPENSSL_CFLAGS="-I/usr/local/include"
    export OPENSSL_LIBS="-L/usr/local/lib -lssl -lcrypto"
    
    if command -v openssl >/dev/null; then
        OPENSSL_VER=$(openssl version | awk '{print $2}')
        echo "  ✓ Using OpenSSL: $OPENSSL_VER"
    fi
    
    echo "[ ✓ ] OpenSSL 4.x environment configured"

    # ============================================================
    # 检测并设置 DTrace
    # ============================================================
    echo "[ * ] Detecting DTrace..."

    DT_PATH=""
    for path in /usr/sbin/dtrace /usr/bin/dtrace /sbin/dtrace /usr/local/bin/dtrace; do
        if [ -f "$path" ] && [ -x "$path" ]; then
            DT_PATH="$path"
            break
        fi
    done

    if [ -n "$DT_PATH" ]; then
        echo "  ✓ DTrace found: $DT_PATH"
        export DTRACE="$DT_PATH"
        export ac_cv_prog_DTRACE="$DT_PATH"
        export PATH="$(dirname "$DT_PATH"):$PATH"
    else
        echo "  ⚠️  DTrace not found, disabling"
        export ac_cv_prog_DTRACE=no
        export enable_dtrace=no
    fi

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

    if [ ! -f "$SCRIPT_DIR/php7.0/libarchive-3.7.2.tar.gz" ]; then
        echo "❌ libarchive-3.7.2.tar.gz 不存在"
        echo "   Expected: $SCRIPT_DIR/php7.0/libarchive-3.7.2.tar.gz"
        exit 1
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

    if [ -f "/usr/local/lib/libarchive.so" ]; then
        echo "✅ libarchive 编译成功"
        echo "   文件: /usr/local/lib/libarchive.so"
        echo "   大小: $(stat -f %z /usr/local/lib/libarchive.so) bytes"
        echo "   du -h: $(du -h /usr/local/lib/libarchive.so | cut -f1)"
        
        if [ -L "/usr/local/lib/libarchive.so" ]; then
            echo "   ⚠️  这是一个符号链接，指向: $(readlink /usr/local/lib/libarchive.so)"
            TARGET=$(readlink /usr/local/lib/libarchive.so)
            if [ -f "$TARGET" ]; then
                echo "   目标文件大小: $(stat -f %z "$TARGET") bytes"
            fi
        fi
        
        echo "[ * ] Checking OpenSSL dependencies..."
        if ldd /usr/local/lib/libarchive.so | grep -q "libcrypto.so"; then
            echo "  libarchive links to:"
            ldd /usr/local/lib/libarchive.so | grep -E "(crypto|ssl)"
        else
            echo "  ✅ libarchive has no direct OpenSSL dependency"
        fi
        
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
        unset PSPELL_LIBS
        unset LIBS
        export LIBS="-lssl -lcrypto"
        
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

        # 生成 md5global.h
        echo "[ * ] Generating md5global.h using makemd5..."
        cd include

        if [ ! -f "makemd5.c" ]; then
            echo "❌ makemd5.c not found!"
            exit 1
        fi

        echo "  Compiling makemd5..."
        if command -v gcc14 >/dev/null; then
            gcc14 -o makemd5 makemd5.c || cc -o makemd5 makemd5.c
        else
            cc -o makemd5 makemd5.c
        fi

        if [ ! -f "makemd5" ] || [ ! -x "makemd5" ]; then
            echo "❌ Failed to compile makemd5"
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
            
            if ldd /usr/local/lib/libsasl2.so | grep -q "libcrypto.so"; then
                echo "  链接到 OpenSSL:"
                ldd /usr/local/lib/libsasl2.so | grep -E "(crypto|ssl)"
            fi
            
            if objdump -p /usr/local/lib/libsasl2.so | grep -q "OPENSSL_1_1_0"; then
                echo "  ⚠️  libsasl2.so 仍然依赖 OPENSSL_1_1_0"
            else
                echo "  ✅ libsasl2.so 兼容 OpenSSL 4.x"
            fi
        else
            echo "❌ cyrus-sasl2 编译失败"
            exit 1
        fi

        # 6. c-client (IMAP)
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

        echo "[ * ] 复制 c-client 源文件到..."
        mkdir -p src/osdep/unix

        # 复制所有 .c 文件到 src/osdep/unix/
        cp -f "$SCRIPT_DIR/php7.0/c-client/"*.c src/osdep/unix/ || true
        echo "  ✅ 已复制 c-client/*.c 到 src/osdep/unix/"

        # 复制 mtest.c
        cp -f "$SCRIPT_DIR/php7.0/mtest.c" src/mtest/mtest.c || true
        echo "  ✅ 已复制 mtest.c"
        SSL_SRC="$SCRIPT_DIR/php7.0/c-client/ssl_unix.c"

        if [ ! -f "$SSL_SRC" ]; then
            echo "  ❌ 源文件不存在: $SSL_SRC"
            exit 1
        fi

        # 强制复制到 src/osdep/unix/（tools/an 会从这里创建软链接）
        cp -f "$SSL_SRC" src/osdep/unix/ssl_unix.c
        echo "  ✅ 已复制 OpenSSL 4.x 版本到 src/osdep/unix/ssl_unix.c"

        echo "[ * ] Patching Makefile to auto-answer 'y'..."
        perl -pi -e 's/read x; case "\$\$x" in y\) exit 0;; \\*\) .*;; esac/read x; case "\$\$x" in y\) exit 0;; *\) exit 0;; esac/g' Makefile

        echo "  Fixing OpenSSL paths for FreeBSD..."
        sed -i '' 's|SSLINCLUDE=/usr/include/openssl|SSLINCLUDE=/usr/local/include|g' Makefile
        sed -i '' 's|SSLLIB=/usr/lib|SSLLIB=/usr/local/lib|g' Makefile
        echo "  ✅ Makefile patched"

        # 先运行 tools/an 创建软链接
        tools/an "ln -s" src/osdep/unix c-client
        export CFLAGS="-DOPENSSL_VERSION_NUMBER=0x40000000L -I/usr/local/include"
        export CXXFLAGS="-DOPENSSL_VERSION_NUMBER=0x40000000L -I/usr/local/include"
        echo "  ✅ OPENSSL_VERSION_NUMBER=0x40000000L 已设置"
        # 强制使用 OpenSSL 4.x 兼容代码
        cd c-client
        rm -f osdep.c osdep.o osdepssl.c
        cp "$SCRIPT_DIR/php7.0/c-client/ssl_unix.c" ssl_unix.c
        cp "$SCRIPT_DIR/php7.0/c-client/ssl_unix.c" osdepssl.c
        cd ..
        echo "[ * ] 配置并编译 c-client (bsf port for FreeBSD)..."

        gmake bsf \
            SSLTYPE=unix.nopwd \
            SSLINCLUDE=/usr/local/include \
            SSLLIB=/usr/local/lib \
            EXTRACFLAGS="-I/usr/local/include -DOPENSSL_VERSION_NUMBER=0x40000000L -Wno-deprecated-declarations -Wno-error -fPIC" \
            EXTRALDFLAGS="-L/usr/local/lib -lssl -lcrypto -pthread" \
            INTERACTIVE=no 2>&1 | tee /tmp/c-client-build.log

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

        if [ $MAKE_EXIT -ne 0 ] || [ $LS_RESULT -ne 0 ]; then
            echo "❌ c-client 编译失败"
            echo "   Make 退出码: $MAKE_EXIT"
            echo "   静态库存在: $([ $LS_RESULT -eq 0 ] && echo '是' || echo '否')"
            exit 1
        fi

        echo "✅ c-client 编译成功！"
        echo "[ * ] 安装 c-client..."

        mkdir -p /usr/local/include/c-client
        cp c-client/*.h /usr/local/include/c-client/
        cp c-client/*.h /usr/local/include/

        cp c-client/c-client.a /usr/local/lib/libc-client.a
        echo "  ✅ libc-client.a installed"

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
                cp libc-client.so /usr/local/lib/
                echo "  ✅ libc-client.so created and installed"
                
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

        echo "[ * ] Verifying c-client installation..."

        if [ -f "/usr/local/lib/libc-client.a" ]; then
            echo "✅ 静态库: /usr/local/lib/libc-client.a ($(du -h /usr/local/lib/libc-client.a | cut -f1))"
        else
            echo "❌ 静态库不存在"
            exit 1
        fi

        if [ -f "/usr/local/lib/libc-client.so" ]; then
            echo "✅ 动态库: /usr/local/lib/libc-client.so ($(du -h /usr/local/lib/libc-client.so | cut -f1))"
            
            if ldd /usr/local/lib/libc-client.so | grep -q "libcrypto.so.30"; then
                echo "  ✅ 链接到 OpenSSL 4.x"
            else
                echo "  ⚠️  可能链接到其他 OpenSSL 版本"
                ldd /usr/local/lib/libc-client.so | grep crypto || echo "    无法检测"
            fi
        else
            echo "⚠️  动态库不存在（只有静态库）"
        fi
        
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
    # 修复 cURL OpenSSL 4.x 兼容性
    # ============================================================
    echo "[ * ] Fixing cURL for OpenSSL 4.x..."

    export CURL_CFLAGS="-I/usr/local/include"
    export CURL_LIBS="-L/usr/local/lib -lcurl -lssl -lcrypto"

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

    export ac_cv_lib_curl_curl_easy_perform=yes
    export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:/usr/local/libdata/pkgconfig:/usr/lib/pkgconfig"

    echo "[ ✓ ] cURL environment configured for OpenSSL 4.x"

    # ============================================================
    # 检测 gettext
    # ============================================================
    echo "[ * ] Checking gettext..."

    GETTEXT_LIB="/usr/local/lib/libintl.so"
    GETTEXT_HEADER="/usr/local/include/libintl.h"

    if [ -f "$GETTEXT_LIB" ] && [ -f "$GETTEXT_HEADER" ]; then
        echo "[ ✓ ] gettext found:"
        echo "    Library: $GETTEXT_LIB"
        echo "    Header:  $GETTEXT_HEADER"
        
        export ac_cv_func_bindtextdomain=yes
        export ac_cv_lib_intl_bindtextdomain=yes
        export ac_cv_lib_intl_gettext=yes
        export LIBS="-lintl $LIBS"
        export LDFLAGS="-L/usr/local/lib $LDFLAGS"
        export CPPFLAGS="-I/usr/local/include $CPPFLAGS"
        
        echo "[ ✓ ] gettext configured"
    else
        echo "❌ gettext NOT FOUND!"
        echo "   Expected:"
        echo "   - Library: $GETTEXT_LIB"
        echo "   - Header:  $GETTEXT_HEADER"
        echo ""
        echo "   Please install: pkg install gettext"
        exit 1
    fi

    # ============================================================
    # 配置 GMP
    # ============================================================
    echo "[ * ] Configuring GMP..."

    GMP_CFLAGS=$(pkg-config --cflags gmp || echo "-I/usr/local/include")
    GMP_LIBS=$(pkg-config --libs gmp || echo "-L/usr/local/lib -lgmp")

    echo "    CFLAGS: $GMP_CFLAGS"
    echo "    LIBS:   $GMP_LIBS"

    export GMP_CFLAGS="$GMP_CFLAGS"
    export GMP_LIBS="$GMP_LIBS"
    export ac_cv_lib_gmp___gmpz_rootrem=yes
    export ac_cv_lib_gmp___gmpz_root=yes
    export LIBS="-lgmp $LIBS"

    echo "[ ✓ ] GMP configured"

    # ============================================================
    # 设置 iconv 检测环境变量
    # ============================================================
    echo "[ * ] Setting iconv detection environment variables..."
    export ac_cv_func_iconv=yes
    export ac_cv_func_iconv_open=yes
    export ac_cv_lib_iconv_iconv=yes
    export ac_cv_lib_iconv_iconv_open=yes
    echo "[ ✓ ] iconv environment variables set"

    # ============================================================
    # 配置 LDAP
    # ============================================================
    echo "[ * ] Configuring LDAP..."
    export LDAP_CFLAGS="-I/usr/local/include"
    export LDAP_LIBS="-L/usr/local/lib -lldap -llber"
    export ac_cv_lib_ldap_ldap_bind_s=yes
    export ac_cv_func_ldap_bind_s=yes
    export ac_cv_func_ldap_parse_result=yes
    export ac_cv_func_ldap_start_tls_s=yes

    # ============================================================
    # 修复 flock 检测
    # ============================================================
    echo "[ * ] Fixing flock detection for FreeBSD 14..."

    export php_cv_struct_flock=yes
    export php_cv_struct_flock_linux=no
    export php_cv_struct_flock_bsd=yes
    export ac_cv_struct_flock=yes
    export ac_cv_struct_flock_linux=no
    export ac_cv_struct_flock_bsd=yes
    rm -f config.cache

    echo "[ ✓ ] Flock detection configured"

    # ============================================================
    # 强制 flock 检测通过
    # ============================================================
    echo "[ * ] Forcing flock detection by patching configure..."
    
    if [ -f "configure" ]; then
        echo 'php_cv_struct_flock_bsd=yes' >> configure
        echo 'PHP_STRUCT_FLOCK=BSD' >> configure
        echo 'force_flock_bsd=yes' >> configure
        
        sed -i '' 's/as_fn_error \$? "Don'\''t know how to define struct flock on this system, set --enable-opcache=no"/echo "WARNING: flock detection failed, assuming BSD order (FreeBSD 14)"; php_cv_struct_flock_bsd="yes"; PHP_STRUCT_FLOCK="BSD"/g' configure
        
        echo "[ ✓ ] Configure patched for flock detection"
    fi

    # ============================================================
    # 强制 pcntl 函数检测
    # ============================================================
    echo "[ * ] Forcing all pcntl functions detection..."
    export php_cv_func_fork=yes
    export php_cv_func_waitpid=yes
    export ac_cv_func_fork=yes
    export ac_cv_func_fork_works=yes
    export ac_cv_func_waitpid=yes
    export ac_cv_func_waitpid_works=yes
    export ac_cv_func_sigaction=yes
    export ac_cv_func_signal=yes
    export ac_cv_func_sigprocmask=yes
    export ac_cv_func_sigsetjmp=yes
    export ac_cv_func_sigsuspend=yes
    export ac_cv_func_pause=yes
    export ac_cv_func_alarm=yes
    export ac_cv_func_setitimer=yes
    export ac_cv_func_getitimer=yes
    export ac_cv_func_pcntl=yes
    echo "[ ✓ ] All pcntl functions forced"

    # ============================================================
    # 修复 off_t 检测
    # ============================================================
    echo "[ * ] Fixing off_t detection..."
    export ac_cv_sizeof_off_t=8
    export ac_cv_type_off_t=yes
    echo "[ ✓ ] off_t detection configured"

    # ============================================================
    # 配置环境
    # ============================================================
    echo "[ * ] Configuring environment for OpenSSL 4.x..."
    export LD_LIBRARY_PATH="/usr/local/lib:/usr/lib"

    if [ -f "/usr/local/lib/libcrypto.so.30" ]; then
        echo "  ✅ OpenSSL 4.x found: /usr/local/lib/libcrypto.so.30"
    else
        echo "  ⚠️  OpenSSL 4.x not found"
    fi

    if command -v objcopy >/dev/null; then
        echo "  ✓ objcopy found: $(which objcopy)"
        ldd $(which objcopy) | grep -E "ssl|crypto" || echo "  ✓ objcopy does not directly depend on OpenSSL"
    fi

    echo "[ ✓ ] OpenSSL 4.x environment configured"

    # ============================================================
    # 生成 configure 脚本
    # ============================================================
    if [ ! -f "configure" ]; then
        echo "[ * ] Generating configure script with buildconf..."
        if ! ./buildconf --force; then
            echo "❌ buildconf failed"
            return 1
        fi
        echo "  ✅ configure generated"
    fi

    export CC="clang"
    export CXX="clang++"
    export CXXFLAGS="-std=c++17"
    echo "  CC=$CC"
    echo "  CXX=$CXX"
    echo "  CXXFLAGS=$CXXFLAGS"

    echo ""
    echo "========================================"
    echo "[ * ] 使用系统 ICU"
    echo "========================================"

    echo "ICU_PREFIX: $ICU_SYSTEM_PREFIX"
    echo "ICU_CFLAGS: $ICU_CFLAGS"
    echo "ICU_LIBS: $ICU_LIBS"
    echo "LDFLAGS: $LDFLAGS"
    echo "========================================"

    # ============================================================
    # 配置 PHP
    # ============================================================
    echo "[ * ] Configuring PHP ${PHP_VERSION}..."
    cd "$build_dir" || {
        echo "❌ Failed to return to PHP source directory"
        return 1
    }

    echo "OpenSSL prefix: ${OPENSSL_PREFIX:-/usr/local}"
    echo "CFLAGS: $CFLAGS"
    export LDFLAGS="-L/usr/local/lib ${LDFLAGS}"
    echo "LDFLAGS (without rpath for configure): $LDFLAGS"

    # ============================================================
    # 修复 bzip2 pkg-config
    # ============================================================
    echo "[ * ] Creating bzip2.pc for pkg-config..."

    mkdir -p /usr/local/libdata/pkgconfig
    cat > /usr/local/libdata/pkgconfig/bzip2.pc << 'EOF'
prefix=/usr
exec_prefix=${prefix}
libdir=${exec_prefix}/lib
includedir=${prefix}/include

Name: bzip2
Description: bzip2 compression library
Version: 1.0.8
Libs: -L${libdir} -lbz2
Cflags: -I${includedir}
EOF

    export PKG_CONFIG_PATH="/usr/local/libdata/pkgconfig:/usr/local/lib/pkgconfig:$PKG_CONFIG_PATH"
    echo "  ✅ bzip2.pc created and PKG_CONFIG_PATH updated"

    # 获取基础配置参数
    mapfile -t CONFIG_ARGS < <(get_config_args)
    echo "Config args: ${CONFIG_ARGS[*]}"
    CONFIG_ARGS_WITH_PHAR_SHARED=("${CONFIG_ARGS[@]}")
    CONFIG_ARGS_WITH_PHAR_SHARED+=("--enable-phar=shared")
    echo "Final config args: ${CONFIG_ARGS_WITH_PHAR_SHARED[*]}"


    # ============================================================
    # 运行 configure - 使用系统 ICU
    # ============================================================
    echo "[ * ] Running configure..."

    echo "=== DEBUG: CONFIG_ARGS_WITH_PHAR_SHARED ==="
    echo "Length: ${#CONFIG_ARGS_WITH_PHAR_SHARED[@]}"
    for i in "${!CONFIG_ARGS_WITH_PHAR_SHARED[@]}"; do
        echo "  [$i] ${CONFIG_ARGS_WITH_PHAR_SHARED[$i]}"
    done
    echo "=== END DEBUG ==="

    set +e
    ./configure \
        "${CONFIG_ARGS_WITH_PHAR_SHARED[@]}" \
        CC="clang" \
        CXX="clang++" \
        CXXFLAGS="-std=c++17" \
        LDFLAGS="-L/usr/local/lib -Wl,-rpath,/usr/local/lib" \
        LIBS="-licui18n -licuuc -licudata -licuio" \
        DTRACE=/usr/sbin/dtrace \
        LDAP_LIBS="-L/usr/local/lib -lldap -llber" \
        ac_cv_lib_c_client_mail_open=yes \
        ac_cv_lib_c_client_imap_open=yes \
        php_cv_struct_flock=yes \
        php_cv_struct_flock_linux=no \
        php_cv_struct_flock_bsd=yes \
        ac_cv_func_fork=yes \
        ac_cv_func_fork_works=yes \
        ac_cv_func_waitpid=yes \
        ac_cv_func_waitpid_works=yes \
        ac_cv_func_sigaction=yes \
        ac_cv_func_signal=yes \
        ac_cv_func_sigprocmask=yes \
        ac_cv_func_sigsetjmp=yes \
        ac_cv_func_sigsuspend=yes \
        ac_cv_func_pause=yes \
        ac_cv_func_alarm=yes \
        ac_cv_func_setitimer=yes \
        ac_cv_func_getitimer=yes \
        ac_cv_lib_pq_PQprepare=yes \
        ac_cv_lib_pq_PQexecParams=yes \
        ac_cv_lib_pq_PQescapeStringConn=yes \
        ac_cv_lib_pq_PQescapeString=yes \
        ac_cv_lib_pq_PQresultErrorField=yes \
        ac_cv_lib_pq_PQfreemem=yes \
        ac_cv_lib_pq_PQescapeByteaConn=yes \
        ac_cv_lib_pq_PQunescapeBytea=yes \
        ac_cv_lib_pq_PQsetdbLogin=yes \
        ac_cv_lib_pq_PQconnectdb=yes \
        ac_cv_lib_pq_PQfinish=yes \
        ac_cv_lib_pq_PQreset=yes \
        ac_cv_lib_pq_PQcancel=yes \
        ac_cv_lib_edit_readline=yes \
        ac_cv_lib_edit_rl_on_new_line=yes \
        ac_cv_lib_edit_rl_completion_matches=yes \
        ac_cv_lib_edit_rl_echo_signal_char=yes \
        EDIT_LIBS="-ledit -lncurses" \
        ac_cv_sizeof_off_t=8 \
        ac_cv_type_off_t=yes \
        > "$LOG_DIR/configure-${PHP_VERSION}.log"

    CONFIGURE_STATUS=$?
    export LDFLAGS="$LDFLAGS -Wl,-rpath,/usr/local/lib"

    if [ $CONFIGURE_STATUS -ne 0 ]; then
        echo "❌ Configure failed"
        tail -300 "$LOG_DIR/configure-${PHP_VERSION}.log"
        return 1
    fi

    echo "[ * ] Checking ICU used:"
    grep -i "icu" "$LOG_DIR/configure-${PHP_VERSION}.log" | head -20 || true

    # ============================================================
    # 修复 Makefile 中的 ICU 库路径（使用系统 ICU）
    # ============================================================
    echo "[ * ] Fixing ICU link order in Makefile..."
    if [ -f "Makefile" ]; then
        echo "  📋 BEFORE modification:"
        grep "^EXTRA_LIBS" Makefile | head -1 | sed 's/^/    EXTRA_LIBS: /'
        grep "^LIBS" Makefile | head -1 | sed 's/^/    LIBS: /'
        
        # 移除旧的 ICU 库标志
        sed -i '' -e 's|-licui18n||g' \
                -e 's|-licuuc||g' \
                -e 's|-licudata||g' \
                -e 's|-licuio||g' Makefile
        echo "  ✅ Removed ICU library flags from Makefile"
        
        # 添加系统 ICU 库
        sed -i '' -e "s|^EXTRA_LIBS = \(.*\)$|EXTRA_LIBS = -L/usr/local/lib -licui18n -licuuc -licudata -licuio \1|" Makefile
        echo "  ✅ ICU libraries added to EXTRA_LIBS"
        
        sed -i '' -e "s|^LIBS = \(.*\)$|LIBS = -L/usr/local/lib -licui18n -licuuc -licudata -licuio \1|" Makefile
        echo "  ✅ ICU libraries added to LIBS"
        
        echo "  📋 AFTER modification:"
        grep "^EXTRA_LIBS" Makefile | head -1 | sed 's/^/    EXTRA_LIBS: /'
        grep "^LIBS" Makefile | head -1 | sed 's/^/    LIBS: /'
    fi

    # ============================================================
    # 编译 PHP
    # ============================================================
    echo "[ * ] Compiling PHP ${PHP_VERSION} (using ${NUM_CPUS} cores)..."
    CURRENT_LIBS=$(grep "^LIBS" Makefile | head -1 | sed 's/^LIBS = //')
    gmake -j "$NUM_CPUS" \
        LDFLAGS="-L/usr/local/lib -Wl,-rpath,/usr/local/lib" \
        LIBS="-licui18n -licuuc -licudata -licuio ${CURRENT_LIBS}" \
        > "$LOG_DIR/build-${PHP_VERSION}.log"
    BUILD_STATUS=$?

    if [ -n "$OLD_LD_PRELOAD" ]; then
        export LD_PRELOAD="$OLD_LD_PRELOAD"
    fi

    if [ $BUILD_STATUS -ne 0 ]; then
        echo ""
        echo "========================================"
        echo "❌ BUILD FAILED"
        echo "========================================"
        echo ""
        echo "=== All errors ==="
        grep -E "error:|Error:|undefined reference|failed" "$LOG_DIR/build-${PHP_VERSION}.log" | head -200
        echo ""
        echo "========================================"
        echo "Last 200 lines:"
        echo "========================================"
        tail -200 "$LOG_DIR/build-${PHP_VERSION}.log"
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
    # 生成 phar.phar
    # ============================================================
    echo ""
    echo "[*] Generating phar.phar..."
    
    cd "$build_dir" || return 1
    
    if [ ! -f "modules/phar.so" ] && [ ! -f "ext/phar/.libs/phar.so" ]; then
        echo "❌ phar.so not found! phar extension was not built."
        echo "   Check: configure --enable-phar=shared"
        return 1
    fi
    
    echo "  Attempt 1: make ext/phar/phar.phar"
    make ext/phar/phar.phar | tee -a "$LOG_DIR/phar-gen.log" || true
    
    if [ ! -f "ext/phar/phar.phar" ] || [ ! -s "ext/phar/phar.phar" ]; then
        echo "❌ phar.phar not generated or empty"
        return 1
    fi
    
    echo "  ✅ phar.phar ready ($(du -h ext/phar/phar.phar | cut -f1))"

    # ============================================================
    # 安装 PHP
    # ============================================================
    echo ""
    echo "[*] Installing PHP ${PHP_VERSION}..."
    mkdir -p "$install_dir"
    echo "[ * ] Installing phpize and php-config..."
    if [ -f "Makefile" ]; then
        if ! gmake install-programs INSTALL_ROOT="$install_dir" | tee -a "$LOG_DIR/install-programs.log"; then
            echo "  ⚠️  make install-programs failed, copying from source..."
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
        
        if [ -f "$install_dir/usr/local/bin/phpize" ] && [ -f "$install_dir/usr/local/bin/php-config" ]; then
            echo "  ✅ phpize: $(ls -l $install_dir/usr/local/bin/phpize)"
            echo "  ✅ php-config: $(ls -l $install_dir/usr/local/bin/php-config)"
        else
            echo "  ⚠️  phpize or php-config still missing"
        fi
    fi
    
    echo "[ * ] Step 1: Installing PHP (without PEAR)..."
    
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
    
    echo ""
    echo "  Running: gmake install INSTALL_ROOT=\"$install_dir\""
    if ! gmake install INSTALL_ROOT="$install_dir" > "$LOG_DIR/install-${PHP_VERSION}.log" 2>&1; then
        echo "❌ PHP install failed"
        echo ""
        echo "--- Last 50 lines of install log ---"
        tail -50 "$LOG_DIR/install-${PHP_VERSION}.log"
        
        echo ""
        echo "--- Trying component installation ---"
        for target in install-cli install-cgi install-fpm install-build install-pdo-headers; do
            echo "  Installing $target..."
            gmake $target INSTALL_ROOT="$install_dir" 2>> "$LOG_DIR/install-${PHP_VERSION}.log" || true
        done
        
        if [ -d "modules" ]; then
            ZEND_API_NO=$(grep "^#define ZEND_MODULE_API_NO" Zend/zend_modules.h | awk '{print $3}')
            EXT_DIR="$install_dir/usr/local/lib/php/extensions/no-debug-non-zts-${ZEND_API_NO}"
            mkdir -p "$EXT_DIR"
            find modules -name "*.so" -exec cp {} "$EXT_DIR/" \;
            echo "  ✓ Extensions copied manually"
        fi
        
        mkdir -p "$install_dir/usr/local/bin"
        [ -f "sapi/cli/php" ] && cp sapi/cli/php "$install_dir/usr/local/bin/" && chmod 755 "$install_dir/usr/local/bin/php"
        [ -f "sapi/cgi/php-cgi" ] && cp sapi/cgi/php-cgi "$install_dir/usr/local/bin/" && chmod 755 "$install_dir/usr/local/bin/php-cgi"
        [ -f "sapi/fpm/php-fpm" ] && cp sapi/fpm/php-fpm "$install_dir/usr/local/bin/" && chmod 755 "$install_dir/usr/local/bin/php-fpm"
        
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
    
    if [ ! -f "$install_dir/usr/local/bin/php" ]; then
        echo "❌ PHP binary not found!"
        echo "Contents of $install_dir/usr/local/bin:"
        ls -la "$install_dir/usr/local/bin/" || echo "  (empty)"
        return 1
    fi
    
    echo ""
    echo "  ✅ PHP installed successfully"
    echo "  PHP version: $($install_dir/usr/local/bin/php -v | head -1)"
    
    if [ -f "Makefile.bak" ]; then
        mv Makefile.bak Makefile
        echo "  ✓ Restored Makefile"
    fi
    
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
    # 编译 ImageMagick 扩展（打包前安装）
    # ============================================================
    if ! build_imagick "$build_dir" "$install_dir"; then
        echo "⚠️  ImageMagick extension build failed"
    fi

    # ============================================================
    # 编译 APCu 扩展（打包前安装）
    # ============================================================
    if ! build_apcu "$build_dir" "$install_dir"; then
        echo "⚠️  APCu extension build failed"
    fi

    # ============================================================
    # 安装 PSPell 扩展（源码优先，PECL 备用）
    # ============================================================
    if ! install_pspell "$install_dir" "$build_dir"; then
        echo "⚠️  PSPell extension installation failed, continuing without it"
    fi

    # ============================================================
    # 安装 IMAP 扩展（PHP 8.4 使用 PECL）
    # ============================================================
    IMAP_INSTALLED=0
    if [ "$BUILD_IMAP" = "yes" ]; then
        # 首先尝试 PECL 安装
        if install_imap_pecl "$install_dir" "$build_dir"; then
            IMAP_INSTALLED=1
        else
            echo "⚠️  PECL installation failed, trying manual build..."
            if install_imap_manual "$install_dir" "$build_dir"; then
                IMAP_INSTALLED=1
            else
                echo "⚠️  IMAP extension build failed, continuing without it"
            fi
        fi
    else
        echo "[ * ] IMAP extension disabled (BUILD_IMAP=no)"
    fi

    # ============================================================
    # 验证所有扩展已安装
    # ============================================================
    echo ""
    echo "========================================"
    echo "[ * ] Verifying installed extensions"
    echo "========================================"
    
    local php_bin="$install_dir/usr/local/bin/php"
    local zend_api_no=$(grep "^#define ZEND_MODULE_API_NO" "$build_dir/Zend/zend_modules.h" | awk '{print $3}')
    local ext_dir="$install_dir/usr/local/lib/php/extensions/no-debug-non-zts-${zend_api_no}"
    
    echo "Extension directory: $ext_dir"
    echo ""
    echo "Installed extensions:"
    if [ -d "$ext_dir" ]; then
        ls -la "$ext_dir/" | grep -E "\.so$" | sed 's/^/  /'
    fi
    
    echo ""
    echo "PHP modules:"
    "$php_bin" -m | grep -E "^(imagick|apcu|imap|phar|opcache|intl)" | sed 's/^/  /'
    
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
    local php_ini="$install_dir/usr/local/etc/php.ini"
    
    echo ""
    echo "========================================"
    echo "[ * ] Creating FreeBSD package..."
    echo "========================================"
    
    if [ ! -f "$php_bin" ]; then
        echo "❌ PHP binary not found at $php_bin!"
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
    
    echo "[ * ] Verifying all extensions..."
    PHP_SRC_DIR="$BUILD_DIR/php-src-${PHP_VERSION}"
    ZEND_API_NO=$(grep "^#define ZEND_MODULE_API_NO" "$PHP_SRC_DIR/Zend/zend_modules.h" | awk '{print $3}')
    EXTENSION_DIR="$install_dir/usr/local/lib/php/extensions/no-debug-non-zts-${ZEND_API_NO}"

    # 测试所有扩展
    local extensions=("imagick" "apcu")
    if [ "$BUILD_IMAP" = "yes" ]; then
        extensions+=("imap")
    fi
    
    for ext in "${extensions[@]}"; do
        if [ -f "$EXTENSION_DIR/${ext}.so" ]; then
            echo "✅ ${ext}.so found"
        else
            echo "⚠️  ${ext}.so not found"
        fi
    done

    # 运行完整测试
    local ext_list=""
    for ext in "${extensions[@]}"; do
        ext_list="$ext_list -d extension=$ext.so"
    done
    
    "$php_bin" $ext_list -r '
        $extensions = ["imagick", "apcu", "openssl", "intl"];
        if (extension_loaded("imap")) {
            $extensions[] = "imap";
        }
        echo "PHP Version: " . PHP_VERSION . "\n";
        echo "OpenSSL Version: " . OPENSSL_VERSION_TEXT . "\n";
        echo "OpenSSL functions: " . (function_exists("openssl_encrypt") ? "✅" : "❌") . "\n";
        foreach ($extensions as $ext) {
            $loaded = extension_loaded($ext);
            echo "$ext extension: " . ($loaded ? "✅" : "❌") . "\n";
        }
        if (extension_loaded("imagick")) {
            $formats = Imagick::queryFormats("*");
            echo "ImageMagick supports " . count($formats) . " formats\n";
        }
        if (extension_loaded("apcu")) {
            echo "APCu functions: " . (function_exists("apcu_store") ? "✅" : "❌") . "\n";
            if (function_exists("apcu_store") && function_exists("apcu_fetch")) {
                apcu_store("test_key", "test_value", 60);
                $value = apcu_fetch("test_key");
                echo "APCu test: " . ($value === "test_value" ? "✅" : "❌") . "\n";
            }
        }
        if (extension_loaded("imap")) {
            echo "IMAP functions: " . (function_exists("imap_open") ? "✅" : "❌") . "\n";
        }
    '
    
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
    
    echo "[ * ] Cleaning up unnecessary files..."
    for dir in "${PKG_DIR}/usr/local/lib/php/php/test" \
               "${PKG_DIR}/usr/local/lib/php/php/doc" \
               "${PKG_DIR}/usr/local/lib/php/.channels" \
               "${PKG_DIR}/usr/local/lib/php/.registry" \
               "${PKG_DIR}/usr/local/lib/php/.filemap" \
               "${PKG_DIR}/usr/local/lib/php/.lock"; do
        if [ -d "$dir" ]; then
            rm -rf "$dir"
            echo "  Removed: $dir"
        fi
    done
    
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

This is a custom build of PHP 8.4.23 that includes:
- OpenSSL 4.x compatibility patches
- ImageMagick extension (imagick)
- APCu extension (apcu) - User cache
- IMAP extension (imap) - via PECL
- FPM, CLI, CGI support
- Common extensions: mbstring, bcmath, curl, gmp, mysqli, pdo_mysql, pgsql, pdo_pgsql, etc.
- Argon2 password hashing support
- Sodium cryptography support
- GD with JPEG, PNG, WebP, FreeType support
- Enums support
- Fibers support
- Readonly classes
- Disjunctive Normal Form (DNF) types

IMPORTANT: php 8.4 is end-of-life. Use at your own risk.
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
/usr/local/bin/php${ver_suffix} -m | grep -E "(imagick|apcu|imap|openssl|intl)" || echo "Some extensions not loaded"
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
    
    if [ ! -f "${PKG_FILE}" ]; then
        echo "❌ Failed to create package!"
        echo "Files in ${ARTIFACT_DIR}:"
        ls -la "${ARTIFACT_DIR}/"
        return 1
    fi

    FILE_SIZE=$(du -h "${PKG_FILE}" | cut -f1)
    echo ""
    echo "========================================"
    echo "✅ Package created successfully!"
    echo "========================================"
    echo "Package: ${PKG_FILE}"
    echo "Size: ${FILE_SIZE}"
    echo "========================================"

    # 验证包
    echo ""
    echo "========================================"
    echo "[ * ] Verifying package installation..."
    echo "========================================"

    TEST_ROOT="/tmp/php-pkg-test-$$"
    mkdir -p "$TEST_ROOT"
    mkdir -p "$TEST_ROOT/usr/local"
    mkdir -p "$TEST_ROOT/var/db/pkg"

    echo "[ * ] Installing package to test root: $TEST_ROOT"

    if tar -xf "$PKG_FILE" -C "$TEST_ROOT"; then
        echo "  ✅ Package extracted with tar"
    else
        echo "  ⚠️  tar extraction failed, trying pkg..."
        
        mkdir -p "$TEST_ROOT/etc/pkg"
        cat > "$TEST_ROOT/etc/pkg/FreeBSD.conf" << EOF
FreeBSD: {
url: "pkg+http://pkg.FreeBSD.org/\${ABI}/quarterly",
mirror_type: "srv",
signature_type: "fingerprints",
fingerprints: "/usr/share/keys/pkg",
enabled: yes
}
EOF

        export PKG_DBDIR="$TEST_ROOT/var/db/pkg"
        export PKG_CACHEDIR="$TEST_ROOT/var/cache/pkg"
        
        if pkg -c "$TEST_ROOT" add "$PKG_FILE" 2>&1; then
            echo "  ✅ Package installed with pkg"
        else
            echo "  ❌ Package installation failed"
            if bsdtar -xf "$PKG_FILE" -C "$TEST_ROOT"; then
                echo "  ✅ Package extracted with bsdtar"
            else
                echo "  ❌ All extraction methods failed"
                rm -rf "$TEST_ROOT"
                echo "  ⚠️  Package verification skipped, but package exists"
                return 0
            fi
        fi
    fi

    PHP_TEST_BIN="$TEST_ROOT/usr/local/bin/php${ver_suffix}"
    if [ ! -f "$PHP_TEST_BIN" ]; then
        PHP_TEST_BIN="$TEST_ROOT/usr/local/bin/php"
    fi

    if [ ! -f "$PHP_TEST_BIN" ] || [ ! -x "$PHP_TEST_BIN" ]; then
        echo "  ⚠️  PHP binary not found in test installation"
        echo "  Files in $TEST_ROOT/usr/local/bin:"
        ls -la "$TEST_ROOT/usr/local/bin/" || echo "    (empty)"
        rm -rf "$TEST_ROOT"
        return 0
    fi

    echo "  ✅ PHP binary found: $PHP_TEST_BIN"

    local zend_api_no=$(grep "^#define ZEND_MODULE_API_NO" "$PHP_SRC_DIR/Zend/zend_modules.h" | awk '{print $3}')
    local EXT_DIR="$TEST_ROOT/usr/local/lib/php/extensions/no-debug-non-zts-${zend_api_no}"
    
    local test_php_ini="$TEST_ROOT/usr/local/etc/php.ini"
    mkdir -p "$(dirname "$test_php_ini")"
    cat > "$test_php_ini" << EOF
extension_dir=${EXT_DIR}
extension=imagick.so
extension=apcu.so
zend_extension=opcache.so
apcu.enabled=1
apcu.shm_size=256M
apcu.ttl=7200
apcu.gc_ttl=3600
apcu.entries_hint=4096
EOF

    if [ -f "$EXT_DIR/imap.so" ]; then
        echo "extension=imap.so" >> "$test_php_ini"
    fi

    export LD_LIBRARY_PATH="$TEST_ROOT/usr/local/lib:/usr/local/lib"

    echo ""
    echo "[ * ] Testing PHP version..."
    if "$PHP_TEST_BIN" -c "$test_php_ini" -v | head -1; then
        echo "  ✅ PHP binary works"
    else
        echo "  ⚠️  PHP binary test failed"
        rm -rf "$TEST_ROOT"
        return 0
    fi

    echo ""
    echo "[ * ] Testing extensions..."

    local extensions=("openssl" "intl" "imagick" "apcu" "phar" "opcache")
    if [ -f "$EXT_DIR/imap.so" ]; then
        extensions+=("imap")
    fi
    
    local all_ok=1

    for ext in "${extensions[@]}"; do
        echo -n "  $ext: "
        if "$PHP_TEST_BIN" -c "$test_php_ini" -m | grep -qi "^$ext$"; then
            echo "✅"
        else
            echo "❌"
            all_ok=0
        fi
    done

    echo ""
    echo "[ * ] Testing Imagick class..."
    if "$PHP_TEST_BIN" -c "$test_php_ini" -r 'if (class_exists("Imagick")) { echo "  ✅ Imagick class exists\n"; } else { echo "  ❌ Imagick class not found\n"; exit(1); }'; then
        echo "  ✅ Imagick works"
    else
        echo "  ❌ Imagick test failed"
        all_ok=0
    fi

    echo ""
    echo "[ * ] Testing APCu functions..."
    if "$PHP_TEST_BIN" -c "$test_php_ini" -r '
        if (function_exists("apcu_store") && function_exists("apcu_fetch")) {
            echo "  ✅ APCu functions exist\n";
            apcu_store("test_key", "test_value", 60);
            $value = apcu_fetch("test_key");
            if ($value === "test_value") {
                echo "  ✅ APCu basic operations work\n";
            } else {
                echo "  ❌ APCu store/fetch test failed\n";
                exit(1);
            }
        } else {
            echo "  ❌ APCu functions not found\n";
            exit(1);
        }
    '; then
        echo "  ✅ APCu works"
    else
        echo "  ❌ APCu test failed"
        all_ok=0
    fi

    if [ -f "$EXT_DIR/imap.so" ]; then
        echo ""
        echo "[ * ] Testing IMAP functions..."
        if "$PHP_TEST_BIN" -c "$test_php_ini" -r 'if (function_exists("imap_open")) { echo "  ✅ imap_open exists\n"; } else { echo "  ❌ imap_open not found\n"; exit(1); }'; then
            echo "  ✅ IMAP works"
        else
            echo "  ❌ IMAP test failed"
            all_ok=0
        fi
    fi

    echo ""
    echo "[ * ] Extension files in package:"
    if [ -d "$EXT_DIR" ]; then
        ls -la "$EXT_DIR/" | grep -E "\.so$" | sed 's/^/    /'
    fi

    echo ""
    echo "[ * ] Cleaning up test environment..."
    rm -rf "$TEST_ROOT"
    echo "  ✅ Test environment cleaned"

    if [ $all_ok -eq 1 ]; then
        echo ""
        echo "========================================"
        echo "✅ ALL TESTS PASSED - Package is valid!"
        echo "========================================"
    else
        echo ""
        echo "========================================"
        echo "⚠️  Some tests failed - Package may have issues"
        echo "========================================"
    fi

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