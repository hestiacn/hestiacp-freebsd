#!/bin/bash
# ============================================================
# 文件名: build-mariadb-packages.sh
# 描述: 在 FreeBSD 上构建类似 Debian 风格的 MariaDB 包
# 目标: 解决 p5-DBD-MariaDB 与 mariadb123-client 的冲突
# 版本: 2.0 - MariaDB 12.3.2
# ============================================================

set -e

# ============================================================
# 配置变量 - MariaDB 12.3.2
# ============================================================
MARIADB_VERSION="12.3.2"
MARIADB_MAJOR="12.3"
PKG_VERSION="123"
WORKDIR="/tmp/hestiacp-src/mariadb-build"
PKGDIR="/tmp/hestiacp-src/pkg"
LOG_FILE="${WORKDIR}/build.log"
MAKE_JOBS=$(sysctl -n hw.ncpu)
architecture="$(uname -m)"
release="$(uname -r | cut -d'.' -f1)"
# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

mkdir -p "$WORKDIR" "$PKGDIR"
cd "$WORKDIR"
export TZ=Asia/Shanghai
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

print_header() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
}

# ============================================================
# 1. 安装编译依赖
# ============================================================
print_header "Step 1: Installing build dependencies"

log "Installing required packages for compilation..."

pkg install -y cmake gmake gcc14 openssl40 libedit ncurses perl5 pkgconf git wget curl bison flex libxml2 liblz4 libunwind icu groff cyrus-sasl hidapi snappy autoconf automake libtool 2>&1 | tee -a "$LOG_FILE"
log "Build dependencies installed successfully"

# ============================================================
# 1.5 编译 Judy 库（FreeBSD 仓库中没有）
# ============================================================
print_header "Step 1.5: Building Judy library from source"

JUDY_VERSION="1.0.5"
JUDY_DIR="/tmp/hestiacp-src/judy-build"

# 检查 Judy 是否已安装
if [ -f /usr/local/lib/libJudy.so ] && [ -f /usr/local/include/Judy.h ]; then
    log "✅ Judy already installed, skipping build"
else
    log "Judy not found, building from source..."
    
    mkdir -p "$JUDY_DIR"
    cd "$JUDY_DIR"
    
    # 下载
    if [ ! -f "v${JUDY_VERSION}-netdata2.tar.gz" ]; then
        log "Downloading Judy ${JUDY_VERSION} from GitHub (netdata version)..."
        fetch "https://github.com/netdata/libjudy/archive/refs/tags/v${JUDY_VERSION}-netdata2.tar.gz" 2>&1 | tee -a "$LOG_FILE"
    fi
    
    # 解压
    if [ ! -d "libjudy-${JUDY_VERSION}-netdata2" ]; then
        log "Extracting Judy..."
        tar -xzf "v${JUDY_VERSION}-netdata2.tar.gz" 2>&1 | tee -a "$LOG_FILE"
    fi
    
    cd "libjudy-${JUDY_VERSION}-netdata2/src"
    # 修改 sh_build 脚本
    log "Fixing sh_build script..."
    sed -i '' 's/^CC=.*/CC="gcc"/' sh_build
    sed -i '' 's/^CPIC=.*/CPIC="-fPIC"/' sh_build
    sed -i '' 's/^COPT=.*/COPT="-O2"/' sh_build
    sed -i '' 's/^#ld -shared -o libJudy.so Judy\*\/\*.o/ld -shared -o libJudy.so Judy*\/\*.o/' sh_build

    # 直接运行 sh_build 编译
    log "Compiling Judy with sh_build..."
    ./sh_build 2>&1 | tee -a "$LOG_FILE"
    if [ ! -f "libJudy.so" ] && [ -f "libJudy.a" ]; then
        log "libJudy.so not generated, creating manually from .o files..."
        O_FILES=$(find Judy* -name "*.o" | tr '\n' ' ')
        if [ -n "$O_FILES" ]; then
            gcc -shared -o libJudy.so $O_FILES -Wl,-soname,libJudy.so
        else
            gcc -shared -o libJudy.so -Wl,-whole-archive libJudy.a -Wl,-no-whole-archive
        fi
        echo "  ✅ libJudy.so created manually"
    fi
    
    # 安装
    log "Installing Judy..."
    cp libJudy.a /usr/local/lib/
    cp libJudy.so /usr/local/lib/
    cp Judy.h /usr/local/include/
    log "Creating Judy pkg-config file..."
    mkdir -p /usr/local/lib/pkgconfig
    cat > /usr/local/lib/pkgconfig/judy.pc << 'EOF'
prefix=/usr/local
exec_prefix=${prefix}
libdir=${exec_prefix}/lib
includedir=${prefix}/include

Name: Judy
Description: Judy dynamic array library
Version: 1.0.5
Libs: -L${libdir} -lJudy
Cflags: -I${includedir}
EOF
    ln -sf /usr/local/lib/libJudy.so /usr/local/lib/libjudy.so || true
    ln -sf /usr/local/lib/libJudy.a /usr/local/lib/libjudy.a || true
    
    ldconfig -m /usr/local/lib
    
    # 验证
    if [ -f /usr/local/lib/libJudy.so ] && [ -f /usr/local/include/Judy.h ]; then
        log "✅ Judy installed successfully"
    else
        log "ERROR: Judy installation failed"
        if [ ! -f /usr/local/lib/libJudy.so ]; then
            log "  libJudy.so not found"
        fi
        if [ ! -f /usr/local/include/Judy.h ]; then
            log "  Judy.h not found"
        fi
        exit 1
    fi
    
    cd "$WORKDIR"
fi

# ============================================================
# 1.6 检查并设置 OpenSSL 环境
# ============================================================
print_header "Step 1.6: Setting up OpenSSL environment"

log "Detecting OpenSSL..."

# 检测并设置 OpenSSL 环境变量
if command -v openssl40 >/dev/null 2>&1; then
    log "✅ Using OpenSSL 4.x (openssl40)"
    export OPENSSL_ROOT=/usr/local
    export OPENSSL_LIB=/usr/local/lib
    export OPENSSL_INCLUDE=/usr/local/include
elif pkg info openssl40 >/dev/null 2>&1; then
    log "✅ openssl40 package installed, setting environment"
    export OPENSSL_ROOT=/usr/local
    export OPENSSL_LIB=/usr/local/lib
    export OPENSSL_INCLUDE=/usr/local/include
    export PATH=/usr/local/bin:$PATH
else
    log "⚠️ Using system OpenSSL (may be 3.x)"
    export OPENSSL_ROOT=/usr
    export OPENSSL_LIB=/usr/lib
    export OPENSSL_INCLUDE=/usr/include
