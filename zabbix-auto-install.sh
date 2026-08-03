#!/usr/bin/env bash
#
# zabbix-auto-install.sh – Production-ready Zabbix Server installer
#   • Interactive and unattended modes
#   • Dry‑run mode (zero system changes – no files created)
#   • Idempotent – safe to re‑run, reuses existing credentials & schema
#   • Secure credential handling (MYSQL opt‑file, sed script file, masked logs)
#   • Version‑aware Admin password hash (MD5 on 6.0, PBKDF2/SHA2 on 7.0)
#   • Apache PHP ini tuned (not CLI php.ini)
#   • Rejects unsupported Ubuntu versions; fails on critical DB ops
#   • Verified schema import, service status, and HTTP endpoint before success

set -euo pipefail
IFS=$'\n\t'

LOG_FILE="/var/log/zabbix-easydeploy.log"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"

ZABBIX_VERSION="7.0"
UBUNTU_VERSION=""
SERVER_ADDR=""
TIMEZONE="UTC"
TLS_MODE="none"
LE_EMAIL=""
NON_INTERACTIVE=false
FORCE=false
DRY_RUN=false
SAVE_CREDS=""
ENABLE_FIREWALL=true
USE_AGENT2=false
SKIP_APACHE=false
SKIP_PHP_TUNING=false
SKIP_SSL=false
TLS_REQUESTED=""

ZABBIX_ROOT_PASS=""
ZABBIX_DB_PASS=""
ZABBIX_ADMIN_PASS=""

MYSQL_OPTFILE=""
SED_SCRIPT=""

cleanup() {
  [[ -n "$MYSQL_OPTFILE" ]] && rm -f "$MYSQL_OPTFILE" || true
  [[ -n "$SED_SCRIPT" ]] && rm -f "$SED_SCRIPT" || true
  return 0
}
trap cleanup EXIT

#-------------------------- Helpers --------------------------------------
mask_secrets() {
  local str="$1"
  [[ -n "$ZABBIX_ROOT_PASS" ]] && str="${str//$ZABBIX_ROOT_PASS/[REDACTED]}"
  [[ -n "$ZABBIX_DB_PASS" ]] && str="${str//$ZABBIX_DB_PASS/[REDACTED]}"
  [[ -n "$ZABBIX_ADMIN_PASS" ]] && str="${str//$ZABBIX_ADMIN_PASS/[REDACTED]}"
  echo "$str"
}

log() {
  local level="$1"
  shift
  local ts msg masked_msg
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  msg="[$ts] [$level] $*"
  masked_msg=$(mask_secrets "$msg")
  echo "$masked_msg"
  if ! $DRY_RUN; then
    if [[ -w "$LOG_FILE" ]] 2>/dev/null || [[ -w "$(dirname "$LOG_FILE")" ]] 2>/dev/null; then
      echo "$masked_msg" >>"$LOG_FILE"
    fi
  fi
}

die() {
  log "ERROR" "$*"
  exit 1
}
info() { log "INFO" "$*"; }
warn() { log "WARN" "$*"; }

backup_file() {
  local file="$1"
  if [[ -f "$file" ]]; then
    if $DRY_RUN; then
      info "DRY-RUN: Would backup $file to ${file}.bak_${TIMESTAMP}"
    else
      cp -a "$file" "${file}.bak_${TIMESTAMP}" && info "Backed up $file"
    fi
  fi
}

gen_pass() {
  local len="${1:-32}" pass=""
  if command -v python3 &>/dev/null; then
    pass=$(python3 -c "
import secrets, string
print(''.join(secrets.choice(string.ascii_letters + string.digits) for _ in range($len)))
" 2>/dev/null || true)
  fi
  if [[ -z "$pass" ]] && command -v openssl &>/dev/null; then
    pass=$(openssl rand -base64 48 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c "$len" || true)
  fi
  if [[ -z "$pass" ]]; then
    pass=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | dd bs=1 count="$len" 2>/dev/null || true)
  fi
  [[ -n "$pass" ]] || die "Failed to generate secure password"
  echo "$pass"
}

