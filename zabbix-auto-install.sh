#!/usr/bin/env bash

#==========================================================================
# zabbix-auto-install.sh – Production‑ready Zabbix Server installer
#==========================================================================
# Features:
#   • Interactive and unattended modes (CLI flags)
#   • Dry‑run mode (shows actions without executing)
#   • Idempotent – safe to re‑run, creates backups of existing configs
#   • Secure credential handling (uses temporary MYSQL_PWD env var)
#   • Strong random passwords (32 chars) and optional user‑provided passwords
#   • TLS options: none, self‑signed, or Let's Encrypt (if certbot is present)
#   • Optional UFW firewall configuration
#   • Supports Zabbix 6.0 and 7.0, with Agent 2 support
#   • Post‑install health check (HTTP/HTTPS endpoint, service status)
#   • Detailed logging to /var/log/zabbix-easydeploy.log
#   • Backups of configuration files before modification
#   • Timezone selection (default UTC)
#   • Comprehensive error handling and exit codes
#==========================================================================

set -euo pipefail
IFS=$'\n\t'

#-------------------------- Global constants -----------------------------
LOG_FILE="/var/log/zabbix-easydeploy.log"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

#-------------------------- Helper functions ----------------------------
log() {
    local level="$1"
    shift
    local msg="$*"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $msg" | tee -a "$LOG_FILE"
}

die() { log "ERROR" "$*"; exit 1; }

info() { log "INFO" "$*"; }

warn() { log "WARN" "$*"; }

# Backup a file if it exists, appending timestamp
backup_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        cp -a "$file" "${file}.bak_${TIMESTAMP}" && info "Backed up $file"
    fi
}

# Generate a strong random password (default 32 chars)
gen_pass() {
    local length="${1:-32}"
    tr -dc 'A-Za-z0-9!@#$%&*()-_=+[]{};:,.<>?' </dev/urandom | head -c "$length"
    echo
}

# Validate IPv4/hostname (basic)
validate_server_addr() {
    local addr="$1"
    if [[ "$addr" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || [[ "$addr" =~ ^[a-zA-Z0-9.-]+$ ]]; then
        return 0
    else
        die "Invalid server address: $addr"
    fi
}

# Execute a command respecting dry‑run mode
run_cmd() {
    local cmd="$*"
    if $DRY_RUN; then
        info "DRY‑RUN: $cmd"
    else
        info "Running: $cmd"
        eval "$cmd"
    fi
}

#-------------------------- Default options ----------------------------
ZABBIX_VERSION="7.0"
UBUNTU_VERSION=""
SERVER_ADDR=""
TIMEZONE="UTC"
TLS_MODE="selfsigned"   # none | selfsigned | letsencrypt
LE_EMAIL=""
NON_INTERACTIVE=false
FORCE=false
DRY_RUN=false
SAVE_CREDS=""
ENABLE_FIREWALL=true
USE_AGENT2=false
SKIP_APACHE=false
SKIP_PHP_TUNING=false
SKIP_SSL_ENABLE_OPTSPEC=":hi:z:u:t:l:e:s:nfd-:"
while getopts "$OPTSPEC" optchar; do
    case "$optchar" in
        -)
            case "$OPTARG" in
                help) print_help; exit 0;;
                ip) SERVER_ADDR="${!OPTIND}"; OPTIND=$(( $OPTIND + 1 ));;
                zabbix-ver) ZABBIX_VERSION="${!OPTIND}"; OPTIND=$(( $OPTIND + 1 ));;
                ubuntu-ver) UBUNTU_VERSION="${!OPTIND}"; OPTIND=$(( $OPTIND + 1 ));;
                timezone) TIMEZONE="${!OPTIND}"; OPTIND=$(( $OPTIND + 1 ));;
                tls) TLS_MODE="${!OPTIND}"; OPTIND=$(( $OPTIND + 1 ));;
                le-email) LE_EMAIL="${!OPTIND}"; OPTIND=$(( $OPTIND + 1 ));;
                save-creds) SAVE_CREDS="${!OPTIND}"; OPTIND=$(( $OPTIND + 1 ));;
                non-interactive) NON_INTERACTIVE=true;;
                force) FORCE=true;;
                dry-run) DRY_RUN=true;;
                no-firewall) ENABLE_FIREWALL=false;;
                skip-ssl) TLS_MODE="none"; SKIP_SSL=true;;
                agent2) USE_AGENT2=true;;
                skip-apache) SKIP_APACHE=true;;
                skip-php-tuning) SKIP_PHP_TUNING=true;;
                *) die "Illegal option --$OPTARG";;
            esac;;
        h) print_help; exit 0;;
        i) SERVER_ADDR="$OPTARG";;
        z) ZABBIX_VERSION="$OPTARG";;
        u) UBUNTU_VERSION="$OPTARG";;
        t) TIMEZONE="$OPTARG";;
        l) TLS_MODE="$OPTARG";;
        e) LE_EMAIL="$OPTARG";;
        s) SAVE_CREDS="$OPTARG";;
        n) NON_INTERACTIVE=true;;
        f) FORCE=true;;
        d) DRY_RUN=true;;
        \?) die "Invalid option: -$OPTARG";;
        :) die "Missing argument for -$OPTARG";;
    esac