fi

# 验证设置
log ""
log "OpenSSL environment:"
log "  OPENSSL_ROOT: $OPENSSL_ROOT"
log "  OPENSSL_LIB: $OPENSSL_LIB"
log "  OPENSSL_INCLUDE: $OPENSSL_INCLUDE"

# 导出到 CMake
export PKG_CONFIG_PATH="${OPENSSL_LIB}/pkgconfig:/usr/local/lib/pkgconfig:$PKG_CONFIG_PATH"
export CFLAGS="-I${OPENSSL_INCLUDE} $CFLAGS"
export LDFLAGS="-L${OPENSSL_LIB} $LDFLAGS"

log ""
log "✅ OpenSSL environment configured"

# ============================================================
# 2. 下载 MariaDB 源码
# ============================================================
print_header "Step 2: Downloading MariaDB source code"

cd "$WORKDIR"

# 检查源码文件是否已存在
if [ -f "mariadb-${MARIADB_VERSION}.tar.gz" ]; then
    log "✅ Source file mariadb-${MARIADB_VERSION}.tar.gz already exists"
    log "   Size: $(ls -lh mariadb-${MARIADB_VERSION}.tar.gz | awk '{print $5}')"
    log "   Skipping download..."
else
    log "Downloading MariaDB ${MARIADB_VERSION} source code..."
    
    if ! fetch -o mariadb-${MARIADB_VERSION}.tar.gz \
        "https://downloads.mariadb.org/interstitial/mariadb-${MARIADB_VERSION}/source/mariadb-${MARIADB_VERSION}.tar.gz" 2>&1; then
        log "Official source failed, trying mirror..."
        fetch -o mariadb-${MARIADB_VERSION}.tar.gz \
            "https://archive.mariadb.org/mariadb-${MARIADB_VERSION}/source/mariadb-${MARIADB_VERSION}.tar.gz"
    fi

    if [ ! -f "mariadb-${MARIADB_VERSION}.tar.gz" ]; then
        log "ERROR: Failed to download MariaDB source code"
        exit 1
    fi
    
    log "✅ Download completed: $(ls -lh mariadb-${MARIADB_VERSION}.tar.gz | awk '{print $5}')"
fi

# ============================================================
# 3. 解压源码
# ============================================================
print_header "Step 3: Extracting source code"

# 检查是否已解压
if [ -d "mariadb-${MARIADB_VERSION}" ]; then
    log "Source directory mariadb-${MARIADB_VERSION} already exists"
    log "Skipping extraction..."
else
    log "Extracting mariadb-${MARIADB_VERSION}.tar.gz..."
    tar -xzf mariadb-${MARIADB_VERSION}.tar.gz 2>&1 | tee -a "$LOG_FILE"
    
    if [ ! -d "mariadb-${MARIADB_VERSION}" ]; then
        log "ERROR: Extraction failed"
        exit 1
    fi
    log "Extraction completed"
fi

cd mariadb-${MARIADB_VERSION}
log "Source ready at: $(pwd)"

# ============================================================
# 3.5 修复 GSSAPI 编译问题（FreeBSD 的 krb5 兼容性）
# ============================================================
print_header "Step 3.5: Fixing GSSAPI for FreeBSD"

GSSAPI_FILE="$WORKDIR/mariadb-${MARIADB_VERSION}/plugin/auth_gssapi/gssapi_server.cc"

if [ -f "$GSSAPI_FILE" ]; then
    log "Fixing GSSAPI: removing #ifdef HAVE_KRB5_XFREE for FreeBSD..."
    sed -i '' 's/krb5_xfree/free/g' "$GSSAPI_FILE"
    sed -i '' '/#ifdef HAVE_KRB5_XFREE/d' "$GSSAPI_FILE"
    sed -i '' '/#endif/d' "$GSSAPI_FILE"
    
    log "✅ GSSAPI fix applied"
else
    log "⚠ GSSAPI file not found, skipping fix"
fi

# ============================================================
# 4. 配置编译选项（完整编译：服务端 + 客户端）
# ============================================================
print_header "Step 4: Configuring build"

log "Creating build directory..."
mkdir -p build
cd build
log "OpenSSL version: $(openssl version || echo 'not found')"
export PKG_CONFIG_PATH=/usr/local/lib/pkgconfig:$PKG_CONFIG_PATH
export PKG_CONFIG_PATH=/usr/local/libdata/pkgconfig:$PKG_CONFIG_PATH
log "Running CMake configuration..."
log "Build type: Release"
log "Install prefix: /usr/local"
log "Jobs: ${MAKE_JOBS}"

cmake .. \
    -DCMAKE_INSTALL_PREFIX=/usr/local \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DFEATURE_SET=large \
    -DJudy_INCLUDE_DIR=/usr/local/include \
    -DJudy_LIBRARY=/usr/local/lib/libJudy.so \
    -DWITH_READLINE=ON \
    -DOPENSSL_ROOT_DIR=/usr/local \
    -DOPENSSL_INCLUDE_DIR=/usr/local/include \
    -DOPENSSL_LIBRARIES="/usr/local/lib/libssl.so;/usr/local/lib/libcrypto.so" \
    -DWITH_SSL=system \
    -DWITH_ZLIB=system \
    -DWITH_LIBEDIT=system \
    -DWITH_EMBEDDED_SERVER=ON \
    -DPLUGIN_INNOBASE=YES \
    -DPLUGIN_MYISAM=YES \
    -DPLUGIN_MYISAMMRG=YES \
    -DPLUGIN_PARTITION=NO \
    -DPLUGIN_PERFSCHEMA=YES \
    -DPLUGIN_ARCHIVE=YES \
    -DPLUGIN_BLACKHOLE=YES \
    -DPLUGIN_FEDERATED=YES \
    -DPLUGIN_FEDERATEDX=YES \
    -DPLUGIN_CONNECT=YES \
    -DPLUGIN_SPIDER=NO \
    -DPLUGIN_MROONGA=NO \
    -DPLUGIN_ROCKSDB=NO \
    -DPLUGIN_TOKUDB=NO \
    -DWITH_UNIT_TESTS=OFF \
    2>&1 | tee -a "$LOG_FILE"

if [ $? -ne 0 ]; then
    log "ERROR: CMake configuration failed"
    exit 1
fi

log "CMake configuration completed successfully"

# ============================================================
# 5. 编译
# ============================================================
print_header "Step 5: Compiling (this may take 30-60 minutes)"

log "Starting compilation with ${MAKE_JOBS} parallel jobs..."
log "Please be patient..."

