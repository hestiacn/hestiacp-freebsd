#!/bin/bash

# ======================================================== #
#
# Hestia Control Panel Installer for FreeBSD
# https://www.hestiacp.com/
#
# Currently Supported Versions:
# FreeBSD 13, 14
#
# ======================================================== #

#----------------------------------------------------------#
#                  Variables&Functions                     #
#----------------------------------------------------------#
export PATH=$PATH:/sbin:/usr/sbin:/usr/local/sbin:/usr/local/bin
export ASSUME_ALWAYS_YES=yes

# 仓库地址
RHOST='pkg.hestiacp.com'
VERSION='freebsd'
HESTIA='/usr/local/hestia'
LOG="/root/hst_install_backups/hst_install-$(date +%d%m%Y%H%M).log"
hst_backups="/root/hst_install_backups/$(date +%d%m%Y%H%M)"
spinner="/-\|"
os='freebsd'

# FreeBSD 系统检测
release=$(freebsd-version -u | cut -d'-' -f1 | cut -d'.' -f1)
full_release=$(freebsd-version -u | cut -d'-' -f1)
architecture=$(uname -m)
codename="freebsd-${release}"

HESTIA_INSTALL_DIR="$HESTIA/install/freebsd"
HESTIA_COMMON_DIR="$HESTIA/install/common"
VERBOSE='no'

# 获取内存大小 (KB)
memory=$(sysctl -n hw.physmem | awk '{print int($1/1024)}')

# 定义软件版本
HESTIA_INSTALL_VER='1.9.6'
# 支持的 PHP 版本
multiphp_v=("56" "70" "71" "72" "73" "74" "80" "81" "82" "83" "84" "85")
# Roundcube / phpmyadmin 需要的 PHP 版本
multiphp_required=("73" "74" "80" "81" "82" "83")
# 默认 PHP 版本
fpm_v="83"
# MariaDB 版本
mariadb_v="10.11"
# Node.js 版本
node_v="20"

# FreeBSD 软件包列表
software="apache24 awstats bind918 curl dovecot exim fail2ban git hestia hestia-nginx hestia-php hestia-web-terminal jq mariadb106-server nginx php83 php83-curl php83-mysqli php83-json php83-mbstring php83-session php83-xml php83-zip postgresql14-client postgresql14-server proftpd pure-ftpd rclone restic roundcube spamassassin sudo vsftpd"

installer_dependencies="curl ca_root_nss gnupg sudo wget"

#----------------------------------------------------------#
#                   FreeBSD 适配函数                        #
#----------------------------------------------------------#

# 密码生成函数
gen_pass() {
	matrix=$1
	length=$2
	if [ -z "$matrix" ]; then
		matrix="a-zA-Z0-9"
	fi
	if [ -z "$length" ]; then
		length=16
	fi
	cat /dev/urandom | env LC_CTYPE=C tr -dc "$matrix" | head -c "$length"
}

# 结果检查函数
check_result() {
	if [ $1 -ne 0 ]; then
		echo "Error: $2"
		exit $1
	fi
}

# 服务管理函数
service_control() {
	local action=$1
	local service=$2
	local service_map=""
	
	case "$service" in
		apache2|apache) service_map="apache24" ;;
		mysql|mariadb) service_map="mysql-server" ;;
		bind9|named) service_map="named" ;;
		php*-fpm) service_map="${service}" ;;
		nginx) service_map="nginx" ;;
		exim4|exim) service_map="exim" ;;
		dovecot) service_map="dovecot" ;;
		vsftpd) service_map="vsftpd" ;;
		proftpd) service_map="proftpd" ;;
		fail2ban) service_map="fail2ban" ;;
		clamav-daemon) service_map="clamav-clamd" ;;
		spamassassin|spamd) service_map="spamassassin" ;;
		hestia) service_map="hestia" ;;
		*) service_map="$service" ;;
	esac
	
	case "$action" in
		start|stop|restart|status|reload)
			service "$service_map" "$action" 2>/dev/null
			;;
		enable)
			sysrc "${service_map}_enable=YES" 2>/dev/null
			;;
		disable)
			sysrc "${service_map}_enable=NO" 2>/dev/null
			;;
	esac
}

# 检查服务是否启用
is_service_enabled() {
	local service=$1
	local var=$(sysrc -n "${service}_enable" 2>/dev/null)
	[ "$var" = "YES" ]
}

# 包管理函数
pkg_install() {
	pkg install -y "$@" >> $LOG 2>&1
}

pkg_remove() {
	pkg delete -y "$@" >> $LOG 2>&1
}

pkg_installed() {
	pkg info -e "$1" > /dev/null 2>&1
}

# 创建用户
create_user() {
	local user=$1
	local comment=$2
	if ! pw user show "$user" 2>/dev/null; then
		pw useradd "$user" -c "$comment" -s /usr/sbin/nologin -m
	fi
}

# 创建组
create_group() {
	local group=$1
	if ! pw group show "$group" 2>/dev/null; then
		pw groupadd "$group"
	fi
}

# 添加用户到组
add_user_to_group() {
	local user=$1
	local group=$2
	pw groupmod "$group" -m "$user" 2>/dev/null
}

# 设置默认值
set_default_value() {
	eval variable=\$$1
	if [ -z "$variable" ]; then
		eval $1=$2
	fi
	if [ "$variable" != 'yes' ] && [ "$variable" != 'no' ]; then
		eval $1=$2
	fi
}

# 设置默认语言
set_default_lang() {
	if [ -z "$lang" ]; then
		eval lang=$1
	fi
	lang_list="ar az bg bn bs ca cs da de el en es fa fi fr hr hu id it ja ka ku ko nl no pl pt pt-br ro ru sk sq sr sv th tr uk ur vi zh-cn zh-tw"
	if ! (echo $lang_list | grep -w $lang > /dev/null 2>&1); then
		eval lang=$1
	fi
}

# 设置默认端口
set_default_port() {
	if [ -z "$port" ]; then
		eval port=$1
	fi
}

# 写入配置
write_config_value() {
	local key="$1"
	local value="$2"
	echo "$key='$value'" >> $HESTIA/conf/hestia.conf
}

# 排序配置文件
sort_config_file() {
	sort $HESTIA/conf/hestia.conf -o /tmp/updconf
	mv $HESTIA/conf/hestia.conf $HESTIA/conf/hestia.conf.bak
	mv /tmp/updconf $HESTIA/conf/hestia.conf
	rm -f $HESTIA/conf/hestia.conf.bak
	if [ ! -d "$HESTIA/conf/defaults/" ]; then
		mkdir -p "$HESTIA/conf/defaults/"
	fi
	cp $HESTIA/conf/hestia.conf $HESTIA/conf/defaults/hestia.conf
}

# 验证用户名
validate_username() {
	if [[ "$username" =~ ^[[:alnum:]][-|\.|_[:alnum:]]{0,28}[[:alnum:]]$ ]]; then
		if [ -n "$(grep ^$username: /etc/passwd /etc/group 2>/dev/null)" ]; then
			echo -e "\nUsername or Group already exists"
			return 0
		else
			return 1
		fi
	else
		echo -e "\nPlease use a valid username (ex. user)."
		return 0
	fi
}

# 验证密码
validate_password() {
	if [ -z "$vpass" ]; then
		return 0
	else
		return 1
	fi
}

# 验证主机名
validate_hostname() {
	servername=$(echo "$servername" | sed -e "s/[.]*$//g")
	servername=$(echo "$servername" | sed -e "s/^[.]*//")
	if [[ $(echo "$servername" | grep -o "\." | wc -l) -gt 1 ]] && [[ ! $servername =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
		return 1
	else
		return 0
	fi
}

# 验证邮箱
validate_email() {
	if [[ ! "$email" =~ ^[A-Za-z0-9._%+-]+@[[:alnum:].-]+\.[A-Za-z]{2,63}$ ]]; then
		return 0
	else
		return 1
	fi
}

# 版本比较
version_ge() {
	test "$(printf '%s\n' "$@" | sort -V | head -n 1)" != "$1" -o -n "$1" -a "$1" = "$2"
}

#----------------------------------------------------------#
#                   帮助函数                               #
#----------------------------------------------------------#

help() {
	echo "Usage: $0 [OPTIONS]
  -a, --apache            Install Apache        [yes|no]  default: yes
  -w, --phpfpm            Install PHP-FPM       [yes|no]  default: yes
  -o, --multiphp          Install MultiPHP      [yes|no]  default: no
  -v, --vsftpd            Install VSFTPD        [yes|no]  default: yes
  -j, --proftpd           Install ProFTPD       [yes|no]  default: no
  -k, --named             Install BIND          [yes|no]  default: yes
  -m, --mysql             Install MariaDB       [yes|no]  default: yes
  -M, --mysql8            Install MySQL 8       [yes|no]  default: no
  -g, --postgresql        Install PostgreSQL    [yes|no]  default: no
  -x, --exim              Install Exim          [yes|no]  default: yes
  -z, --dovecot           Install Dovecot       [yes|no]  default: yes
  -Z, --sieve             Install Sieve         [yes|no]  default: no
  -c, --clamav            Install ClamAV        [yes|no]  default: yes
  -t, --spamassassin      Install SpamAssassin  [yes|no]  default: yes
  -i, --iptables          Install pf            [yes|no]  default: yes
  -b, --fail2ban          Install Fail2Ban      [yes|no]  default: yes
  -q, --quota             Filesystem Quota      [yes|no]  default: no
  -L, --resourcelimit     Resource Limitation   [yes|no]  default: no
  -W, --webterminal       Web Terminal          [yes|no]  default: no
  -d, --api               Activate API          [yes|no]  default: yes
  -r, --port              Change Backend Port             default: 8083
  -l, --lang              Default language                default: en
  -y, --interactive       Interactive install   [yes|no]  default: yes
  -s, --hostname          Set hostname
  -e, --email             Set admin email
  -u, --username          Set admin user
  -p, --password          Set admin password
  -D, --with-pkgs         Path to Hestia pkgs
  -f, --force             Force installation
  -h, --help              Print this help

  Example: bash $0 -e demo@hestiacp.com -p p4ssw0rd --multiphp yes"
	exit 1
}

#----------------------------------------------------------#
#                    Verifications                         #
#----------------------------------------------------------#

# 创建临时文件
tmpfile=$(mktemp -p /tmp)

# 参数解析
for arg; do
	delim=""
	case "$arg" in
		--apache) args="${args}-a " ;;
		--phpfpm) args="${args}-w " ;;
		--vsftpd) args="${args}-v " ;;
		--proftpd) args="${args}-j " ;;
		--named) args="${args}-k " ;;
		--mysql) args="${args}-m " ;;
		--mariadb) args="${args}-m " ;;
		--mysql-classic) args="${args}-M " ;;
		--mysql8) args="${args}-M " ;;
		--postgresql) args="${args}-g " ;;
		--exim) args="${args}-x " ;;
		--dovecot) args="${args}-z " ;;
		--sieve) args="${args}-Z " ;;
		--clamav) args="${args}-c " ;;
		--spamassassin) args="${args}-t " ;;
		--iptables) args="${args}-i " ;;
		--fail2ban) args="${args}-b " ;;
		--multiphp) args="${args}-o " ;;
		--quota) args="${args}-q " ;;
		--resourcelimit) args="${args}-L " ;;
		--webterminal) args="${args}-W " ;;
		--port) args="${args}-r " ;;
		--lang) args="${args}-l " ;;
		--interactive) args="${args}-y " ;;
		--api) args="${args}-d " ;;
		--hostname) args="${args}-s " ;;
		--email) args="${args}-e " ;;
		--username) args="${args}-u " ;;
		--password) args="${args}-p " ;;
		--force) args="${args}-f " ;;
		--with-pkgs) args="${args}-D " ;;
		--help) args="${args}-h " ;;
		*)
			[[ "${arg:0:1}" == "-" ]] || delim="\""
			args="${args}${delim}${arg}${delim} "
			;;
	esac
