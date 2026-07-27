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
    
    # 下载 netdata 版本
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
        exit 1
    fi
    
    cd "$WORKDIR"
fi

# ============================================================
# 1.6 检查 OpenSSL 版本
# ============================================================
print_header "Step 1.6: Checking OpenSSL version"

log "OpenSSL version check:"
log ""

# 检查 openssl 命令
if command -v openssl >/dev/null 2>&1; then
    OPENSSL_VER=$(openssl version 2>/dev/null | head -1)
    log "  openssl: $OPENSSL_VER"
else
    log "  openssl: not found"
fi

# 检查 openssl40
if command -v openssl40 >/dev/null 2>&1; then
    OPENSSL40_VER=$(openssl40 version 2>/dev/null | head -1)
    log "  openssl40: $OPENSSL40_VER"
else
    log "  openssl40: not found"
fi

# 检查 pkg 中的 openssl40
if pkg info openssl40 >/dev/null 2>&1; then
    OPENSSL40_PKG=$(pkg info openssl40 | grep Version | awk '{print $2}')
    log "  openssl40 pkg: $OPENSSL40_PKG"
else
    log "  openssl40 pkg: not installed"
fi

# 判断当前使用的版本
if command -v openssl40 >/dev/null 2>&1; then
    log "✅ Using OpenSSL 4.x (openssl40)"
elif pkg info openssl40 >/dev/null 2>&1; then
    log "⚠️ openssl40 installed but not in PATH"
    log "   Adding /usr/local/bin to PATH..."
    export PATH=/usr/local/bin:$PATH
elif command -v openssl >/dev/null 2>&1; then
    OPENSSL_VER=$(openssl version | awk '{print $2}')
    OPENSSL_MAJOR=$(echo "$OPENSSL_VER" | cut -d. -f1)
    if [ "$OPENSSL_MAJOR" -ge 4 ]; then
        log "✅ Using OpenSSL 4.x (system default)"
    else
        log "⚠️ Using OpenSSL $OPENSSL_VER (not 4.x)"
        log "   MariaDB 12.3.2 is compatible with OpenSSL 3.x and 4.x"
        log "   Continuing with OpenSSL $OPENSSL_VER"
    fi
else
    log "❌ OpenSSL not found!"
    log "   Please install openssl40:"
    log "   pkg install -y openssl40"
    exit 1
fi

log ""
log "✅ OpenSSL check completed"

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
    
    # 删除 #ifdef 和 #endif 行，只保留 #define
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

log "Stripping binaries to reduce size..."
find "$INSTALL_DIR" -name "*.so" -exec strip -s {} \; || true
find "$INSTALL_DIR" -name "*.a" -exec strip -s {} \; || true
find "$INSTALL_DIR" -type f -executable -exec strip -s {} \; || true

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

# 复制共享库
if [ -d "$INSTALL_DIR/usr/local/lib" ]; then
    cp "$INSTALL_DIR/usr/local/lib/libmariadb"* "$LIBDIR/usr/local/lib/" || true
    cp "$INSTALL_DIR/usr/local/lib/libmysqlclient"* "$LIBDIR/usr/local/lib/" || true
fi