make -j${MAKE_JOBS} 2>&1 | tee -a "$LOG_FILE"

if [ $? -ne 0 ]; then
    log "ERROR: Compilation failed, trying with single job..."
    make 2>&1 | tee -a "$LOG_FILE"
    if [ $? -ne 0 ]; then
        log "ERROR: Compilation failed again"
        exit 1
    fi
fi

log "Compilation completed successfully"

# ============================================================
# 6. 安装到临时目录
# ============================================================
print_header "Step 6: Installing to temporary directory"

INSTALL_DIR="/tmp/mariadb-install"
rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR"

log "Installing to: $INSTALL_DIR"
make install DESTDIR="$INSTALL_DIR" 2>&1 | tee -a "$LOG_FILE"

if [ $? -ne 0 ]; then
    log "ERROR: Installation failed"
    exit 1
fi

log "Installation completed successfully"
log "Files installed: $(find "$INSTALL_DIR" -type f | wc -l) files"

cd "$WORKDIR"

log "Removing test files to reduce package size..."
# 删除测试套件（节省 500MB-1GB）
if [ -d "$INSTALL_DIR/usr/local/mariadb-test" ]; then
    rm -rf "$INSTALL_DIR/usr/local/mariadb-test"
    log "✅ Removed mariadb-test"
fi

if [ -d "$INSTALL_DIR/usr/local/sql-bench" ]; then
    rm -rf "$INSTALL_DIR/usr/local/sql-bench"
    log "✅ Removed sql-bench"
fi

log "Stripping binaries to reduce size..."
find "$INSTALL_DIR" -name "*.so" -exec strip -s {} \; || true
find "$INSTALL_DIR" -name "*.a" -exec strip -s {} \; || true
find "$INSTALL_DIR" -type f -perm -111 -exec strip -s {} \; || true

log "Final files: $(find "$INSTALL_DIR" -type f | wc -l) files"

# ============================================================
# 6.5 查看安装目录结构（调试用）
# ============================================================
print_header "Step 6.5: Checking installed files"

log "INSTALL_DIR: $INSTALL_DIR"
log "Files in INSTALL_DIR/usr/local:"
ls -la "$INSTALL_DIR/usr/local" | tee -a "$LOG_FILE"

log ""
log "Files in INSTALL_DIR/usr/local/bin:"
ls -la "$INSTALL_DIR/usr/local/bin" | tee -a "$LOG_FILE"

log ""
log "Files in INSTALL_DIR/usr/local/lib:"
ls -la "$INSTALL_DIR/usr/local/lib" | tee -a "$LOG_FILE"

log ""
log "Files in INSTALL_DIR/usr/local/sbin (if exists):"
ls -la "$INSTALL_DIR/usr/local/sbin" | tee -a "$LOG_FILE" || echo "  (sbin not found - mariadbd is in bin)"

log ""
log "Files in INSTALL_DIR/usr/local/include (if exists):"
ls -la "$INSTALL_DIR/usr/local/include" | tee -a "$LOG_FILE" || echo "  (include not found)"

log ""
log "Total files: $(find "$INSTALL_DIR" -type f | wc -l)"
log "Total directories: $(find "$INSTALL_DIR" -type d | wc -l)"

# ============================================================
# 7. 创建分离的包结构（像 Debian 一样）
# ============================================================
print_header "Step 7: Creating package structures"

mkdir -p "$PKGDIR"

# ============================================================
# 7.1 创建 libmariadb 包（共享库）
# ============================================================
log "Creating libmariadb package..."

LIBDIR="$PKGDIR/libmariadb"
mkdir -p "$LIBDIR/usr/local/lib" \
         "$LIBDIR/usr/local/include/mariadb" \
         "$LIBDIR/usr/local/lib/pkgconfig"

# === 调试：显示源文件位置 ===
log "DEBUG: Checking source files..."
log "  INSTALL_DIR/usr/local/lib contents:"
ls -la "$INSTALL_DIR/usr/local/lib" | head -20 | tee -a "$LOG_FILE"

# 复制共享库
if [ -d "$INSTALL_DIR/usr/local/lib" ]; then
    log "DEBUG: Copying libmariadb* from $INSTALL_DIR/usr/local/lib"
    cp -v "$INSTALL_DIR/usr/local/lib/libmariadb"* "$LIBDIR/usr/local/lib/" 2>&1 | tee -a "$LOG_FILE" || true
    cp -v "$INSTALL_DIR/usr/local/lib/libmysqlclient"* "$LIBDIR/usr/local/lib/" 2>&1 | tee -a "$LOG_FILE" || true
fi

# === 调试：检查复制结果 ===
log "DEBUG: LIBDIR/usr/local/lib contents after copy:"
ls -la "$LIBDIR/usr/local/lib" | tee -a "$LOG_FILE"

