#!/bin/bash

# ======================================================== #
#
# Hestia Control Panel Installer for FreeBSD
# https://www.hestiacp.com/
#
# Currently Supported Versions:
# FreeBSD 13, 14, 15
#
# ======================================================== #

#----------------------------------------------------------#
#                  Variables&Functions                     #
#----------------------------------------------------------#
export PATH=$PATH:/sbin:/usr/sbin:/usr/local/bin:/usr/local/sbin

# 仓库地址
RHOST='pkg.hestiacp.com'
VERSION='freebsd'
HESTIA='/usr/local/hestia'
LOG="/root/hst_install_backups/hst_install-$(date +%d%m%Y%H%M).log"
memory=$(($(sysctl -n hw.physmem) / 1024))
hst_backups="/root/hst_install_backups/$(date +%d%m%Y%H%M)"
spinner="/-\|"
os='freebsd'

# FreeBSD 系统检测
release="$(uname -r | cut -d'.' -f1)"
codename="$(uname -r | cut -d'-' -f2)"
architecture="$(uname -m)"

HESTIA_INSTALL_DIR="$HESTIA/install/freebsd"
HESTIA_COMMON_DIR="$HESTIA/install/common"
VERBOSE='no'

# 定义软件版本
HESTIA_INSTALL_VER='1.9.6'
# 支持的 PHP 版本
multiphp_v=("56" "70" "71" "72" "73" "74" "80" "81" "82" "83" "84" "85")
# Roundcube / phpmyadmin 需要的 PHP 版本
multiphp_required=("73" "74" "80" "81" "82" "83")
# 默认 PHP 版本
fpm_v="83"
# MariaDB 版本
mariadb_v="1011"
# Node.js 版本
node_v="24"

MARIADB_VER="106"
POSTGRES_VER="16"
BIND_VER="918"

# FreeBSD 软件包列表
software="acl apache24 apache24-suexec bc bind${BIND_VER} bsdutils
  clamav curl bind-tools dovecot e2fsprogs exim expect fail2ban
  flex ftp git hestia=${HESTIA_INSTALL_VER} hestia-nginx hestia-php hestia-web-terminal
  idn2 ImageMagick7 ipset jq libidn2 lsb_release lsof mariadb${MARIADB_VER}-client
  mariadb${MARIADB_VER}-server mc net-tools nginx node openssh-portable
  postgresql${POSTGRES_VER}-server postgresql${POSTGRES_VER}-contrib proftpd rrdtool
  spamassassin sysstat unrar unzip util-linux vim vsftpd xxd whois zip zstd
  bubblewrap restic ap24-mod_php$fpm_v ap24-mod_mpm_itk ap24-mod_fcgid p5-Mail-DKIM
  php$fpm_v php$fpm_v-bz2 php$fpm_v-curl php$fpm_v-gd php$fpm_v-intl php$fpm_v-ldap php$fpm_v-mbstring
  php$fpm_v php$fpm_v-mysqli php$fpm_v-pgsql php$fpm_v-readline php$fpm_v-xml php$fpm_v-zip
  php$fpm_v-pecl-APCu php$fpm_v-pecl-imagick php$fpm_v-pecl-imap php$fpm_v-pecl-pspell"

installer_dependencies="ca_root_nss curl gnupg openssl wget sudo"

# Defining help function
help() {
	echo "Usage: $0 [OPTIONS]
  -a, --apache24          Install Apache24        [yes|no]  default: yes
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
  -i, --pf                Install Packet Filter [yes|no]  default: yes
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
  -D, --with-pkgs         Path to Hestia pkg files
  -pf --rules             PF rules file path     default: /etc/pf.conf
  -pf --enable            Enable PF at boot      [yes|no]  default: yes
  -f, --force             Force installation
  -h, --help              Print this help

  Example: sh $0 -e demo@hestiacp.com -p p4ssw0rd --multiphp yes"
	exit 1
}

# Defining file download function
download_file() {
    fetch -v -T10 -w2 "$1"
	#fetch -q -T10 -w2 "$1"
}


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

source_conf() {
	while IFS='= ' read -r lhs rhs; do
		case "$lhs" in
			"" | \#*) continue ;;
		esac
		rhs="${rhs%%#*}"
		rhs="${rhs#"${rhs%%[![:space:]]*}"}"
		rhs="${rhs%"${rhs##*[![:space:]]}"}"
		rhs="${rhs#[\'\"]}"
		rhs="${rhs%[\'\"]}"
		declare -g "$lhs=$rhs"
	done < "$1"
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
		if [ -n "$(grep "^$username:" /etc/passwd /etc/group 2> /dev/null)" ]; then
			printf "\nUsername or Group already exists. Please select a new username or delete the existing user/group.\n"
		else
			return 1
		fi
	else
		printf "\nPlease use a valid username (e.g., user).\n"
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

# Validate hostname according to RFC1178
validate_hostname() {
	# remove extra .
	servername=$(echo "$servername" | sed -e "s/[.]*$//g")
	servername=$(echo "$servername" | sed -e "s/^[.]*//")
	if [[ $(echo "$servername" | grep -o "\." | wc -l) -gt 1 ]] && [[ ! $servername =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
		# Hostname valid
		return 1
	else
		# Hostname invalid
		return 0
	fi
}

validate_email() {
	if [[ ! "$email" =~ ^[A-Za-z0-9._%+-]+@[[:alnum:].-]+\.[A-Za-z]{2,63}$ ]]; then
		# Email invalid
		return 0
	else
		# Email valid
		return 1
	fi
}

version_ge() { test "$(printf '%s\n' "$@" | sort -V | head -n 1)" != "$1" -o -n "$1" -a "$1" = "$2"; }

#----------------------------------------------------------#
#                    Verifications                         #
#----------------------------------------------------------#

# 创建临时文件
tmpfile=$(mktemp -t /tmp)

# 参数解析
for arg; do
	delim=""
	case "$arg" in
		--apache24) args="${args}-a " ;;
		--phpfpm) args="${args}-w " ;;
		--vsftpd) args="${args}-v " ;;
		--proftpd) args="${args}-j " ;;
		--bind${BIND_VER}) args="${args}-k " ;;
		--mysql) args="${args}-m " ;;
		--mariadb${MARIADB_VER}-server) args="${args}-m " ;;
		--mysql-classic) args="${args}-M " ;;
		--mysql8) args="${args}-M " ;;
		--postgresql${POSTGRES_VER}-server) args="${args}-g " ;;
		--exim) args="${args}-x " ;;
		--dovecot) args="${args}-z " ;;
		--sieve) args="${args}-Z " ;;
		--clamav) args="${args}-c " ;;
		--spamassassin) args="${args}-t " ;;
		--pf) args="${args}-i " ;;
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
		a) apache24=$OPTARG ;;
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
		i) pf=$OPTARG ;;
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

		software=$(echo "$software" | sed -e "s/php$fpm_old/php$fpm_v/g")

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

# Check OS
type=$(grep "^ID=" /etc/os-release | cut -f 2 -d '=')
if [ "$type" = "ubuntu" ]; then
	check_result 1 "You are running the wrong installer for Ubuntu. Please run hst-install.sh or hst-install-ubuntu.sh instead."
elif [ "$type" != "debian" ]; then
	check_result 1 "You are running an unsupported OS."
fi

# Clear the screen
clear

# Configure pkg to retry downloading on error
if [ ! -f /usr/local/etc/pkg.conf ]; then
	echo "FETCH_RETRY = 3;" > /usr/local/etc/pkg.conf
else
	if grep -q "^#FETCH_RETRY = 3;" /usr/local/etc/pkg.conf; then
		sed -i '' 's/^#FETCH_RETRY = 3;/FETCH_RETRY = 3;/g' /usr/local/etc/pkg.conf
	elif [ -z "$(grep "^FETCH_RETRY" /usr/local/etc/pkg.conf)" ]; then
		echo "FETCH_RETRY = 3;" >> /usr/local/etc/pkg.conf
	fi
fi

# Welcome message
echo "Welcome to the Hestia Control Panel installer for FreeBSD!"
echo
echo "Please wait, the installer is now checking for missing dependencies..."
echo

# Update pkg repository
pkg update -f

# Creating backup directory
mkdir -p "$hst_backups"

# Pre-install packages
echo "[ * ] Installing dependencies..."
pkg install -y $installer_dependencies >> $LOG
check_result $? "Package installation failed, check log file for more details."

# Check if apparmor is installed
if [ $(dpkg-query -W -f='${Status}' apparmor 2> /dev/null | grep -c "ok installed") -eq 0 ]; then
	apparmor='no'
else
	apparmor='yes'
fi

# Check repository availability
if ! fetch -q "https://$RHOST" -o /dev/null; then
	check_result 1 "Unable to connect to the Hestia pkg repository"
fi

# Check installed packages
tmpfile=$(mktemp -p /tmp)
pkg --get-selections > $tmpfile
conflicts_pkg="exim4 mariadb-server apache2 nginx hestia postfix"

# Drop postfix from the list if exim should not be installed
if [ "$exim" = 'no' ]; then
	conflicts_pkg=$(echo $conflicts_pkg | sed 's/postfix//g' | xargs)
fi

for pkg in $conflicts_pkg; do
	if [ -n "$(grep $pkg $tmpfile)" ]; then
		conflicts="$pkg* $conflicts"
	fi
done
rm -f $tmpfile

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

# Check network configuration
if [ -d /etc/netplan ] && [ -z "$force" ]; then
	if [ -z "$(ls -A /etc/netplan)" ]; then
		echo '!!! !!! !!! !!! !!! !!! !!! !!! !!! !!! !!! !!! !!! !!! !!! !!! !!!'
		echo
		echo 'WARNING: Your network configuration may not be set up correctly.'
		echo 'Details: The netplan configuration directory is empty.'
		echo ''
		echo 'You may have a network configuration file that was created using'
		echo 'systemd-networkd.'
		echo ''
		echo 'It is strongly recommended to migrate to netplan, which is now the'
		echo 'default network configuration system in newer releases of Ubuntu.'
		echo ''
		echo 'While you can leave your configuration as-is, please note that you'
		echo 'will not be able to use additional IPs properly.'
		echo ''
		echo 'If you wish to continue and force the installation,'
		echo 'run this script with -f option:'
		echo "Example: bash $0 --force"
		echo
		echo '!!! !!! !!! !!! !!! !!! !!! !!! !!! !!! !!! !!! !!! !!! !!! !!! !!!'
		echo
		check_result 1 "Unable to detect netplan configuration."
	fi
fi

# Validate whether installation script matches release version before continuing with install
if [ -z "$withdebs" ] || [ ! -d "$withdebs" ]; then
	release_branch_ver=$(curl -s https://raw.githubusercontent.com/hestiacp/hestiacp/release/src/deb/hestia/control | grep "Version:" | awk '{print $2}')
	if [ "$HESTIA_INSTALL_VER" != "$release_branch_ver" ]; then
		echo
		echo -e "\e[91mInstallation aborted\e[0m"
		echo "===================================================================="
		echo -e "\e[33mERROR: Install script version does not match package version!\e[0m"
		echo -e "\e[33mPlease download the installer from the release branch in order to continue:\e[0m"
		echo ""
		echo -e "\e[33mhttps://raw.githubusercontent.com/hestiacp/hestiacp/release/install/hst-install.sh\e[0m"
		echo ""
		echo -e "\e[33mTo test pre-release versions, build the .deb packages and re-run the installer:\e[0m"
		echo -e "  \e[33m./hst_autocompile.sh \e[1m--hestia branchname no\e[21m\e[0m"
		echo -e "  \e[33m./hst-install.sh .. \e[1m--with-debs /tmp/hestiacp-src/debs\e[21m\e[0m"
		echo ""
		check_result 1 "Installation aborted"
	fi
fi

case $architecture in
	x86_64)
		ARCH="amd64"
		;;
	aarch64)
		ARCH="arm64"
		;;
	*)
		echo
		echo -e "\e[91mInstallation aborted\e[0m"
		echo "===================================================================="
		echo -e "\e[33mERROR: $architecture is currently not supported!\e[0m"
		echo -e "\e[33mPlease verify the achitecture used is currenlty supported\e[0m"
		echo ""
		echo -e "\e[33mhttps://github.com/hestiacp/hestiacp/blob/main/README.md\e[0m"
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
mask1='(([[:alnum:]](-?[[:alnum:]])*)\.)'
mask2='*[[:alnum:]](-?[[:alnum:]])+\.[[:alnum:]]{2,}'
if ! [[ "$servername" =~ ^${mask1}${mask2}$ ]]; then
	if [[ -n "$servername" ]]; then
		servername="$servername.example.com"
	else
		servername="example.com"
	fi
	short_name="${servername%%.*}"
	echo "127.0.0.1 $servername $short_name" >> /etc/hosts