done
eval set -- "$args"

# 解析参数
while getopts "a:w:v:j:k:m:M:g:d:x:z:Z:c:t:i:b:r:o:q:L:l:y:s:u:e:p:W:D:fh" Option; do
	case $Option in
		a) apache=$OPTARG ;;
		w) phpfpm=$OPTARG ;;
		o) multiphp=$OPTARG ;;
		v) vsftpd=$OPTARG ;;
		j) proftpd=$OPTARG ;;
		k) named=$OPTARG ;;
		m) mysql=$OPTARG ;;
		M) mysql8=$OPTARG ;;
		g) postgresql=$OPTARG ;;
		x) exim=$OPTARG ;;
		z) dovecot=$OPTARG ;;
		Z) sieve=$OPTARG ;;
		c) clamd=$OPTARG ;;
		t) spamd=$OPTARG ;;
		i) iptables=$OPTARG ;;
		b) fail2ban=$OPTARG ;;
		q) quota=$OPTARG ;;
		L) resourcelimit=$OPTARG ;;
		W) webterminal=$OPTARG ;;
		r) port=$OPTARG ;;
		l) lang=$OPTARG ;;
		d) api=$OPTARG ;;
		y) interactive=$OPTARG ;;
		s) servername=$OPTARG ;;
		e) email=$OPTARG ;;
		u) username=$OPTARG ;;
		p) vpass=$OPTARG ;;
		D) withpkgs=$OPTARG ;;
		f) force='yes' ;;
		h) help ;;
		*) help ;;
	esac
done

# 处理 MultiPHP
if [ -n "$multiphp" ]; then
	if [ "$multiphp" != 'no' ] && [ "$multiphp" != 'yes' ]; then
		php_versions=$(echo $multiphp | tr ',' "\n")
		multiphp_version=()
		for php_version in "${php_versions[@]}"; do
			if [[ $(echo "${multiphp_v[@]}" | fgrep -w "$php_version") ]]; then
				multiphp_version=(${multiphp_version[@]} "$php_version")
			else
				echo "$php_version is not supported"
				exit 1
			fi
		done
		multiphp_v=()
		for version in "${multiphp_version[@]}"; do
			multiphp_v=(${multiphp_v[@]} $version)
		done
		fpm_old=$fpm_v
		multiphp="yes"
		fpm_v=$(printf "%s\n" "${multiphp_version[@]}" | sort -V | tail -n1)
		fpm_last=$(printf "%s\n" "${multiphp_required[@]}" | sort -V | tail -n1)
		if [[ -z $(echo "${multiphp_required[@]}" | fgrep -w $fpm_v) ]]; then
			if version_ge $fpm_v $fpm_last; then
				multiphp_version=(${multiphp_version[@]} $fpm_last)
				fpm_v=$fpm_last
			else
				echo "Selected PHP versions are not supported any more by Dependencies..."
				exit 1
			fi
		fi
	fi
fi

# 设置默认值
set_default_value 'nginx' 'yes'
set_default_value 'apache' 'yes'
set_default_value 'phpfpm' 'yes'
set_default_value 'multiphp' 'no'
set_default_value 'vsftpd' 'yes'
set_default_value 'proftpd' 'no'
set_default_value 'named' 'yes'
set_default_value 'mysql' 'yes'
set_default_value 'mysql8' 'no'
set_default_value 'postgresql' 'no'
set_default_value 'exim' 'yes'
set_default_value 'dovecot' 'yes'
set_default_value 'sieve' 'no'

if [ $memory -lt 1500000 ]; then
	set_default_value 'clamd' 'no'
	set_default_value 'spamd' 'no'
elif [ $memory -lt 3000000 ]; then
	set_default_value 'clamd' 'no'
	set_default_value 'spamd' 'yes'
else
	set_default_value 'clamd' 'yes'
	set_default_value 'spamd' 'yes'
fi

set_default_value 'iptables' 'yes'
set_default_value 'fail2ban' 'yes'
set_default_value 'quota' 'no'
set_default_value 'resourcelimit' 'no'
set_default_value 'webterminal' 'no'
set_default_value 'interactive' 'yes'
set_default_value 'api' 'yes'
set_default_port '8083'
set_default_lang 'en'

# 检查软件冲突
if [ "$proftpd" = 'yes' ]; then
	vsftpd='no'
fi
if [ "$exim" = 'no' ]; then
	clamd='no'
	spamd='no'
	dovecot='no'
fi
if [ "$dovecot" = 'no' ]; then
	sieve='no'
fi
if [ "$iptables" = 'no' ]; then
	fail2ban='no'
fi
if [ "$apache" = 'no' ]; then
	phpfpm='yes'
fi

if [ "$mysql" = 'yes' ] && [ "$mysql8" = 'yes' ]; then
	mysql='no'
fi

if [ "$mysql8" = 'yes' ] && [ "$architecture" = 'aarch64' ]; then
    check_result 1 "MySQL 8 does not support ARM64 on FreeBSD yet. Please use MariaDB or MySQL 5.7. Unable to continue."
fi

# 检查 root 权限
if [ "x$(id -u)" != 'x0' ]; then
	check_result 1 "Script can be run executed only by root"
fi

# 检查是否已安装
if [ -d "$HESTIA" ]; then
	check_result 1 "Hestia install detected. Unable to continue"
fi

# 检查 FreeBSD 版本
if [ "$release" -lt 13 ]; then
	echo "Error: FreeBSD 13 or higher is required"
	echo "Current version: $full_release"
	exit 1
fi

# 清屏
clear

# 欢迎消息
echo "Welcome to the Hestia Control Panel installer for FreeBSD!"
echo
echo "Please wait, the installer is now checking for missing dependencies..."
echo

# 创建备份目录
mkdir -p "$hst_backups"

# 安装依赖
echo "[ * ] Installing dependencies..."
pkg_install $installer_dependencies
check_result $? "Package installation failed, check log file for more details."

# Check if apparmor is installed (FreeBSD pkg syntax)
if pkg info -e apparmor > /dev/null 2>&1; then
    apparmor='yes'
else
    apparmor='no'
fi

# Check repository availability using FreeBSD native fetch
fetch -q -o /dev/null "https://$RHOST"
check_result $? "Unable to connect to the Hestia repository"

# 检查已安装的包
tmpfile_pkg=$(mktemp -p /tmp)
pkg info > $tmpfile_pkg
conflicts_pkg="exim mariadb-server apache24 nginx hestia postfix"

if [ "$exim" = 'no' ]; then
	conflicts_pkg=$(echo $conflicts_pkg | sed 's/postfix//g' | xargs)
fi

for pkg in $conflicts_pkg; do
	if grep -q "^$pkg" $tmpfile_pkg; then
		conflicts="$pkg* $conflicts"
	fi
done
rm -f $tmpfile_pkg

if [ -n "$conflicts" ] && [ -z "$force" ]; then
	echo '!!! !!! !!! !!! !!! !!! !!! !!! !!! !!! !!! !!! !!! !!! !!! !!! !!!'
	echo
	echo 'WARNING: The following packages are already installed'
	echo "$conflicts"
	echo
	echo 'It is highly recommended that you remove them before proceeding.'
	echo
	echo '!!! !!! !!! !!! !!! !!! !!! !!! !!! !!! !!! !!! !!! !11 !! !!! !!!'
	echo
	read -p 'Would you like to remove the conflicting packages? [y/N] ' answer
	if [ "$answer" = 'y' ] || [ "$answer" = 'Y' ]; then
		pkg_delete_force=$(echo $conflicts | tr ' ' '\n' | cut -d'*' -f1 | xargs)
		pkg_remove $pkg_delete_force
		unset answer
	else
		check_result 1 "Hestia Control Panel should be installed on a clean server."
	fi
fi

# 检查架构支持
case $architecture in
	amd64|x86_64)
		ARCH="amd64"
		;;
	arm64|aarch64)
		ARCH="arm64"
		;;
	*)
		echo
		echo -e "\e[91mInstallation aborted\e[0m"
		echo "===================================================================="
		echo -e "\e[33mERROR: $architecture is currently not supported!\e[0m"
		echo ""
		check_result 1 "Installation aborted"
		;;
esac

#----------------------------------------------------------#
#                       Brief Info                         #
#----------------------------------------------------------#

install_welcome_message() {
	DISPLAY_VER=$(echo $HESTIA_INSTALL_VER | sed "s|~alpha||g" | sed "s|~beta||g")
	echo
	echo '                _   _           _   _        ____ ____                  '
	echo '               | | | | ___  ___| |_(_) __ _ / ___|  _ \                 '
	echo '               | |_| |/ _ \/ __| __| |/ _` | |   | |_) |                '
	echo '               |  _  |  __/\__ \ |_| | (_| | |___|  __/                 '
	echo '               |_| |_|\___||___/\__|_|\__,_|\____|_|                    '
	echo "                                                                        "
	echo "                          Hestia Control Panel                          "
	if [[ "$HESTIA_INSTALL_VER" =~ "beta" ]]; then
		echo "                              BETA RELEASE                          "
	fi
	if [[ "$HESTIA_INSTALL_VER" =~ "alpha" ]]; then
		echo "                          DEVELOPMENT SNAPSHOT                      "
		echo "                    NOT INTENDED FOR PRODUCTION USE                 "
		echo "                          USE AT YOUR OWN RISK                      "
	fi
	echo "                                  ${DISPLAY_VER}                        "
	echo "                            www.hestiacp.com                            "
	echo
	echo "========================================================================"
	echo
	echo "Thank you for downloading Hestia Control Panel! In a few moments,"
	echo "we will begin installing the following components on your server:"
	echo
}

# 打印 ASCII logo
clear
install_welcome_message

# Web stack
echo '   - NGINX Web / Proxy Server'
if [ "$apache" = 'yes' ]; then
	echo '   - Apache Web Server (as backend)'
fi
if [ "$phpfpm" = 'yes' ] && [ "$multiphp" = 'no' ]; then
	echo '   - PHP-FPM Application Server'