# 复制头文件
if [ -d "$INSTALL_DIR/usr/local/include/mariadb" ]; then
    log "DEBUG: Copying mariadb headers..."
    cp -rv "$INSTALL_DIR/usr/local/include/mariadb"/* "$LIBDIR/usr/local/include/mariadb/" 2>&1 | tee -a "$LOG_FILE" || true
fi

# 复制 MySQL 兼容头文件到 include/mysql
if [ -d "$INSTALL_DIR/usr/local/include/mysql" ]; then
    log "DEBUG: Copying mysql headers..."
    mkdir -p "$LIBDIR/usr/local/include/mysql"
    cp -rv "$INSTALL_DIR/usr/local/include/mysql"/* "$LIBDIR/usr/local/include/mysql/" 2>&1 | tee -a "$LOG_FILE" || true
fi

# === 调试：检查头文件 ===
log "DEBUG: LIBDIR/usr/local/include contents:"
ls -la "$LIBDIR/usr/local/include" | tee -a "$LOG_FILE"

# 复制 pkgconfig
if [ -f "$INSTALL_DIR/usr/local/lib/pkgconfig/mariadb.pc" ]; then
    log "DEBUG: Copying mariadb.pc"
    cp -v "$INSTALL_DIR/usr/local/lib/pkgconfig/mariadb.pc" "$LIBDIR/usr/local/lib/pkgconfig/" 2>&1 | tee -a "$LOG_FILE"
fi

# 创建 MySQL 兼容符号链接
cd "$LIBDIR/usr/local/lib"
log "DEBUG: Creating symlinks in $(pwd)"
[ -f libmariadb.so ] && ln -sf libmariadb.so libmysqlclient.so && log "  → libmysqlclient.so -> libmariadb.so" || log "  ⚠ libmariadb.so not found, skipping symlink"
cd "$LIBDIR/usr/local/lib/pkgconfig"
[ -f mariadb.pc ] && ln -sf mariadb.pc mysqlclient.pc && log "  → mysqlclient.pc -> mariadb.pc" || log "  ⚠ mariadb.pc not found, skipping symlink"
cd "$WORKDIR"

# === 调试：检查最终的包目录结构 ===
log "DEBUG: Final LIBDIR structure:"
find "$LIBDIR" -type f -o -type l | sort | tee -a "$LOG_FILE"
log "DEBUG: LIBDIR file count: $(find "$LIBDIR" -type f | wc -l)"
log "DEBUG: LIBDIR symlink count: $(find "$LIBDIR" -type l | wc -l)"

# 创建 MANIFEST
cat > "$LIBDIR/+MANIFEST" << EOF
{
  "name": "libmariadb",
  "version": "${MARIADB_VERSION}",
  "origin": "databases/libmariadb",
  "comment": "MariaDB client shared libraries (compatibility layer)",
  "desc": "MariaDB client shared libraries\nProvides libmysqlclient.so compatibility symlink\nDoes NOT conflict with other MariaDB/MySQL packages",
  "maintainer": "custom@localhost",
  "abi": "FreeBSD:${release}:${architecture}",
  "arch": "FreeBSD:${release}:${architecture}",
  "prefix": "/usr/local",
  "deps": {
    "openssl": {
      "origin": "security/openssl",
      "version": "3.0"
    },
    "zlib": {
      "origin": "archivers/zlib",
      "version": "1.3"
    },
    "libedit": {
      "origin": "devel/libedit",
      "version": "3.1"
    }
  }
}
EOF

log "DEBUG: +MANIFEST created:"
cat "$LIBDIR/+MANIFEST" | tee -a "$LOG_FILE"

# 创建 INSTALL 脚本
cat > "$LIBDIR/+INSTALL" << 'EOF'
#!/bin/sh
# POST-INSTALL script for libmariadb

echo "libmariadb: Creating compatibility symlinks..."

# Create libmysqlclient.so symlink
if [ -f /usr/local/lib/libmariadb.so ] && [ ! -L /usr/local/lib/libmysqlclient.so ]; then
    mkdir -p /usr/local/lib
    ln -sf /usr/local/lib/libmariadb.so /usr/local/lib/libmysqlclient.so
    echo "  → libmysqlclient.so -> libmariadb.so"
fi

# Create pkgconfig symlink
if [ -f /usr/local/lib/pkgconfig/mariadb.pc ] && [ ! -L /usr/local/lib/pkgconfig/mysqlclient.pc ]; then
    mkdir -p /usr/local/lib/pkgconfig
    ln -sf /usr/local/lib/pkgconfig/mariadb.pc /usr/local/lib/pkgconfig/mysqlclient.pc
    echo "  → mysqlclient.pc -> mariadb.pc"
fi

echo "libmariadb: Compatibility links created"
EOF
chmod +x "$LIBDIR/+INSTALL"

# 创建 POST_DEINSTALL 脚本
cat > "$LIBDIR/+POST_DEINSTALL" << 'EOF'
#!/bin/sh
# POST-DEINSTALL script for libmariadb

echo "libmariadb: Removing compatibility symlinks..."
rm -f /usr/local/lib/libmysqlclient.so
rm -f /usr/local/lib/pkgconfig/mysqlclient.pc
echo "libmariadb: Cleanup completed"
EOF
chmod +x "$LIBDIR/+POST_DEINSTALL"

# ============================================================
# 动态生成 pkg-plist（修复：路径需要包含 usr/local/）
# ============================================================
log "Generating pkg-plist for libmariadb..."
PLIST_FILE="$LIBDIR/pkg-plist"
> "$PLIST_FILE"

if [ -d "$LIBDIR/usr/local" ]; then
    cd "$LIBDIR"
    find usr/local -type f -o -type l | sed 's/^usr\/local\///' | sort >> "$PLIST_FILE"
    cd "$WORKDIR"
fi

log "DEBUG: pkg-plist created:"
cat "$PLIST_FILE" | tee -a "$LOG_FILE"
log "DEBUG: Total entries: $(wc -l < "$PLIST_FILE")"

# 打包
cd "$PKGDIR"
log "DEBUG: Running pkg create in $(pwd)"
log "DEBUG: pkg create -o . -m libmariadb"
pkg create -m "$LIBDIR" -p "$LIBDIR/pkg-plist" -r "$LIBDIR" -o . 2>&1 | tee -a "$LOG_FILE"

if [ $? -eq 0 ]; then
    log "DEBUG: Package created. Checking results..."
    ls -la "$PKGDIR"/*.pkg 2>&1 | tee -a "$LOG_FILE"
    rm -rf libmariadb
    log "✓ libmariadb package created"
else
    log "ERROR: Failed to create libmariadb package"
    exit 1
fi

# ============================================================
# 7.2 创建 mariadb-client-core 包（核心客户端工具）
# ============================================================
log "Creating mariadb-client-core package..."

COREDIR="$PKGDIR/mariadb-client-core"
mkdir -p "$COREDIR/usr/local/bin"

log "DEBUG: Available files in INSTALL_DIR/usr/local/bin:"
ls -la "$INSTALL_DIR/usr/local/bin" | tee -a "$LOG_FILE"

if [ -d "$INSTALL_DIR/usr/local/bin" ]; then
    for tool in mariadb mariadb-admin mariadb-dump mariadb-check mariadb-import mariadb-show; do
        if [ -f "$INSTALL_DIR/usr/local/bin/$tool" ]; then
            cp "$INSTALL_DIR/usr/local/bin/$tool" "$COREDIR/usr/local/bin/"
            log "  Copied: $tool"
        else
            log "  ⚠ Not found: $tool"
        fi
    done
fi

# 创建 MySQL 兼容符号链接
cd "$COREDIR/usr/local/bin"
if [ -f mariadb ]; then
    ln -sf mariadb mysql
    log "  → mysql -> mariadb"
fi
if [ -f mariadb-admin ]; then
    ln -sf mariadb-admin mysqladmin
    log "  → mysqladmin -> mariadb-admin"
fi
if [ -f mariadb-dump ]; then
    ln -sf mariadb-dump mysqldump
    log "  → mysqldump -> mariadb-dump"
fi
if [ -f mariadb-check ]; then
    ln -sf mariadb-check mysqlcheck
    log "  → mysqlcheck -> mariadb-check"
fi
if [ -f mariadb-import ]; then
    ln -sf mariadb-import mysqlimport
    log "  → mysqlimport -> mariadb-import"
fi
if [ -f mariadb-show ]; then
    ln -sf mariadb-show mysqlshow
    log "  → mysqlshow -> mariadb-show"
fi
cd "$WORKDIR"

# 动态生成 pkg-plist（根据实际安装的文件）
log "Generating pkg-plist for mariadb-client-core..."
PLIST_FILE="$COREDIR/pkg-plist"
> "$PLIST_FILE"

# 列出实际安装的文件并生成 plist
if [ -d "$COREDIR/usr/local/bin" ]; then
    cd "$COREDIR"
    find usr/local/bin -type f -o -type l | sed 's/^usr\/local\///' | sort >> "$PLIST_FILE"
    cd "$WORKDIR"
fi

log "DEBUG: pkg-plist contents:"
cat "$PLIST_FILE" | tee -a "$LOG_FILE"

# 创建 MANIFEST
cat > "$COREDIR/+MANIFEST" << EOF
{
  "name": "mariadb-client-core",
  "version": "${MARIADB_VERSION}",
  "origin": "databases/mariadb-client-core",
  "comment": "MariaDB client core tools (compatibility layer)",
  "desc": "Core MariaDB client tools\nProvides /usr/local/bin/mysql as compatibility symlink\nDoes NOT conflict with other MariaDB/MySQL packages",
  "maintainer": "custom@localhost",
  "abi": "FreeBSD:${release}:${architecture}",
  "arch": "FreeBSD:${release}:${architecture}",
  "prefix": "/usr/local",
  "deps": {
    "libmariadb": {
      "origin": "databases/libmariadb",
      "version": "${MARIADB_VERSION}"
    }
  }
}
EOF

# 创建 INSTALL 脚本
cat > "$COREDIR/+INSTALL" << 'EOF'
#!/bin/sh
# POST-INSTALL script for mariadb-client-core

echo "mariadb-client-core: Creating MySQL compatibility symlinks..."

if [ -f /usr/local/bin/mariadb ] && [ ! -L /usr/local/bin/mysql ]; then
    ln -sf mariadb /usr/local/bin/mysql
    echo "  → mysql -> mariadb"
fi
if [ -f /usr/local/bin/mariadb-admin ] && [ ! -L /usr/local/bin/mysqladmin ]; then
    ln -sf mariadb-admin /usr/local/bin/mysqladmin
    echo "  → mysqladmin -> mariadb-admin"
fi
if [ -f /usr/local/bin/mariadb-dump ] && [ ! -L /usr/local/bin/mysqldump ]; then
    ln -sf mariadb-dump /usr/local/bin/mysqldump
    echo "  → mysqldump -> mariadb-dump"
fi
if [ -f /usr/local/bin/mariadb-check ] && [ ! -L /usr/local/bin/mysqlcheck ]; then
    ln -sf mariadb-check /usr/local/bin/mysqlcheck
    echo "  → mysqlcheck -> mariadb-check"
fi
if [ -f /usr/local/bin/mariadb-import ] && [ ! -L /usr/local/bin/mysqlimport ]; then
    ln -sf mariadb-import /usr/local/bin/mysqlimport
    echo "  → mysqlimport -> mariadb-import"
fi
if [ -f /usr/local/bin/mariadb-show ] && [ ! -L /usr/local/bin/mysqlshow ]; then
    ln -sf mariadb-show /usr/local/bin/mysqlshow
    echo "  → mysqlshow -> mariadb-show"
fi

echo "mariadb-client-core: Installation complete"
EOF
chmod +x "$COREDIR/+INSTALL"

# 创建 POST_DEINSTALL 脚本
cat > "$COREDIR/+POST_DEINSTALL" << 'EOF'
#!/bin/sh
# POST-DEINSTALL script for mariadb-client-core

echo "mariadb-client-core: Removing compatibility symlinks..."
rm -f /usr/local/bin/mysql
rm -f /usr/local/bin/mysqladmin
rm -f /usr/local/bin/mysqldump
rm -f /usr/local/bin/mysqlcheck
rm -f /usr/local/bin/mysqlimport
rm -f /usr/local/bin/mysqlshow
echo "mariadb-client-core: Cleanup completed"
EOF
chmod +x "$COREDIR/+POST_DEINSTALL"

# 打包
cd "$PKGDIR"
log "DEBUG: Running pkg create for mariadb-client-core..."
pkg create -m "$COREDIR" -p "$COREDIR/pkg-plist" -r "$COREDIR" -o . 2>&1 | tee -a "$LOG_FILE"

if [ $? -eq 0 ]; then
    rm -rf mariadb-client-core
    log "✓ mariadb-client-core package created"
else
    log "ERROR: Failed to create mariadb-client-core package"
    exit 1
fi

# ============================================================
# 7.3 创建 mariadb${PKG_VERSION}-client 包（完整客户端）
# ============================================================
log "Creating mariadb${PKG_VERSION}-client package..."

CLIENTDIR="$PKGDIR/mariadb${PKG_VERSION}-client"
mkdir -p "$CLIENTDIR/usr/local"

# 复制所有非 bin/lib/include/mariadb-test 的内容
if [ -d "$INSTALL_DIR/usr/local" ]; then
    # 复制 share
    if [ -d "$INSTALL_DIR/usr/local/share" ]; then
        mkdir -p "$CLIENTDIR/usr/local/share"
        cp -r "$INSTALL_DIR/usr/local/share"/* "$CLIENTDIR/usr/local/share/" || true
    fi
    
    # 复制 man
    if [ -d "$INSTALL_DIR/usr/local/man" ]; then
        mkdir -p "$CLIENTDIR/usr/local/man"
        cp -r "$INSTALL_DIR/usr/local/man"/* "$CLIENTDIR/usr/local/man/" || true
    fi
    
    # 复制 support-files
    if [ -d "$INSTALL_DIR/usr/local/support-files" ]; then
        mkdir -p "$CLIENTDIR/usr/local/support-files"
        cp -r "$INSTALL_DIR/usr/local/support-files"/* "$CLIENTDIR/usr/local/support-files/" || true
    fi
    
    # 复制 scripts
    if [ -d "$INSTALL_DIR/usr/local/scripts" ]; then
        mkdir -p "$CLIENTDIR/usr/local/scripts"
        cp -r "$INSTALL_DIR/usr/local/scripts"/* "$CLIENTDIR/usr/local/scripts/" || true
    fi
    
    # 复制 docs
    if [ -d "$INSTALL_DIR/usr/local/docs" ]; then
        mkdir -p "$CLIENTDIR/usr/local/docs"
        cp -r "$INSTALL_DIR/usr/local/docs"/* "$CLIENTDIR/usr/local/docs/" || true
    fi
    
    # 复制根目录的文件（README, COPYING 等）
    cp "$INSTALL_DIR/usr/local/"*.md "$INSTALL_DIR/usr/local/"*.txt "$INSTALL_DIR/usr/local/COPYING" "$INSTALL_DIR/usr/local/CREDITS" "$INSTALL_DIR/usr/local/INSTALL-BINARY" "$CLIENTDIR/usr/local/" 2>/dev/null || true
fi

# 创建客户端配置文件模板
mkdir -p "$CLIENTDIR/usr/local/etc/mysql/conf.d"
cat > "$CLIENTDIR/usr/local/etc/mysql/my.cnf.sample" << 'EOF'
[client]
port = 3306
socket = /var/run/mysql/mysql.sock
default-character-set = utf8mb4
EOF

cat > "$CLIENTDIR/usr/local/etc/mysql/conf.d/client.cnf.sample" << 'EOF'
[client]
port = 3306
socket = /var/run/mysql/mysql.sock
default-character-set = utf8mb4
EOF

# ============================================================
# 动态生成 pkg-plist（修复：在 CLIENTDIR 中执行 find）
# ============================================================
log "Generating pkg-plist for mariadb${PKG_VERSION}-client..."
PLIST_FILE="$CLIENTDIR/pkg-plist"
> "$PLIST_FILE"

if [ -d "$CLIENTDIR/usr/local" ]; then
    cd "$CLIENTDIR"
    find usr/local -type f -o -type l | sed 's/^usr\/local\///' | sort >> "$PLIST_FILE"
    cd "$WORKDIR"
fi

log "DEBUG: pkg-plist contents (first 50 lines):"
head -50 "$PLIST_FILE" | tee -a "$LOG_FILE"
log "DEBUG: Total entries: $(wc -l < "$PLIST_FILE")"

# 创建 MANIFEST
cat > "$CLIENTDIR/+MANIFEST" << EOF
{
  "name": "mariadb${PKG_VERSION}-client",
  "version": "${MARIADB_VERSION}",
  "origin": "databases/mariadb${PKG_VERSION}-client",
  "comment": "MariaDB ${MARIADB_MAJOR} client (complete package)",
  "desc": "Complete MariaDB client package\nDepends on mariadb-client-core for binaries and libmariadb for libraries",
  "maintainer": "custom@localhost",
  "abi": "FreeBSD:${release}:${architecture}",
  "arch": "FreeBSD:${release}:${architecture}",
  "prefix": "/usr/local",
  "deps": {
    "libmariadb": {
      "origin": "databases/libmariadb",
      "version": "${MARIADB_VERSION}"
    },
    "mariadb-client-core": {
      "origin": "databases/mariadb-client-core",
      "version": "${MARIADB_VERSION}"
    }
  }
}
EOF

# 打包
cd "$PKGDIR"
log "DEBUG: Running pkg create for mariadb${PKG_VERSION}-client..."
pkg create -m "$CLIENTDIR" -p "$CLIENTDIR/pkg-plist" -r "$CLIENTDIR" -o . 2>&1 | tee -a "$LOG_FILE"

if [ $? -eq 0 ]; then
    rm -rf "mariadb${PKG_VERSION}-client"
    log "✓ mariadb${PKG_VERSION}-client package created"
else
    log "ERROR: Failed to create mariadb${PKG_VERSION}-client package"
    exit 1
fi

# ============================================================
# 7.4 创建 mariadb${PKG_VERSION}-server 包（服务端）
# ============================================================
log "Creating mariadb${PKG_VERSION}-server package..."

SERVERDIR="$PKGDIR/mariadb${PKG_VERSION}-server"
mkdir -p "$SERVERDIR/usr/local/bin"

# 复制服务端二进制文件
if [ -d "$INSTALL_DIR/usr/local/bin" ]; then
    cp "$INSTALL_DIR/usr/local/bin/mariadbd" "$SERVERDIR/usr/local/bin/" || true
    cp "$INSTALL_DIR/usr/local/bin/mysqld" "$SERVERDIR/usr/local/bin/" || true
    cp "$INSTALL_DIR/usr/local/bin/mariadb-backup" "$SERVERDIR/usr/local/bin/" || true
    cp "$INSTALL_DIR/usr/local/bin/mariabackup" "$SERVERDIR/usr/local/bin/" || true
    cp "$INSTALL_DIR/usr/local/bin/mbstream" "$SERVERDIR/usr/local/bin/" || true
    cp "$INSTALL_DIR/usr/local/bin/innochecksum" "$SERVERDIR/usr/local/bin/" || true
    cp "$INSTALL_DIR/usr/local/bin/mariadbd-multi" "$SERVERDIR/usr/local/bin/" || true
    cp "$INSTALL_DIR/usr/local/bin/mariadbd-safe" "$SERVERDIR/usr/local/bin/" || true
    cp "$INSTALL_DIR/usr/local/bin/mariadbd-safe-helper" "$SERVERDIR/usr/local/bin/" || true
fi

# 复制服务端插件
if [ -d "$INSTALL_DIR/usr/local/lib/mariadb/plugin" ]; then
    mkdir -p "$SERVERDIR/usr/local/lib/mariadb"
    cp -r "$INSTALL_DIR/usr/local/lib/mariadb/plugin" "$SERVERDIR/usr/local/lib/mariadb/" || true
fi

# 复制服务端库文件
if [ -d "$INSTALL_DIR/usr/local/lib" ]; then
    mkdir -p "$SERVERDIR/usr/local/lib"
    cp "$INSTALL_DIR/usr/local/lib/libmariadbd"* "$SERVERDIR/usr/local/lib/" || true
    cp "$INSTALL_DIR/usr/local/lib/libmysqld"* "$SERVERDIR/usr/local/lib/" || true
fi

# 复制配置文件
if [ -d "$INSTALL_DIR/usr/local/etc/mysql" ]; then
    mkdir -p "$SERVERDIR/usr/local/etc"
    cp -r "$INSTALL_DIR/usr/local/etc/mysql" "$SERVERDIR/usr/local/etc/" || true
fi

# 创建服务端配置文件模板
mkdir -p "$SERVERDIR/usr/local/etc/mysql/conf.d"
cat > "$SERVERDIR/usr/local/etc/mysql/conf.d/server.cnf.sample" << 'EOF'
[mysqld]
port = 3306
socket = /tmp/mysql.sock
datadir = /var/db/mysql
pid-file = /var/run/mysqld/mysqld.pid
user = mysql
bind-address = 127.0.0.1
EOF

# 复制数据目录
if [ -d "$INSTALL_DIR/usr/local/share/mysql" ]; then
    mkdir -p "$SERVERDIR/usr/local/share"
    cp -r "$INSTALL_DIR/usr/local/share/mysql" "$SERVERDIR/usr/local/share/" || true
fi

# 复制 man 手册
if [ -d "$INSTALL_DIR/usr/local/man" ]; then
    mkdir -p "$SERVERDIR/usr/local"
    cp -r "$INSTALL_DIR/usr/local/man" "$SERVERDIR/usr/local/" || true
fi

# ============================================================
# 动态生成 pkg-plist（修复：在 SERVERDIR 中执行 find）
# ============================================================
log "Generating pkg-plist for mariadb${PKG_VERSION}-server..."
PLIST_FILE="$SERVERDIR/pkg-plist"
> "$PLIST_FILE"

if [ -d "$SERVERDIR/usr/local" ]; then
    cd "$SERVERDIR"
    find usr/local -type f -o -type l | sed 's/^usr\/local\///' | sort >> "$PLIST_FILE"
    cd "$WORKDIR"
fi

log "DEBUG: pkg-plist entries: $(wc -l < "$PLIST_FILE")"
log "DEBUG: pkg-plist contents (first 50 lines):"
head -50 "$PLIST_FILE" | tee -a "$LOG_FILE"

# 创建 MANIFEST
cat > "$SERVERDIR/+MANIFEST" << EOF
{
  "name": "mariadb${PKG_VERSION}-server",
  "version": "${MARIADB_VERSION}",
  "origin": "databases/mariadb${PKG_VERSION}-server",
  "comment": "MariaDB ${MARIADB_MAJOR} server",
  "desc": "MariaDB server package\nDepends on mariadb${PKG_VERSION}-client for tools",
  "maintainer": "custom@localhost",
  "abi": "FreeBSD:${release}:${architecture}",
  "arch": "FreeBSD:${release}:${architecture}",
  "prefix": "/usr/local",
  "deps": {
    "mariadb${PKG_VERSION}-client": {
      "origin": "databases/mariadb${PKG_VERSION}-client",
      "version": "${MARIADB_VERSION}"
    }
  }
}
EOF

# 创建服务启动脚本
mkdir -p "$SERVERDIR/usr/local/etc/rc.d"
cat > "$SERVERDIR/usr/local/etc/rc.d/mariadb" << 'EOF'
#!/bin/bash
# $FreeBSD$
# PROVIDE: mariadb
# REQUIRE: DAEMON
# KEYWORD: shutdown

. /etc/rc.subr

name=mariadb
rcvar=mariadb_enable

load_rc_config $name

: ${mariadb_enable:=NO}
: ${mariadb_user:=mysql}
: ${mariadb_datadir:=/var/db/mysql}
: ${mariadb_pidfile:=/var/run/mysqld/mysqld.pid}

command=/usr/local/bin/mysqld
command_args="--basedir=/usr/local --datadir=${mariadb_datadir} --pid-file=${mariadb_pidfile}"

mariadb_precmd()
{
    if [ ! -d "${mariadb_datadir}" ]; then
        mkdir -p "${mariadb_datadir}"
        chown ${mariadb_user}:${mariadb_user} "${mariadb_datadir}"
    fi
    if [ ! -d "/var/run/mysqld" ]; then
        mkdir -p /var/run/mysqld
        chown ${mariadb_user}:${mariadb_user} /var/run/mysqld
    fi
}

run_rc_command "$1"
EOF
chmod +x "$SERVERDIR/usr/local/etc/rc.d/mariadb"

# 打包
cd "$PKGDIR"
log "DEBUG: Running pkg create for mariadb${PKG_VERSION}-server..."
pkg create -m "$SERVERDIR" -p "$SERVERDIR/pkg-plist" -r "$SERVERDIR" -o . 2>&1 | tee -a "$LOG_FILE"

if [ $? -eq 0 ]; then
    rm -rf "mariadb${PKG_VERSION}-server"
    log "✓ mariadb${PKG_VERSION}-server package created"
else
    log "ERROR: Failed to create mariadb${PKG_VERSION}-server package"
    exit 1
fi

# ============================================================
# 8. 创建修改后的 p5-DBD-MariaDB 包
# ============================================================
print_header "Step 8: Creating modified p5-DBD-MariaDB package"

log "Downloading original p5-DBD-MariaDB package..."
pkg fetch -y p5-DBD-MariaDB 2>&1 | tee -a "$LOG_FILE"

# === 调试：查找下载的包 ===
log "DEBUG: Looking for p5-DBD-MariaDB package in /var/cache/pkg"
ls -la /var/cache/pkg/*DBD* 2>&1 | tee -a "$LOG_FILE"

DBD_PKG=$(find /var/cache/pkg -name "p5-DBD-MariaDB-*.pkg" -type f)

if [ -z "$DBD_PKG" ]; then
    log "WARNING: Could not find downloaded p5-DBD-MariaDB package"
    log "DEBUG: Contents of /var/cache/pkg:"
    ls -la /var/cache/pkg/ | tee -a "$LOG_FILE"
else
    log "✅ Found package: $(basename "$DBD_PKG")"
    log "DEBUG: Package size: $(ls -lh "$DBD_PKG" | awk '{print $5}')"

    DBDDIR="$PKGDIR/p5-DBD-MariaDB-custom"
    mkdir -p "$DBDDIR"

    log "Extracting original package..."
    tar -xf "$DBD_PKG" -C "$DBDDIR" 2>&1 | tee -a "$LOG_FILE"

    # === 调试：检查解压结果 ===
    log "DEBUG: Extracted files in $DBDDIR:"
    ls -la "$DBDDIR" | tee -a "$LOG_FILE"

    cd "$DBDDIR"

    if [ -f "+MANIFEST" ]; then
        log "DEBUG: Original +MANIFEST:"
        cat "+MANIFEST" | tee -a "$LOG_FILE"
        
        log "Modifying MANIFEST dependencies..."
        sed -i '' 's/"mysql84-client"/"libmariadb"/g' +MANIFEST
        sed -i '' 's/"mysql[0-9]*-client"/"libmariadb"/g' +MANIFEST
        sed -i '' 's/"origin":"databases\/mysql84-client"/"origin":"databases\/libmariadb"/g' +MANIFEST
        sed -i '' 's/"version":"1.23"/"version":"1.23.custom"/g' +MANIFEST
        sed -i '' 's/"version":"8.4.10_1"/"version":"12.3.2"/g' +MANIFEST
        sed -i '' 's/"comment":"MariaDB driver for the Perl5 Database Interface (DBI)"/"comment":"MariaDB driver (custom - depends on libmariadb)"/g' +MANIFEST
        sed -i '' 's/"libmysqlclient.so.24"/"libmariadb.so"/g' +MANIFEST
        
        log "DEBUG: Modified +MANIFEST:"
        cat "+MANIFEST" | tee -a "$LOG_FILE"
        
        log "Modified dependencies:"
        grep -A 5 '"deps"' +MANIFEST | tee -a "$LOG_FILE"
    fi

    # 修改 +COMPACT_MANIFEST
    if [ -f "+COMPACT_MANIFEST" ]; then
        log "Modifying +COMPACT_MANIFEST..."
        sed -i '' 's/"name":"p5-DBD-MariaDB"/"name":"p5-DBD-MariaDB-custom"/g' +COMPACT_MANIFEST
        sed -i '' 's/"origin":"databases\/p5-DBD-MariaDB"/"origin":"databases\/p5-DBD-MariaDB-custom"/g' +COMPACT_MANIFEST
        sed -i '' 's/"version":"1.23"/"version":"1.23.custom"/g' +COMPACT_MANIFEST
        sed -i '' 's/"comment":"MariaDB driver for the Perl5 Database Interface (DBI)"/"comment":"MariaDB driver (custom - depends on libmariadb)"/g' +COMPACT_MANIFEST
        sed -i '' 's/"mysql84-client"/"libmariadb"/g' +COMPACT_MANIFEST
        sed -i '' 's/"origin":"databases\/mysql84-client"/"origin":"databases\/libmariadb"/g' +COMPACT_MANIFEST
        sed -i '' 's/"version":"8.4.10_1"/"version":"12.3.2"/g' +COMPACT_MANIFEST
        sed -i '' 's/"libmysqlclient.so.24",//g' +COMPACT_MANIFEST
        sed -i '' 's/, "libmysqlclient.so.24"//g' +COMPACT_MANIFEST
        log "DEBUG: Modified +COMPACT_MANIFEST:"
        cat "+COMPACT_MANIFEST" | tee -a "$LOG_FILE"
    fi

    # 创建 POST_INSTALL 脚本
    cat > "+POST_INSTALL" << 'EOF'
#!/bin/sh
# POST-INSTALL script for p5-DBD-MariaDB-custom

echo "p5-DBD-MariaDB-custom: Creating compatibility symlinks..."
if [ -f /usr/local/lib/libmariadb.so ] && [ ! -L /usr/local/lib/libmysqlclient.so.24 ]; then
    ln -sf /usr/local/lib/libmariadb.so /usr/local/lib/libmysqlclient.so.24
    echo "  → libmysqlclient.so.24 -> libmariadb.so"
fi
echo "p5-DBD-MariaDB-custom: Installation complete"
EOF
    chmod +x "+POST_INSTALL"

    cat > "+POST_DEINSTALL" << 'EOF'
#!/bin/sh
# POST-DEINSTALL script for p5-DBD-MariaDB-custom

echo "p5-DBD-MariaDB-custom: Removing compatibility symlinks..."
rm -f /usr/local/lib/libmysqlclient.so.24
echo "p5-DBD-MariaDB-custom: Cleanup completed"
EOF
    chmod +x "+POST_DEINSTALL"

    cd "$PKGDIR"

    log "Re-packaging using pkg create..."
    log "DEBUG: pkg create -o . -m \"$DBDDIR\" -r \"$DBDDIR\""

    # 使用 -m 指定 manifest 目录
    pkg create -m "$DBDDIR" -r "$DBDDIR" -o . 2>&1 | tee -a "$LOG_FILE"

    # 检查生成的包
    if [ -f "p5-DBD-MariaDB-1.23.custom.pkg" ]; then
        mv "p5-DBD-MariaDB-1.23.custom.pkg" "p5-DBD-MariaDB-custom.pkg"
        log "✅ Renamed p5-DBD-MariaDB-1.23.custom.pkg -> p5-DBD-MariaDB-custom.pkg"
    elif [ -f "p5-DBD-MariaDB-1.23.pkg" ]; then
        mv "p5-DBD-MariaDB-1.23.pkg" "p5-DBD-MariaDB-custom.pkg"
        log "✅ Renamed p5-DBD-MariaDB-1.23.pkg -> p5-DBD-MariaDB-custom.pkg"
    fi

    # 检查重命名后的包
    if [ -f "p5-DBD-MariaDB-custom.pkg" ]; then
        log "✅ Package created successfully: p5-DBD-MariaDB-custom.pkg"
        ls -la "p5-DBD-MariaDB-custom.pkg" | tee -a "$LOG_FILE"
    else
        log "ERROR: Failed to create p5-DBD-MariaDB-custom.pkg"
        log "DEBUG: Available packages in $PKGDIR:"
        ls -la *.pkg 2>&1 | tee -a "$LOG_FILE"
        exit 1
    fi

    rm -rf "$DBDDIR"

    log "✅ p5-DBD-MariaDB-custom package created"
fi

cd "$WORKDIR"

# ============================================================
# 9. 总结
# ============================================================
print_header "Build Complete!"

echo -e "${GREEN}✓ All packages built successfully!${NC}"
echo ""
echo "Packages location: $PKGDIR"
echo ""
echo "Package list:"
ls -la "$PKGDIR"/*.pkg || echo "No packages found"
echo ""
echo "=========================================="
echo "Package structure (like Debian):"
echo "=========================================="
echo ""
echo "  libmariadb              - Shared libraries (libmysqlclient.so)"
echo "  mariadb-client-core     - Core tools (mysql command)"
echo "  mariadb${PKG_VERSION}-client       - Complete client"
echo "  mariadb${PKG_VERSION}-server       - Server daemon"
echo "  p5-DBD-MariaDB-custom   - Perl DBD (depends on libmariadb)"
echo ""
echo "=========================================="
echo "Installation:"
echo "=========================================="
echo ""
echo "  pkg install -r mariadb-custom mariadb${PKG_VERSION}-server"
echo ""
echo "  Or individually:"
echo "  pkg install -r mariadb-custom libmariadb"
echo "  pkg install -r mariadb-custom mariadb-client-core"
echo "  pkg install -r mariadb-custom mariadb${PKG_VERSION}-client"
echo "  pkg install -r mariadb-custom mariadb${PKG_VERSION}-server"
echo "  pkg install -r mariadb-custom p5-DBD-MariaDB-custom"
echo ""
echo -e "${GREEN}✓ Done!${NC}"