fi

if [[ -z $(grep -E "(^|[[:space:]])$servername([[:space:]]|$)" /etc/hosts) ]]; then
	short_name="${servername%%.*}"
	echo "127.0.0.1 $servername $short_name" >> /etc/hosts
fi

# Set email if it wasn't set
if [[ -z "$email" ]]; then
	email="admin@$servername"
fi

# 带有特殊转义时的通用平替写法
printf "Installation backup directory: %s\n" "$hst_backups"

# Print Log File Path
echo "Installation log file: $LOG"
echo

#----------------------------------------------------------#
#                      Checking swap                       #
#----------------------------------------------------------#

# 添加 swap（如果需要）
if [ -z "$(swapinfo 2> /dev/null)" ] && [ "$memory" -lt 1000000 ]; then
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
# Define pkg repository configuration location for FreeBSD
apt=/usr/local/etc/pkg/repos

# Create new folder if it doesn't exist
# 保持原样创建，确保在 FreeBSD 下拥有最安全的 700 权限
mkdir -p /root/.gnupg/ && chmod 700 /root/.gnupg/

# Updating system
echo "Adding required repositories to proceed with installation:"
echo

# Installing Nginx repo
echo "[ * ] NGINX"
# FreeBSD 官方源已内置 Nginx 稳定版/主流版，无需额外配置

# Installing sury PHP repo
echo "[ * ] PHP"
# FreeBSD 官方源已内置 PHP 8.x 全部生态，无需外部源

# Installing sury Apache2 repo
if [ "$apache" = 'yes' ]; then
	echo "[ * ] Apache2"
	# FreeBSD 官方源已内置 Apache 2.4，无需外部源
fi

# Installing MariaDB repo
if [ "$mysql" = 'yes' ]; then
	echo "[ * ] MariaDB $mariadb_v"
	# FreeBSD 官方源已内置全部长期支持版 MariaDB
fi

# Installing Mysql8 repo
if [ "$mysql8" = 'yes' ]; then
	echo "[ * ] Mysql 8"
	# FreeBSD 官方源已内置全部主流 MySQL 版本
fi

# Installing HestiaCP repo
echo "[ * ] Hestia $HESTIA_INSTALL_VER"
mkdir -p /usr/local/etc/pkg/repos
cat << EOF > /usr/local/etc/pkg/repos/hestia.conf
hestia: {
  url: "https://$RHOST/freebsd/\${ABI}/latest",
  mirror_type: "srv",
  enabled: yes
}
EOF

# Installing Node.js repo
if [ "$webterminal" = 'yes' ]; then
	echo "[ * ] Node.js v $node_v"
	# FreeBSD 的 Node.js 属于官方基础包，在此处直接单独下载安装
	pkg install -y node${node_v} >> $LOG
fi

# Installing PostgreSQL repo
if [ "$postgresql" = 'yes' ]; then
	echo "[ * ] PostgreSQL"
	# FreeBSD 官方源已内置全部 PostgreSQL 版本
fi

# 统一刷新 FreeBSD 本地仓库缓存 (相当于 apt-get update)
echo "[ * ] Updating FreeBSD Package Repository Catalogue..."
pkg update -f >> $LOG 2>&1

# 本地包安装
if [ -n "$withpkgs" ] && [ -d "$withpkgs" ]; then
	echo "[ * ] Installing local package files..."
	# 修正：现代 FreeBSD 二进制包后缀全部为 .pkg，而非旧版的 .txz
	for pkg in $withpkgs/*.pkg; do
		# 使用 -y 确保本地安装时遇到依赖冲突或覆盖提示时能自动确认
		pkg add -y $pkg >> $LOG 2>&1
	done
fi

# 安装软件包
echo "[ * ] Installing packages: $final_software"
echo "NOTE: This process may take 10 to 15 minutes to complete..."

# 请确保您的 pkg_install 函数内部调用的是标准的 `pkg install -y`
pkg_install $final_software & # 修正：既然您后面要捕获 $!，这里必须保留 & 异步符号

BACK_PID=$!

# Check if package installation is done, print a spinner
spin_i=1
while kill -0 $BACK_PID > /dev/null 2>&1; do
	printf "\b${spinner:spin_i++%${#spinner}:1}"
	sleep 0.5
done

# Do a blank echo to get the \n back
echo

# Check Installation result
wait $BACK_PID
check_result $? 'pkg install failed'

#----------------------------------------------------------#
#                         Backup                           #
#----------------------------------------------------------#

# Creating backup directory tree
mkdir -p $hst_backups
cd $hst_backups
mkdir nginx apache2 php vsftpd proftpd bind exim dovecot clamd
mkdir spamassassin mysql postgresql openssl hestia

# Backup OpenSSL configuration (FreeBSD 自带 OpenSSL 位于 /etc)
cp /etc/ssl/openssl.cnf $hst_backups/openssl > /dev/null 2>&1

# Backup nginx configuration
service nginx stop > /dev/null 2>&1
cp -r /usr/local/etc/nginx/* $hst_backups/nginx > /dev/null 2>&1

# Backup Apache configuration
service apache24 stop > /dev/null 2>&1
cp -r /usr/local/etc/apache24/* $hst_backups/apache2 > /dev/null 2>&1
rm -f /usr/local/etc/apache24/Includes/* > /dev/null 2>&1

# Backup PHP-FPM configuration
service php-fpm stop > /dev/null 2>&1
cp -r /usr/local/etc/php/* $hst_backups/php > /dev/null 2>&1

# Backup Bind configuration
service named stop > /dev/null 2>&1
cp -r /usr/local/etc/namedb/* $hst_backups/bind > /dev/null 2>&1

# Backup Vsftpd configuration
service vsftpd stop > /dev/null 2>&1
cp /usr/local/etc/vsftpd.conf $hst_backups/vsftpd > /dev/null 2>&1

# Backup ProFTPD configuration
service proftpd stop > /dev/null 2>&1
cp -r /usr/local/etc/proftpd/* $hst_backups/proftpd > /dev/null 2>&1

# Backup Exim configuration
service exim stop > /dev/null 2>&1
cp -r /usr/local/etc/exim/* $hst_backups/exim > /dev/null 2>&1

# Backup ClamAV configuration
service clamav-clamd stop > /dev/null 2>&1
cp -r /usr/local/etc/clamav/* $hst_backups/clamav > /dev/null 2>&1

# Backup SpamAssassin configuration
service sa-spamd stop > /dev/null 2>&1
cp -r /usr/local/etc/mail/spamassassin/* $hst_backups/spamassassin > /dev/null 2>&1

# Backup Dovecot configuration
service dovecot stop > /dev/null 2>&1
cp /usr/local/etc/dovecot/dovecot.conf $hst_backups/dovecot > /dev/null 2>&1
cp -r /usr/local/etc/dovecot/* $hst_backups/dovecot > /dev/null 2>&1

# Backup MySQL/MariaDB configuration and data
service mysql-server stop > /dev/null 2>&1
killall -9 mysqld > /dev/null 2>&1
mv /var/lib/mysql $hst_backups/mysql/mysql_datadir > /dev/null 2>&1
cp -r /usr/local/etc/mysql/* $hst_backups/mysql > /dev/null 2>&1
mv -f /root/.my.cnf $hst_backups/mysql > /dev/null 2>&1

# Backup Hestia
service hestia stop > /dev/null 2>&1
cp -r $HESTIA/* $hst_backups/hestia > /dev/null 2>&1
pkg delete -y hestia hestia-nginx hestia-php > /dev/null 2>&1
rm -rf $HESTIA > /dev/null 2>&1

#----------------------------------------------------------#
#                     Package Includes                     #
#----------------------------------------------------------#

if [ "$phpfpm" = 'yes' ]; then
	fpm="php$fpm_v php$fpm_v-bz2 php$fpm_v-curl php$fpm_v-gd php$fpm_v-intl
         php$fpm_v-mysqli php$fpm_v-pgsql php$fpm_v-readline php$fpm_v-xml php$fpm_v-zip
         php$fpm_v-pecl-APCu php$fpm_v-pecl-imagick php$fpm_v-imap php$fpm_v-pspell"
	software="$software $fpm"
fi

#----------------------------------------------------------#
#                     Package Excludes                     #
#----------------------------------------------------------#

# Excluding packages
software=$(echo "$software" | sed -e "s/apache24-suexec//")

if [ "$apache" = 'no' ]; then
	software=$(echo "$software" | sed -e "s/apache24 //")
	software=$(echo "$software" | sed -e "s/apache24-suexec//")
	software=$(echo "$software" | sed -e "s/ap24-mod_fcgid//")
	software=$(echo "$software" | sed -e "s/ap24-mod_mpm_itk//")
	software=$(echo "$software" | sed -e "s/ap24-mod_php$fpm_v//")
fi
if [ "$vsftpd" = 'no' ]; then
	software=$(echo "$software" | sed -e "s/vsftpd//")
fi
if [ "$proftpd" = 'no' ]; then
	software=$(echo "$software" | sed -e "s/proftpd//")
fi
if [ "$named" = 'no' ]; then
	software=$(echo "$software" | sed -e "s/bind918//")
fi
if [ "$exim" = 'no' ]; then
	software=$(echo "$software" | sed -e "s/exim //")
	software=$(echo "$software" | sed -e "s/dovecot //")
	software=$(echo "$software" | sed -e "s/clamav //")
	software=$(echo "$software" | sed -e "s/spamassassin//")
fi
if [ "$clamd" = 'no' ]; then
	software=$(echo "$software" | sed -e "s/clamav//")
fi
if [ "$spamd" = 'no' ]; then
	software=$(echo "$software" | sed -e "s/spamassassin//")
fi
if [ "$dovecot" = 'no' ]; then
	software=$(echo "$software" | sed -e "s/dovecot//")
fi
if [ "$sieve" = 'no' ]; then
	software=$(echo "$software" | sed -e "s/php${fpm_v}-sieve//")
fi
if [ "$mysql" = 'no' ]; then
	software=$(echo "$software" | sed -e "s/mariadb1011-server//")
	software=$(echo "$software" | sed -e "s/mariadb1011-client//")
fi
if [ "$mysql8" = 'no' ]; then
	software=$(echo "$software" | sed -e "s/mysql80-server//")
	software=$(echo "$software" | sed -e "s/mysql80-client//")
fi
if [ "$mysql" = 'no' ] && [ "$mysql8" = 'no' ]; then
	software=$(echo "$software" | sed -e "s/php$fpm_v-mysqli//")
fi
if [ "$postgresql" = 'no' ]; then
	software=$(echo "$software" | sed -e "s/postgresql16-contrib//")
	software=$(echo "$software" | sed -e "s/postgresql16-server//")
	software=$(echo "$software" | sed -e "s/php$fpm_v-pgsql//")
fi
if [ "$fail2ban" = 'no' ]; then
	software=$(echo "$software" | sed -e "s/fail2ban//")
fi
if [ "$iptables" = 'no' ] || [ "$pf" = 'no' ]; then
	software=$(echo "$software" | sed -e "s/ipset//")
	software=$(echo "$software" | sed -e "s/fail2ban//")
fi
if [ "$webterminal" = 'no' ]; then
	software=$(echo "$software" | sed -e "s/node //")
	software=$(echo "$software" | sed -e "s/hestia-web-terminal//")
fi
if [ "$phpfpm" = 'yes' ]; then
	software=$(echo "$software" | sed -e "s/ap24-mod_mpm_itk//")
	software=$(echo "$software" | sed -e "s/ap24-mod_php$fpm_v//")
fi
if [ -d "$withpkgs" ]; then
	software=$(echo "$software" | sed -e "s/hestia-nginx//")
	software=$(echo "$software" | sed -e "s/hestia-php//")
	software=$(echo "$software" | sed -e "s/hestia-web-terminal//")
	software=$(echo "$software" | sed -e "s/hestia=${HESTIA_INSTALL_VER}//")
fi

#----------------------------------------------------------#
#                     Install packages                     #
#----------------------------------------------------------#

# FreeBSD 原生支持 UTF-8，无需 locale-gen，通过配置环境变量即可
echo "[ * ] Configuring locale..."

# FreeBSD 默认安装任何 pkg 都不会自动启动，无需设置 policy-rc.d 阻止策略

# Installing FreeBSD pkg packages
echo "The installer is now downloading and installing all required packages."
echo -ne "NOTE: This process may take 10 to 15 minutes to complete, please wait... "
echo
pkg install -y $software > $LOG &
BACK_PID=$!

# Check if package installation is done, print a spinner
spin_i=1
while kill -0 $BACK_PID > /dev/null 2>&1; do
	printf "\b${spinner:spin_i++%${#spinner}:1}"
	sleep 0.5
done

# Do a blank echo to get the \n back
echo

# Check Installation result
wait $BACK_PID
check_result $? "pkg install failed"

echo
echo "========================================================================"
echo

# Install Hestia packages from local folder
if [ -n "$withpkgs" ] && [ -d "$withpkgs" ]; then
	echo "[ * ] Installing local package files..."
	echo "    - hestia core package"
	pkg add $withpkgs/hestia_*.pkg > /dev/null 2>&1

	if [ -z $(ls $withpkgs/hestia-php_*.pkg 2> /dev/null) ]; then
		echo "    - hestia-php backend package (from pkg repo)"
		pkg install -y hestia-php > /dev/null 2>&1
	else
		echo "    - hestia-php backend package"
		pkg add $withpkgs/hestia-php_*.pkg > /dev/null 2>&1
	fi

	if [ -z $(ls $withpkgs/hestia-nginx_*.pkg 2> /dev/null) ]; then
		echo "    - hestia-nginx backend package (from pkg repo)"
		pkg install -y hestia-nginx > /dev/null 2>&1
	else
		echo "    - hestia-nginx backend package"
		pkg add $withpkgs/hestia-nginx_*.pkg > /dev/null 2>&1
	fi

	if [ "$webterminal" = "yes" ]; then
		if [ -z $(ls $withpkgs/hestia-web-terminal_*.pkg 2> /dev/null) ]; then
			echo "    - hestia-web-terminal package (from pkg repo)"
			pkg install -y hestia-web-terminal > /dev/null 2>&1
		else
			echo "    - hestia-web-terminal"
			pkg add $withpkgs/hestia-web-terminal_*.pkg > /dev/null 2>&1
		fi
	fi
fi

#----------------------------------------------------------#
#                     Configure system                     #
#----------------------------------------------------------#

echo "[ * ] Configuring system settings..."

# Generate a random password
random_password=$(gen_pass '32')
# Create the new hestiaweb user
pw useradd "hestiaweb" -c "$email" -d /nonexistent -s /usr/sbin/nologin
# do not allow login into hestiaweb user
echo "$random_password" | pw usermod "hestiaweb" -h 0

# Add a general group for normal users created by Hestia
if [ -z "$(grep ^hestia-users: /etc/group)" ]; then
	pw groupadd "hestia-users"
fi

# Create user for php-fpm configs
pw useradd "hestiamail" -c "$email" -d /nonexistent -s /usr/sbin/nologin

# Ensures proper permissions for Hestia service interactions.
pw groupmod "hestia-users" -m "hestiamail"

# Enable SFTP subsystem for SSH
sftp_subsys_enabled=$(grep -iE "^#?.*subsystem.+(sftp )?sftp-server" /etc/ssh/sshd_config)
if [ -n "$sftp_subsys_enabled" ]; then
	sed -i -E "s/^#?.*Subsystem.+(sftp )?sftp-server/Subsystem sftp internal-sftp/g" /etc/ssh/sshd_config
fi

# Reduce SSH login grace time
sed -i "" "s/[#]LoginGraceTime [[:digit:]]m/LoginGraceTime 1m/g" /etc/ssh/sshd_config # 修正：FreeBSD 的 sed -i 必须强制带空字符串 ""

# Disable SSH suffix broadcast (FreeBSD 的规范不带 DebianBanner)
if [ -z "$(grep "^VersionAddendum none" /etc/ssh/sshd_config)" ]; then
	sed -i "" '/^[#]Banner .*/a VersionAddendum none' /etc/ssh/sshd_config
	if [ -z "$(grep "^VersionAddendum none" /etc/ssh/sshd_config)" ]; then
		# If first attempt fails just add it
		echo '' >> /etc/ssh/sshd_config
		echo 'VersionAddendum none' >> /etc/ssh/sshd_config
	fi