fi
if [ "$multiphp" = 'yes' ]; then
	phpfpm='yes'
	echo -n '   - Multi-PHP Environment: Version'
	for version in "${multiphp_v[@]}"; do
		echo -n " php$version"
	done
	echo ''
fi

# DNS stack
if [ "$named" = 'yes' ]; then
	echo '   - Bind DNS Server'
fi

# Mail stack
if [ "$exim" = 'yes' ]; then
	echo -n '   - Exim Mail Server'
	if [ "$clamd" = 'yes' ] || [ "$spamd" = 'yes' ]; then
		echo -n ' + '
		if [ "$clamd" = 'yes' ]; then
			echo -n 'ClamAV '
		fi
		if [ "$spamd" = 'yes' ]; then
			if [ "$clamd" = 'yes' ]; then
				echo -n '+ '
			fi
			echo -n 'SpamAssassin'
		fi
	fi
	echo
	if [ "$dovecot" = 'yes' ]; then
		echo -n '   - Dovecot POP3/IMAP Server'
		if [ "$sieve" = 'yes' ]; then
			echo -n '+ Sieve'
		fi
	fi
fi

echo

# Database stack
if [ "$mysql" = 'yes' ]; then
	echo '   - MariaDB Database Server'
fi
if [ "$mysql8" = 'yes' ]; then
	echo '   - MySQL8 Database Server'
fi
if [ "$postgresql" = 'yes' ]; then
	echo '   - PostgreSQL Database Server'
fi

# FTP stack
if [ "$vsftpd" = 'yes' ]; then
	echo '   - Vsftpd FTP Server'
fi
if [ "$proftpd" = 'yes' ]; then
	echo '   - ProFTPD FTP Server'
fi

if [ "$webterminal" = 'yes' ]; then
	echo '   - Web terminal'
fi

# Firewall stack
if [ "$iptables" = 'yes' ]; then
	echo -n '   - Firewall (pf)'
fi
if [ "$iptables" = 'yes' ] && [ "$fail2ban" = 'yes' ]; then
	echo -n ' + Fail2Ban Access Monitor'
fi
echo -e "\n"
echo "========================================================================"
echo -e "\n"

# 询问确认
if [ "$interactive" = 'yes' ]; then
	read -p 'Would you like to continue with the installation? [y/N]: ' answer
	if [ "$answer" != 'y' ] && [ "$answer" != 'Y' ]; then
		echo 'Goodbye'
		exit 1
	fi
fi

# 验证用户名
if [ -z "$username" ]; then
	while validate_username; do
		read -p 'Please enter administrator username: ' username
	done
else
	if validate_username; then
		exit 1
	fi
fi

# 验证密码
if [ -z "$vpass" ]; then
	while validate_password; do
		read -p 'Please enter administrator password: ' vpass
	done
else
	if validate_password; then
		echo "Please use a valid password"
		exit 1
	fi
fi

# 验证邮箱
if [ -z "$email" ]; then
	while validate_email; do
		echo -e "\nPlease use a valid email address (ex. info@domain.tld)."
		read -p 'Please enter admin email address: ' email
	done
else
	if validate_email; then
		echo "Please use a valid email address (ex. info@domain.tld)."
		exit 1
	fi
fi

# 验证主机名
if [ -z "$servername" ]; then
	read -p "Please enter FQDN hostname [$(hostname -f)]: " servername
	if [ -z "$servername" ]; then
		servername=$(hostname -f)
	fi
	while validate_hostname; do
		echo -e "\nPlease use a valid hostname according to RFC1178 (ex. hostname.domain.tld)."
		read -p "Please enter FQDN hostname [$(hostname -f)]: " servername
	done
else
	if validate_hostname; then
		echo "Please use a valid hostname according to RFC1178 (ex. hostname.domain.tld)."
		exit 1
	fi
fi

# 生成密码
displaypass="The password you chose during installation."
if [ -z "$vpass" ]; then
	vpass=$(gen_pass)
	displaypass=$vpass
fi

# 设置主机名
if ! [[ "$servername" =~ ^(([a-zA-Z0-9](-?[a-zA-Z0-9])*)\.)+[a-zA-Z]{2,}$ ]]; then
	if [ -n "$servername" ]; then
		servername="$servername.example.com"
	else
		servername="example.com"
	fi
	echo "127.0.0.1 $servername" >> /etc/hosts
fi

if [ -z "$(grep -i "$servername" /etc/hosts 2>/dev/null)" ]; then
	echo "127.0.0.1 $servername" >> /etc/hosts
fi

# 设置邮箱
if [ -z "$email" ]; then
	email="admin@$servername"
fi

echo -e "Installation backup directory: $hst_backups"
echo "Installation log file: $LOG"
echo

#----------------------------------------------------------#
#                      Checking swap                       #
#----------------------------------------------------------#

# 添加 swap（如果需要）
if [ -z "$(swapinfo 2>/dev/null)" ] && [ "$memory" -lt 1000000 ]; then
	echo "[ * ] Creating swap file..."
	dd if=/dev/zero of=/swapfile bs=1m count=1024 >> $LOG 2>&1
	chmod 600 /swapfile
	mdconfig -a -t vnode -f /swapfile -u 0
	swapon /dev/md0
	echo "/dev/md0 none swap sw 0 0" >> /etc/fstab
fi

#----------------------------------------------------------#
#                     Install packages                     #
#----------------------------------------------------------#

# 构建包列表
final_software="$software"

if [ "$apache" = 'no' ]; then
	final_software=$(echo "$final_software" | sed 's/apache24//g')
fi
if [ "$vsftpd" = 'no' ]; then
	final_software=$(echo "$final_software" | sed 's/vsftpd//g')
fi
if [ "$proftpd" = 'no' ]; then
	final_software=$(echo "$final_software" | sed 's/proftpd//g')
fi
if [ "$named" = 'no' ]; then
	final_software=$(echo "$final_software" | sed 's/bind918//g')
fi
if [ "$exim" = 'no' ]; then
	final_software=$(echo "$final_software" | sed 's/exim//g')
	final_software=$(echo "$final_software" | sed 's/dovecot//g')
	final_software=$(echo "$final_software" | sed 's/clamav-daemon//g')
	final_software=$(echo "$final_software" | sed 's/spamassassin//g')
fi
if [ "$clamd" = 'no' ]; then
	final_software=$(echo "$final_software" | sed 's/clamav-daemon//g')
fi
if [ "$spamd" = 'no' ]; then
	final_software=$(echo "$final_software" | sed 's/spamassassin//g')
fi
if [ "$dovecot" = 'no' ]; then
	final_software=$(echo "$final_software" | sed 's/dovecot//g')
fi
if [ "$mysql" = 'no' ]; then
	final_software=$(echo "$final_software" | sed 's/mariadb106-server//g')
fi
if [ "$mysql8" = 'no' ]; then
	final_software=$(echo "$final_software" | sed 's/mysql80-server//g')
fi
if [ "$postgresql" = 'no' ]; then
	final_software=$(echo "$final_software" | sed 's/postgresql14-server//g')
	final_software=$(echo "$final_software" | sed 's/postgresql14-client//g')
fi
if [ "$fail2ban" = 'no' ]; then
	final_software=$(echo "$final_software" | sed 's/fail2ban//g')
fi
if [ "$webterminal" = 'no' ]; then
	final_software=$(echo "$final_software" | sed 's/hestia-web-terminal//g')
fi
if [ "$phpfpm" = 'no' ]; then
	final_software=$(echo "$final_software" | sed 's/php83//g')
	final_software=$(echo "$final_software" | sed 's/php83-curl//g')
	final_software=$(echo "$final_software" | sed 's/php83-mysqli//g')
	final_software=$(echo "$final_software" | sed 's/php83-json//g')
	final_software=$(echo "$final_software" | sed 's/php83-mbstring//g')
	final_software=$(echo "$final_software" | sed 's/php83-session//g')
	final_software=$(echo "$final_software" | sed 's/php83-xml//g')
	final_software=$(echo "$final_software" | sed 's/php83-zip//g')
fi