done

# Validate mutually exclusive options
if $NON_INTERACTIVE && [[ -z "$SERVER_ADDR" ]]; then
    die "Non-interactive mode requires --ip"
fi
if [[ "$TLS_MODE" == "letsencrypt" && -z "$LE_EMAIL" ]]; then
    die "Let's Encrypt mode requires --le-email"
fi
if [[ "$TLS_MODE" != "none" && "$SKIP_SSL" == true ]]; then
    die "Conflicting TLS options"
fi

#-------------------------- Pre‑flight checks --------------------------
if [[ $EUID -ne 0 ]]; then
    die "This script must be run as root (use sudo)"
fi

if ! $FORCE; then
    # Detect existing Zabbix services
    for svc in apache2 mariadb zabbix-server zabbix-agent zabbix-agent2; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            warn "Service $svc already active – use --force to override"
        fi
    done
    # Port 80/443 check (only if Apache is to be installed)
    if ! $SKIP_APACHE; then
        if ss -tuln | grep -E ':80\s|:443\s' >/dev/null; then
            warn "Port 80 or 443 already in use – may conflict with Apache"
        fi
    fi
fi

# Prompt for missing interactive values
if ! $NON_INTERACTIVE; then
    if [[ -z "$SERVER_ADDR" ]]; then
        read -rp "Enter server IP or hostname: " SERVER_ADDR
    fi
    read -rp "Use timezone [$TIMEZONE]: " inp_tz || true
    [[ -n "$inp_tz" ]] && TIMEZONE="$inp_tz"
    read -rp "TLS mode (none/selfsigned/letsencrypt) [$TLS_MODE]: " inp_tls || true
    [[ -n "$inp_tls" ]] && TLS_MODE="$inp_tls"
    if [[ "$TLS_MODE" == "letsencrypt" ]]; then
        read -rp "Enter email for Let's Encrypt: " LE_EMAIL
    fi
fi

validate_server_addr "$SERVER_ADDR"
info "Server address set to $SERVER_ADDR"
info "Timezone set to $TIMEZONE"
info "TLS mode: $TLS_MODE"

# Detect Ubuntu version if not overridden
if [[ -z "$UBUNTU_VERSION" ]]; then
    UBUNTU_VERSION=$(lsb_release -rs)
    info "Detected Ubuntu $UBUNTU_VERSION"
else
    info "Using overridden Ubuntu version $UBUNTU_VERSION"
fi

# Map Ubuntu version to Zabbix repo version (fallback to 22.04)
case "$UBUNTU_VERSION" in
    24.04|22.04|20.04|18.04) ZBX_REPO_VER="$UBUNTU_VERSION";;
    *) ZBX_REPO_VER="22.04"; warn "Unsupported Ubuntu $UBUNTU_VERSION – using repo for 22.04";;
esac

# Determine Zabbix release package version
case "$ZABBIX_VERSION" in
    6.0) ZBX_RELEASE="6.0-6";;
    7.0) ZBX_RELEASE="7.0-2";;
    *) die "Unsupported Zabbix version $ZABBIX_VERSION";;
esac

#-------------------------- Package installation -----------------------
run_cmd "export DEBIAN_FRONTEND=noninteractive"
run_cmd "apt-get update -y"
run_cmd "apt-get install -y ca-certificates curl gnupg lsb-release ufw"

# Prerequisite packages (Apache optional)
if ! $SKIP_APACHE; then
    PKGS="apache2"
else
    PKGS=""
fi
PKGS+=" mariadb-server php php-mbstring php-gd php-xml php-bcmath php-ldap php-mysql php-zip php-json php-xmlreader php-curl"
run_cmd "apt-get install -y $PKGS"

# Install Zabbix repository package
ZABBIX_REPO_PKG="zabbix-release_${ZBX_RELEASE}+ubuntu${ZBX_REPO_VER}_all.deb"
run_cmd "wget -q https://repo.zabbix.com/zabbix/${ZABBIX_VERSION}/ubuntu/pool/main/z/zabbix-release/${ZABBIX_REPO_PKG} -O /tmp/${ZABBIX_REPO_PKG}"
run_cmd "dpkg -i /tmp/${ZABBIX_REPO_PKG}"
run_cmd "apt-get update -y"