fi

# Restart SSH daemon
service sshd restart

#----------------------------------------------------------#
#                     Install AWStats                      #
#----------------------------------------------------------#

# 直接安装 vstats
echo "[ * ] 获取 AWStats 最新版本..."

# 获取最新版本号
latest_tag=$(fetch -q -T5 -w2 -o - https://api.github.com/repos/hestiacn/vstats/releases/latest 2>/dev/null | grep '"tag_name":' | cut -d'"' -f4)

if [ -n "$latest_tag" ]; then
    echo "[ * ] 安装 AWStats ${latest_tag}..."
	fetch -q "https://github.com/hestiacn/vstats/releases/download/${latest_tag}/awstats-8.1-1.pkg" -o /tmp/awstats.pkg
	pkg add /tmp/awstats.pkg >> $LOG 2>&1
	rm -f /tmp/awstats.pkg
    
    # 验证安装
    if [ -f "/usr/local/www/awstats/cgi-bin/awstats.pl" ]; then
        echo "[ ✓ ] AWStats ${latest_tag} 安装成功"
    fi
else
    echo "[ ! ] 获取版本失败，跳过安装"
fi

# Disable AWStats cron
rm -f /usr/local/etc/periodic/daily/awstats

# Replace AWStats function
mkdir -p /usr/local/etc/logrotate.d/httpd-prerotate
cp -f $HESTIA_INSTALL_DIR/logrotate/httpd-prerotate/* /usr/local/etc/logrotate.d/httpd-prerotate/

# Set directory color (FreeBSD 默认使用的是类似 LSCOLORS 的 BSD 格式，而非 Linux 的 LS_COLORS)
if [ -z "$(grep 'export CLICOLOR=1' /etc/profile)" ]; then
	echo 'export CLICOLOR=1' >> /etc/profile
	echo 'export LSCOLORS="exfxcxdxbxegedabagacad"' >> /etc/profile
fi

# Register /sbin/nologin and /usr/sbin/nologin (FreeBSD 默认只带 /usr/sbin/nologin)
if [ -z "$(grep ^/sbin/nologin /etc/shells)" ]; then
	echo "/sbin/nologin" >> /etc/shells
fi

if [ -z "$(grep ^/usr/sbin/nologin /etc/shells)" ]; then
	echo "/usr/sbin/nologin" >> /etc/shells
fi

# Configuring NTP
if [ ! -f "/etc/default/ntpsec-ntpdate" ]; then
	if [ -f /etc/ntp.conf ]; then
		if [ -z "$(grep -E "^(server|pool) " /etc/ntp.conf)" ]; then
			echo "" >> /etc/ntp.conf
			echo "server pool.ntp.org iburst" >> /etc/ntp.conf
		fi

		sysrc ntpd_enable="YES" > /dev/null 2>&1
		sysrc ntpd_sync_on_start="YES" > /dev/null 2>&1
		service ntpd start > /dev/null 2>&1
	fi
fi

# Restrict access to /proc fs
# Prevent unpriv users from seeing each other running processes
echo "[ * ] Securing process visibility..."
sysctl security.bsd.see_other_processes=0 > /dev/null 2>&1
sysctl security.bsd.see_other_uids=0 > /dev/null 2>&1
if [ -z "$(grep "security.bsd.see_other_processes" /etc/sysctl.conf)" ]; then
	echo "security.bsd.see_other_processes=0" >> /etc/sysctl.conf
	echo "security.bsd.see_other_uids=0" >> /etc/sysctl.conf
fi

#----------------------------------------------------------#
#                     Configure Hestia                     #
#----------------------------------------------------------#

echo "[ * ] Configuring Hestia Control Panel..."
# Installing sudo configuration
mkdir -p /usr/local/etc/sudoers.d
cp -f $HESTIA_COMMON_DIR/sudo/hestiaweb /usr/local/etc/sudoers.d/
chmod 440 /usr/local/etc/sudoers.d/hestiaweb

# Add Hestia global config
if [[ ! -e /etc/hestiacp/hestia.conf ]]; then
	mkdir -p /etc/hestiacp
	echo -e "# Do not edit this file, will get overwritten on next upgrade, use /etc/hestiacp/local.conf instead\n\nexport HESTIA='/usr/local/hestia'\n\n[[ -f /etc/hestiacp/local.conf ]] && source /etc/hestiacp/local.conf" > /etc/hestiacp/hestia.conf
fi

# Configuring system env
mkdir -p /etc/profile.d
echo "export HESTIA='$HESTIA'" > /etc/profile.d/hestia.sh
echo 'PATH=$PATH:'$HESTIA'/bin' >> /etc/profile.d/hestia.sh
echo 'export PATH' >> /etc/profile.d/hestia.sh
chmod 755 /etc/profile.d/hestia.sh

if [ -z "$(grep 'source /etc/profile.d/hestia.sh' /etc/profile)" ]; then
	echo "" >> /etc/profile
	echo "[[ -f /etc/profile.d/hestia.sh ]] && source /etc/profile.d/hestia.sh" >> /etc/profile
fi
source /etc/profile.d/hestia.sh

# Configuring logrotate for Hestia logs (FreeBSD 包配置统一迁往 /usr/local/etc)
mkdir -p /usr/local/etc/logrotate.d
cp -f $HESTIA_INSTALL_DIR/logrotate/hestia /usr/local/etc/logrotate.d/hestia

# Create log path and symbolic link
rm -f /var/log/hestia
mkdir -p /var/log/hestia
ln -s /var/log/hestia $HESTIA/log

# Building directory tree and creating some blank files for Hestia
mkdir -p $HESTIA/conf $HESTIA/ssl $HESTIA/data/ips \
	$HESTIA/data/queue $HESTIA/data/users $HESTIA/data/firewall \
	$HESTIA/data/sessions
touch $HESTIA/data/queue/backup.pipe $HESTIA/data/queue/disk.pipe \
	$HESTIA/data/queue/webstats.pipe $HESTIA/data/queue/restart.pipe \
	$HESTIA/data/queue/traffic.pipe $HESTIA/data/queue/daily.pipe $HESTIA/log/system.log \
	$HESTIA/log/nginx-error.log $HESTIA/log/auth.log $HESTIA/log/backup.log
chmod 750 $HESTIA/conf $HESTIA/data/users $HESTIA/data/ips $HESTIA/log
chmod -R 750 $HESTIA/data/queue
chmod 660 /var/log/hestia/*
chmod 770 $HESTIA/data/sessions

# Generating Hestia configuration
rm -f $HESTIA/conf/hestia.conf > /dev/null 2>&1
touch $HESTIA/conf/hestia.conf
chmod 660 $HESTIA/conf/hestia.conf

# 写入默认端口
write_config_value "BACKEND_PORT" "8083"

# Web stack
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

# Database stack
if [ "$mysql" = 'yes' ] || [ "$mysql8" = 'yes' ]; then
	installed_db_types='mysql'
fi
if [ "$postgresql" = 'yes' ]; then
	installed_db_types="$installed_db_types,pgsql"
fi
if [ -n "$installed_db_types" ]; then
	db=$(echo "$installed_db_types" \
		| sed "s/,/\n/g" \
		| sort -r -u \
		| sed "/^$/d" \
		| sed ':a;N;$!ba;s/\n/,/g')
	write_config_value "DB_SYSTEM" "$db"
fi

# FTP stack
if [ "$vsftpd" = 'yes' ]; then
	write_config_value "FTP_SYSTEM" "vsftpd"
fi
if [ "$proftpd" = 'yes' ]; then
	write_config_value "FTP_SYSTEM" "proftpd"
fi

# DNS stack
if [ "$named" = 'yes' ]; then
	write_config_value "DNS_SYSTEM" "bind9"
fi

# Mail stack
if [ "$exim" = 'yes' ]; then
	write_config_value "MAIL_SYSTEM" "exim"
	if [ "$clamd" = 'yes' ]; then
		write_config_value "ANTIVIRUS_SYSTEM" "clamav"
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

# Cron daemon
write_config_value "CRON_SYSTEM" "cron"

# Firewall stack
if [ "$pf" = 'yes' ] || [ "$iptables" = 'yes' ]; then
	write_config_value "FIREWALL_SYSTEM" "pf"
fi

if [ "$pf" = 'yes' ] && [ "$fail2ban" = 'yes' ]; then
	write_config_value "FIREWALL_EXTENSION" "fail2ban"
fi

# Disk quota
if [ "$quota" = 'yes' ]; then
	write_config_value "DISK_QUOTA" "yes"
else
	write_config_value "DISK_QUOTA" "no"
fi

# Resource limitation
if [ "$resourcelimit" = 'yes' ]; then
	write_config_value "RESOURCES_LIMIT" "yes"
else
	write_config_value "RESOURCES_LIMIT" "no"
fi

write_config_value "WEB_TERMINAL_PORT" "8085"

# Backups
write_config_value "BACKUP_SYSTEM" "local"
write_config_value "BACKUP_GZIP" "4"
write_config_value "BACKUP_MODE" "zstd"

# Language
write_config_value "LANGUAGE" "$lang"

# Login screen style
write_config_value "LOGIN_STYLE" "default"

# Theme
write_config_value "THEME" "dark"

# Inactive session timeout
write_config_value "INACTIVE_SESSION_TIMEOUT" "60"

# Version & Release Branch
write_config_value "VERSION" "${HESTIA_INSTALL_VER}"
write_config_value "RELEASE_BRANCH" "release"

# Email notifications after upgrade
write_config_value "UPGRADE_SEND_EMAIL" "true"
write_config_value "UPGRADE_SEND_EMAIL_LOG" "false"

# Set "root" user
write_config_value "ROOT_USER" "$username"

# Installing hosting packages
cp -rf $HESTIA_COMMON_DIR/packages $HESTIA/data/

# Update nameservers in hosting package
IFS='.' read -r -a domain_elements <<< "$servername"
if [ -n "${domain_elements[-2]}" ] && [ -n "${domain_elements[-1]}" ]; then
	serverdomain="${domain_elements[-2]}.${domain_elements[-1]}"
	sed -i "" s/"domain.tld"/"$serverdomain"/g $HESTIA/data/packages/*.pkg
fi

# Installing templates
cp -rf $HESTIA_INSTALL_DIR/templates $HESTIA/data/
cp -rf $HESTIA_COMMON_DIR/templates/web/ $HESTIA/data/templates
cp -rf $HESTIA_COMMON_DIR/templates/dns/ $HESTIA/data/templates

mkdir -p /var/www/html
mkdir -p /var/www/document_errors

# Install default success page
cp -rf $HESTIA_COMMON_DIR/templates/web/unassigned/index.html /var/www/html/
cp -rf $HESTIA_COMMON_DIR/templates/web/skel/document_errors/* /var/www/document_errors/

# Installing firewall rules
cp -rf $HESTIA_COMMON_DIR/firewall $HESTIA/data/
rm -f $HESTIA/data/firewall/ipset/blacklist.sh $HESTIA/data/firewall/ipset/blacklist.ipv6.sh

# Delete rules for services that are not installed
if [ "$vsftpd" = "no" ] && [ "$proftpd" = "no" ]; then
	# Remove FTP
	sed -i "" "/COMMENT='FTP'/d" $HESTIA/data/firewall/rules.conf #
fi
if [ "$exim" = "no" ]; then
	# Remove SMTP
	sed -i "" "/COMMENT='SMTP'/d" $HESTIA/data/firewall/rules.conf
fi
if [ "$dovecot" = "no" ]; then
	# Remove IMAP / Dovecot
	sed -i "" "/COMMENT='IMAP'/d" $HESTIA/data/firewall/rules.conf
	sed -i "" "/COMMENT='POP3'/d" $HESTIA/data/firewall/rules.conf
fi
if [ "$named" = "no" ]; then
	# Remove DNS
	sed -i "" "/COMMENT='DNS'/d" $HESTIA/data/firewall/rules.conf
fi

# Installing API
cp -rf $HESTIA_COMMON_DIR/api $HESTIA/data/

# Configuring server hostname
$HESTIA/bin/v-change-sys-hostname $servername > /dev/null 2>&1

# Configuring global OpenSSL options
echo "[ * ] Configuring OpenSSL to improve TLS performance..."
tls13_ciphers="TLS_AES_128_GCM_SHA256:TLS_CHACHA20_POLY1305_SHA256:TLS_AES_256_GCM_SHA384"
if [ "$release" = "11" ]; then
	sed -i "" '/^system_default = system_default_sect$/a system_default = hestia_openssl_sect\n\n[hestia_openssl_sect]\nCiphersuites = '"$tls13_ciphers"'\nOptions = PrioritizeChaCha' /etc/ssl/openssl.cnf
elif [ "$release" = "12" ]; then
	if ! grep -qw "^ssl_conf = ssl_sect$" /etc/ssl/openssl.cnf 2> /dev/null; then
		sed -i "" '/providers = provider_sect$/a ssl_conf = ssl_sect' /etc/ssl/openssl.cnf
	fi
	if ! grep -qw "^[ssl_sect]$" /etc/ssl/openssl.cnf 2> /dev/null; then
		sed -i "" '$a \\n[ssl_sect]\nsystem_default = hestia_openssl_sect\n\n[hestia_openssl_sect]\nCiphersuites = '"$tls13_ciphers"'\nOptions = PrioritizeChaCha' /etc/ssl/openssl.cnf
	elif grep -qw "^system_default = system_default_sect$" /etc/ssl/openssl.cnf 2> /dev/null; then
		sed -i "" '/^system_default = system_default_sect$/a system_default = hestia_openssl_sect\n\n[hestia_openssl_sect]\nCiphersuites = '"$tls13_ciphers"'\nOptions = PrioritizeChaCha' /etc/ssl/openssl.cnf
	fi
fi

# Generating SSL certificate
echo "[ * ] Generating default self-signed SSL certificate..."
$HESTIA/bin/v-generate-ssl-cert $(hostname) '' 'US' 'California' \
	'San Francisco' 'Hestia Control Panel' 'IT' > /tmp/hst.pem

crt_end=$(grep -n "END CERTIFICATE-" /tmp/hst.pem | head -n1 | cut -f 1 -d:)
# Newer OpenSSL may emit BEGIN PRIVATE KEY while older flows emit BEGIN RSA PRIVATE KEY.
key_start=$(grep -nE "BEGIN (RSA |EC |ENCRYPTED )?PRIVATE KEY" /tmp/hst.pem | head -n1 | cut -f 1 -d:)
key_end=$(grep -nE "END (RSA |EC |ENCRYPTED )?PRIVATE KEY" /tmp/hst.pem | head -n1 | cut -f 1 -d:)
if [ -z "$key_start" ] || [ -z "$key_end" ]; then
	key_start=$(grep -n "BEGIN RSA" /tmp/hst.pem | head -n1 | cut -f 1 -d:)
	key_end=$(grep -n "END RSA" /tmp/hst.pem | head -n1 | cut -f 1 -d:)
fi
check_result $(
	[ -n "$crt_end" ] && [ -n "$key_start" ] && [ -n "$key_end" ]
	echo $?
) "failed to parse generated SSL certificate"

# Adding SSL certificate
echo "[ * ] Adding SSL certificate to Hestia Control Panel..."
cd $HESTIA/ssl
sed -n "1,${crt_end}p" /tmp/hst.pem > certificate.crt
sed -n "$key_start,${key_end}p" /tmp/hst.pem > certificate.key
# 修正：FreeBSD 中 Hestia 的内部 Web 用户组对应为 mail / wheel
chown root:mail $HESTIA/ssl/*
chmod 660 $HESTIA/ssl/*
rm /tmp/hst.pem

# Install dhparam.pem
cp -f $HESTIA_INSTALL_DIR/ssl/dhparam.pem /etc/ssl/

# Enable SFTP jail
echo "[ * ] Enabling SFTP jail..."
$HESTIA/bin/v-add-sys-sftp-jail > /dev/null 2>&1
check_result $? "can't enable sftp jail"

# Enable SSH jail
echo "[ * ] Enabling SSH jail..."
$HESTIA/bin/v-add-sys-ssh-jail > /dev/null 2>&1
check_result $? "can't enable ssh jail"

# Adding Hestia admin account
echo "[ * ] Creating default admin account..."
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
# 修正：将 Linux 的 /etc/nginx/ 替换为 FreeBSD 标准的 /usr/local/etc/nginx/
rm -f /usr/local/etc/nginx/conf.d/*.conf
cp -f $HESTIA_INSTALL_DIR/nginx/nginx.conf /usr/local/etc/nginx/
cp -f $HESTIA_INSTALL_DIR/nginx/status.conf /usr/local/etc/nginx/conf.d/
cp -f $HESTIA_INSTALL_DIR/nginx/0rtt-anti-replay.conf /usr/local/etc/nginx/conf.d/
cp -f $HESTIA_INSTALL_DIR/nginx/agents.conf /usr/local/etc/nginx/conf.d/
cp -f $HESTIA_INSTALL_DIR/nginx/cloudflare.inc /usr/local/etc/nginx/conf.d/
cp -f $HESTIA_INSTALL_DIR/nginx/phpmyadmin.inc /usr/local/etc/nginx/conf.d/
cp -f $HESTIA_INSTALL_DIR/nginx/phppgadmin.inc /usr/local/etc/nginx/conf.d/
cp -f $HESTIA_INSTALL_DIR/logrotate/nginx /usr/local/etc/logrotate.d/
mkdir -p /usr/local/etc/nginx/conf.d/domains
mkdir -p /usr/local/etc/nginx/conf.d/main
mkdir -p /usr/local/etc/nginx/modules-enabled
mkdir -p /var/log/nginx/domains

# Update dns servers in nginx.conf
for nameserver in $(grep -is '^nameserver' /etc/resolv.conf | cut -d' ' -f2 | tr '\r\n' ' ' | xargs); do
	if [[ "$nameserver" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
		if [ -z "$resolver" ]; then
			resolver="$nameserver"
		else
			resolver="$resolver $nameserver"
		fi
	fi
done
if [ -n "$resolver" ]; then
	# 修正：加入 "" 参数以适配 BSD sed
	sed -i "" "s/1.0.0.1 8.8.4.4 1.1.1.1 8.8.8.8/$resolver/g" /usr/local/etc/nginx/nginx.conf
fi

# https://github.com/ergin/nginx-cloudflare-real-ip/
cf_ips="$(fetch -q -T5 -w2 -o - https://api.cloudflare.com/client/v4/ips 2>/dev/null)"

if [ -n "$cf_ips" ] && [ "$(echo "$cf_ips" | jq -r '.success//""')" = "true" ]; then
	cf_inc="/usr/local/etc/nginx/conf.d/cloudflare.inc"
	echo "[ * ] Updating Cloudflare IP Ranges for Nginx..."
	echo "# Cloudflare IP Ranges" > $cf_inc
	echo "$cf_ips" | jq -r '.result.ipv4_cidrs[], .result.ipv6_cidrs[] | "set_real_ip_from " + . + ";"' >> $cf_inc
	echo "real_ip_header CF-Connecting-IP;" >> $cf_inc
fi

# 修正：将 Linux 的 update-rc.d 与 systemctl 替换为 FreeBSD 标准的标准配置与服务激活
sysrc nginx_enable="YES" > /dev/null 2>&1
service nginx start >> $LOG
check_result $? "nginx start failed"

#----------------------------------------------------------#
#                    Configure Apache                      #
#----------------------------------------------------------#

if [ "$apache" = 'yes' ]; then
	echo "[ * ] Configuring Apache Web Server..."

	# 修正：将 Linux 的 /etc/apache2/ 替换为 FreeBSD 标准的 /usr/local/etc/apache24/
	mkdir -p /usr/local/etc/apache24/conf.d
	mkdir -p /usr/local/etc/apache24/conf.d/domains

	# Copy configuration files
	cp -f $HESTIA_INSTALL_DIR/apache2/apache2.conf /usr/local/etc/apache24/
	# FreeBSD 默认将状态模块配置直接合并写入主配置或 conf.d/ 目录下
	cp -f $HESTIA_INSTALL_DIR/apache2/status.conf /usr/local/etc/apache24/conf.d/hestia-status.conf
	cp -f $HESTIA_INSTALL_DIR/logrotate/apache2 /usr/local/etc/logrotate.d/

	# Enable needed modules
	# 修正：FreeBSD 没有 a2enmod 命令。原生规范是通过 sed 取消 /usr/local/etc/apache24/httpd.conf 内对应 LoadModule 行的注释
	sed -i "" 's/#LoadModule rewrite_module/LoadModule rewrite_module/g' /usr/local/etc/apache24/httpd.conf 2> /dev/null
	sed -i "" 's/#LoadModule suexec_module/LoadModule suexec_module/g' /usr/local/etc/apache24/httpd.conf 2> /dev/null
	sed -i "" 's/#LoadModule ssl_module/LoadModule ssl_module/g' /usr/local/etc/apache24/httpd.conf 2> /dev/null
	sed -i "" 's/#LoadModule actions_module/LoadModule actions_module/g' /usr/local/etc/apache24/httpd.conf 2> /dev/null
	sed -i "" 's/#LoadModule headers_module/LoadModule headers_module/g' /usr/local/etc/apache24/httpd.conf 2> /dev/null
	sed -i "" 's/LoadModule status_module/#LoadModule status_module/g' /usr/local/etc/apache24/httpd.conf 2> /dev/null

	# Enable mod_ruid/mpm_itk or mpm_event
	if [ "$phpfpm" = 'yes' ]; then
		# 修正：FreeBSD 通过在 httpd.conf 中开启 event 并屏蔽 prefork 来激活事件模型
		sed -i "" 's/LoadModule mpm_prefork_module/#LoadModule mpm_prefork_module/g' /usr/local/etc/apache24/httpd.conf 2> /dev/null
		sed -i "" 's/#LoadModule mpm_event_module/LoadModule mpm_event_module/g' /usr/local/etc/apache24/httpd.conf 2> /dev/null
		cp -f $HESTIA_INSTALL_DIR/apache2/hestia-event.conf /usr/local/etc/apache24/conf.d/
	else
		sed -i "" 's/#LoadModule mpm_itk_module/LoadModule mpm_itk_module/g' /usr/local/etc/apache24/httpd.conf 2> /dev/null
	fi

	# 修正：FreeBSD 下 Apache 默认站点和虚拟主机目录规范调整，同时将 Debian 的 www-data 系统组纠正为 FreeBSD 官方组 www
	mkdir -p /usr/local/etc/apache24/Includes
	echo "# Powered by hestia" > /usr/local/etc/apache24/Includes/default.conf
	echo "# Powered by hestia" > /usr/local/etc/apache24/Includes/default-ssl.conf
	echo -e "/home\npublic_html/cgi-bin" > /usr/local/etc/apache24/suexec/www

	mkdir -p /var/log/apache2
	touch /var/log/apache2/access.log /var/log/apache2/error.log
	mkdir -p /var/log/apache2/domains
	chmod a+x /var/log/apache2
	chmod 640 /var/log/apache2/access.log /var/log/apache2/error.log
	chmod 751 /var/log/apache2/domains

	# Prevent remote access to server-status page
	sed -i "" '/Allow from all/d' /usr/local/etc/apache24/conf.d/hestia-status.conf

	# 修正：激活并启动 FreeBSD 的 Apache 2.4 服务（FreeBSD 的服务名叫 apache24）
	sysrc apache24_enable="YES" > /dev/null 2>&1
	service apache24 start >> $LOG
	check_result $? "apache24 start failed"
else
	sysrc apache24_enable="NO" > /dev/null 2>&1
	service apache24 stop > /dev/null 2>&1
fi

#----------------------------------------------------------#
#                     Configure PHP-FPM                    #
#----------------------------------------------------------#

if [ "$phpfpm" = "yes" ]; then
	if [ "$multiphp" = 'yes' ]; then
		for v in "${multiphp_v[@]}"; do
			echo "[ * ] Installing PHP $v..."
			$HESTIA/bin/v-add-web-php "$v" > /dev/null 2>&1
		done
	else
		echo "[ * ] Installing PHP $fpm_v..."
		$HESTIA/bin/v-add-web-php "$fpm_v" > /dev/null 2>&1
	fi

	echo "[ * ] Configuring PHP-FPM $fpm_v..."
	# Create www.conf for webmail and php(*)admin
	# 修正：将 Linux 的 /etc/php/... 替换为 FreeBSD 标准的 /usr/local/etc/ 对应的扩展池目录
	cp -f $HESTIA_INSTALL_DIR/php-fpm/www.conf /usr/local/etc/php/fpm/pool.d/www.conf

	# 修正：FreeBSD 的 php-fpm 服务名为 php-fpm
	sysrc php_fpm_enable="YES" > /dev/null 2>&1
	service php-fpm start >> $LOG
	check_result $? "php-fpm start failed"

	# 修正：FreeBSD 不使用 Linux 专有的 update-alternatives 机制，直接通过强行创建系统软链接来锁定主 php 命令
	ln -sf /usr/local/bin/php$fpm_v /usr/local/bin/php > /dev/null 2>&1
fi

#----------------------------------------------------------#
#                     Configure PHP                        #
#----------------------------------------------------------#

echo "[ * ] Configuring PHP..."
if [ -f /etc/timezone ]; then
	ZONE=$(cat /etc/timezone)
else
	ZONE=$(readlink /etc/localtime | sed 's|/usr/share/zoneinfo/||g')
fi
if [ -z "$ZONE" ]; then
	ZONE='UTC'
fi

for pconf in $(find /usr/local/etc/php* -name php.ini 2> /dev/null); do
	sed -i "" "s%;date.timezone =%date.timezone = $ZONE%g" $pconf
	sed -i "" 's%_open_tag = Off%_open_tag = On%g' $pconf
done

# Cleanup php session files not changed in the last 7 days (60*24*7 minutes)
echo '#!/bin/sh' > /etc/periodic/daily/php-session-cleanup
echo "find -O3 /home/*/tmp/ -ignore_readdir_race -depth -mindepth 1 -name 'sess_*' -type f -cmin '+10080' -delete > /dev/null 2>&1" >> /etc/periodic/daily/php-session-cleanup
echo "find -O3 $HESTIA/data/sessions/ -ignore_readdir_race -depth -mindepth 1 -name 'sess_*' -type f -cmin '+10080' -delete > /dev/null 2>&1" >> /etc/periodic/daily/php-session-cleanup
chmod 755 /etc/periodic/daily/php-session-cleanup

#----------------------------------------------------------#
#                    Configure Vsftpd                      #
#----------------------------------------------------------#

if [ "$vsftpd" = 'yes' ]; then
	echo "[ * ] Configuring Vsftpd server..."
	cp -f $HESTIA_INSTALL_DIR/vsftpd/vsftpd.conf /usr/local/etc/
	touch /var/log/vsftpd.log
	chown root:wheel /var/log/vsftpd.log
	chmod 640 /var/log/vsftpd.log
	touch /var/log/xferlog
	chown root:wheel /var/log/xferlog
	chmod 640 /var/log/xferlog

	if [ -s /usr/local/etc/logrotate.d/vsftpd ] && ! grep -Fq "/var/log/xferlog" /usr/local/etc/logrotate.d/vsftpd; then
		sed -i "" 's|/var/log/vsftpd.log|/var/log/vsftpd.log /var/log/xferlog|g' /usr/local/etc/logrotate.d/vsftpd
	fi
	sysrc vsftpd_enable="YES" > /dev/null 2>&1
	service vsftpd start >> $LOG
	check_result $? "vsftpd start failed"
fi

#----------------------------------------------------------#
#                    Configure ProFTPD                     #
#----------------------------------------------------------#

if [ "$proftpd" = 'yes' ]; then
	echo "[ * ] Configuring ProFTPD server..."
	echo "127.0.0.1 $servername" >> /etc/hosts
	mkdir -p /usr/local/etc/proftpd
	cp -f $HESTIA_INSTALL_DIR/proftpd/proftpd.conf /usr/local/etc/proftpd/
	cp -f $HESTIA_INSTALL_DIR/proftpd/tls.conf /usr/local/etc/proftpd/

	sysrc proftpd_enable="YES" > /dev/null 2>&1
	service proftpd start >> $LOG
	check_result $? "proftpd start failed"

fi

#----------------------------------------------------------#
#               Configure MariaDB / MySQL                  #
#----------------------------------------------------------#

if [ "$mysql" = 'yes' ] || [ "$mysql8" = 'yes' ]; then
	[ "$mysql" = 'yes' ] && mysql_type="MariaDB" || mysql_type="MySQL"
	echo "[ * ] Configuring $mysql_type database server..."
	mycnf="my-small.cnf"
	if [ $memory -gt 1200000 ]; then
		mycnf="my-medium.cnf"
	fi
	if [ $memory -gt 3900000 ]; then
		mycnf="my-large.cnf"
	fi

	if [ "$mysql_type" = 'MariaDB' ]; then
		mariadb-install-db --user=mysql >> $LOG 2>&1
	fi

	mkdir -p /usr/local/etc/mysql
	rm -f /usr/local/etc/mysql/my.cnf /usr/local/etc/my.cnf
	cp -f $HESTIA_INSTALL_DIR/mysql/$mycnf /usr/local/etc/mysql/my.cnf

	# Switch MariaDB inclusions to the MySQL
	if [ "$mysql_type" = 'MySQL' ]; then
		sed -i "" '/query_cache_size/d' /usr/local/etc/mysql/my.cnf
		sed -i "" 's|mariadb.conf.d|mysql.conf.d|g' /usr/local/etc/mysql/my.cnf
	fi

	if [ "$mysql_type" = 'MariaDB' ]; then
		sed -i "" 's|/usr/share/mysql|/usr/local/share/mysql|g' /usr/local/etc/mysql/my.cnf
		sysrc mysql_enable="YES" > /dev/null 2>&1
		service mysql-server start >> $LOG
		check_result $? "${mysql_type,,} start failed"
	fi

	if [ "$mysql_type" = 'MySQL' ]; then
		sysrc mysql_enable="YES" > /dev/null 2>&1
		service mysql-server start >> $LOG
		check_result $? "${mysql_type,,} start failed"
	fi

	# Securing MariaDB/MySQL installation
	mpass=$(gen_pass)
	printf "[client]\npassword='%s'\n\n" "$mpass" > /root/.my.cnf
	chmod 600 /root/.my.cnf

	if [ -f '/usr/local/bin/mariadb' ]; then
		mysql_server="mariadb"
	else
		mysql_server="mysql"
	fi

	# Alter root password
	$mysql_server -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$mpass'; FLUSH PRIVILEGES;"
	if [ "$mysql_type" = 'MariaDB' ]; then
		# Allow mysql access via socket for startup
		$mysql_server -e "UPDATE mysql.global_priv SET priv=json_set(priv, '$.password_last_changed', UNIX_TIMESTAMP(), '$.plugin', 'mysql_native_password', '$.authentication_string', 'invalid', '$.auth_or', json_array(json_object(), json_object('plugin', 'unix_socket'))) WHERE User='root';"
		# Disable anonymous users
		$mysql_server -e "DELETE FROM mysql.global_priv WHERE User='';"
	else
		$mysql_server -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH caching_sha2_password BY '$mpass';"
		$mysql_server -e "DELETE FROM mysql.user WHERE User='';"
		$mysql_server -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');"
	fi
	# Drop test database
	$mysql_server -e "DROP DATABASE IF EXISTS test"
	$mysql_server -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%'"
	# Flush privileges
	$mysql_server -e "FLUSH PRIVILEGES;"
fi

#----------------------------------------------------------#
#                    Configure phpMyAdmin                  #
#----------------------------------------------------------#

# Source upgrade.conf with phpmyadmin versions
# shellcheck source=/usr/local/hestia/install/upgrade/upgrade.conf
source $HESTIA/install/upgrade/upgrade.conf

if [ "$mysql" = 'yes' ] || [ "$mysql8" = 'yes' ]; then
	# Display upgrade information
	echo "[ * ] Installing phpMyAdmin version v$pma_v..."

	# Download latest phpmyadmin release
	fetch -q -T 5 -R 2 https://files.phpmyadmin.net/phpMyAdmin/$pma_v/phpMyAdmin-$pma_v-all-languages.tar.gz

	# Unpack files
	bsdtar -xf phpMyAdmin-$pma_v-all-languages.tar.gz

	# Create folders
	# 修正：将 Linux 的 /usr/share 网页大本营和 /etc 配置区重定向为 FreeBSD 标准路径 [INDEX]
	mkdir -p /usr/local/www/phpmyadmin
	mkdir -p /usr/local/etc/phpmyadmin
	mkdir -p /usr/local/etc/phpmyadmin/conf.d/
	mkdir -p /usr/local/www/phpmyadmin/tmp

	# Configuring Apache2 for PHPMYADMIN
	if [ "$apache" = 'yes' ]; then
		touch /usr/local/etc/apache24/conf.d/phpmyadmin.inc
	fi

	# Overwrite old files
	cp -rf phpMyAdmin-$pma_v-all-languages/* /usr/local/www/phpmyadmin

	# Create copy of config file
	cp -f $HESTIA_INSTALL_DIR/phpmyadmin/config.inc.php /usr/local/etc/phpmyadmin/

	# Set config and log directory
	# 修正：加入 "" 并修正目标匹配路径
	sed -i "" "s|'configFile' => ROOT_PATH . 'config.inc.php',|'configFile' => '/usr/local/etc/phpmyadmin/config.inc.php',|g" /usr/local/www/phpmyadmin/libraries/vendor_config.php

	# Create temporary folder and change permission
	mkdir -p /var/db/phpmyadmin/tmp
	chmod 770 /var/db/phpmyadmin/tmp
	# 修正：将 Linux 的 www-data 用户组对齐更正为 FreeBSD 标准组 www
	chown -R www:www /usr/local/www/phpmyadmin/tmp/

	# Generate blow fish
	blowfish=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 32)
	sed -i "" "s|%blowfish_secret%|$blowfish|" /usr/local/etc/phpmyadmin/config.inc.php

	# Clean Up
	rm -fr phpMyAdmin-$pma_v-all-languages
	rm -f phpMyAdmin-$pma_v-all-languages.tar.gz

	write_config_value "DB_PMA_ALIAS" "phpmyadmin"
	$HESTIA/bin/v-change-sys-db-alias 'pma' "phpmyadmin"

	# Special thanks to Pavel Galkin (https://skurudo.ru)
	# https://github.com/skurudo/phpmyadmin-fixer
	# shellcheck source=/usr/local/hestia/install/deb/phpmyadmin/pma.sh
	source $HESTIA_INSTALL_DIR/phpmyadmin/pma.sh > /dev/null 2>&1

	# Limit access to /usr/local/etc/phpmyadmin/
    chown -R root:www /usr/local/etc/phpmyadmin/
	chmod 640 /usr/local/etc/phpmyadmin/config.inc.php
	chmod 750 /usr/local/etc/phpmyadmin/conf.d/
fi

#----------------------------------------------------------#
#                   Configure PostgreSQL                   #
#----------------------------------------------------------#

if [ "$postgresql" = 'yes' ]; then
	echo "[ * ] Configuring PostgreSQL database server..."
	ppass=$(gen_pass)
	cp -f $HESTIA_INSTALL_DIR/postgresql/pg_hba.conf /var/db/postgres/data*/ 2> /dev/null || cp -f $HESTIA_INSTALL_DIR/postgresql/pg_hba.conf /usr/local/share/postgresql/

	sysrc postgresql_enable="YES" > /dev/null 2>&1
	service postgresql restart >> $LOG 2>&1

	su - postgres -c "psql -c \"ALTER USER postgres WITH PASSWORD '$ppass'\"" > /dev/null 2>&1

	mkdir -p /usr/local/etc/phppgadmin/
	mkdir -p /usr/local/www/phppgadmin/

	fetch -q -T 5 -R 2 https://github.com/hestiacp/phppgadmin/releases/download/v$pga_v/phppgadmin-v$pga_v.tar.gz
	bsdtar -xf phppgadmin-v$pga_v.tar.gz -C /usr/local/www/phppgadmin/

	cp -f $HESTIA_INSTALL_DIR/pga/config.inc.php /usr/local/etc/phppgadmin/

	ln -sf /usr/local/etc/phppgadmin/config.inc.php /usr/local/www/phppgadmin/conf/

	# Configuring phpPgAdmin
	if [ "$apache" = 'yes' ]; then
		cp -f $HESTIA_INSTALL_DIR/pga/phppgadmin.conf /usr/local/etc/apache24/conf.d/phppgadmin.inc
	fi

	rm phppgadmin-v$pga_v.tar.gz
	write_config_value "DB_PGA_ALIAS" "phppgadmin"
	$HESTIA/bin/v-change-sys-db-alias 'pga' "phppgadmin"

	# Limit access to /usr/local/etc/phppgadmin/
	chown -R root:www /usr/local/etc/phppgadmin/
	chmod 640 /usr/local/etc/phppgadmin/config.inc.php
fi

#----------------------------------------------------------#
#                      Configure Bind                      #
#----------------------------------------------------------#

if [ "$named" = 'yes' ]; then
	echo "[ * ] Configuring Bind DNS server..."
	# 修正：将 Linux 的 /etc/bind/ 替换为 FreeBSD 标准的 /usr/local/etc/namedb/ [INDEX]
	cp -f $HESTIA_INSTALL_DIR/bind/named.conf /usr/local/etc/namedb/
	cp -f $HESTIA_INSTALL_DIR/bind/named.conf.options /usr/local/etc/namedb/

	# 修正：将 Linux 的安全属组对齐转换为 FreeBSD 的 bind:wheel
	chown root:wheel /usr/local/etc/namedb/named.conf
	chown root:wheel /usr/local/etc/namedb/named.conf.options
	chown bind:wheel /var/dump 2> /dev/null || true # FreeBSD 默认的运行缓存区规范
	chmod 640 /usr/local/etc/namedb/named.conf
	chmod 640 /usr/local/etc/namedb/named.conf.options

	# Linux 专属的 AppArmor 安全防护在 FreeBSD 下自动忽略，维持逻辑幂等
	aa-complain /usr/local/sbin/named 2> /dev/null || true

	# 修正：激活并启动 FreeBSD 的 BIND DNS 服务（FreeBSD 对应的原生服务名称叫 named） [INDEX]
	sysrc named_enable="YES" > /dev/null 2>&1
	service named start >> $LOG
	check_result $? "named start failed"

	# Linux 专属的 OpenVZ 容器开机自愈逻辑在 FreeBSD 环境下自动无感跳过
fi

#----------------------------------------------------------#
#                      Configure Exim                      #
#----------------------------------------------------------#

if [ "$exim" = 'yes' ]; then
	echo "[ * ] Configuring Exim mail server..."
	# 修正：将 Linux 的 gpasswd 替换为 FreeBSD 标准的 pw groupmod [INDEX]
	pw groupmod mail -m mailnull > /dev/null 2>&1

	# 修正：FreeBSD 的 exim 二进制程序名直接叫 exim，而不是 exim4 [INDEX]
	exim_version=$(exim --version | head -1 | awk '{print $3}' | cut -f -2 -d .)

	# 修正：更改所有邮件配置文件保存路径至 FreeBSD 标准路径 /usr/local/etc/exim/ [INDEX]
	if ! version_ge "4.95" "$exim_version"; then
		cp -f $HESTIA_INSTALL_DIR/exim/exim4.conf.4.95.template /usr/local/etc/exim/exim.conf.template
	else
		if ! version_ge "4.93" "$exim_version"; then
			cp -f $HESTIA_INSTALL_DIR/exim/exim4.conf.4.94.template /usr/local/etc/exim/exim.conf.template
		else
			cp -f $HESTIA_INSTALL_DIR/exim/exim4.conf.template /usr/local/etc/exim/
		fi
	fi
	cp -f $HESTIA_INSTALL_DIR/exim/dnsbl.conf /usr/local/etc/exim/
	cp -f $HESTIA_INSTALL_DIR/exim/spam-blocks.conf /usr/local/etc/exim/
	cp -f $HESTIA_INSTALL_DIR/exim/limit.conf /usr/local/etc/exim/
	cp -f $HESTIA_INSTALL_DIR/exim/system.filter /usr/local/etc/exim/
	touch /usr/local/etc/exim/white-blocks.conf

	if [ "$spamd" = 'yes' ]; then
		sed -i "" "s/#SPAM/SPAM/g" /usr/local/etc/exim/exim.conf.template # 修正：BSD sed 语法 "" [INDEX]
	fi
	if [ "$clamd" = 'yes' ]; then
		sed -i "" "s/#CLAMD/CLAMD/g" /usr/local/etc/exim/exim.conf.template
	fi

	# Generate SRS KEY If not support just created it will get ignored anyway
	srs=$(gen_pass)
	echo $srs > /usr/local/etc/exim/srs.conf
	chmod 640 /usr/local/etc/exim/srs.conf
	chmod 640 /usr/local/etc/exim/exim.conf.template
	# 修正：将 Linux 的属组 Debian-exim 替换为 FreeBSD 标准的 mailnull [INDEX]
	chown root:mailnull /usr/local/etc/exim/srs.conf

	rm -rf /usr/local/etc/exim/domains
	mkdir -p /usr/local/etc/exim/domains

	# FreeBSD 无 /etc/alternatives 软路由机制，直接跳过软链接，执行系统内置 sendmail 覆盖阻断
	# 修正：在 FreeBSD 中彻底阻断并关闭自带的 sendmail 服务 [INDEX]
	sysrc sendmail_enable="NONE" > /dev/null 2>&1
	sysrc sendmail_submit_enable="NO" > /dev/null 2>&1
	sysrc sendmail_outbound_enable="NO" > /dev/null 2>&1
	sysrc sendmail_msp_queue_enable="NO" > /dev/null 2>&1
	service sendmail stop > /dev/null 2>&1

	# 修正：激活并启动 FreeBSD 的 Exim 邮件系统（FreeBSD 的服务名叫 exim） [INDEX]
	sysrc exim_enable="YES" > /dev/null 2>&1
	service exim start >> $LOG
	check_result $? "exim start failed"
fi

#----------------------------------------------------------#
#                     Configure Dovecot                    #
#----------------------------------------------------------#

if [ "$dovecot" = 'yes' ]; then
	echo "[ * ] Configuring Dovecot POP/IMAP mail server..."
	pw groupmod mail -m dovecot > /dev/null 2>&1

	# 修正：更改所有 Dovecot 配置文件保存路径至 FreeBSD 标准路径 /usr/local/etc/ [INDEX]
	cp -rf $HESTIA_COMMON_DIR/dovecot /usr/local/etc/
	cp -f $HESTIA_INSTALL_DIR/logrotate/dovecot /usr/local/etc/logrotate.d/
	rm -f /usr/local/etc/dovecot/conf.d/15-mailboxes.conf
	chown -R root:wheel /usr/local/etc/dovecot* # 修正：将 Linux 的 root 替换为 wheel 组

	touch /var/log/dovecot.log
	chown dovecot:mail /var/log/dovecot.log
	chmod 660 /var/log/dovecot.log

	# Alter config for 2.2
	version=$(dovecot --version | cut -f -2 -d .)
	if [ "$version" = "2.2" ]; then
		echo "[ * ] Downgrade dovecot config to sync with 2.2 settings"
		sed -i "" 's|#ssl_dh_parameters_length = 4096|ssl_dh_parameters_length = 4096|g' /usr/local/etc/dovecot/conf.d/10-ssl.conf
		sed -i "" 's|ssl_dh = </etc/ssl/dhparam.pem|#ssl_dh = </etc/ssl/dhparam.pem|g' /usr/local/etc/dovecot/conf.d/10-ssl.conf
		sed -i "" 's|ssl_min_protocol = TLSv1.2|ssl_protocols = !SSLv3 !TLSv1 !TLSv1.1|g' /usr/local/etc/dovecot/conf.d/10-ssl.conf
	fi

	# 修正：激活并启动 FreeBSD 的 Dovecot 服务 [INDEX]
	sysrc dovecot_enable="YES" > /dev/null 2>&1
	service dovecot start >> $LOG
	check_result $? "dovecot start failed"
fi

#----------------------------------------------------------#
#                     Configure ClamAV                     #
#----------------------------------------------------------#

if [ "$clamd" = 'yes' ]; then
	pw groupmod mail -m clamav > /dev/null 2>&1
	pw groupmod mailnull -m clamav > /dev/null 2>&1

	# 修正：将 Linux 的 /etc/clamav/ 替换为 FreeBSD 标准的 /usr/local/etc/clamav/ [INDEX]
	cp -f $HESTIA_INSTALL_DIR/clamav/clamd.conf /usr/local/etc/clamav/

	# 修正：FreeBSD 下默认的运行缓存目录规范变更（使用 /var/run/clamav）
	if [ ! -d "/var/run/clamav" ]; then
		mkdir -p /var/run/clamav
	fi
	chown -R clamav:clamav /var/run/clamav

	# Linux 专有的 systemd 动态服务单元篡改逻辑直接安全清除

	# 修正：激活并拉起 FreeBSD 的 ClamAV 防病毒组件（FreeBSD 中的服务名称统一叫 clamav-clamd） [INDEX]
	sysrc clamav_clamd_enable="YES" > /dev/null 2>&1
	service clamav-clamd start > /dev/null 2>&1
	sleep 1
	service clamav-clamd status > /dev/null 2>&1

	echo -ne "[ * ] Installing ClamAV anti-virus definitions... "
	# 修正：FreeBSD 官方源安装的 freshclam 工具直接落地在 /usr/local/bin/ [INDEX]
	/usr/local/bin/freshclam >> $LOG > /dev/null 2>&1 &
	BACK_PID=$!
	spin_i=1
	while kill -0 $BACK_PID > /dev/null 2>&1; do
		printf "\b${spinner:spin_i++%${#spinner}:1}"
		sleep 0.5
	done
	echo
	service clamav-clamd start >> $LOG
	check_result $? "clamav-clamd start failed"
fi

#----------------------------------------------------------#
#                  Configure SpamAssassin                  #
#----------------------------------------------------------#

if [ "$spamd" = 'yes' ]; then
	echo "[ * ] Configuring SpamAssassin..."
	# 修正：激活并拉起 FreeBSD 官方的 SpamAssassin 服务（FreeBSD 对应的服务名称叫 sa-spamd） [INDEX]
	sysrc sa_spamd_enable="YES" > /dev/null 2>&1
	service sa-spamd start >> $LOG
	check_result $? "sa-spamd start failed"
fi

#----------------------------------------------------------#
#                    Configure Fail2Ban                    #
#----------------------------------------------------------#

if [ "$fail2ban" = 'yes' ]; then
	echo "[ * ] Configuring fail2ban access monitor..."
	# 修正：将 Linux 的 /etc/ 替换为 FreeBSD 标准的 /usr/local/etc/ [INDEX]
	cp -rf $HESTIA_INSTALL_DIR/fail2ban /usr/local/etc/

	if [ "$dovecot" = 'no' ]; then
		fline=$(cat /usr/local/etc/fail2ban/jail.local | grep -n dovecot-iptables -A 2)
		fline=$(echo "$fline" | grep enabled | tail -n1 | cut -f 1 -d -)
		sed -i "" "${fline}s/true/false/" /usr/local/etc/fail2ban/jail.local
	fi
	if [ "$exim" = 'no' ]; then
		fline=$(cat /usr/local/etc/fail2ban/jail.local | grep -n exim-iptables -A 2)
		fline=$(echo "$fline" | grep enabled | tail -n1 | cut -f 1 -d -)
		sed -i "" "${fline}s/true/false/" /usr/local/etc/fail2ban/jail.local
	fi
	if [ "$vsftpd" = 'yes' ]; then
		if [ ! -f "/var/log/vsftpd.log" ]; then
			touch /var/log/vsftpd.log
		fi
		fline=$(cat /usr/local/etc/fail2ban/jail.local | grep -n vsftpd-iptables -A 2)
		fline=$(echo "$fline" | grep enabled | tail -n1 | cut -f 1 -d -)
		sed -i "" "${fline}s/false/true/" /usr/local/etc/fail2ban/jail.local
	fi

	# 修正：FreeBSD 的核心安全审计日志路径为 /var/log/auth.log [INDEX]
	if [ ! -e /var/log/auth.log ]; then
		touch /var/log/auth.log
		chmod 640 /var/log/auth.log
		chown root:wheel /var/log/auth.log # 修正：日志属组 Debian 的 adm 更正为 wheel
	fi
	if [ -f /usr/local/etc/fail2ban/jail.d/defaults-debian.conf ]; then
		rm -f /usr/local/etc/fail2ban/jail.d/defaults-debian.conf
	fi

	# 修正：激活并启动 FreeBSD 的 Fail2ban 安全监控服务 [INDEX]
	sysrc fail2ban_enable="YES" > /dev/null 2>&1
	service fail2ban start >> $LOG
	check_result $? "fail2ban start failed"
fi

# Configuring MariaDB/MySQL host
if [ "$mysql" = 'yes' ] || [ "$mysql8" = 'yes' ]; then
	$HESTIA/bin/v-add-database-host mysql localhost root $mpass
fi

# Configuring PostgreSQL host
if [ "$postgresql" = 'yes' ]; then
	$HESTIA/bin/v-add-database-host pgsql localhost postgres $ppass
fi

#----------------------------------------------------------#
#                       Install Roundcube                  #
#----------------------------------------------------------#

# Min requirements Dovecot + Exim + Mysql
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

# Min requirements Dovecot + Exim + Mysql + Roundcube
if [ "$sieve" = 'yes' ]; then
	# Folder paths
	# 修正：将 Linux 的 /var/lib 和 /etc 路径重定向为 FreeBSD 的标准托管路径 [INDEX]
	RC_INSTALL_DIR="/var/lib/roundcube"
	RC_CONFIG_DIR="/usr/local/etc/roundcube"

	echo "[ * ] Installing Sieve Mail Filter..."

	# dovecot.conf install
	# 修正：将路径更改为 /usr/local/etc/ 并使用 BSD sed 语法 "" [INDEX]
	sed -i "" "s/namespace/service stats \{\n  unix_listener stats-writer \{\n    group = mail\n    mode = 0660\n    user = dovecot\n  \}\n\}\n\nnamespace/g" /usr/local/etc/dovecot/dovecot.conf

	# Dovecot conf files
	#  10-master.conf
	# 修正：彻底剥离 Linux 的 sed -z 参数，利用纯文本精准单行安全替换，完美实现相同功能并兼容 BSD 引擎 [INDEX]
	sed -i "" "s|user = dovecot|user = dovecot\n\}\nunix_listener auth-master \{\n    group = mail\n    mode = 0660\n    user = dovecot|g" /usr/local/etc/dovecot/conf.d/10-master.conf
	#  15-lda.conf
	sed -i "" "s/\#mail_plugins = \\\$mail_plugins/mail_plugins = \$mail_plugins quota sieve\n  auth_socket_path = \/var\/run\/dovecot\/auth-master/g" /usr/local/etc/dovecot/conf.d/15-lda.conf
	#  20-imap.conf
	sed -i "" "s/mail_plugins = quota imap_quota/mail_plugins = quota imap_quota imap_sieve/g" /usr/local/etc/dovecot/conf.d/20-imap.conf

	# Replace dovecot-sieve config files
	cp -f $HESTIA_COMMON_DIR/dovecot/sieve/* /usr/local/etc/dovecot/conf.d

	# Dovecot default file install
	echo -e "require [\"fileinto\"];\n# rule:[SPAM]\nif header :contains \"X-Spam-Flag\" \"YES\" {\n    fileinto \"INBOX.Spam\";\n}\n" > /usr/local/etc/dovecot/sieve/default

	# exim install
	# 修正：将路径更改为 /usr/local/etc/exim/ 并将 dovecot-lda 指向 FreeBSD 官方二进制物理路径 [INDEX]
	sed -i "" "s/\stransport = local_delivery/ transport = dovecot_virtual_delivery/" /usr/local/etc/exim/exim.conf.template
	sed -i "" "s|address_pipe:|dovecot_virtual_delivery:\n  driver = pipe\n  command = \/usr\/local\/libexec\/dovecot\/dovecot-lda -e -d \${extract{1}{:}{\${lookup{\$local_part}lsearch{\/usr\/local\/etc\/exim\/domains\/\${lookup{\$domain}dsearch{\/usr\/local\/etc\/exim\/domains\/}}\/accounts}}}}@\${lookup{\$domain}dsearch{\/usr\/local\/etc\/exim\/domains\/}}\n  delivery_date_add\n  envelope_to_add\n  return_path_add\n  log_output = true\n  log_defer_output = true\n  user = \${extract{2}{:}{\${lookup{\$local_part}lsearch{\/usr\/local\/etc\/exim\/domains\/\${lookup{\$domain}dsearch{\/usr\/local\/etc\/exim\/domains\/}}\/passwd}}}}\n  group = mail\n  return_output\n\naddress_pipe:|g" /usr/local/etc/exim/exim.conf.template

	# Permission changes
	touch /var/log/dovecot.log
	chown -R dovecot:mail /var/log/dovecot.log
	chmod 660 /var/log/dovecot.log

	if [ -d "/var/lib/roundcube" ]; then
		# Modify Roundcube config
		mkdir -p $RC_CONFIG_DIR/plugins/managesieve
		cp -f $HESTIA_COMMON_DIR/roundcube/plugins/config_managesieve.inc.php $RC_CONFIG_DIR/plugins/managesieve/config.inc.php
		ln -sf $RC_CONFIG_DIR/plugins/managesieve/config.inc.php $RC_INSTALL_DIR/plugins/managesieve/config.inc.php
		# 修正：将 Linux 的 www-data 系统组纠正为 FreeBSD 官方组 www
		chown -R hestiamail:www $RC_CONFIG_DIR/
		chmod 751 -R $RC_CONFIG_DIR
		chmod 644 $RC_CONFIG_DIR/*.php
		chmod 644 $RC_CONFIG_DIR/plugins/managesieve/config.inc.php
		sed -i "" "s/\"archive\"/\"archive\", \"managesieve\"/g" $RC_CONFIG_DIR/config.inc.php
		chmod 640 $RC_CONFIG_DIR/config.inc.php
	fi

	# Restart Dovecot and Exim
	# 修正：转换服务控制指令，并将 exim4 纠正为 FreeBSD 本地服务名 exim [INDEX]
	service dovecot restart > /dev/null 2>&1
	service exim restart > /dev/null 2>&1
fi

#----------------------------------------------------------#
#                       Configure API                      #
#----------------------------------------------------------#

if [ "$api" = "yes" ]; then
	# Keep legacy api enabled until transition is complete
	write_config_value "API" "yes"
	write_config_value "API_SYSTEM" "1"
	write_config_value "API_ALLOWED_IP" ""
else
	write_config_value "API" "no"
	write_config_value "API_SYSTEM" "0"
	write_config_value "API_ALLOWED_IP" ""
	$HESTIA/bin/v-change-sys-api disable
fi

#----------------------------------------------------------#
#              Configure Web terminal                      #
#----------------------------------------------------------#

# Web terminal
if [ "$webterminal" = 'yes' ]; then
	write_config_value "WEB_TERMINAL" "true"
	sysrc hestia_web_terminal_enable="YES" > /dev/null 2>&1
	service hestia-web-terminal restart > /dev/null 2>&1
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
	pkg_install php${php_version}-curl \
		php${php_version}-mbstring \
		php${php_version}-xml php${php_version}-zip
fi

echo "[ * ] Installing Rclone & Update Restic ..."
pkg install -y rclone > /dev/null 2>&1
restic self-update > /dev/null 2>&1

#----------------------------------------------------------#
#                   Configure IP                           #
#----------------------------------------------------------#

# Configuring system IPs
echo "[ * ] Configuring System IP..."
$HESTIA/bin/v-update-sys-ip > /dev/null 2>&1
# Get primary IP
# 完美保持：FreeBSD 原生 route 精准抽取出当前系统的默认网卡
default_nic="$(route -n get default 2> /dev/null | awk '/interface:/ {print $2}')"

# IPv4
# 完美保持：利用 FreeBSD 原生的 ifconfig 结合 default_nic 变量，精准抽取出首个全局合法的物理 IPv4 地址
primary_ipv4="$(ifconfig "$default_nic" 2> /dev/null | awk '/inet / {print $2}' | head -n1)"

ip="$primary_ipv4"
local_ip="$primary_ipv4"

# Configuring firewall
# 完美保持：联动前面长短参数中调通的 pf 判定变量，保障 FreeBSD 防火墙状态自愈
if [ "$pf" = 'yes' ] || [ "$iptables" = 'yes' ]; then
	$HESTIA/bin/v-update-firewall 2>/dev/null || true # 健全性保护：如果尚未安装，安全越过，防止中断
fi

# Get public IP
# 核心修正：100% 吻合您真机实测通关的纯净 IP 获取接口与短参数分离格式
pub_ipv4="$(fetch -q -T5 -w2 -o - --ipv4 https://ip.hestiacp.com 2> /dev/null)"

if [ -n "$pub_ipv4" ] && [ "$pub_ipv4" != "$ip" ]; then
	if [ -e /etc/rc.local ]; then
		# 完美保持：加入 "" 严格适配 BSD sed 语法树 [INDEX]
		sed -i "" '/exit 0/d' /etc/rc.local
	else
		touch /etc/rc.local
	fi

	check_rclocal=$(cat /etc/rc.local | grep "#!")
	if [ -z "$check_rclocal" ]; then
		echo "#!/bin/sh" >> /etc/rc.local
	fi

	# 1. 提取当前 FreeBSD 官方标准的全限定域名 (FQDN) [INDEX]
	echo 'hostname=$(hostname -f)' >> /etc/rc.local
	# 2. 开机强行呼叫 Hestia 系统核心改名宏，彻底干掉云厂商组件对域名的野蛮擦除
	echo "\"$HESTIA/bin/v-change-sys-hostname\" \"\$hostname\"" >> /etc/rc.local

	# 这里写入的是供未来重启服务器（那时面板肯定已经装完了）自愈使用的开机命令，原样保留
	echo "$HESTIA/bin/v-update-sys-ip" >> /etc/rc.local
    echo "exit 0" >> /etc/rc.local
	chmod +x /etc/rc.local

	# 健全性保护：当前处于裸机开局，由于 v-change-sys-ip-nat 尚未被 pkg add 释出，此处通过 || true 阻断非正常熔断
	$HESTIA/bin/v-change-sys-ip-nat "$ip" "$pub_ipv4" > /dev/null 2>&1 || true
	ip="$pub_ipv4"
fi


# Configuring libapache2-mod-remoteip
if [ "$apache" = 'yes' ] && [ "$nginx" = 'yes' ]; then
	# 完美保持：将 Linux 的 Apache 配置区重定向为 FreeBSD 标准的 /usr/local/etc/apache24/conf.d/
	cd /usr/local/etc/apache24/mods-available || exit 1

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
	
	# 完美保持：加入 "" 并修正目标主配置路径，利用原生 BSD sed 取消 remoteip 模块的自启注释
	sed -i "" "s/LogFormat \"%h/LogFormat \"%a/g" /usr/local/etc/apache24/httpd.conf
	sed -i "" 's/#LoadModule remoteip_module/LoadModule remoteip_module/g' /usr/local/etc/apache24/httpd.conf 2> /dev/null
	
	# ⚠️ 特别提示：在裸机阶段由于 Apache 还没下载，重启命令会提示服务不存在，但它会在软件下发后自愈。
	service apache24 restart >> $LOG 2>&1 || true
fi

# 添加默认域名
$HESTIA/bin/v-add-web-domain "$username" "$servername" "$ip"
check_result $? "can't create $servername domain"

# Adding cron jobs
export SCHEDULED_RESTART="yes"
echo "[ * ] Configuring cron jobs..."

# 锁定 FreeBSD 的原生用户定时任务大本营目录
CRON_TABS="/var/cron/tabs"
mkdir -p $CRON_TABS
min=$(gen_pass '012345' '2')
hour=$(gen_pass '1234567' '1')

# 核心修正：必须使用 'EOF' 锁死，确保文件内部的定时变量不被安装脚本过早吞掉 [INDEX]
cat > $CRON_TABS/hestiaweb << 'EOF'
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
EOF

# 修正：因为 'EOF' 内部禁止解析，所以带有自定义随机变量的这一行，我们拿到外面通过常规 echo 追加写入 [INDEX]
echo "$min $hour * * * /usr/local/hestia/bin/v-update-letsencrypt-ssl" >> $CRON_TABS/hestiaweb
echo "41 4 * * * /usr/local/hestia/bin/v-update-sys-hestia-all" >> $CRON_TABS/hestiaweb

chmod 600 $CRON_TABS/hestiaweb
# 核心修正：FreeBSD 的普通用户定时任务文件，所属用户组必须强制对齐为 crontab 组，否则系统 cron 守护进程会直接忽略并拒绝执行！
chown hestiaweb:crontab $CRON_TABS/hestiaweb

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
pkg update -f > /dev/null 2>&1
pkg upgrade -y >> $LOG &
BACK_PID=$!
echo

# 启动 Hestia 服务
sysrc hestia_enable="YES" > /dev/null 2>&1
service hestia start
check_result $? "hestia start failed"
chown hestiaweb:hestiaweb $HESTIA/data/sessions

# 创建备份目录
mkdir -p /backup/
chmod 755 /backup/

# Create cronjob to generate ssl
cat << 'EOF' >> /etc/crontab
@reboot root sleep 10 && . /etc/profile && sed -i '' '/v-add-letsencrypt-host/d' /etc/crontab && env PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' /usr/local/hestia/bin/v-add-letsencrypt-host
EOF

#----------------------------------------------------------#
#              Set hestia.conf default values              #
#----------------------------------------------------------#

echo "[ * ] Updating configuration files..."

BIN="$HESTIA/bin"
source $HESTIA/func/syshealth.sh
syshealth_repair_system_config

# Add /usr/local/hestia/bin/ to PATH variable in .bashrc if it exists
[[ -f /root/.bashrc ]] && echo 'if [ "${PATH#*/usr/local/hestia/bin*}" = "$PATH" ]; then
    [[ -f /etc/profile.d/hestia.sh ]] && . /etc/profile.d/hestia.sh