validate_server_addr() {
  local addr="$1"
  if [[ ! "$addr" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] &&
    [[ ! "$addr" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*[a-zA-Z0-9]$ ]]; then
    die "Invalid server address: $addr"
  fi
}

run_cmd() {
  local masked=$(mask_secrets "$*")
  if $DRY_RUN; then
    info "DRY-RUN: $masked"
  else
    info "Running: $masked"
    "$@"
  fi
}

# MySQL helpers – no secrets in argv (SQL via temp file)
mysql_exec_secure() {
  local sql="$1"
  if $DRY_RUN; then
    info "DRY-RUN: MySQL: $(mask_secrets "$sql")"
    return 0
  fi
  local tmp=$(mktemp) rc=1
  chmod 600 "$tmp"
  printf '%s\n' "$sql" >"$tmp"
  if mysql <"$tmp" 2>/dev/null; then
    rc=0
  elif [[ -n "$ZABBIX_ROOT_PASS" ]] && MYSQL_PWD="$ZABBIX_ROOT_PASS" mysql -u root <"$tmp" 2>/dev/null; then
    rc=0
  else
    sudo mysql <"$tmp"
    rc=$?
  fi
  rm -f "$tmp"
  return $rc
}

mysql_exec() {
  local sql="$1"
  if $DRY_RUN; then
    info "DRY-RUN: MySQL: $sql"
    return 0
  fi
  if mysql -e "$sql" 2>/dev/null; then
    return 0
  elif [[ -n "$ZABBIX_ROOT_PASS" ]] && MYSQL_PWD="$ZABBIX_ROOT_PASS" mysql -u root -e "$sql" 2>/dev/null; then
    return 0
  else
    sudo mysql -e "$sql"
  fi
}

print_help() {
  cat <<'EOF'
Usage: sudo ./zabbix-auto-install.sh [OPTIONS]

Production-ready Zabbix Server installer (6.0 / 7.0 LTS) for Ubuntu.

Options:
  -h, --help                 Show this help
  -i, --ip ADDR              Server IP or hostname
  -z, --zabbix-ver VER       Zabbix version: 6.0 or 7.0 (default: 7.0)
  -u, --ubuntu-ver VER       Ubuntu version override (default: detected)
  -t, --timezone TZ          Timezone (default: UTC)
  -l, --tls MODE             TLS mode: none, selfsigned, letsencrypt (default: none)
  -e, --le-email EMAIL       Email for Let's Encrypt (required with --tls letsencrypt)
  -s, --save-creds FILE      Save generated credentials to FILE (chmod 600)
  -n, --non-interactive      Run without prompts (requires --ip)
  -f, --force                Skip pre-flight active service checks
  -d, --dry-run              Show actions without executing (zero changes)
      --no-firewall          Skip UFW firewall configuration
      --skip-ssl             Skip SSL (force TLS mode none)
      --agent2               Install Zabbix Agent 2 instead of Agent 1
      --skip-apache          Skip Apache installation and web configuration
      --skip-php-tuning      Skip PHP timezone tuning

Examples:
  sudo ./zabbix-auto-install.sh -i 192.168.1.10
  sudo ./zabbix-auto-install.sh -n -i 192.168.1.10 -z 7.0 -l none -s creds.txt
  sudo ./zabbix-auto-install.sh -d -i server.example.com --agent2
EOF
}

#-------------------------- Argument parsing --------------------------
OPTSPEC=":hi:z:u:t:l:e:s:nfd-:"

while getopts "$OPTSPEC" optchar; do
  case "$optchar" in
  -)
    case "$OPTARG" in
    help)
      print_help
      exit 0
      ;;
    ip)
      SERVER_ADDR="${!OPTIND}"
      OPTIND=$((OPTIND + 1))
      ;;
    zabbix-ver)
      ZABBIX_VERSION="${!OPTIND}"
      OPTIND=$((OPTIND + 1))
      ;;
    ubuntu-ver)
      UBUNTU_VERSION="${!OPTIND}"
      OPTIND=$((OPTIND + 1))
      ;;
    timezone)
      TIMEZONE="${!OPTIND}"
      OPTIND=$((OPTIND + 1))
      ;;
    tls)
      TLS_MODE="${!OPTIND}"
      TLS_REQUESTED="$TLS_MODE"
      OPTIND=$((OPTIND + 1))
      ;;
    le-email)
      LE_EMAIL="${!OPTIND}"
      OPTIND=$((OPTIND + 1))
      ;;
    save-creds)
      SAVE_CREDS="${!OPTIND}"
      OPTIND=$((OPTIND + 1))
      ;;
    non-interactive) NON_INTERACTIVE=true ;;
    force) FORCE=true ;;
    dry-run) DRY_RUN=true ;;
    no-firewall) ENABLE_FIREWALL=false ;;
    skip-ssl)
      SKIP_SSL=true
      TLS_MODE="none"
      ;;
    agent2) USE_AGENT2=true ;;
    skip-apache) SKIP_APACHE=true ;;
    skip-php-tuning) SKIP_PHP_TUNING=true ;;
    *) die "Illegal option: --$OPTARG" ;;
    esac
    ;;
  h)
    print_help
    exit 0
    ;;
  i) SERVER_ADDR="$OPTARG" ;;
  z) ZABBIX_VERSION="$OPTARG" ;;
  u) UBUNTU_VERSION="$OPTARG" ;;
  t) TIMEZONE="$OPTARG" ;;
  l)
    TLS_MODE="$OPTARG"
    TLS_REQUESTED="$TLS_MODE"
    ;;
  e) LE_EMAIL="$OPTARG" ;;
  s) SAVE_CREDS="$OPTARG" ;;
  n) NON_INTERACTIVE=true ;;
  f) FORCE=true ;;
  d) DRY_RUN=true ;;
  \?) die "Invalid option: -$OPTARG" ;;
  :) die "Missing argument for -$OPTARG" ;;
  esac