# 本地包安装
if [ -n "$withpkgs" ] && [ -d "$withpkgs" ]; then
	echo "[ * ] Installing local package files..."
	for pkg in $withpkgs/*.txz; do
		pkg add $pkg >> $LOG 2>&1
	done
fi

# 安装软件包
echo "[ * ] Installing packages: $final_software"
echo "NOTE: This process may take 10 to 15 minutes to complete..."

pkg_install $final_software &
BACK_PID=$!

spin_i=1
while kill -0 $BACK_PID 2>/dev/null; do
	printf "\b${spinner:spin_i++%${#spinner}:1}"
	sleep 0.5
done
echo

wait $BACK_PID
check_result $? "pkg install failed"

echo
echo "========================================================================"
echo

# 安装 Hestia 本地包
if [ -n "$withpkgs" ] && [ -d "$withpkgs" ]; then
	echo "[ * ] Installing local package files..."
	
	if [ -f "$withpkgs/hestia-php-*.txz" ]; then
		echo "    - hestia-php backend package"
		pkg add $withpkgs/hestia-php-*.txz > /dev/null 2>&1
	fi

	if [ -f "$withpkgs/hestia-nginx-*.txz" ]; then
		echo "    - hestia-nginx backend package"
		pkg add $withpkgs/hestia-nginx-*.txz > /dev/null 2>&1
	fi

	if [ "$webterminal" = "yes" ]; then
		if [ -f "$withpkgs/hestia-web-terminal-*.txz" ]; then
			echo "    - hestia-web-terminal package"
			pkg add $withpkgs/hestia-web-terminal-*.txz > /dev/null 2>&1
		fi
	fi

	if [ -f "$withpkgs/hestia-*.txz" ]; then
		echo "    - hestia core package"
		pkg add $withpkgs/hestia-*.txz > /dev/null 2>&1
	fi
fi

#----------------------------------------------------------#
#                         Backup                           #
#----------------------------------------------------------#

# 创建备份目录树
mkdir -p $hst_backups
cd $hst_backups
mkdir nginx apache24 php vsftpd proftpd named exim dovecot clamd
mkdir spamassassin mysql postgresql openssl hestia

# Backup OpenSSL 配置
cp /etc/ssl/openssl.cnf $hst_backups/openssl 2>/dev/null

# Backup nginx 配置
service_control stop nginx 2>/dev/null
cp -r /usr/local/etc/nginx/* $hst_backups/nginx 2>/dev/null

# Backup Apache 配置
if [ "$apache" = 'yes' ]; then
	service_control stop apache24 2>/dev/null
	cp -r /usr/local/etc/apache24/* $hst_backups/apache24 2>/dev/null
fi

# Backup PHP-FPM 配置
service_control stop php-fpm 2>/dev/null
cp -r /usr/local/etc/php* $hst_backups/php 2>/dev/null

# Backup Bind 配置
if [ "$named" = 'yes' ]; then
	service_control stop named 2>/dev/null
	cp -r /usr/local/etc/namedb/* $hst_backups/named 2>/dev/null
fi

# Backup Vsftpd 配置
if [ "$vsftpd" = 'yes' ]; then
	service_control stop vsftpd 2>/dev/null
	cp /usr/local/etc/vsftpd.conf $hst_backups/vsftpd 2>/dev/null
fi

# Backup ProFTPD 配置
if [ "$proftpd" = 'yes' ]; then
	service_control stop proftpd 2>/dev/null
	cp -r /usr/local/etc/proftpd/* $hst_backups/proftpd 2>/dev/null
fi

# Backup Exim 配置
if [ "$exim" = 'yes' ]; then
	service_control stop exim 2>/dev/null
	cp -r /usr/local/etc/exim/* $hst_backups/exim 2>/dev/null
fi

# Backup ClamAV 配置
if [ "$clamd" = 'yes' ]; then
	service_control stop clamav-clamd 2>/dev/null
	cp -r /usr/local/etc/clamav/* $hst_backups/clamav 2>/dev/null
fi

# Backup SpamAssassin 配置
if [ "$spamd" = 'yes' ]; then
	service_control stop spamassassin 2>/dev/null
	cp -r /usr/local/etc/spamassassin/* $hst_backups/spamassassin 2>/dev/null
fi

# Backup Dovecot 配置
if [ "$dovecot" = 'yes' ]; then
	service_control stop dovecot 2>/dev/null
	cp /usr/local/etc/dovecot/dovecot.conf $hst_backups/dovecot 2>/dev/null
	cp -r /usr/local/etc/dovecot/conf.d $hst_backups/dovecot 2>/dev/null
fi

# Backup MySQL/MariaDB 配置和数据
if [ "$mysql" = 'yes' ] || [ "$mysql8" = 'yes' ]; then
	service_control stop mysql-server 2>/dev/null
	cp -r /var/db/mysql $hst_backups/mysql/mysql_datadir 2>/dev/null
	cp -r /usr/local/etc/mysql/* $hst_backups/mysql 2>/dev/null
fi

# Backup PostgreSQL 配置
if [ "$postgresql" = 'yes' ]; then
	service_control stop postgresql 2>/dev/null
	cp -r /var/db/postgres/* $hst_backups/postgresql 2>/dev/null
fi

# Backup Hestia
if [ -d "$HESTIA" ]; then
	service_control stop hestia 2>/dev/null
	cp -r $HESTIA/* $hst_backups/hestia 2>/dev/null
fi

#----------------------------------------------------------#
#                     Package Includes                     #
#----------------------------------------------------------#

if [ "$phpfpm" = 'yes' ]; then
	# FreeBSD 包名格式
	fpm="php${fpm_v} php${fpm_v}-curl php${fpm_v}-mysqli php${fpm_v}-json \
	     php${fpm_v}-mbstring php${fpm_v}-session php${fpm_v}-xml php${fpm_v}-zip \
	     php${fpm_v}-gd php${fpm_v}-intl php${fpm_v}-soap"
	software="$software $fpm"
fi

#----------------------------------------------------------#
#                     Package Excludes                     #
#----------------------------------------------------------#

# 排除不需要的包
if [ "$apache" = 'no' ]; then
	software=$(echo "$software" | sed -e "s/apache24//g")
fi
if [ "$vsftpd" = 'no' ]; then
	software=$(echo "$software" | sed -e "s/vsftpd//g")
fi
if [ "$proftpd" = 'no' ]; then
	software=$(echo "$software" | sed -e "s/proftpd//g")
fi
if [ "$named" = 'no' ]; then
	software=$(echo "$software" | sed -e "s/bind918//g")
fi
if [ "$exim" = 'no' ]; then
	software=$(echo "$software" | sed -e "s/exim//g")
	software=$(echo "$software" | sed -e "s/dovecot//g")
	software=$(echo "$software" | sed -e "s/clamav-daemon//g")
	software=$(echo "$software" | sed -e "s/spamassassin//g")
fi
if [ "$clamd" = 'no' ]; then
	software=$(echo "$software" | sed -e "s/clamav-daemon//g")
fi
if [ "$spamd" = 'no' ]; then
	software=$(echo "$software" | sed -e "s/spamassassin//g")
fi
if [ "$dovecot" = 'no' ]; then
	software=$(echo "$software" | sed -e "s/dovecot//g")
fi
if [ "$mysql" = 'no' ]; then
	software=$(echo "$software" | sed -e "s/mariadb106-server//g")
fi
if [ "$mysql8" = 'no' ]; then
	software=$(echo "$software" | sed -e "s/mysql80-server//g")
fi
if [ "$postgresql" = 'no' ]; then
	software=$(echo "$software" | sed -e "s/postgresql14-server//g")
	software=$(echo "$software" | sed -e "s/postgresql14-client//g")
fi
if [ "$fail2ban" = 'no' ]; then
	software=$(echo "$software" | sed -e "s/fail2ban//g")
fi
if [ "$webterminal" = 'no' ]; then
	software=$(echo "$software" | sed -e "s/hestia-web-terminal//g")
fi
if [ "$phpfpm" = 'yes' ]; then
	# FreeBSD 没有这些包
	software=$(echo "$software" | sed -e "s/php${fpm_v}-cgi//g")
fi

#----------------------------------------------------------#
#                     Configure system                     #
#----------------------------------------------------------#

echo "[ * ] Configuring system settings..."

# 生成随机密码
random_password=$(gen_pass '32')
# 创建 hestiaweb 用户
create_user "hestiaweb" "$email"
echo hestiaweb:$random_password | chpass -e

# 添加用户组
create_group "hestia-users"

# 创建 hestiamail 用户
create_user "hestiamail" "$email"
add_user_to_group hestiamail hestia-users

# 配置 SSH
if [ -f /etc/ssh/sshd_config ]; then
	if ! grep -q "Subsystem sftp internal-sftp" /etc/ssh/sshd_config; then
		sed -i '' 's/Subsystem.*sftp.*/Subsystem sftp internal-sftp/' /etc/ssh/sshd_config
	fi
	sed -i '' 's/^#LoginGraceTime.*/LoginGraceTime 1m/' /etc/ssh/sshd_config
	if ! grep -q "DebianBanner no" /etc/ssh/sshd_config; then
		echo "DebianBanner no" >> /etc/ssh/sshd_config
	fi
	service_control restart sshd
fi

# 删除 AWStats cron
rm -f /etc/cron.d/awstats 2>/dev/null

# 设置目录颜色
if [ -z "$(grep 'LS_COLORS="$LS_COLORS:di=00;33"' /etc/profile 2>/dev/null)" ]; then
	echo 'LS_COLORS="$LS_COLORS:di=00;33"' >> /etc/profile
fi

# 注册 nologin
if [ -z "$(grep ^/usr/sbin/nologin /etc/shells)" ]; then
	echo "/usr/sbin/nologin" >> /etc/shells
fi

# 配置 NTP
if [ -f /etc/rc.conf ]; then
	if ! grep -q "ntpd_enable" /etc/rc.conf; then
		echo 'ntpd_enable="YES"' >> /etc/rc.conf
		echo 'ntpd_sync_on_start="YES"' >> /etc/rc.conf
	fi
	service_control start ntpd
fi

#----------------------------------------------------------#
#                     Configure Hestia                     #
#----------------------------------------------------------#

echo "[ * ] Configuring Hestia Control Panel..."

# 创建 sudo 配置
mkdir -p /usr/local/etc/sudoers.d
cp -f $HESTIA_COMMON_DIR/sudo/hestiaweb /usr/local/etc/sudoers.d/
chmod 440 /usr/local/etc/sudoers.d/hestiaweb

# 创建全局配置
if [ ! -e /usr/local/etc/hestiacp/hestia.conf ]; then
	mkdir -p /usr/local/etc/hestiacp
	echo -e "# Do not edit this file, will get overwritten on next upgrade\n\nexport HESTIA='/usr/local/hestia'\n\n[[ -f /usr/local/etc/hestiacp/local.conf ]] && source /usr/local/etc/hestiacp/local.conf" > /usr/local/etc/hestiacp/hestia.conf
fi

# 配置环境变量
echo "export HESTIA='$HESTIA'" > /etc/profile.d/hestia.sh
echo 'PATH=$PATH:'$HESTIA'/bin' >> /etc/profile.d/hestia.sh
echo 'export PATH' >> /etc/profile.d/hestia.sh
chmod 755 /etc/profile.d/hestia.sh
source /etc/profile.d/hestia.sh

# 配置 newsyslog（FreeBSD 的 logrotate）
if [ -f $HESTIA_INSTALL_DIR/logrotate/hestia ]; then
	cp -f $HESTIA_INSTALL_DIR/logrotate/hestia /usr/local/etc/newsyslog.conf.d/hestia.conf
fi

# 创建目录结构
rm -f /var/log/hestia
mkdir -p /var/log/hestia
ln -s /var/log/hestia $HESTIA/log

mkdir -p $HESTIA/conf $HESTIA/ssl $HESTIA/data/ips \
	$HESTIA/data/queue $HESTIA/data/users $HESTIA/data/firewall \
	$HESTIA/data/sessions

touch $HESTIA/data/queue/backup.pipe $HESTIA/data/queue/disk.pipe \
	$HESTIA/data/queue/webstats.pipe $HESTIA/data/queue/restart.pipe \
	$HESTIA/data/queue/traffic.pipe $HESTIA/data/queue/daily.pipe \
	$HESTIA/log/system.log $HESTIA/log/nginx-error.log \
	$HESTIA/log/auth.log $HESTIA/log/backup.log