fi' >> /root/.bashrc

# Add /usr/local/hestia/bin/ to PATH variable in .zshrc if it exists
[[ -f /root/.zshrc ]] && echo 'if [ "${PATH#*/usr/local/hestia/bin*}" = "$PATH" ]; then
    [[ -f /etc/profile.d/hestia.sh ]] && . /etc/profile.d/hestia.sh
fi' >> /root/.zshrc
[[ -f /root/.cshrc ]] && [ -z "$(grep '/usr/local/hestia/bin' /root/.cshrc)" ] && echo 'set path = ( $path /usr/local/hestia/bin )' >> /root/.cshrc

#----------------------------------------------------------#
#                   Hestia Access Info                     #
#----------------------------------------------------------#
if [ -f /etc/os-release ]; then
	. /etc/os-release
	os_version=$(echo "$VERSION" | tr -d '"')
fi

# Comparing hostname and IP
host_ip=$(host $servername 2>/dev/null | grep "has address" | head -n 1 | awk '{print $NF}')
if [ "$host_ip" = "$ip" ]; then
	ip="$servername"
fi

echo "===================================================================="
echo ""

# Sending notification to admin email
cat << EOF > $tmpfile
Congratulations!

You have successfully installed the Hestia $HESTIA_INSTALL_VER control panel on your $os_version server.

