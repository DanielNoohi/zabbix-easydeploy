#!/bin/bash

# --- Self-healing for Windows CRLF line endings ---
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
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

function print_status() {
    echo -e "${GREEN}[*] $1${NC}"
}

function print_error() {
    echo -e "${RED}[!] $1${NC}"
}

function print_warning() {
    echo -e "${YELLOW}[!] $1${NC}"
}

function print_info() {
    echo -e "${BLUE}[i] $1${NC}"
}

# --- Help function ---
show_help() {
    cat << EOF
Usage: sudo ./zabbix-auto-install.sh [OPTIONS]

Options:
  -h, --help              Show this help message
  -i, --ip ADDRESS        Server IP or domain (non-interactive)
  -z, --zabbix-ver VER    Zabbix version: 6.0 or 7.0 (default: 7.0)
  -u, --ubuntu-ver VER    Override Ubuntu version detection
  -s, --save-creds FILE   Save credentials to file after installation
  -n, --non-interactive   Run without prompts (requires -i)
  -f, --force             Skip pre-flight checks (use with caution)
  --no-firewall           Skip UFW firewall configuration
  --no-ssl                Skip SSL certificate setup

Examples:
  sudo ./zabbix-auto-install.sh
  sudo ./zabbix-auto-install.sh -i 192.168.1.10 -z 7.0 -s creds.txt
  sudo ./zabbix-auto-install.sh --non-interactive --ip zabbix.example.com --zabbix-ver 6.0

EOF
}

# --- Default values ---
ZABBIX_VERSION="7.0"
SAVE_CREDS_FILE=""
NON_INTERACTIVE=false
FORCE=false
SKIP_FIREWALL=false
SKIP_SSL=false
SERVER_ADDR=""

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -i|--ip)
            SERVER_ADDR="$2"
            shift 2
            ;;
        -z|--zabbix-ver)
            if [[ "$2" =~ ^(6\.0|7\.0)$ ]]; then
                ZABBIX_VERSION="$2"
            else
                print_error "Invalid Zabbix version. Use 6.0 or 7.0"
                exit 1
            fi
            shift 2
            ;;
        -u|--ubuntu-ver)
            UBUNTU_VERSION_OVERRIDE="$2"
            shift 2
            ;;
        -s|--save-creds)
            SAVE_CREDS_FILE="$2"
            shift 2
            ;;
        -n|--non-interactive)
            NON_INTERACTIVE=true
            shift
            ;;
        -f|--force)
            FORCE=true
            shift
            ;;
        --no-firewall)
            SKIP_FIREWALL=true
            shift
            ;;
        --no-ssl)
            SKIP_SSL=true
            shift
            ;;
        *)
            print_error "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# --- Root check ---
if [[ $EUID -ne 0 ]]; then
    print_error "This script must be run as root. Use sudo ./zabbix-auto-install.sh"
    exit 1
fi

# --- Check services and port 80 ---
if [[ "$FORCE" != true ]]; then
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
fi

# --- User input for server address ---
if [[ -z "$SERVER_ADDR" ]]; then
    if [[ "$NON_INTERACTIVE" == true ]]; then
        print_error "Server address required for non-interactive mode. Use -i or --ip"
        exit 1
    fi
    echo
    read -p "Enter your server's IP address or domain name (e.g., 192.168.1.10 or zabbix.example.com): " SERVER_ADDR
    if [[ -z "$SERVER_ADDR" ]]; then
        print_error "You must enter an IP or domain. Aborting."
        exit 1
    fi
fi

# --- Strong random passwords (16 chars) ---
gen_pass() {
    tr -dc 'A-Za-z0-9!@#$%&*' </dev/urandom | head -c16
    echo
}
ZABBIX_ROOT_PASS=$(gen_pass)
ZABBIX_DB_PASS=$(gen_pass)
ZABBIX_ADMIN_PASS=$(gen_pass)

print_status "Updating package list..."
apt update

print_status "Installing prerequisites..."
apt install -y apache2 mariadb-server php php-mbstring php-gd php-xml php-bcmath php-ldap php-mysql php-zip php-json php-xmlreader php-curl wget curl gnupg2 lsb-release ca-certificates