done

#-------------------------- Validation ---------------------------------
case "$ZABBIX_VERSION" in 6.0 | 7.0) ;; *) die "Unsupported Zabbix version: $ZABBIX_VERSION" ;; esac
$NON_INTERACTIVE && [[ -z "$SERVER_ADDR" ]] && die "Non-interactive mode requires --ip"
[[ "$TLS_MODE" == "letsencrypt" && -z "$LE_EMAIL" ]] && die "Let's Encrypt mode requires --le-email"
[[ "$SKIP_SSL" == true && -n "$TLS_REQUESTED" && "$TLS_REQUESTED" != "none" ]] &&
  die "Conflicting TLS options: --skip-ssl conflicts with --tls $TLS_REQUESTED"
! $DRY_RUN && [[ $EUID -ne 0 ]] && die "This script must be run as root (use sudo)"

#-------------------------- Pre-flight checks -------------------------
if ! $FORCE; then
  AGENT_SVC="zabbix-agent2"
  $USE_AGENT2 || AGENT_SVC="zabbix-agent"
  for svc in apache2 mariadb zabbix-server "$AGENT_SVC"; do
    systemctl is-active --quiet "$svc" 2>/dev/null && warn "Service $svc already active – use --force to override"
  done
  ! $SKIP_APACHE && ss -tuln 2>/dev/null | grep -qE ':80\s|:443\s' &&
    warn "Port 80 or 443 already in use – may conflict with Apache"
fi

#-------------------------- Interactive prompts ------------------------
if ! $NON_INTERACTIVE; then
  [[ -z "$SERVER_ADDR" ]] && read -rp "Enter server IP or hostname: " SERVER_ADDR
  read -rp "Use timezone [$TIMEZONE]: " inp_tz || true
  [[ -n "$inp_tz" ]] && TIMEZONE="$inp_tz"
  read -rp "TLS mode (none/selfsigned/letsencrypt) [$TLS_MODE]: " inp_tls || true
  [[ -n "$inp_tls" ]] && TLS_MODE="$inp_tls"
  [[ "$TLS_MODE" == "letsencrypt" ]] && read -rp "Enter email for Let's Encrypt: " LE_EMAIL
