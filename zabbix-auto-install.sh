#!/bin/bash

# Detect CRLF line endings and fix automatically if needed
if file "$0" | grep -q "CRLF"; then
    echo "[*] Converting script line endings from CRLF to LF for compatibility..."
    tmpfix=$(mktemp)
    tr -d '\r' < "$0" > "$tmpfix"
    chmod +x "$tmpfix"
    exec bash "$tmpfix" "$@"
    exit
fi

set -e

GREEN='\033[0;32m'
RED='\033[1;31m'
NC='\033[0m'

function print_status() {
    echo -e "${GREEN}[*] $1${NC}"
}
function print_error() {
    echo -e "${RED}[!] $1${NC}"
}

# Ensure running as root
if [[ $EUID -ne 0 ]]; then
    print_error "This script must be run as root. Use sudo ./script_name.sh"
    exit 1
fi

# Check if services exist or ports are used
for svc in apache2 mariadb zabbix-server; do
    if systemctl is-active --quiet $svc; then
        print_error "Service '$svc' is already installed and active! Stop or remove it first."
        exit 1
    fi
done

if ss -tuln | grep -q ":80 "; then
    print_error "Port 80 is in use! Please free it first."
    exit 1
fi

# Get server IP or domain
echo
read -p "Enter your server's IP address or domain name (e.g., 192.168.1.10 or zabbix.example.com): " SERVER_ADDR
if [[ -z "$SERVER_ADDR" ]]; then
    print_error "You must enter an IP or domain. Aborting."
    exit 1
fi

# Generate strong random passwords (exactly 12 chars)
gen_pass() {
    tr -dc 'A-Za-z0-9!@#$%&*' </dev/urandom | head -c12
    echo
}

ZABBIX_ROOT_PASS=$(gen_pass)
ZABBIX_DB_PASS=$(gen_pass)

print_status "Updating package list..."
apt update

print_status "Installing prerequisites..."
apt install -y apache2 mariadb-server php php-mbstring php-gd php-xml php-bcmath php-ldap php-mysql php-zip php-json php-xmlreader php-curl wget curl gnupg2 lsb-release

print_status "Securing MariaDB..."
mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${ZABBIX_ROOT_PASS}'; FLUSH PRIVILEGES;"
mysql -uroot -p"${ZABBIX_ROOT_PASS}" -e "DELETE FROM mysql.user WHERE User=''; DROP DATABASE IF EXISTS test; DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%'; FLUSH PRIVILEGES;"

print_status "Creating Zabbix database and user..."
mysql -uroot -p"${ZABBIX_ROOT_PASS}" -e "CREATE DATABASE zabbix CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;"
mysql -uroot -p"${ZABBIX_ROOT_PASS}" -e "CREATE USER 'zabbix'@'localhost' IDENTIFIED BY '${ZABBIX_DB_PASS}';"
mysql -uroot -p"${ZABBIX_ROOT_PASS}" -e "GRANT ALL PRIVILEGES ON zabbix.* TO 'zabbix'@'localhost'; FLUSH PRIVILEGES;"

print_status "Adding Zabbix repository..."
wget https://repo.zabbix.com/zabbix/6.0/ubuntu/pool/main/z/zabbix-release/zabbix-release_6.0-6+ubuntu$(lsb_release -rs)_all.deb
dpkg -i zabbix-release_6.0-6+ubuntu$(lsb_release -rs)_all.deb
apt update

print_status "Installing Zabbix server components..."
apt install -y zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf zabbix-sql-scripts zabbix-agent

print_status "Importing initial schema..."
zcat /usr/share/zabbix-sql-scripts/mysql/server.sql.gz | mysql -uzabbix -p"${ZABBIX_DB_PASS}" zabbix

print_status "Configuring Zabbix database connection..."
sed -i "s/^# DBPassword=.*/DBPassword=${ZABBIX_DB_PASS}/" /etc/zabbix/zabbix_server.conf

print_status "Restarting and enabling services..."
systemctl restart zabbix-server zabbix-agent apache2
systemctl enable zabbix-server zabbix-agent apache2

echo
echo "====================== INSTALLATION COMPLETE ======================"
echo -e "${GREEN}✅ Zabbix is successfully installed!${NC}"
echo
echo -e "${RED}⚠️  IMPORTANT: SAVE THESE CREDENTIALS NOW. THEY WILL NOT BE SHOWN AGAIN!${NC}"
echo "-------------------------------------------------------------------"
echo -e "${GREEN}🌐 Web interface:${NC} http://${SERVER_ADDR}/zabbix"
echo -e "${GREEN}🔑 Zabbix Web Login:${NC} Admin / zabbix"
echo "🔐 Database User: zabbix"
echo "🔐 Database Pass: ${ZABBIX_DB_PASS}"
echo "🔐 MariaDB Root Pass: ${ZABBIX_ROOT_PASS}"
echo "-------------------------------------------------------------------"
echo -e "${GREEN}👌 Enjoy your fully automated Zabbix installation!${NC}"
echo "==================================================================="