chmod 750 $HESTIA/conf $HESTIA/data/users $HESTIA/data/ips $HESTIA/log
chmod -R 750 $HESTIA/data/queue
chmod 660 /var/log/hestia/*
chmod 770 $HESTIA/data/sessions

# 生成 Hestia 配置
rm -f $HESTIA/conf/hestia.conf
touch $HESTIA/conf/hestia.conf
chmod 660 $HESTIA/conf/hestia.conf

# 写入默认端口
write_config_value "BACKEND_PORT" "8083"

# Web 配置
if [ "$apache" = 'yes' ]; then
	write_config_value "WEB_SYSTEM" "apache2"
	write_config_value "WEB_RGROUPS" "www"
	write_config_value "WEB_PORT" "8080"
	write_config_value "WEB_SSL_PORT" "8443"
	write_config_value "WEB_SSL" "mod_ssl"
	write_config_value "PROXY_SYSTEM" "nginx"
	write_config_value "PROXY_PORT" "80"
	write_config_value "PROXY_SSL_PORT" "443"
	write_config_value "STATS_SYSTEM" "awstats"
fi

if [ "$apache" = 'no' ]; then
	write_config_value "WEB_SYSTEM" "nginx"
	write_config_value "WEB_PORT" "80"
	write_config_value "WEB_SSL_PORT" "443"
	write_config_value "WEB_SSL" "openssl"
	write_config_value "STATS_SYSTEM" "awstats"
fi

if [ "$phpfpm" = 'yes' ]; then
	write_config_value "WEB_BACKEND" "php-fpm"
fi

# 数据库配置
if [ "$mysql" = 'yes' ] || [ "$mysql8" = 'yes' ]; then
	installed_db_types='mysql'
fi
if [ "$postgresql" = 'yes' ]; then
	if [ -n "$installed_db_types" ]; then
		installed_db_types="$installed_db_types,pgsql"
	else
		installed_db_types='pgsql'
	fi
fi
if [ -n "$installed_db_types" ]; then
	db=$(echo "$installed_db_types" | sed "s/,/\n/g" | sort -r -u | sed "/^$/d" | tr '\n' ',' | sed 's/,$//')
	write_config_value "DB_SYSTEM" "$db"
fi

# FTP 配置
if [ "$vsftpd" = 'yes' ]; then
	write_config_value "FTP_SYSTEM" "vsftpd"
fi
if [ "$proftpd" = 'yes' ]; then
	write_config_value "FTP_SYSTEM" "proftpd"
fi

# DNS 配置
if [ "$named" = 'yes' ]; then
	write_config_value "DNS_SYSTEM" "bind9"
fi

# 邮件配置
if [ "$exim" = 'yes' ]; then
	write_config_value "MAIL_SYSTEM" "exim4"
	if [ "$clamd" = 'yes' ]; then
		write_config_value "ANTIVIRUS_SYSTEM" "clamav-daemon"
	fi
	if [ "$spamd" = 'yes' ]; then
		write_config_value "ANTISPAM_SYSTEM" "spamassassin"
	fi
	if [ "$dovecot" = 'yes' ]; then
		write_config_value "IMAP_SYSTEM" "dovecot"
	fi
	if [ "$sieve" = 'yes' ]; then
		write_config_value "SIEVE_SYSTEM" "yes"
	fi
fi

# 其他配置
write_config_value "CRON_SYSTEM" "cron"

if [ "$iptables" = 'yes' ]; then
	write_config_value "FIREWALL_SYSTEM" "pf"
fi
if [ "$iptables" = 'yes' ] && [ "$fail2ban" = 'yes' ]; then
	write_config_value "FIREWALL_EXTENSION" "fail2ban"
fi

if [ "$quota" = 'yes' ]; then
	write_config_value "DISK_QUOTA" "yes"
else
	write_config_value "DISK_QUOTA" "no"
fi

if [ "$resourcelimit" = 'yes' ]; then
	write_config_value "RESOURCES_LIMIT" "yes"
else
	write_config_value "RESOURCES_LIMIT" "no"
fi

write_config_value "WEB_TERMINAL_PORT" "8085"
write_config_value "BACKUP_SYSTEM" "local"
write_config_value "BACKUP_GZIP" "4"
write_config_value "BACKUP_MODE" "zstd"
write_config_value "LANGUAGE" "$lang"
write_config_value "LOGIN_STYLE" "default"
write_config_value "THEME" "dark"
write_config_value "INACTIVE_SESSION_TIMEOUT" "60"
write_config_value "VERSION" "${HESTIA_INSTALL_VER}"
write_config_value "RELEASE_BRANCH" "release"
write_config_value "UPGRADE_SEND_EMAIL" "true"
write_config_value "UPGRADE_SEND_EMAIL_LOG" "false"
write_config_value "ROOT_USER" "$username"

# 安装模板和包
cp -rf $HESTIA_COMMON_DIR/packages $HESTIA/data/
cp -rf $HESTIA_INSTALL_DIR/templates $HESTIA/data/
cp -rf $HESTIA_COMMON_DIR/templates/web/ $HESTIA/data/templates
cp -rf $HESTIA_COMMON_DIR/templates/dns/ $HESTIA/data/templates

mkdir -p /usr/local/www/hestia
mkdir -p /usr/local/www/document_errors

cp -rf $HESTIA_COMMON_DIR/templates/web/unassigned/index.html /usr/local/www/hestia/
cp -rf $HESTIA_COMMON_DIR/templates/web/skel/document_errors/* /usr/local/www/document_errors/

# 安装防火墙规则
cp -rf $HESTIA_COMMON_DIR/firewall $HESTIA/data/
rm -f $HESTIA/data/firewall/ipset/blacklist.sh $HESTIA/data/firewall/ipset/blacklist.ipv6.sh

# 删除未安装服务的防火墙规则
if [ "$vsftpd" = "no" ] && [ "$proftpd" = "no" ]; then
	sed -i '' "/COMMENT='FTP'/d" $HESTIA/data/firewall/rules.conf
fi
if [ "$exim" = "no" ]; then
	sed -i '' "/COMMENT='SMTP'/d" $HESTIA/data/firewall/rules.conf
fi
if [ "$dovecot" = "no" ]; then
	sed -i '' "/COMMENT='IMAP'/d" $HESTIA/data/firewall/rules.conf
	sed -i '' "/COMMENT='POP3'/d" $HESTIA/data/firewall/rules.conf
fi
if [ "$named" = "no" ]; then
	sed -i '' "/COMMENT='DNS'/d" $HESTIA/data/firewall/rules.conf
fi

# 安装 API
cp -rf $HESTIA_COMMON_DIR/api $HESTIA/data/

# 设置主机名
$HESTIA/bin/v-change-sys-hostname $servername > /dev/null 2>&1

# 配置 SSL
echo "[ * ] Generating default SSL certificate..."
$HESTIA/bin/v-generate-ssl-cert $(hostname) '' 'US' 'California' \
	'San Francisco' 'Hestia Control Panel' 'IT' > /tmp/hst.pem

crt_end=$(grep -n "END CERTIFICATE-" /tmp/hst.pem | head -n1 | cut -f 1 -d:)
key_start=$(grep -nE "BEGIN (RSA |EC |ENCRYPTED )?PRIVATE KEY" /tmp/hst.pem | head -n1 | cut -f 1 -d:)
key_end=$(grep -nE "END (RSA |EC |ENCRYPTED )?PRIVATE KEY" /tmp/hst.pem | head -n1 | cut -f 1 -d:)

cd $HESTIA/ssl
sed -n "1,${crt_end}p" /tmp/hst.pem > certificate.crt
sed -n "${key_start},${key_end}p" /tmp/hst.pem > certificate.key
chown root:mail $HESTIA/ssl/*
chmod 660 $HESTIA/ssl/*
rm /tmp/hst.pem

# 安装 dhparam
if [ -f $HESTIA_INSTALL_DIR/ssl/dhparam.pem ]; then
	cp -f $HESTIA_INSTALL_DIR/ssl/dhparam.pem /usr/local/etc/ssl/
fi

# 创建管理员账户
echo "[ * ] Creating admin account..."
$HESTIA/bin/v-add-user "$username" "$vpass" "$email" "default" "System Administrator"
check_result $? "can't create admin user"
$HESTIA/bin/v-change-user-shell "$username" nologin
$HESTIA/bin/v-change-user-role "$username" admin
$HESTIA/bin/v-change-user-language "$username" "$lang"
$HESTIA/bin/v-change-sys-config-value 'POLICY_SYSTEM_PROTECTED_ADMIN' 'yes'

#----------------------------------------------------------#
#                     Configure Nginx                      #
#----------------------------------------------------------#

echo "[ * ] Configuring NGINX..."

NGINX_CONF_DIR="/usr/local/etc/nginx"
mkdir -p $NGINX_CONF_DIR/conf.d/domains
mkdir -p $NGINX_CONF_DIR/conf.d/main
mkdir -p /var/log/nginx/domains

rm -f $NGINX_CONF_DIR/conf.d/*.conf
cp -f $HESTIA_INSTALL_DIR/nginx/nginx.conf $NGINX_CONF_DIR/
cp -f $HESTIA_INSTALL_DIR/nginx/status.conf $NGINX_CONF_DIR/conf.d/
cp -f $HESTIA_INSTALL_DIR/nginx/0rtt-anti-replay.conf $NGINX_CONF_DIR/conf.d/
cp -f $HESTIA_INSTALL_DIR/nginx/agents.conf $NGINX_CONF_DIR/conf.d/
cp -f $HESTIA_INSTALL_DIR/nginx/cloudflare.inc $NGINX_CONF_DIR/conf.d/
cp -f $HESTIA_INSTALL_DIR/nginx/phpmyadmin.inc $NGINX_CONF_DIR/conf.d/
cp -f $HESTIA_INSTALL_DIR/nginx/phppgadmin.inc $NGINX_CONF_DIR/conf.d/

# 设置 DNS 解析器
resolver=""
for nameserver in $(grep '^nameserver' /etc/resolv.conf | awk '{print $2}'); do
	if [ -n "$resolver" ]; then
		resolver="$resolver $nameserver"
	else
		resolver="$nameserver"
	fi
done
if [ -n "$resolver" ]; then
	sed -i '' "s/1.1.1.1 8.8.8.8/$resolver/g" $NGINX_CONF_DIR/nginx.conf
fi

# 配置 Cloudflare IP
cf_ips=$(curl -fsLm5 --retry 2 https://api.cloudflare.com/client/v4/ips 2>/dev/null)
if [ -n "$cf_ips" ] && command -v jq >/dev/null 2>&1; then
	cf_inc="$NGINX_CONF_DIR/conf.d/cloudflare.inc"
	echo "[ * ] Updating Cloudflare IP Ranges..."
	echo "# Cloudflare IP Ranges" > $cf_inc
	echo "" >> $cf_inc
	echo "# IPv4" >> $cf_inc
	for ipv4 in $(echo "$cf_ips" | jq -r '.result.ipv4_cidrs[]//""' | sort); do
		echo "set_real_ip_from $ipv4;" >> $cf_inc
	done
	echo "" >> $cf_inc
	echo "# IPv6" >> $cf_inc
	for ipv6 in $(echo "$cf_ips" | jq -r '.result.ipv6_cidrs[]//""' | sort); do
		echo "set_real_ip_from $ipv6;" >> $cf_inc
	done
	echo "" >> $cf_inc
	echo "real_ip_header CF-Connecting-IP;" >> $cf_inc
fi

service_control enable nginx
service_control start nginx
check_result $? "nginx start failed"

#----------------------------------------------------------#
#                    Configure Apache                      #
#----------------------------------------------------------#

if [ "$apache" = 'yes' ]; then
	echo "[ * ] Configuring Apache Web Server..."

	APACHE_CONF_DIR="/usr/local/etc/apache24"
	mkdir -p $APACHE_CONF_DIR/conf.d
	mkdir -p $APACHE_CONF_DIR/conf.d/domains
	mkdir -p /var/log/apache2/domains

	cp -f $HESTIA_INSTALL_DIR/apache2/apache2.conf $APACHE_CONF_DIR/
	cp -f $HESTIA_INSTALL_DIR/apache2/status.conf $APACHE_CONF_DIR/conf.d/hestia-status.conf

	# 启用模块
	sed -i '' 's/#LoadModule rewrite_module/LoadModule rewrite_module/' $APACHE_CONF_DIR/httpd.conf
	sed -i '' 's/#LoadModule suexec_module/LoadModule suexec_module/' $APACHE_CONF_DIR/httpd.conf
	sed -i '' 's/#LoadModule ssl_module/LoadModule ssl_module/' $APACHE_CONF_DIR/httpd.conf
	sed -i '' 's/#LoadModule actions_module/LoadModule actions_module/' $APACHE_CONF_DIR/httpd.conf
	sed -i '' 's/#LoadModule headers_module/LoadModule headers_module/' $APACHE_CONF_DIR/httpd.conf

	if [ "$phpfpm" = 'yes' ]; then
		sed -i '' 's/#LoadModule proxy_module/LoadModule proxy_module/' $APACHE_CONF_DIR/httpd.conf
		sed -i '' 's/#LoadModule proxy_fcgi_module/LoadModule proxy_fcgi_module/' $APACHE_CONF_DIR/httpd.conf
		cp -f $HESTIA_INSTALL_DIR/apache2/hestia-event.conf $APACHE_CONF_DIR/conf.d/
	else
		sed -i '' 's/#LoadModule mpm_itk_module/LoadModule mpm_itk_module/' $APACHE_CONF_DIR/httpd.conf
	fi

	# 创建 suexec 配置
	echo "/usr/local/www\npublic_html/cgi-bin" > $APACHE_CONF_DIR/suexec/www-data

	# 设置日志
	touch /var/log/apache2/access.log /var/log/apache2/error.log
	chmod 640 /var/log/apache2/access.log /var/log/apache2/error.log
	chmod 751 /var/log/apache2/domains

	service_control enable apache24
	service_control start apache24
	check_result $? "apache2 start failed"
else
	service_control disable apache24
	service_control stop apache24 2>/dev/null
fi

#----------------------------------------------------------#
#                     Configure PHP-FPM                    #
#----------------------------------------------------------#

if [ "$phpfpm" = "yes" ]; then
	PHP_FPM_CONF_DIR="/usr/local/etc/php-fpm.d"
	PHP_VERSION="${fpm_v}"

	if [ "$multiphp" = 'yes' ]; then
		for v in "${multiphp_v[@]}"; do
			echo "[ * ] Installing PHP $v..."
			$HESTIA/bin/v-add-web-php "$v" > /dev/null 2>&1
		done
	else
		echo "[ * ] Installing PHP $PHP_VERSION..."
		$HESTIA/bin/v-add-web-php "$PHP_VERSION" > /dev/null 2>&1
	fi

	echo "[ * ] Configuring PHP-FPM $PHP_VERSION..."
	cp -f $HESTIA_INSTALL_DIR/php-fpm/www.conf $PHP_FPM_CONF_DIR/

	service_control enable php-fpm
	service_control start php-fpm
	check_result $? "php-fpm start failed"
fi

#----------------------------------------------------------#
#                     Configure PHP                        #
#----------------------------------------------------------#

echo "[ * ] Configuring PHP..."

ZONE=$(date +"%Z")
if [ -z "$ZONE" ]; then
	ZONE='UTC'
fi

for pconf in $(find /usr/local/etc -name "php.ini" 2>/dev/null); do
	sed -i '' "s/;date.timezone =/date.timezone = $ZONE/" $pconf
	sed -i '' 's/short_open_tag = Off/short_open_tag = On/' $pconf
done

# 清理 PHP session
cat > /etc/periodic/daily/php-session-cleanup << 'EOF'
#!/bin/sh
find /home/*/tmp/ -ignore_readdir_race -depth -mindepth 1 -name 'sess_*' -type f -mmin +10080 -delete 2>/dev/null
find /usr/local/hestia/data/sessions/ -ignore_readdir_race -depth -mindepth 1 -name 'sess_*' -type f -mmin +10080 -delete 2>/dev/null
EOF
chmod 755 /etc/periodic/daily/php-session-cleanup