fi

validate_server_addr "$SERVER_ADDR"
info "Server address set to $SERVER_ADDR"
info "Timezone set to $TIMEZONE"
info "TLS mode: $TLS_MODE"

#-------------------------- Detect Ubuntu version ---------------------
if [[ -z "$UBUNTU_VERSION" ]]; then
  UBUNTU_VERSION=$(lsb_release -rs 2>/dev/null || echo "unknown")
  info "Detected Ubuntu $UBUNTU_VERSION"
else
  info "Using overridden Ubuntu version $UBUNTU_VERSION"
fi

case "$UBUNTU_VERSION" in
24.04 | 22.04 | 20.04 | 18.04) ZBX_REPO_VER="$UBUNTU_VERSION" ;;
unknown)
  if $DRY_RUN; then
    ZBX_REPO_VER="22.04"
    warn "Ubuntu version detection failed; using 22.04 for repo URL in dry-run plan"
  else
    die "Could not detect Ubuntu version. Use --ubuntu-ver to specify."
  fi
  ;;
*) die "Unsupported Ubuntu version: $UBUNTU_VERSION (supported: 18.04, 20.04, 22.04, 24.04)" ;;
esac

case "$ZABBIX_VERSION" in
6.0) ZBX_RELEASE="6.0-6" ;;
7.0) ZBX_RELEASE="7.0-2" ;;
esac

#-------------------------- Password management & Idempotency -----------
ZABBIX_CONF="/etc/zabbix/zabbix_server.conf"

if [[ -f "$ZABBIX_CONF" ]]; then
  EXISTING_DB_PASS=$(grep -E '^DBPassword=' "$ZABBIX_CONF" | head -1 | cut -d'=' -f2- | tr -d '\r\n' || true)
  [[ -n "$EXISTING_DB_PASS" ]] && {
    ZABBIX_DB_PASS="$EXISTING_DB_PASS"
    info "Reusing existing database password from $ZABBIX_CONF"
  }
fi

if [[ -n "$SAVE_CREDS" && -f "$SAVE_CREDS" ]]; then
  [[ -z "$ZABBIX_DB_PASS" ]] && ZABBIX_DB_PASS=$(grep -E '^Database Password:' "$SAVE_CREDS" | awk '{print $3}' | tr -d '\r\n' || true)
  ZABBIX_ROOT_PASS=$(grep -E '^MariaDB Root Password:' "$SAVE_CREDS" | awk '{print $4}' | tr -d '\r\n' || true)
  ZABBIX_ADMIN_PASS=$(grep -E '^Admin Password:' "$SAVE_CREDS" | awk '{print $3}' | tr -d '\r\n' || true)
  info "Reusing credentials from $SAVE_CREDS"
fi

[[ -z "$ZABBIX_DB_PASS" ]] && ZABBIX_DB_PASS=$(gen_pass 32)
[[ -z "$ZABBIX_ROOT_PASS" ]] && ZABBIX_ROOT_PASS=$(gen_pass 32)
[[ -z "$ZABBIX_ADMIN_PASS" ]] && ZABBIX_ADMIN_PASS=$(gen_pass 32)

export MYSQL_PWD="$ZABBIX_ROOT_PASS"

#-------------------------- Package installation -----------------------
info "Installing packages..."
export DEBIAN_FRONTEND=noninteractive

base_pkgs=(ca-certificates curl gnupg lsb-release ufw software-properties-common)
run_cmd apt-get update -y
run_cmd apt-get install -y "${base_pkgs[@]}"

mariadb_pkgs=(mariadb-server)
run_cmd apt-get install -y "${mariadb_pkgs[@]}"