print_status "Securing MariaDB..."
# Set root password using modern authentication (mysql_native_password for compatibility)
mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED VIA mysql_native_password USING PASSWORD('${ZABBIX_ROOT_PASS}'); FLUSH PRIVILEGES;"
# Remove anonymous users, drop test database, and remove privileges for test database
mysql -uroot -p"${ZABBIX_ROOT_PASS}" -e "DELETE FROM mysql.user WHERE User=''; DROP DATABASE IF EXISTS test; DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%'; FLUSH PRIVILEGES;"

print_status "Creating Zabbix database and user..."
mysql -uroot -p"${ZABBIX_ROOT_PASS}" -e "CREATE DATABASE zabbix CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;"
mysql -uroot -p"${ZABBIX_ROOT_PASS}" -e "CREATE USER 'zabbix'@'localhost' IDENTIFIED BY '${ZABBIX_DB_PASS}';"
mysql -uroot -p"${ZABBIX_ROOT_PASS}" -e "GRANT ALL PRIVILEGES ON zabbix.* TO 'zabbix'@'localhost'; FLUSH PRIVILEGES;"

# --- Ubuntu version detection ---
if [[ -n "$UBUNTU_VERSION_OVERRIDE" ]]; then
    UBUNTU_VERSION="$UBUNTU_VERSION_OVERRIDE"
else
    UBUNTU_VERSION=$(lsb_release -rs)
fi

# --- Zabbix repo selection ---
case "$UBUNTU_VERSION" in
    24.04|22.04|20.04|18.04)
        ZBX_VER="$UBUNTU_VERSION"
        ;;
    *)
        ZBX_VER="22.04"
        print_warning "Your Ubuntu version ($UBUNTU_VERSION) is not officially supported by Zabbix. Using 22.04 repo (should work fine)."
        ;;
esac

# Zabbix release package version mapping
case "$ZABBIX_VERSION" in
    6.0)
        ZABBIX_RELEASE_VER="6.0-6"
        ;;
    7.0)
        ZABBIX_RELEASE_VER="7.0-2"
        ;;
esac

print_status "Adding Zabbix ${ZABBIX_VERSION} repository..."
wget -q "https://repo.zabbix.com/zabbix/${ZABBIX_VERSION}/ubuntu/pool/main/z/zabbix-release/zabbix-release_${ZABBIX_RELEASE_VER}+ubuntu${ZBX_VER}_all.deb"
dpkg -i "zabbix-release_${ZABBIX_RELEASE_VER}+ubuntu${ZBX_VER}_all.deb"
apt update

print_status "Installing Zabbix server components..."
apt install -y zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf zabbix-sql-scripts zabbix-agent

print_status "Importing initial schema..."
zcat /usr/share/zabbix-sql-scripts/mysql/server.sql.gz | mysql -uzabbix -p"${ZABBIX_DB_PASS}" zabbix

print_status "Setting Zabbix admin password..."
mysql -uzabbix -p"${ZABBIX_DB_PASS}" zabbix -e "UPDATE users SET passwd=MD5('${ZABBIX_ADMIN_PASS}') WHERE alias='Admin';"

print_status "Configuring Zabbix database connection..."
sed -i "s/^# DBPassword=.*/DBPassword=${ZABBIX_DB_PASS}/" /etc/zabbix/zabbix_server.conf

# --- Configure Zabbix agent ---
print_status "Configuring Zabbix agent..."
sed -i "s/^Server=127.0.0.1/Server=127.0.0.1/" /etc/zabbix/zabbix_agentd.conf
sed -i "s/^ServerActive=127.0.0.1/ServerActive=127.0.0.1/" /etc/zabbix/zabbix_agentd.conf
sed -i "s/^Hostname=Zabbix server/Hostname=$(hostname)/" /etc/zabbix/zabbix_agentd.conf

# --- Configure Apache ---
print_status "Configuring Apache..."
# Enable required modules
a2enmod rewrite ssl headers >/dev/null 2>&1

# Configure PHP timezone
PHP_INI=$(php -i | grep "Loaded Configuration File" | awk -F '=>' '{print $2}' | xargs)
if [[ -f "$PHP_INI" ]]; then
    sed -i "s/^;date.timezone =/date.timezone = UTC/" "$PHP_INI"