#----------------------------------------------------------#
#                    Configure Vsftpd                      #
#----------------------------------------------------------#

if [ "$vsftpd" = 'yes' ]; then
	echo "[ * ] Configuring Vsftpd server..."

	VSFTPD_CONF="/usr/local/etc/vsftpd.conf"
	cp -f $HESTIA_INSTALL_DIR/vsftpd/vsftpd.conf $VSFTPD_CONF

	touch /var/log/vsftpd.log
	chown root:wheel /var/log/vsftpd.log
	chmod 640 /var/log/vsftpd.log
	touch /var/log/xferlog
	chown root:wheel /var/log/xferlog
	chmod 640 /var/log/xferlog

	service_control enable vsftpd
	service_control start vsftpd
	check_result $? "vsftpd start failed"
fi

#----------------------------------------------------------#
#                    Configure ProFTPD                     #
#----------------------------------------------------------#

if [ "$proftpd" = 'yes' ]; then
	echo "[ * ] Configuring ProFTPD server..."

	PROFTpd_CONF="/usr/local/etc/proftpd.conf"
	cp -f $HESTIA_INSTALL_DIR/proftpd/proftpd.conf $PROFTpd_CONF
	cp -f $HESTIA_INSTALL_DIR/proftpd/tls.conf /usr/local/etc/proftpd/tls.conf

	service_control enable proftpd
	service_control start proftpd
	check_result $? "proftpd start failed"
fi

#----------------------------------------------------------#
#                      Configure Bind                      #
#----------------------------------------------------------#

if [ "$named" = 'yes' ]; then
	echo "[ * ] Configuring Bind DNS server..."

	NAMED_CONF_DIR="/usr/local/etc/namedb"
	cp -f $HESTIA_INSTALL_DIR/bind/named.conf $NAMED_CONF_DIR/
	cp -f $HESTIA_INSTALL_DIR/bind/named.conf.options $NAMED_CONF_DIR/

	chown root:bind $NAMED_CONF_DIR/named.conf
	chown root:bind $NAMED_CONF_DIR/named.conf.options
	chown bind:bind /var/cache/bind
	chmod 640 $NAMED_CONF_DIR/named.conf
	chmod 640 $NAMED_CONF_DIR/named.conf.options

	service_control enable named
	service_control start named
	check_result $? "named start failed"
fi

#----------------------------------------------------------#
#                      Configure Exim                      #
#----------------------------------------------------------#

if [ "$exim" = 'yes' ]; then
	echo "[ * ] Configuring Exim mail server..."

	create_group "Debian-exim" 2>/dev/null
	add_user_to_group Debian-exim mail 2>/dev/null

	EXIM_CONF_DIR="/usr/local/etc/exim"
	mkdir -p $EXIM_CONF_DIR/domains

	cp -f $HESTIA_INSTALL_DIR/exim/exim4.conf.template $EXIM_CONF_DIR/
	cp -f $HESTIA_INSTALL_DIR/exim/dnsbl.conf $EXIM_CONF_DIR/
	cp -f $HESTIA_INSTALL_DIR/exim/spam-blocks.conf $EXIM_CONF_DIR/
	cp -f $HESTIA_INSTALL_DIR/exim/limit.conf $EXIM_CONF_DIR/
	cp -f $HESTIA_INSTALL_DIR/exim/system.filter $EXIM_CONF_DIR/
	touch $EXIM_CONF_DIR/white-blocks.conf

	if [ "$spamd" = 'yes' ]; then
		sed -i '' 's/#SPAM/SPAM/g' $EXIM_CONF_DIR/exim4.conf.template
	fi
	if [ "$clamd" = 'yes' ]; then
		sed -i '' 's/#CLAMD/CLAMD/g' $EXIM_CONF_DIR/exim4.conf.template
	fi

	srs=$(gen_pass)
	echo $srs > $EXIM_CONF_DIR/srs.conf
	chmod 640 $EXIM_CONF_DIR/srs.conf
	chown root:mail $EXIM_CONF_DIR/srs.conf

	service_control enable exim
	service_control start exim
	check_result $? "exim start failed"
fi

#----------------------------------------------------------#
#                     Configure Dovecot                    #
#----------------------------------------------------------#