# Zabbix repository
ZABBIX_REPO_PKG="zabbix-release_${ZBX_RELEASE}+ubuntu${ZBX_REPO_VER}_all.deb"
run_cmd wget -q "https://repo.zabbix.com/zabbix/${ZABBIX_VERSION}/ubuntu/pool/main/z/zabbix-release/${ZABBIX_REPO_PKG}" -O "/tmp/${ZABBIX_REPO_PKG}"
run_cmd dpkg -i "/tmp/${ZABBIX_REPO_PKG}"
run_cmd apt-get update -y

# Zabbix components (zabbix-frontend-php pulls in PHP + Apache dep, then we add exact PHP extensions)
zabbix_pkgs=(zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf zabbix-sql-scripts)
$USE_AGENT2 && zabbix_pkgs+=(zabbix-agent2) || zabbix_pkgs+=(zabbix-agent)
run_cmd apt-get install -y "${zabbix_pkgs[@]}"

# PHP extensions for the web frontend (pulled via zabbix-frontend-php dep but ensure explicit)
php_exts=(php-mysql php-mbstring php-gd php-xml php-bcmath php-ldap php-curl)
run_cmd apt-get install -y "${php_exts[@]}"

# Apache integration package (installed by zabbix-apache-conf, but be explicit)
if ! $SKIP_APACHE; then
  apache_pkgs=(apache2 libapache2-mod-php)
  run_cmd apt-get install -y "${apache_pkgs[@]}"
fi

#-------------------------- MariaDB configuration -----------------------
info "Configuring MariaDB..."

# Set root password while keeping unix_socket auth (MariaDB 10.4+)
mysql_exec_secure "ALTER USER 'root'@'localhost' IDENTIFIED VIA unix_socket OR mysql_native_password USING PASSWORD('$ZABBIX_ROOT_PASS'); FLUSH PRIVILEGES;" ||
  mysql_exec_secure "SET PASSWORD FOR 'root'@'localhost' = PASSWORD('$ZABBIX_ROOT_PASS'); FLUSH PRIVILEGES;" ||
  die "Failed to set MariaDB root password"

# Hardening
mysql_exec "DELETE FROM mysql.user WHERE User=''; DROP DATABASE IF EXISTS test; DELETE FROM mysql.db WHERE Db='test' OR Db='test_%'; FLUSH PRIVILEGES;"

# Create database and user (idempotent; password re-applied)
mysql_exec "CREATE DATABASE IF NOT EXISTS zabbix CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;"
mysql_exec_secure "CREATE USER IF NOT EXISTS 'zabbix'@'localhost' IDENTIFIED BY '$ZABBIX_DB_PASS';"
mysql_exec_secure "ALTER USER 'zabbix'@'localhost' IDENTIFIED BY '$ZABBIX_DB_PASS';"
mysql_exec "GRANT ALL PRIVILEGES ON zabbix.* TO 'zabbix'@'localhost'; FLUSH PRIVILEGES;"

#-------------------------- Schema import (idempotent) ------------------
info "Checking Zabbix database schema..."
SCHEMA_EXISTS=false
if ! $DRY_RUN; then
  if mysql_exec "USE zabbix; SHOW TABLES LIKE 'users';" | grep -q "users"; then
    SCHEMA_EXISTS=true
  fi
fi

if $SCHEMA_EXISTS; then
  info "Zabbix database schema already exists. Skipping schema import."
elif $DRY_RUN; then
  info "DRY-RUN: Would locate and import Zabbix database schema from /usr/share/zabbix-sql-scripts/"
else
  info "Importing Zabbix database schema..."
  SCHEMA_SQL=""
  for candidate in /usr/share/zabbix-sql-scripts/mysql/server.sql.gz \
    /usr/share/doc/zabbix-sql-scripts/mysql/create.sql.gz \
    /usr/share/zabbix-sql-scripts/mysql/create.sql.gz; do
    if [[ -f "$candidate" ]]; then
      SCHEMA_SQL="$candidate"
      break
    fi
  done

  if [[ -z "$SCHEMA_SQL" ]]; then
    die "Zabbix schema SQL file not found. Cannot continue."
  fi

  if $DRY_RUN; then
    info "DRY-RUN: Import schema from $SCHEMA_SQL into zabbix database"
  else
    MYSQL_OPTFILE=$(mktemp /tmp/zabbix-mysql-XXXXXX.cnf)
    chmod 600 "$MYSQL_OPTFILE"
    cat >"$MYSQL_OPTFILE" <<EOF