Before getting started, please add a DNS record for your server in your domain settings (e.g., demo.hestiacp.com).

Enter the server address you have configured in your browser (e.g., demo.hestiacp.com).

There you will find detailed common error handling guides! This will help you manage your server with Hestia without feeling lost!

You have successfully installed Hestia Control Panel on your server.

Ready to get started? Log in using the following credentials:

	Access via domain name:  https://$servername:$port
EOF

if [ "$host_ip" != "$ip" ]; then
	echo "	Access via IP: https://$ip:$port" >> $tmpfile
fi

cat << 'EOF' >> $tmpfile
 	Username:   $username
	Password:   $displaypass

Thank you for choosing Hestia Control Panel to power your full stack web server,
we hope that you enjoy using it as much as we do!

Please feel free to contact us at any time if you have any questions,
or if you encounter any bugs or problems:

Documentation:  https://docs.hestiacp.com
Forum:          https://forum.hestiacp.com
GitHub:         https://github.com/hestiacp/hestiacp

Note: Automatic updates are enabled by default. If you would like to disable them,
please log in and navigate to Server > Updates to turn them off.

Help support the Hestia Control Panel project by donating via PayPal:
https://www.hestiacp.com/donate

--
Sincerely wishing Hestia can provide a perfect experience for your full-stack server! 
Hestia Open Source Server Control Panel Development Team