if [ "$dovecot" = 'yes' ]; then
	echo "[ * ] Configuring Dovecot POP/IMAP mail server..."

	add_user_to_group dovecot mail 2>/dev/null

	DOVECOT_CONF_DIR="/usr/local/etc/dovecot"
	cp -rf $HESTIA_COMMON_DIR/dovecot/* $DOVECOT_CONF_DIR/

	touch /var/log/dovecot.log
	chown dovecot:mail /var/log/dovecot.log
	chmod 660 /var/log/dovecot.log

	# 检测 Dovecot 版本
	version=$(dovecot --version | cut -f -2 -d .)
	if [ "$version" = "2.2" ]; then
		echo "[ * ] Adjusting Dovecot config for version 2.2"
		sed -i '' 's/ssl_dh = <\/usr\/local\/etc\/ssl\/dhparam.pem/#ssl_dh = <\/usr\/local\/etc\/ssl\/dhparam.pem/' $DOVECOT_CONF_DIR/conf.d/10-ssl.conf
		sed -i '' 's/ssl_min_protocol = TLSv1.2/ssl_protocols = !SSLv3 !TLSv1 !TLSv1.1/' $DOVECOT_CONF_DIR/conf.d/10-ssl.conf
	fi

	service_control enable dovecot
	service_control start dovecot
	check_result $? "dovecot start failed"
fi

#----------------------------------------------------------#
#                      Configure Bind                      #
#----------------------------------------------------------#

if [ "$named" = 'yes' ]; then
    echo "[ * ] Configuring Bind DNS server..."
    cp -f $HESTIA_INSTALL_DIR/bind/named.conf /etc/bind/
    cp -f $HESTIA_INSTALL_DIR/bind/named.conf.options /etc/bind/
    chown root:bind /etc/bind/named.conf
    chown root:bind /etc/bind/named.conf.options
    chown bind:bind /var/cache/bind
    chmod 640 /etc/bind/named.conf
    chmod 640 /etc/bind/named.conf.options
    aa-complain /usr/sbin/named 2> /dev/null
    if [ "$apparmor" = 'yes' ]; then
        echo "/home/** rwm," >> /etc/apparmor.d/local/usr.sbin.named 2> /dev/null
        systemctl status apparmor > /dev/null 2>&1
        if [ $? -ne 0 ]; then
            systemctl restart apparmor >> $LOG
        fi
    fi
    update-rc.d bind9 defaults > /dev/null 2>&1
    systemctl start bind9
    check_result $? "bind9 start failed"

    # Workaround for OpenVZ/Virtuozzo
    if [ -e "/proc/vz/veinfo" ] && [ -e "/etc/rc.local" ]; then
        sed -i "s/^exit 0/service bind9 restart\nexit 0/" /etc/rc.local
    fi
fi

#----------------------------------------------------------#
#                      Configure Exim                      #
#----------------------------------------------------------#

if [ "$exim" = 'yes' ]; then
    echo "[ * ] Configuring Exim mail server..."
    gpasswd -a Debian-exim mail > /dev/null 2>&1
    exim_version=$(exim4 --version | head -1 | awk '{print $3}' | cut -f -2 -d .)
    # if Exim version > 4.9.4 or greater!
    if ! version_ge "4.95" "$exim_version"; then
        cp -f $HESTIA_INSTALL_DIR/exim/exim4.conf.4.95.template /etc/exim4/exim4.conf.template
    else
        if ! version_ge "4.93" "$exim_version"; then
            cp -f $HESTIA_INSTALL_DIR/exim/exim4.conf.4.94.template /etc/exim4/exim4.conf.template
        else
            cp -f $HESTIA_INSTALL_DIR/exim/exim4.conf.template /etc/exim4/
        fi
    fi
    cp -f $HESTIA_INSTALL_DIR/exim/dnsbl.conf /etc/exim4/
    cp -f $HESTIA_INSTALL_DIR/exim/spam-blocks.conf /etc/exim4/
    cp -f $HESTIA_INSTALL_DIR/exim/limit.conf /etc/exim4/
    cp -f $HESTIA_INSTALL_DIR/exim/system.filter /etc/exim4/
    touch /etc/exim4/white-blocks.conf

    if [ "$spamd" = 'yes' ]; then
        sed -i "s/#SPAM/SPAM/g" /etc/exim4/exim4.conf.template
    fi
    if [ "$clamd" = 'yes' ]; then
        sed -i "s/#CLAMD/CLAMD/g" /etc/exim4/exim4.conf.template
    fi

    # Generate SRS KEY If not support just created it will get ignored anyway
    srs=$(gen_pass)
    echo $srs > /etc/exim4/srs.conf
    chmod 640 /etc/exim4/srs.conf
    chmod 640 /etc/exim4/exim4.conf.template
    chown root:Debian-exim /etc/exim4/srs.conf

    rm -rf /etc/exim4/domains
    mkdir -p /etc/exim4/domains

    rm -f /etc/alternatives/mta
    ln -s /usr/sbin/exim4 /etc/alternatives/mta
    update-rc.d -f sendmail remove > /dev/null 2>&1
    systemctl stop sendmail > /dev/null 2>&1
    update-rc.d -f postfix remove > /dev/null 2>&1
    systemctl stop postfix > /dev/null 2>&1
    update-rc.d exim4 defaults
    systemctl start exim4 >> $LOG
    check_result $? "exim4 start failed"
fi

#----------------------------------------------------------#
#                     Configure Dovecot                    #
#----------------------------------------------------------#

if [ "$dovecot" = 'yes' ]; then
    echo "[ * ] Configuring Dovecot POP/IMAP mail server..."
    gpasswd -a dovecot mail > /dev/null 2>&1
    cp -rf $HESTIA_COMMON_DIR/dovecot /etc/
    cp -f $HESTIA_INSTALL_DIR/logrotate/dovecot /etc/logrotate.d/
    rm -f /etc/dovecot/conf.d/15-mailboxes.conf
    chown -R root:root /etc/dovecot*
    touch /var/log/dovecot.log
    chown -R dovecot:mail /var/log/dovecot.log
    chmod 660 /var/log/dovecot.log
    # Alter config for 2.2
    version=$(dovecot --version | cut -f -2 -d .)
    if [ "$version" = "2.2" ]; then
        echo "[ * ] Downgrade dovecot config to sync with 2.2 settings"
        sed -i 's|#ssl_dh_parameters_length = 4096|ssl_dh_parameters_length = 4096|g' /etc/dovecot/conf.d/10-ssl.conf
        sed -i 's|ssl_dh = </usr/local/etc/ssl/dhparam.pem|#ssl_dh = </usr/local/etc/ssl/dhparam.pem|g' /etc/dovecot/conf.d/10-ssl.conf
        sed -i 's|ssl_min_protocol = TLSv1.2|ssl_protocols = !SSLv3 !TLSv1 !TLSv1.1|g' /etc/dovecot/conf.d/10-ssl.conf
    fi

    update-rc.d dovecot defaults
    systemctl start dovecot >> $LOG
    check_result $? "dovecot start failed"
fi

#----------------------------------------------------------#
#                    Configure ClamAV                      #
#----------------------------------------------------------#

if [ "$clamd" = 'yes' ]; then
    gpasswd -a clamav mail > /dev/null 2>&1
    gpasswd -a clamav Debian-exim > /dev/null 2>&1
    cp -f $HESTIA_INSTALL_DIR/clamav/clamd.conf /etc/clamav/
    update-rc.d clamav-daemon defaults
    if [ ! -d "/run/clamav" ]; then
        mkdir /run/clamav
    fi
    chown -R clamav:clamav /run/clamav
    if [ -e "/lib/systemd/system/clamav-daemon.service" ]; then
        exec_pre1='ExecStartPre=-/bin/mkdir -p /run/clamav'
        exec_pre2='ExecStartPre=-/bin/chown -R clamav:clamav /run/clamav'
        sed -i "s|\[Service\]|[Service]\n$exec_pre1\n$exec_pre2|g" \
            /lib/systemd/system/clamav-daemon.service
        systemctl daemon-reload
    fi
    systemctl start clamav-daemon > /dev/null 2>&1
    sleep 1
    systemctl status clamav-daemon > /dev/null 2>&1
    echo -ne "[ * ] Installing ClamAV anti-virus definitions... "
    /usr/bin/freshclam >> $LOG > /dev/null 2>&1
    BACK_PID=$!
    spin_i=1
    while kill -0 $BACK_PID > /dev/null 2>&1; do
        printf "\b${spinner:spin_i++%${#spinner}:1}"
        sleep 0.5
    done
    echo
    systemctl start clamav-daemon >> $LOG
    check_result $? "clamav-daemon start failed"
fi

#----------------------------------------------------------#
#                  Configure SpamAssassin                  #
#----------------------------------------------------------#

if [ "$spamd" = 'yes' ]; then
    echo "[ * ] Configuring SpamAssassin..."
    update-rc.d spamassassin defaults > /dev/null 2>&1
    if [ "$release" = "11" ]; then
        update-rc.d spamassassin enable > /dev/null 2>&1
        systemctl start spamassassin >> $LOG
        check_result $? "spamassassin start failed"
        unit_files="$(systemctl list-unit-files | grep spamassassin)"
        if [[ "$unit_files" =~ "disabled" ]]; then
            systemctl enable spamassassin > /dev/null 2>&1
        fi
        sed -i "s/#CRON=1/CRON=1/" /etc/default/spamassassin
    else
        # Deb 12+ renamed to spamd
        update-rc.d spamd enable > /dev/null 2>&1
        systemctl start spamd >> $LOG
        unit_files="$(systemctl list-unit-files | grep spamd)"
        if [[ "$unit_files" =~ "disabled" ]]; then
            systemctl enable spamd > /dev/null 2>&1
        fi

    fi
fi

#----------------------------------------------------------#
#                    Configure Fail2Ban                    #
#----------------------------------------------------------#

if [ "$fail2ban" = 'yes' ]; then
	echo "[ * ] Configuring Fail2Ban..."

	F2B_ETC="/usr/local/etc/fail2ban"
	mkdir -p "$F2B_ETC"
	cp -rf $HESTIA_INSTALL_DIR/fail2ban/* "$F2B_ETC/"

	if [ "$dovecot" = 'no' ]; then
		sed -i '' 's/enabled = true/enabled = false/' "$F2B_ETC/jail.local"
	fi
	if [ "$exim" = 'no' ]; then
		sed -i '' 's/\[exim-iptables\]/&\nenabled = false/' "$F2B_ETC/jail.local"
	fi

	touch /var/log/auth.log
	chmod 640 /var/log/auth.log

	sed -i '' 's/backend = auto/backend = polling/' "$F2B_ETC/jail.conf"
	sed -i '' 's/banaction = iptables-multiport/banaction = pf/' "$F2B_ETC/jail.local"

	service_control enable fail2ban
	service_control start fail2ban
	check_result $? "fail2ban start failed"
fi

#----------------------------------------------------------#
#                    Configure pf                          #
#----------------------------------------------------------#

if [ "$iptables" = 'yes' ]; then
	echo "[ * ] Configuring pf firewall..."

	PF_CONF="/etc/pf.conf"
	cp -f $HESTIA_INSTALL_DIR/pf/pf.conf $PF_CONF

	# 启用 pf
	if ! grep -q "pf_enable" /etc/rc.conf; then
		echo 'pf_enable="YES"' >> /etc/rc.conf
		echo 'pflog_enable="YES"' >> /etc/rc.conf
	fi

	# 加载 pf 内核模块
	kldload pf 2>/dev/null

	# 应用规则
	pfctl -f $PF_CONF 2>/dev/null
	pfctl -e 2>/dev/null

	$HESTIA/bin/v-update-firewall
fi

#----------------------------------------------------------#
#               Configure MariaDB/MySQL host               #
#----------------------------------------------------------#

if [ "$mysql" = 'yes' ] || [ "$mysql8" = 'yes' ]; then
	$HESTIA/bin/v-add-database-host mysql localhost root $mpass
fi

#----------------------------------------------------------#
#               Configure PostgreSQL host                  #
#----------------------------------------------------------#

if [ "$postgresql" = 'yes' ]; then
	$HESTIA/bin/v-add-database-host pgsql localhost postgres $ppass
fi

#----------------------------------------------------------#
#                    Install Roundcube                     #
#----------------------------------------------------------#

if ([ "$mysql" == 'yes' ] || [ "$mysql8" == 'yes' ]) && [ "$dovecot" == "yes" ]; then
	echo "[ * ] Installing Roundcube..."
	$HESTIA/bin/v-add-sys-roundcube
	write_config_value "WEBMAIL_ALIAS" "webmail"
else
	write_config_value "WEBMAIL_ALIAS" ""
	write_config_value "WEBMAIL_SYSTEM" ""
fi

#----------------------------------------------------------#
#                     Install Sieve                        #
#----------------------------------------------------------#

if [ "$sieve" = 'yes' ]; then
	echo "[ * ] Installing Sieve Mail Filter..."

	RC_INSTALL_DIR="/usr/local/www/roundcube"
	RC_CONFIG_DIR="/usr/local/etc/roundcube"

	# 修改 Dovecot 配置
	sed -i '' 's/^#mail_plugins = $mail_plugins/mail_plugins = $mail_plugins quota sieve/' /usr/local/etc/dovecot/conf.d/15-lda.conf
	sed -i '' 's/mail_plugins = quota imap_quota/mail_plugins = quota imap_quota imap_sieve/' /usr/local/etc/dovecot/conf.d/20-imap.conf

	cp -f $HESTIA_COMMON_DIR/dovecot/sieve/* /usr/local/etc/dovecot/conf.d/

	# 创建默认筛子规则
	mkdir -p /usr/local/etc/dovecot/sieve
	cat > /usr/local/etc/dovecot/sieve/default.sieve << 'EOF'
require ["fileinto"];
if header :contains "X-Spam-Flag" "YES" {
    fileinto "INBOX.Spam";
}
EOF
	sievec /usr/local/etc/dovecot/sieve/default.sieve

	if [ -d "$RC_INSTALL_DIR" ]; then
		mkdir -p $RC_CONFIG_DIR/plugins/managesieve
		cp -f $HESTIA_COMMON_DIR/roundcube/plugins/config_managesieve.inc.php $RC_CONFIG_DIR/plugins/managesieve/config.inc.php
		sed -i '' 's/"archive"/"archive", "managesieve"/' $RC_CONFIG_DIR/config.inc.php
	fi

	service_control restart dovecot
	service_control restart exim
fi

#----------------------------------------------------------#
#                       Configure API                      #
#----------------------------------------------------------#

if [ "$api" = 'yes' ]; then
	write_config_value "API" "yes"
	write_config_value "API_SYSTEM" "1"
	write_config_value "API_ALLOWED_IP" ""
	$HESTIA/bin/v-change-sys-api enable
else
	write_config_value "API" "no"
	write_config_value "API_SYSTEM" "0"
	write_config_value "API_ALLOWED_IP" ""
	$HESTIA/bin/v-change-sys-api disable
fi

#----------------------------------------------------------#
#              Configure Web terminal                      #
#----------------------------------------------------------#

if [ "$webterminal" = 'yes' ]; then
	write_config_value "WEB_TERMINAL" "true"
	service_control enable hestia-web-terminal
	service_control start hestia-web-terminal
else
	write_config_value "WEB_TERMINAL" "false"
fi

#----------------------------------------------------------#
#                  Configure File Manager                  #
#----------------------------------------------------------#

echo "[ * ] Configuring File Manager..."
$HESTIA/bin/v-add-sys-filemanager quiet

#----------------------------------------------------------#
#                  Configure dependencies                  #
#----------------------------------------------------------#

echo "[ * ] Installing PHP dependencies..."
if [ "$phpfpm" = 'yes' ]; then
	php_version=$(php -r 'echo PHP_MAJOR_VERSION . PHP_MINOR_VERSION;')
	pkg_install php${php_version}-curl php${php_version}-json \
	               php${php_version}-mbstring php${php_version}-session \
	               php${php_version}-xml php${php_version}-zip
fi

echo "[ * ] Installing Rclone & Restic ..."
pkg_install rclone restic

#----------------------------------------------------------#
#                   Configure IP                           #
#----------------------------------------------------------#

echo "[ * ] Configuring System IP..."
$HESTIA/bin/v-update-sys-ip > /dev/null 2>&1

# 获取默认网卡和 IP
default_nic=$(netstat -rn | grep '^default' | awk '{print $4}' | head -1)
primary_ipv4=$(ifconfig "$default_nic" 2>/dev/null | grep -E 'inet ' | grep -v '127.0.0.1' | awk '{print $2}' | head -1)
ip="$primary_ipv4"
local_ip="$primary_ipv4"

# 配置防火墙
if [ "$iptables" = 'yes' ]; then
	$HESTIA/bin/v-update-firewall
fi

# 获取公网 IP
pub_ipv4=$(curl -fsLm5 --retry 2 --ipv4 https://ip.hestiacp.com/ 2>/dev/null)
if [ -n "$pub_ipv4" ] && [ "$pub_ipv4" != "$ip" ]; then
	$HESTIA/bin/v-change-sys-ip-nat "$ip" "$pub_ipv4" > /dev/null 2>&1
	ip="$pub_ipv4"
fi

# 配置 libapache2-mod-remoteip
if [ "$apache" = 'yes' ] && [ "$nginx" = 'yes' ]; then
	cd /usr/local/etc/apache24/mods-available
	echo "<IfModule mod_remoteip.c>" > remoteip.conf
	echo "  RemoteIPHeader X-Real-IP" >> remoteip.conf
	if [ "$local_ip" != "127.0.0.1" ] && [ "$pub_ipv4" != "127.0.0.1" ]; then
		echo "  RemoteIPInternalProxy 127.0.0.1" >> remoteip.conf
	fi
	if [ -n "$local_ip" ] && [ "$local_ip" != "$pub_ipv4" ]; then
		echo "  RemoteIPInternalProxy $local_ip" >> remoteip.conf
	fi
	if [ -n "$pub_ipv4" ]; then
		echo "  RemoteIPInternalProxy $pub_ipv4" >> remoteip.conf
	fi
	echo "</IfModule>" >> remoteip.conf
	sed -i '' "s/LogFormat \"%h/LogFormat \"%a/g" /usr/local/etc/apache24/apache2.conf
	service_control restart apache24
fi

# 添加默认域名
$HESTIA/bin/v-add-web-domain "$username" "$servername" "$ip"
check_result $? "can't create $servername domain"

#----------------------------------------------------------#
#                    Configure Cron                        #
#----------------------------------------------------------#

echo "[ * ] Configuring cron jobs..."
CRON_TABS="/var/cron/tabs"
mkdir -p $CRON_TABS
min=$(gen_pass '012345' '2')
hour=$(gen_pass '1234567' '1')

cat > $CRON_TABS/hestiaweb << EOF
MAILTO=""
CONTENT_TYPE="text/plain; charset=utf-8"
*/2 * * * * /usr/local/hestia/bin/v-update-sys-queue restart
10 00 * * * /usr/local/hestia/bin/v-update-sys-queue daily
15 02 * * * /usr/local/hestia/bin/v-update-sys-queue disk
10 00 * * * /usr/local/hestia/bin/v-update-sys-queue traffic
30 03 * * * /usr/local/hestia/bin/v-update-sys-queue webstats
*/5 * * * * /usr/local/hestia/bin/v-update-sys-queue backup
10 05 * * * /usr/local/hestia/bin/v-backup-users
20 00 * * * /usr/local/hestia/bin/v-update-user-stats
*/5 * * * * /usr/local/hestia/bin/v-update-sys-rrd
$min $hour * * * /usr/local/hestia/bin/v-update-letsencrypt-ssl
41 4 * * * /usr/local/hestia/bin/v-update-sys-hestia-all
EOF