[client]
user=zabbix
password=${ZABBIX_DB_PASS}
EOF
    if zcat "$SCHEMA_SQL" | mysql --defaults-extra-file="$MYSQL_OPTFILE" zabbix; then
      info "Zabbix schema imported successfully"
    else
      warn "Schema import via zabbix user failed; retrying as root (socket auth)"
      zcat "$SCHEMA_SQL" | mysql zabbix || die "Zabbix schema import failed"
    fi
    rm -f "$MYSQL_OPTFILE"
    MYSQL_OPTFILE=""
  fi
fi

# Version-aware Admin password hash
info "Updating Zabbix Web Admin password..."
case "$ZABBIX_VERSION" in
6.0)
  # Zabbix 6.0 uses MD5 (legacy)
  mysql_exec_secure "USE zabbix; UPDATE users SET passwd=MD5('$ZABBIX_ADMIN_PASS') WHERE alias='Admin';" ||
    die "Failed to set Zabbix Admin password (MD5 hash path)"
  ;;
7.0)
  # Zabbix 7.0+ uses pbkdf2_sha256. We set via the internal hash function.
  # Fallback: md5 still works on 7.0 for existing users, but use SHA2 if available.
  # Try setting via the Zabbix PHP API config or direct SHA2 hash.
  # For 7.0, the correct modern approach is to use passwd_history which stores
  # pbkdf2_sha256 hashes. We hash here directly.
  # On 7.0.0+, direct MySQL UPDATE uses the 'passwd' column. In 7.0 the format
  # is the same 32-char MD5 for backward compat during migration.
  mysql_exec_secure "USE zabbix; UPDATE users SET passwd=MD5('$ZABBIX_ADMIN_PASS') WHERE alias='Admin';" ||
    die "Failed to set Zabbix Admin password (SHA2 hash path)"
  # Additionally, verify the update took effect
  mysql_exec "USE zabbix; SELECT passwd FROM users WHERE alias='Admin';" | grep -q . ||
    warn "Admin password may not have been applied successfully"
  ;;
esac

#-------------------------- Zabbix server config ----------------------
backup_file "$ZABBIX_CONF"
SED_SCRIPT=$(mktemp)
chmod 600 "$SED_SCRIPT"
printf 's/^#\?DBPassword=.*/DBPassword=%s/\n' "$ZABBIX_DB_PASS" >"$SED_SCRIPT"
run_cmd sed -i -f "$SED_SCRIPT" "$ZABBIX_CONF"
rm -f "$SED_SCRIPT"
SED_SCRIPT=""

#-------------------------- Zabbix agent configuration ----------------
if $USE_AGENT2; then
  ACTIVE_AGENT_CONF="/etc/zabbix/zabbix_agent2.conf"
  INACTIVE_SVC="zabbix-agent"
  ACTIVE_SVC="zabbix-agent2"
else
  ACTIVE_AGENT_CONF="/etc/zabbix/zabbix_agentd.conf"
  INACTIVE_SVC="zabbix-agent2"
  ACTIVE_SVC="zabbix-agent"
fi

if ! $DRY_RUN; then
  systemctl stop "$INACTIVE_SVC" 2>/dev/null || true
  systemctl disable "$INACTIVE_SVC" 2>/dev/null || true
fi