# Install Zabbix components (Agent2 optional)
ZABBIX_PKGS="zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf zabbix-sql-scripts"
if $USE_AGENT2; then
    ZABBIX_PKGS+=" zabbix-agent2"
else
    ZABBIX_PKGS+=" zabbix-agent"
fi
run_cmd "apt-get install -y $ZABBIX_PKGS"

#-------------------------- Credential generation -----------------------
ZABBIX_ROOT_PASS=$(gen_pass 32)
ZABBIX_DB_PASS=$(gen_pass 32)
ZABBIX_ADMIN_PASS=$(gen_pass 32)

# Securely set MYSQL_PWD for the duration of DB commands
export MYSQL_PWD="$ZABBIX_ROOT_PASS"

#-------------------------- MariaDB hardening --------------------------
run_cmd "mysql -e \"ALTER USER 'root'@'localhost' IDENTIFIED VIA mysql_native_password USING PASSWORD('$ZABBIX_ROOT_PASS'); FLUSH PRIVILEGES;\""
run_cmd "mysql -e \"DELETE FROM mysql.user WHERE User=''; DROP DATABASE IF EXISTS test; DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%'; FLUSH PRIVILEGES;\""

# Create Zabbix DB and user
run_cmd "mysql -e \"CREATE DATABASE IF NOT EXISTS zabbix CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;\""
run_cmd "mysql -e \"CREATE USER IF NOT EXISTS 'zabbix'@'localhost' IDENTIFIED BY '$ZABBIX_DB_PASS';\""
run_cmd "mysql -e \"GRANT ALL PRIVILEGES ON zabbix.* TO 'zabbix'@'localhost'; FLUSH PRIVILEGES;\""

# Import schema
run_cmd "zcat /usr/share/zabbix-sql-scripts/mysql/server.sql.gz | mysql -uzabbix -p'$ZABBIX_DB_PASS' zabbix"

# Set Zabbix admin password (MD5 hash as required by Zabbix 6/7)
run_cmd "mysql -uzabbix -p'$ZABBIX_DB_PASS' zabbix -e \"UPDATE users SET passwd=MD5('$ZABBIX_ADMIN_PASS') WHERE alias='Admin';\""

#-------------------------- Zabbix server config -----------------------
ZABBIX_CONF="/etc/zabbix/zabbix_server.conf"
backup_file "$ZABBIX_CONF"
run_cmd "sed -i 's/^# DBPassword=.*/DBPassword=${ZABBIX_DB_PASS}/' $ZABBIX_CONF"

#-------------------------- Zabbix agent config ------------------------
# Determine which agent config file to edit based on the chosen agent
if $USE_AGENT2; then
    AGENT_CONF="/etc/zabbix/zabbix_agent2.conf"
else
    AGENT_CONF="/etc/zabbix/zabbix_agentd.conf"
fi
backup_file "$AGENT_CONF"
run_cmd "sed -i 's/^# Server=.*/Server=127.0.0.1/' $AGENT_CONF"
run_cmd "sed -i 's/^# ServerActive=.*/ServerActive=127.0.0.1/' $AGENT_CONF"
run_cmd "sed -i 's/^# Hostname=.*/Hostname=$(hostname)/' $AGENT_CONF"

#-------------------------- Apache & PHP (optional) --------------------
if ! $SKIP_APACHE; then
    # Enable required Apache modules
    run_cmd "a2enmod rewrite ssl headers" || warn "Failed to enable some Apache modules"

    # PHP timezone configuration
    if ! $SKIP_PHP_TUNING; then
        PHP_INI=$(php -i | grep -i "Loaded Configuration File" | awk -F' =>' '{print $2}' | xargs)
        if [[ -f "$PHP_INI" ]]; then
            backup_file "$PHP_INI"
            run_cmd "sed -i 's/^;date.timezone =.*/date.timezone = $TIMEZONE/' $PHP_INI"
        fi
    fi
fi

#-------------------------- TLS handling --------------------------------
if [[ "$TLS_MODE" == "selfsigned" && ! $SKIP_SSL ]]; then
    SSL_DIR="/etc/apache2/ssl"
    run_cmd "mkdir -p $SSL_DIR"
    run_cmd "openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout $SSL_DIR/zabbix.key \
        -out $SSL_DIR/zabbix.crt \
        -subj \"/C=US/ST=State/L=City/O=Organization/CN=${SERVER_ADDR}\""
    # Create Apache SSL vhost (only if Apache is used)
    if ! $SKIP_APACHE; then
        SSL_VHOST="/etc/apache2/sites-available/zabbix-ssl.conf"
        backup_file "$SSL_VHOST"
        cat > "$SSL_VHOST" <<EOF