# 复制头文件
if [ -d "$INSTALL_DIR/usr/local/include/mariadb" ]; then
    cp -r "$INSTALL_DIR/usr/local/include/mariadb"/* "$LIBDIR/usr/local/include/mariadb/" || true
fi

# 复制 MySQL 兼容头文件到 include/mysql
if [ -d "$INSTALL_DIR/usr/local/include/mysql" ]; then
    mkdir -p "$LIBDIR/usr/local/include/mysql"
    cp -r "$INSTALL_DIR/usr/local/include/mysql"/* "$LIBDIR/usr/local/include/mysql/" || true
fi

# 复制 pkgconfig
if [ -f "$INSTALL_DIR/usr/local/lib/pkgconfig/mariadb.pc" ]; then
    cp "$INSTALL_DIR/usr/local/lib/pkgconfig/mariadb.pc" "$LIBDIR/usr/local/lib/pkgconfig/"
fi

# 创建 MySQL 兼容符号链接
cd "$LIBDIR/usr/local/lib"
[ -f libmariadb.so ] && ln -sf libmariadb.so libmysqlclient.so || true
cd "$LIBDIR/usr/local/lib/pkgconfig"
[ -f mariadb.pc ] && ln -sf mariadb.pc mysqlclient.pc || true
cd "$WORKDIR"

# 创建 MANIFEST（版本用 12.3.2）
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

# 创建 INSTALL 脚本
cat > "$LIBDIR/+INSTALL" << 'EOF'
#!/bin/bash
# POST-INSTALL script for libmariadb

echo "libmariadb: Creating compatibility symlinks..."

# Create libmysqlclient.so symlink
if [ -f /usr/local/lib/mariadb/libmariadb.so ] && [ ! -L /usr/local/lib/libmysqlclient.so ]; then
    mkdir -p /usr/local/lib
    ln -sf /usr/local/lib/mariadb/libmariadb.so /usr/local/lib/libmysqlclient.so
    echo "  → libmysqlclient.so -> libmariadb.so"
fi

# Create pkgconfig symlink
if [ -f /usr/local/lib/mariadb/pkgconfig/mariadb.pc ] && [ ! -L /usr/local/lib/pkgconfig/mysqlclient.pc ]; then
    mkdir -p /usr/local/lib/pkgconfig
    ln -sf /usr/local/lib/mariadb/pkgconfig/mariadb.pc /usr/local/lib/pkgconfig/mysqlclient.pc
    echo "  → mysqlclient.pc -> mariadb.pc"
fi

echo "libmariadb: Compatibility links created"
EOF
chmod +x "$LIBDIR/+INSTALL"

# 创建 POST_DEINSTALL 脚本
cat > "$LIBDIR/+POST_DEINSTALL" << 'EOF'
#!/bin/bash
# POST-DEINSTALL script for libmariadb

echo "libmariadb: Removing compatibility symlinks..."
rm -f /usr/local/lib/libmysqlclient.so
rm -f /usr/local/lib/pkgconfig/mysqlclient.pc
echo "libmariadb: Cleanup completed"
EOF
chmod +x "$LIBDIR/+POST_DEINSTALL"

# 创建 pkg-plist
cat > "$LIBDIR/pkg-plist" << 'EOF'
@dir lib/mariadb
lib/mariadb/libmariadb.so
lib/mariadb/libmariadb.so.3
lib/mariadb/libmariadb.so.3.1.18
lib/mariadb/libmariadbclient.a
lib/mariadb/libmariadbclient.so
@dir include/mariadb
include/mariadb/mysql.h
include/mariadb/mysqld_error.h
include/mariadb/mysql_version.h
include/mariadb/mariadb_com.h
include/mariadb/mariadb_version.h
@dir include/mysql
include/mysql/mysql.h
include/mysql/mysql_com.h
include/mysql/mysql_version.h
include/mysql/mariadb_version.h
include/mysql/mysqld_error.h
include/mysql/errmsg.h
@dir lib
lib/libmysqlclient.so
@dir lib/pkgconfig
lib/pkgconfig/mysqlclient.pc
EOF

log "libmariadb package created"

# 打包
cd "$PKGDIR"
pkg create -o . -m libmariadb
rm -rf libmariadb
log "✓ libmariadb package created"

# ============================================================
# 7.2 创建 mariadb-client-core 包（核心客户端工具）
# ============================================================
log "Creating mariadb-client-core package..."

COREDIR="$PKGDIR/mariadb-client-core"
mkdir -p "$COREDIR/usr/local/bin"

# 复制核心工具
if [ -d "$INSTALL_DIR/usr/local/bin" ]; then
    cp "$INSTALL_DIR/usr/local/bin/mariadb"* "$COREDIR/usr/local/bin/" || true
    cp "$INSTALL_DIR/usr/local/bin/mysql"* "$COREDIR/usr/local/bin/" || true
fi

# 创建 MySQL 兼容符号链接
cd "$COREDIR/usr/local/bin"
[ -f mariadb ] && ln -sf mariadb mysql || true
[ -f mariadbadmin ] && ln -sf mariadbadmin mysqladmin || true
[ -f mariadbdump ] && ln -sf mariadbdump mysqldump || true
[ -f mariadbcheck ] && ln -sf mariadbcheck mysqlcheck || true
[ -f mariadbimport ] && ln -sf mariadbimport mysqlimport || true
[ -f mariadbshow ] && ln -sf mariadbshow mysqlshow || true
cd "$WORKDIR"

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

# 创建 pkg-plist
cat > "$COREDIR/pkg-plist" << 'EOF'
bin/mariadb
bin/mariadbadmin
bin/mariadbdump
bin/mariadbcheck
bin/mariadbimport
bin/mariadbshow
bin/mysql
bin/mysqladmin
bin/mysqldump
bin/mysqlcheck
bin/mysqlimport
bin/mysqlshow
EOF

# 创建 INSTALL 脚本
cat > "$COREDIR/+INSTALL" << 'EOF'
#!/bin/bash
# POST-INSTALL script for mariadb-client-core

echo "mariadb-client-core: Creating MySQL compatibility symlinks..."

if [ -f /usr/local/bin/mariadb ] && [ ! -L /usr/local/bin/mysql ]; then
    ln -sf mariadb /usr/local/bin/mysql
    ln -sf mariadbadmin /usr/local/bin/mysqladmin
    ln -sf mariadbdump /usr/local/bin/mysqldump
    ln -sf mariadbcheck /usr/local/bin/mysqlcheck
    ln -sf mariadbimport /usr/local/bin/mysqlimport
    ln -sf mariadbshow /usr/local/bin/mysqlshow
    echo "  → MySQL compatibility symlinks created"
fi
echo "mariadb-client-core: Installation complete"
EOF
chmod +x "$COREDIR/+INSTALL"

# 创建 POST_DEINSTALL 脚本
cat > "$COREDIR/+POST_DEINSTALL" << 'EOF'
#!/bin/bash
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
pkg create -o . -m mariadb-client-core
rm -rf mariadb-client-core
log "✓ mariadb-client-core package created"

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

cd "$PKGDIR"
pkg create -o . -m "mariadb${PKG_VERSION}-client"
rm -rf "mariadb${PKG_VERSION}-client"
log "✓ mariadb${PKG_VERSION}-client package created"

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

cd "$PKGDIR"
pkg create -o . -m "mariadb${PKG_VERSION}-server"
rm -rf "mariadb${PKG_VERSION}-server"
log "✓ mariadb${PKG_VERSION}-server package created"

# ============================================================
# 8. 创建修改后的 p5-DBD-MariaDB 包
# ============================================================
print_header "Step 8: Creating modified p5-DBD-MariaDB package"

log "Downloading original p5-DBD-MariaDB package..."
pkg fetch -y -o "$PKGDIR" p5-DBD-MariaDB 2>&1 | tee -a "$LOG_FILE"

DBD_PKG=$(ls "$PKGDIR"/p5-DBD-MariaDB-*.pkg | head -1)

if [ -z "$DBD_PKG" ]; then
    log "WARNING: Could not download p5-DBD-MariaDB, skipping..."
else
    log "Original package: $(basename "$DBD_PKG")"
    
    DBDDIR="$PKGDIR/p5-DBD-MariaDB-custom"
    mkdir -p "$DBDDIR/usr/local"
    
    cd "$DBDDIR"
    log "Extracting original package..."
    tar -xf "$DBD_PKG" 2>&1 | tee -a "$LOG_FILE"
    
    log "Modifying dependencies..."
    if [ -f "+MANIFEST" ]; then
        sed -i '' 's/"mysql80-client"/"libmariadb"/g' +MANIFEST
        sed -i '' 's/"mysql84-client"/"libmariadb"/g' +MANIFEST
        sed -i '' 's/"mysql90-client"/"libmariadb"/g' +MANIFEST
        sed -i '' 's/"mysql97-client"/"libmariadb"/g' +MANIFEST
        sed -i '' 's/"version": "1.23"/"version": "1.23.custom"/g' +MANIFEST
        sed -i '' 's/"comment": "MariaDB driver for the Perl5 Database Interface (DBI)"/"comment": "MariaDB driver (custom - depends on libmariadb)"/g' +MANIFEST
    fi
    
    log "Re-packaging..."
    tar -cf "../p5-DBD-MariaDB-custom.pkg" *
    cd "$PKGDIR"
    rm -rf "$DBDDIR"
    
    log "✓ p5-DBD-MariaDB-custom package created"
fi

rm -rf "$INSTALL_DIR"

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