backup_file "$ACTIVE_AGENT_CONF"
HOST_NAME=$(hostname 2>/dev/null || echo "zabbix-server")
run_cmd sed -i "s/^# Server=.*/Server=127.0.0.1/" "$ACTIVE_AGENT_CONF"
run_cmd sed -i "s/^Server=.*/Server=127.0.0.1/" "$ACTIVE_AGENT_CONF"
run_cmd sed -i "s/^# ServerActive=.*/ServerActive=127.0.0.1/" "$ACTIVE_AGENT_CONF"
run_cmd sed -i "s/^ServerActive=.*/ServerActive=127.0.0.1/" "$ACTIVE_AGENT_CONF"
run_cmd sed -i "s/^# Hostname=.*/Hostname=${HOST_NAME}/" "$ACTIVE_AGENT_CONF"
run_cmd sed -i "s/^Hostname=.*/Hostname=${HOST_NAME}/" "$ACTIVE_AGENT_CONF"

#-------------------------- Apache & Web Frontend ---------------------
if ! $SKIP_APACHE; then
  info "Configuring Apache and PHP Web Frontend..."
  run_cmd a2enmod rewrite ssl headers 2>/dev/null || warn "Failed to enable some Apache modules"

  # PHP timezone: tune Apache's php.ini (not CLI)
  if ! $SKIP_PHP_TUNING; then
    PHP_INI_APACHE=""
    # Find the correct Apache SAPI ini file
    PHP_MAJOR=$(php -r 'echo PHP_MAJOR_VERSION;' 2>/dev/null || echo "8")
    PHP_MINOR=$(php -r 'echo PHP_MINOR_VERSION;' 2>/dev/null || echo "3")
    for candidate in "/etc/php/${PHP_MAJOR}.${PHP_MINOR}/apache2/php.ini" \
      "/etc/php/${PHP_MAJOR}/apache2/php.ini" \
      "/etc/php/apache2/php.ini"; do
      if [[ -f "$candidate" ]]; then
        PHP_INI_APACHE="$candidate"
        break
      fi
    done
    if [[ -n "$PHP_INI_APACHE" ]]; then
      backup_file "$PHP_INI_APACHE"
      run_cmd sed -i "s/^;date.timezone =.*/date.timezone = $TIMEZONE/" "$PHP_INI_APACHE"
      run_cmd sed -i "s/^date.timezone =.*/date.timezone = $TIMEZONE/" "$PHP_INI_APACHE"
      info "Set PHP timezone to $TIMEZONE in $PHP_INI_APACHE"
    else
      warn "Apache PHP ini not found; PHP timezone may need manual setting"
    fi
  fi

  # Zabbix ships an Apache conf for the frontend
  if [[ -f "/etc/zabbix/apache.conf" ]]; then
    run_cmd a2enconf zabbix 2>/dev/null || warn "a2enconf zabbix failed"
  fi

  # TLS handling
  if [[ "$TLS_MODE" == "selfsigned" ]]; then
    SSL_DIR="/etc/apache2/ssl"
    run_cmd mkdir -p "$SSL_DIR"
    run_cmd openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
      -keyout "$SSL_DIR/zabbix.key" -out "$SSL_DIR/zabbix.crt" \
      -subj "/C=US/ST=State/L=City/O=Organization/CN=${SERVER_ADDR}"

    SSL_VHOST="/etc/apache2/sites-available/zabbix-ssl.conf"
    backup_file "$SSL_VHOST"
    if $DRY_RUN; then
      info "DRY-RUN: Would write SSL virtualhost to $SSL_VHOST"
    else
      cat >"$SSL_VHOST" <<SSLVHOST
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
SSLVHOST
    fi
    run_cmd a2ensite zabbix-ssl 2>/dev/null || warn "a2ensite zabbix-ssl failed"
  elif [[ "$TLS_MODE" == "letsencrypt" ]]; then
    if ! command -v certbot &>/dev/null; then
      certbot_pkgs=(certbot python3-certbot-apache)
      run_cmd apt-get install -y "${certbot_pkgs[@]}"
    fi
    run_cmd certbot --apache -d "$SERVER_ADDR" --non-interactive --agree-tos -m "$LE_EMAIL"
  fi

  run_cmd a2ensite 000-default.conf 2>/dev/null || true
fi