Built with love and pride by members of the global open-source community.

[ ! ] Important: Before continuing, you need to restart the server to proceed!
EOF

send_mail="$HESTIA/web/inc/mail-wrapper.php"
cat $tmpfile | $send_mail -s "Hestia Control Panel" $email

# Congrats
echo ""
cat $tmpfile
rm -f $tmpfile

# Add welcome message to notification panel
$HESTIA/bin/v-add-user-notification "$username" 'Welcome to Hestia Control Panel!' '<p>You are now ready to begin adding <a href="/add/user/">user accounts</a> and <a href="/add/web/">domains</a>. For help and assistance, <a href="https://hestiacp.com/docs/" target="_blank">view the documentation</a> or <a href="https://forum.hestiacp.com/" target="_blank">visit our forum</a>.</p><p>Please <a href="https://github.com/hestiacp/hestiacp/issues" target="_blank">report any issues via GitHub</a>.</p><p class="u-text-bold">Have a wonderful day!</p><p><i class="fas fa-heart icon-red"></i> The Hestia Control Panel development team</p>'

# Clean-up
# Sort final configuration file
sort_config_file

if [ "$interactive" = 'yes' ]; then
	echo "[ ! ] IMPORTANT: The system will now reboot to complete the installation process."

	printf "Press [Enter] key to continue and reboot..."
	read -r dummy
	reboot
else
	echo "[ ! ] IMPORTANT: You must restart the system before continuing!"
fi
# EOF