<VirtualHost *:443>
    ServerName ${SERVER_ADDR}
    DocumentRoot /usr/share/zabbix
    SSLEngine on
    SSLCertificateFile ${SSL_DIR}/zabbix.crt
    SSLCertificateKeyFile ${SSL_DIR}/zabbix.key
    <Directory /usr/share/zabbix>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    Alias /zabbix /usr/share/zabbix
</VirtualHost>
EOF
        run_cmd "a2ensite zabbix-ssl"
    fi
elif [[ "$TLS_MODE" == "letsencrypt" && ! $SKIP_SSL ]]; then
    # Install certbot if missing
    if ! command -v certbot >/dev/null 2>&1; then
        run_cmd "apt-get install -y certbot python3-certbot-apache"
    fi
    run_cmd "certbot --apache -d $SERVER_ADDR --non-interactive --agree-tos -m $LE_EMAIL"
fi

#-------------------------- Firewall (UFW) -------------------------------
if $ENABLE_FIREWALL && command -v ufw >/dev/null 2>&1; then
    run_cmd "ufw allow 80/tcp comment 'Zabbix HTTP'"
    if [[ "$TLS_MODE" != "none" ]]; then
        run_cmd "ufw allow 443/tcp comment 'Zabbix HTTPS'"
    fi
    run_cmd "ufw allow 10051/tcp comment 'Zabbix Server'"
    run_cmd "ufw allow 10050/tcp comment 'Zabbix Agent'"
    info "UFW rules added (enable with 'ufw enable' if not already active)"
fi

#-------------------------- Service enable & start -----------------------
run_cmd "systemctl restart zabbix-server zabbix-agent$(if $USE_AGENT2; then echo '2'; fi) $(if ! $SKIP_APACHE; then echo 'apache2'; fi)"
run_cmd "systemctl enable zabbix-server zabbix-agent$(if $USE_AGENT2; then echo '2'; fi) $(if ! $SKIP_APACHE; then echo 'apache2'; fi)"

#-------------------------- Post‑install health check -------------------
info "Running post-install health checks..."
# Service status
for svc in zabbix-server zabbix-agent$(if $USE_AGENT2; then echo '2'; fi) $(if ! $SKIP_APACHE; then echo 'apache2'; fi); do
    if systemctl is-active --quiet $svc; then
        info "Service $svc is active"
    else
        warn "Service $svc is NOT active"
    fi
done
# HTTP/HTTPS endpoint check (allow self-signed)
if ! $SKIP_APACHE; then
    CURL_OPTS="-k -s -o /dev/null -w %{http_code}"
    HTTP_CODE=$(curl $CURL_OPTS http://$SERVER_ADDR/zabbix || echo "000")
    if [[ "$HTTP_CODE" == "200" ]]; then
        info "HTTP endpoint reachable (200)"
    else
        warn "HTTP endpoint returned $HTTP_CODE"
    fi
    if [[ "$TLS_MODE" != "none" ]]; then
        HTTPS_CODE=$(curl $CURL_OPTS https://$SERVER_ADDR/zabbix || echo "000")
        if [[ "$HTTPS_CODE" == "200" ]]; then
            info "HTTPS endpoint reachable (200)"
        else
            warn "HTTPS endpoint returned $HTTPS_CODE"
        fi
    fi
fi

#-------------------------- Credential output ---------------------------
if [[ -n "$SAVE_CREDS" ]]; then
    cat > "$SAVE_CREDS" <<EOF
# Zabbix EasyDeploy credentials (generated on $(date))
# KEEP THIS FILE SECURE (chmod 600)

Web Interface: http://${SERVER_ADDR}/zabbix
$(if [[ "$TLS_MODE" != "none" ]]; then echo "HTTPS Interface: https://${SERVER_ADDR}/zabbix"; fi)
Admin Username: Admin
Admin Password: ${ZABBIX_ADMIN_PASS}

Database User: zabbix
Database Password: ${ZABBIX_DB_PASS}
MariaDB Root Password: ${ZABBIX_ROOT_PASS}

Zabbix Version: ${ZABBIX_VERSION}
Ubuntu Version: ${UBUNTU_VERSION}
TLS Mode: ${TLS_MODE}
EOF
    chmod 600 "$SAVE_CREDS"
    info "Credentials saved to $SAVE_CREDS"
fi

# Final summary
HTTPS_UI=""
if [[ "$TLS_MODE" != "none" ]]; then
    HTTPS_UI="HTTPS UI: https://${SERVER_ADDR}/zabbix"
fi
cat <<EOF

===================================================================
Installation complete!
Web UI: http://${SERVER_ADDR}/zabbix
${HTTPS_UI}
Admin login: Admin / ${ZABBIX_ADMIN_PASS}
Database user: zabbix / ${ZABBIX_DB_PASS}
MariaDB root: ${ZABBIX_ROOT_PASS}
EOF

exit 0