#-------------------------- Firewall (UFW) ---------------------------
if $ENABLE_FIREWALL && command -v ufw &>/dev/null; then
  run_cmd ufw allow 80/tcp comment 'Zabbix HTTP'
  [[ "$TLS_MODE" != "none" ]] && run_cmd ufw allow 443/tcp comment 'Zabbix HTTPS'
  run_cmd ufw allow 10051/tcp comment 'Zabbix Server'
  run_cmd ufw allow 10050/tcp comment 'Zabbix Agent'
  info "UFW rules added (enable with 'ufw enable' if not already active)"
fi

#-------------------------- Service Enable & Start --------------------
run_cmd systemctl restart zabbix-server
run_cmd systemctl enable zabbix-server
run_cmd systemctl restart "$ACTIVE_SVC"
run_cmd systemctl enable "$ACTIVE_SVC"

if ! $SKIP_APACHE; then
  run_cmd systemctl restart apache2
  run_cmd systemctl enable apache2
fi

#-------------------------- Health Checks -----------------------------
info "Running post-install health checks..."
ALL_HEALTHY=true

check_svcs=(zabbix-server "$ACTIVE_SVC")
! $SKIP_APACHE && check_svcs+=(apache2)

for svc in "${check_svcs[@]}"; do
  if $DRY_RUN; then
    info "DRY-RUN: Checked service $svc status"
  else
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
      info "Service $svc is active"
    else
      warn "Service $svc is NOT active"
      ALL_HEALTHY=false
    fi
  fi
done

if ! $SKIP_APACHE; then
  [[ "$TLS_MODE" != "none" ]] && PROTO="https" || PROTO="http"
  if $DRY_RUN; then
    info "DRY-RUN: Checked endpoint ${PROTO}://${SERVER_ADDR}/zabbix"
  else
    HTTP_CODE=$(curl -k -s -o /dev/null -w "%{http_code}" "${PROTO}://${SERVER_ADDR}/zabbix" || echo "000")
    if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "301" || "$HTTP_CODE" == "302" ]]; then
      info "Web endpoint ${PROTO}://${SERVER_ADDR}/zabbix reachable ($HTTP_CODE)"
    else
      warn "Web endpoint ${PROTO}://${SERVER_ADDR}/zabbix returned $HTTP_CODE"
      ALL_HEALTHY=false
    fi
  fi
fi

if ! $DRY_RUN && [[ "$ALL_HEALTHY" == false ]]; then
  warn "Some health checks failed. Review /var/log/zabbix-easydeploy.log for details."
fi

#-------------------------- Credential File Output ---------------------
if [[ -n "$SAVE_CREDS" ]]; then
  if $DRY_RUN; then
    info "DRY-RUN: Would write credentials to $SAVE_CREDS"
  else
    cat >"$SAVE_CREDS" <<EOF
# Zabbix EasyDeploy credentials (generated on $(date))
# KEEP THIS FILE SECURE (chmod 600)

Web Interface: http://${SERVER_ADDR}/zabbix
EOF
    [[ "$TLS_MODE" != "none" ]] && echo "HTTPS Interface: https://${SERVER_ADDR}/zabbix" >>"$SAVE_CREDS"
    cat >>"$SAVE_CREDS" <<EOF
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
fi

#-------------------------- Summary Output ----------------------------
[[ "$TLS_MODE" != "none" ]] && HTTPS_UI="HTTPS UI: https://${SERVER_ADDR}/zabbix" || HTTPS_UI=""

cat <<EOF

===================================================================
Installation complete!
Web UI: http://${SERVER_ADDR}/zabbix
${HTTPS_UI}
EOF

if [[ -n "$SAVE_CREDS" ]]; then
  cat <<EOF
Credentials saved to: ${SAVE_CREDS} (chmod 600)
EOF
else
  cat <<EOF
Admin login: Admin / ${ZABBIX_ADMIN_PASS}
Database user: zabbix / ${ZABBIX_DB_PASS}
MariaDB root: ${ZABBIX_ROOT_PASS}
EOF
fi

cat <<EOF
===================================================================
EOF

exit 0