fi

print_status "Restarting and enabling services..."
systemctl restart zabbix-server zabbix-agent apache2
systemctl enable zabbix-server zabbix-agent apache2

# --- Firewall configuration ---
if [[ "$SKIP_FIREWALL" != true ]] && command -v ufw >/dev/null 2>&1; then
    print_status "Configuring UFW firewall..."
    ufw allow 80/tcp comment "Zabbix HTTP" >/dev/null 2>&1
    ufw allow 443/tcp comment "Zabbix HTTPS" >/dev/null 2>&1
    ufw allow 10051/tcp comment "Zabbix Server" >/dev/null 2>&1
    ufw allow 10050/tcp comment "Zabbix Agent" >/dev/null 2>&1
    print_info "Firewall rules added. Enable UFW with 'ufw enable' if not already active."
fi

# --- SSL Setup (self-signed for immediate use) ---
if [[ "$SKIP_SSL" != true ]]; then
    print_status "Setting up SSL certificate..."
    mkdir -p /etc/apache2/ssl
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout /etc/apache2/ssl/zabbix.key \
        -out /etc/apache2/ssl/zabbix.crt \
        -subj "/C=US/ST=State/L=City/O=Organization/CN=${SERVER_ADDR}" >/dev/null 2>&1

    # Create SSL virtual host
    cat > /etc/apache2/sites-available/zabbix-ssl.conf << VHOST
<VirtualHost *:443>
    ServerName ${SERVER_ADDR}
    DocumentRoot /usr/share/zabbix

    SSLEngine on
    SSLCertificateFile /etc/apache2/ssl/zabbix.crt
    SSLCertificateKeyFile /etc/apache2/ssl/zabbix.key

    <Directory /usr/share/zabbix>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    Alias /zabbix /usr/share/zabbix
</VirtualHost>
VHOST

    a2ensite zabbix-ssl >/dev/null 2>&1
    systemctl reload apache2
    print_info "Self-signed SSL certificate created. For production, replace with Let's Encrypt or a valid certificate."
fi

# --- Save credentials to file if requested ---
if [[ -n "$SAVE_CREDS_FILE" ]]; then
    cat > "$SAVE_CREDS_FILE" << CREDS
# Zabbix Installation Credentials
# Generated on $(date)
# KEEP THIS FILE SECURE!

Web Interface: https://${SERVER_ADDR}/zabbix (or http://${SERVER_ADDR}/zabbix)
Admin Username: Admin
Admin Password: ${ZABBIX_ADMIN_PASS}

Database User: zabbix
Database Password: ${ZABBIX_DB_PASS}

MariaDB Root Password: ${ZABBIX_ROOT_PASS}

Zabbix Version: ${ZABBIX_VERSION}
Ubuntu Version: ${UBUNTU_VERSION}
CREDS
    chmod 600 "$SAVE_CREDS_FILE"
    print_info "Credentials saved to $SAVE_CREDS_FILE (chmod 600)"
fi

echo
echo "====================== INSTALLATION COMPLETE ======================"
echo -e "${GREEN}✅ Zabbix ${ZABBIX_VERSION} is successfully installed!${NC}"
echo
echo -e "${RED}⚠️  IMPORTANT: SAVE THESE CREDENTIALS NOW. THEY WILL NOT BE SHOWN AGAIN!${NC}"
echo "-------------------------------------------------------------------"
echo -e "${GREEN}🌐 Web interface:${NC} http://${SERVER_ADDR}/zabbix"
if [[ "$SKIP_SSL" != true ]]; then
    echo -e "${GREEN}🔒 HTTPS interface:${NC} https://${SERVER_ADDR}/zabbix (self-signed cert)"
fi
echo -e "${GREEN}🔑 Zabbix Web Login:${NC} Admin / ${ZABBIX_ADMIN_PASS}"
echo "🔐 Database User: zabbix"
echo "🔐 Database Pass: ${ZABBIX_DB_PASS}"
echo "🔐 MariaDB Root Pass: ${ZABBIX_ROOT_PASS}"
echo "-------------------------------------------------------------------"
echo -e "${GREEN}👌 Enjoy your fully automated Zabbix installation!${NC}"
echo "==================================================================="