chmod 600 $CRON_TABS/hestiaweb
chown hestiaweb:wheel $CRON_TABS/hestiaweb

# 启用自动更新
$HESTIA/bin/v-add-cron-hestia-autoupdate pkg

echo "[ * ] Building initial RRD images..."
$HESTIA/bin/v-update-sys-rrd

# 启用磁盘配额
if [ "$quota" = 'yes' ]; then
	$HESTIA/bin/v-add-sys-quota
fi

# 设置后端端口
$HESTIA/bin/v-change-sys-port $port > /dev/null 2>&1

# 创建默认配置
$HESTIA/bin/v-update-sys-defaults

# Update remaining packages since repositories have changed
echo "[ * ] Installing remaining software updates..."
pkg upgrade -y >> $LOG 2>&1
check_result $? "pkg upgrade failed"

# 启动 Hestia 服务
sysrc hestia_enable=YES
service hestia start
check_result $? "hestia start failed"
chown hestiaweb:hestiaweb $HESTIA/data/sessions

# 创建备份目录
mkdir -p /backup/
chmod 755 /backup/

# Create cronjob to generate ssl
cat << 'EOF' >> /etc/crontab
@reboot root sleep 10 && sed -i '' '/v-add-letsencrypt-host/d' /etc/crontab && env PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' /usr/local/hestia/bin/v-add-letsencrypt-host
EOF

#----------------------------------------------------------#
#              Set hestia.conf default values              #
#----------------------------------------------------------#

echo "[ * ] Updating configuration files..."

BIN="$HESTIA/bin"
source $HESTIA/func/syshealth.sh
syshealth_repair_system_config

# 添加到 PATH
[ -f /root/.bashrc ] && echo 'if [ "${PATH#*/usr/local/hestia/bin*}" = "$PATH" ]; then
    . /etc/profile.d/hestia.sh
fi' >> /root/.bashrc

[ -f /root/.zshrc ] && echo 'if [ "${PATH#*/usr/local/hestia/bin*}" = "$PATH" ]; then
    . /etc/profile.d/hestia.sh
fi' >> /root/.zshrc

[ -f /root/.profile ] && echo 'if [ "${PATH#*/usr/local/hestia/bin*}" = "$PATH" ]; then
    . /etc/profile.d/hestia.sh
fi' >> /root/.profile

#----------------------------------------------------------#
#                   Hestia Access Info                     #
#----------------------------------------------------------#

# 比较主机名和 IP
host_ip=$(host $servername 2>/dev/null | head -n 1 | awk '{print $NF}')
if [ "$host_ip" = "$ip" ]; then
	ip="$servername"
fi

echo -e "\n"
echo "===================================================================="
echo -e "\n"

# 发送通知到管理员邮箱
echo -e "Congratulations!

You have successfully installed Hestia Control Panel on your FreeBSD server.

Ready to get started? Log in using the following credentials:

	Admin URL:  https://$servername:$port" > $tmpfile
if [ "$host_ip" != "$ip" ]; then
	echo "	Backup URL: https://$ip:$port" >> $tmpfile
fi
echo -e -n " 	Username:   $username
	Password:   $displaypass

Thank you for choosing Hestia Control Panel to power your full stack web server,
we hope that you enjoy using it as much as we do!

Please feel free to contact us at any time if you have any questions,
or if you encounter any bugs or problems:

Documentation:  https://docs.hestiacp.com/
Forum:          https://forum.hestiacp.com/
GitHub:         https://www.github.com/hestiacp/hestiacp

Note: Automatic updates are enabled by default. If you would like to disable them,
please log in and navigate to Server > Updates to turn them off.

Help support the Hestia Control Panel project by donating via PayPal:
https://www.hestiacp.com/donate

--
Sincerely yours,
The Hestia Control Panel development team

Made with love & pride by the open-source community around the world.
" >> $tmpfile

send_mail="$HESTIA/web/inc/mail-wrapper.php"
cat $tmpfile | $send_mail -s "Hestia Control Panel" $email 2>/dev/null

# 显示信息
echo
cat $tmpfile
rm -f $tmpfile

# 添加欢迎通知
$HESTIA/bin/v-add-user-notification "$username" 'Welcome to Hestia Control Panel!' '<p>You are now ready to begin adding <a href="/add/user/">user accounts</a> and <a href="/add/web/">domains</a>. For help and assistance, <a href="https://hestiacp.com/docs/" target="_blank">view the documentation</a> or <a href="https://forum.hestiacp.com/" target="_blank">visit our forum</a>.</p><p>Please <a href="https://github.com/hestiacp/hestiacp/issues" target="_blank">report any issues via GitHub</a>.</p><p class="u-text-bold">Have a wonderful day!</p><p><i class="fas fa-heart icon-red"></i> The Hestia Control Panel development team</p>'

# 排序配置文件
sort_config_file

if [ "$interactive" = 'yes' ]; then
	echo "[ ! ] IMPORTANT: The system will now reboot to complete the installation process."
	read -n 1 -s -r -p "Press any key to continue"
	reboot
else
	echo "[ ! ] IMPORTANT: You must restart the system before continuing!"
fi

# EOF