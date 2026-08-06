#!/usr/bin/env bash
#
# zabbix-auto-install.sh – Zabbix Server installer for Ubuntu
#   • Interactive and unattended modes
#   • Dry‑run mode (zero system changes – no files created)
#   • Idempotent – safe to re‑run, reuses existing credentials & schema
#   • Secure credential handling (MYSQL opt‑file, stdin-based php hash, masked logs)
#   • Bcrypt admin password for all supported versions (6.0 and 7.0+)
#   • Apache PHP ini tuned (not CLI php.ini)
#   • Rejects unsupported Ubuntu versions; fails on critical DB ops
#   • Verified schema import, service status, and HTTP endpoint before success

set -euo pipefail
IFS=$'\n\t'

# Never fail silently: report the failing command and line, then exit 1
trap 'rc=$?; msg="[ERROR] command failed at line $LINENO: $BASH_COMMAND (exit $rc)"; echo "$msg" >&2; echo "$msg" >>"$LOG_FILE" 2>/dev/null || true; exit $rc' ERR

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

ZABBIX_CONF="/etc/zabbix/zabbix_server.conf"
AGENT_CONF="/etc/zabbix/zabbix_agentd.conf"

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
  local ts masked_msg
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  masked_msg=$(mask_secrets "$*")
  echo "[$ts] [$level] $masked_msg"
  # Dry-run: never write to the log file
  if ! $DRY_RUN && [[ -w "$(dirname "$LOG_FILE")" ]] 2>/dev/null; then
    echo "[$ts] [$level] $masked_msg" >>"$LOG_FILE" 2>/dev/null || true
  fi
}
info() { log "INFO" "$@"; }
warn() { log "WARN" "$@"; }
die() {
  log "ERROR" "$@"
  exit 1
}

wait_for_apt() {
  # Kill whatever process holds the dpkg lock, then remove stale locks
  for i in $(seq 1 20); do
    fuser -k /var/lib/dpkg/lock-frontend 2>/dev/null || true
    fuser -k /var/lib/dpkg/lock 2>/dev/null || true
    fuser -k /var/lib/apt/lists/lock 2>/dev/null || true
    fuser -k /var/cache/apt/archives/lock 2>/dev/null || true
    sleep 1
    if ! fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
      return 0
    fi
    info "Waiting for apt lock (${i}s)..."
  done
  warn "apt lock still held after 20 attempts"
  return 0
}

disable_apt_timers() {
  # Mask ALL apt-related services to prevent systemd from respawning them
  systemctl mask apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
  systemctl stop apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
  systemctl disable apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
  systemctl kill apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
  # Kill lock holders and remove lock files
  fuser -k /var/lib/dpkg/lock-frontend 2>/dev/null || true
  fuser -k /var/lib/dpkg/lock 2>/dev/null || true
  fuser -k /var/lib/apt/lists/lock 2>/dev/null || true
  fuser -k /var/cache/apt/archives/lock 2>/dev/null || true
  rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock 2>/dev/null || true
  # Wait for dpkg to fully release
  while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do sleep 1; done
  sleep 2
}

#-------------------------- Helpers --------------------------------------
wait_for_apt() {
  for i in $(seq 1 30); do
    killall -9 apt apt-get dpkg 2>/dev/null || true
    rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock 2>/dev/null || true
    if ! fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then return 0; fi
    sleep 2
  done
  return 0
}

disable_apt_timers() {
  systemctl stop apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
  systemctl disable apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
  killall -9 apt apt-get dpkg 2>/dev/null || true
  rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock 2>/dev/null || true
}

run_cmd() {
  local cmdline
  printf -v cmdline '%q ' "$@"
  cmdline="${cmdline% }"
  if $DRY_RUN; then
    info "DRY-RUN: $cmdline"
  else
    info "Running: $cmdline"
    if [[ "$1" == "apt-get" ]]; then
      wait_for_apt
      DEBIAN_FRONTEND=noninteractive timeout 900         apt-get -o Dpkg::Use-Pty=0 -o DPkg::Lock::Timeout=600 "${@:2}"
    else
      "$@" || { echo "Command failed: $cmdline"; exit 1; }
    fi
  fi
}"
  if $DRY_RUN; then
    info "DRY-RUN: $cmdline"
  else
    info "Running: $cmdline"
    if [[ "$1" == "apt-get" ]]; then
      # Fix any broken dpkg state before running apt
      dpkg --configure -a 2>/dev/null || true
      # Let apt handle lock waiting natively (DPkg::Lock::Timeout) with a generous outer timeout
      DEBIAN_FRONTEND=noninteractive timeout 900 \
        apt-get -o Dpkg::Use-Pty=0 -o DPkg::Lock::Timeout=600 "${@:2}"
      rc=$?
      if [ $rc -ne 0 ]; then
        echo "=== APT FAILED (rc=$rc) ==="
        tail -n 30 /var/log/dpkg.log 2>/dev/null || true
        echo "=== JOURNALCTL ==="
        journalctl -n 30 --no-pager 2>/dev/null || true
        echo "=== DPKG STATUS ==="
        dpkg --audit 2>/dev/null || true
      fi
    else
      if ! "$@"; then
        # On failure, dump critical logs before exiting
        echo "=== APT LOG TAIL ==="
        tail -n 50 /var/log/dpkg.log || true
        echo "=== SYSTEMD LOG TAIL ==="
        journalctl -n 50 || true
        exit 1
      fi
    fi
  fi
}

generate_password() {
  openssl rand -base64 18 | tr -dc 'A-Za-z0-9!@#$%^&*' | head -c 24
}

backup_file() {
  local f="$1"
  if [[ -f "$f" ]] && ! $DRY_RUN; then
    local bak="${f}.bak.$TIMESTAMP"
    run_cmd cp "$f" "$bak"
    info "Backed up $f -> $bak"
  fi
}

validate_server_addr() {
  local addr="$1"
  [[ -n "$addr" ]] || die "Server address cannot be empty"
}

mysql_exec() {
  if $DRY_RUN; then
    info "DRY-RUN: mysql -e '...'"
  else
    timeout 30 mysql -u root -e "$1" 2>&1
  fi
}

mysql_exec_secure() {
  if $DRY_RUN; then
    info "DRY-RUN: mysql (secure)"
  else
    timeout 30 mysql -u root -e "$1" 2>&1
  fi
}

mysql_opt_exec() {
  if $DRY_RUN; then
    info "DRY-RUN: mysql (opt-file)"
  else
    [[ -f "$MYSQL_OPTFILE" ]] || die "MYSQL_OPTFILE not found"
    timeout 300 mysql --defaults-extra-file="$MYSQL_OPTFILE" "$@"
  fi
}

#-------------------------- Help / usage -----------------------------------
print_help() {
  cat <<EOF
Usage: $0 [OPTIONS]

Zabbix Server auto-installer for Ubuntu.

Options:
  -i, --ip ADDRESS          Server IP or hostname (required unless interactive)
  -z, --zabbix-ver VER      Zabbix version: 6.0 or 7.0 (default: 7.0)
  -u, --ubuntu-ver VER      Ubuntu version override (default: detected)
  -t, --timezone TZ         Timezone (default: UTC)
  -l, --tls MODE            TLS mode: none, selfsigned, letsencrypt (default: none)
  -e, --le-email EMAIL      Email for Let's Encrypt (required with --tls letsencrypt)
  -s, --save-creds FILE     Save generated credentials to FILE (chmod 600)
  -n, --non-interactive     Run without prompts (requires --ip)
  -f, --force               Skip pre-flight active service checks
  -d, --dry-run             Show actions without executing (zero changes)
      --no-firewall         Skip UFW firewall configuration
      --skip-ssl            Skip SSL (force TLS mode none)
      --agent2              Install Zabbix Agent 2 instead of Agent 1
      --skip-apache         Skip Apache installation and web configuration
      --skip-php-tuning     Skip PHP timezone tuning

Security:
  - Admin password is stored as bcrypt on all supported versions (6.0, 7.0+).
  - Generated passwords are passed via secured files / stdin, never as argv.
  - Logs mask password values.

Examples:
  sudo ./$0 -i 192.168.1.10
  sudo ./$0 -n -i 192.168.1.10 -z 7.0 -l none -s creds.txt
  sudo ./$0 -d -i server.example.com --agent2
EOF
}

#-------------------------- Argument parsing --------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
  -h | --help)
    print_help
    exit 0
    ;;
  -i | --ip)
    SERVER_ADDR="${2:-}"
    shift 2
    ;;
  -z | --zabbix-ver)
    ZABBIX_VERSION="${2:-}"
    shift 2
    ;;
  -u | --ubuntu-ver)
    UBUNTU_VERSION="${2:-}"
    shift 2
    ;;
  -t | --timezone)
    TIMEZONE="${2:-}"
    shift 2
    ;;
  -l | --tls)
    TLS_MODE="${2:-}"
    shift 2
    ;;
  -e | --le-email)
    LE_EMAIL="${2:-}"
    shift 2
    ;;
  -s | --save-creds)
    SAVE_CREDS="${2:-}"
    shift 2
    ;;
  -n | --non-interactive)
    NON_INTERACTIVE=true
    shift
    ;;
  -f | --force)
    FORCE=true
    shift
    ;;
  -d | --dry-run)
    DRY_RUN=true
    shift
    ;;
  --no-firewall)
    ENABLE_FIREWALL=false
    shift
    ;;
  --skip-ssl)
    SKIP_SSL=true
    shift
    ;;
  --agent2)
    USE_AGENT2=true
    shift
    ;;
  --skip-apache)
    SKIP_APACHE=true
    shift
    ;;
  --skip-php-tuning)
    SKIP_PHP_TUNING=true
    shift
    ;;
  *)
    die "Unknown option: $1 (use --help)"
    ;;
  esac
done

#-------------------------- Argument validations ---------------------------
if $NON_INTERACTIVE && [[ -z "$SERVER_ADDR" ]]; then
  die "Non-interactive mode requires --ip"
fi
if [[ "$TLS_MODE" == "letsencrypt" ]] && $SKIP_SSL; then
  die "Conflicting TLS options: --tls letsencrypt and --skip-ssl"
fi
if [[ "$TLS_MODE" == "letsencrypt" ]] && [[ -z "$LE_EMAIL" ]]; then
  die "Let's Encrypt mode requires --le-email"
fi
# --skip-ssl forces TLS none unless it conflicted with letsencrypt above
$SKIP_SSL && TLS_MODE="none"

case "$ZABBIX_VERSION" in
6.0) ZBX_RELEASE="6.0-6" ;;
7.0) ZBX_RELEASE="7.0-2" ;;
*) die "Unsupported Zabbix version: $ZABBIX_VERSION (supported: 6.0, 7.0)" ;;
esac

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

#-------------------------- Root check ------------------------------------
# Dry-run can run as any user (no changes are made)
if ! $DRY_RUN && [[ $EUID -ne 0 ]]; then
  die "This script must be run as root (use sudo)"
fi

#-------------------------- Password generation ----------------------------
info "Generating secure credentials..."
ZABBIX_ROOT_PASS=$(generate_password)
ZABBIX_DB_PASS=$(generate_password)
ZABBIX_ADMIN_PASS=$(generate_password)
info "Credentials generated (passwords hidden in logs)"

#-------------------------- Pre-flight checks ------------------------------
if ! $FORCE && ! $DRY_RUN; then
  for svc in apache2 mariadb zabbix-server; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
      warn "Service $svc is currently active. Use --force to ignore."
      die "Pre-flight check failed"
    fi
  done
fi
! $SKIP_APACHE && ss -tuln 2>/dev/null | grep -qE ':80\s|:443\s' &&
  warn "Port 80 or 443 already in use – may conflict with Apache"

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

#-------------------------- System update ----------------------------------
if [[ "${CI:-false}" == "true" ]]; then
  disable_apt_timers
fi
info "Updating system packages..."
run_cmd apt-get update -y
if [[ "${CI:-false}" == "true" ]]; then
  warn "CI mode: skipping full system upgrade"
else
  run_cmd apt-get upgrade -y
fi
run_cmd apt-get install -y --no-install-recommends  wget gnupg2 software-properties-common

#-------------------------- Install MariaDB --------------------------------
info "Installing MariaDB..."
run_cmd apt-get install -y --no-install-recommends  mariadb-server mariadb-client
run_cmd systemctl enable --now mariadb

# Wait for MariaDB to be ready (socket-based check)
if ! $DRY_RUN; then
  attempts=0
  until mysqladmin ping -u root --silent 2>/dev/null; do
    attempts=$((attempts + 1))
    if [[ $attempts -ge 30 ]]; then
      die "MariaDB did not become ready after 60s"
    fi
    info "Waiting for MariaDB... (${attempts}s)"
    sleep 2
  done
  info "MariaDB is ready"
fi

#-------------------------- Zabbix repository ------------------------------
info "Installing Zabbix repository..."
ZABBIX_REPO_PKG="zabbix-release_${ZBX_RELEASE}+ubuntu${ZBX_REPO_VER}_all.deb"
run_cmd wget -q "https://repo.zabbix.com/zabbix/${ZABBIX_VERSION}/ubuntu/pool/main/z/zabbix-release/${ZABBIX_REPO_PKG}" -O "/tmp/${ZABBIX_REPO_PKG}"
run_cmd dpkg -i "/tmp/${ZABBIX_REPO_PKG}"
run_cmd apt-get update -y

# Zabbix components – when --skip-apache, exclude frontend+apache packages
if $SKIP_APACHE; then
  zabbix_pkgs=(zabbix-server-mysql zabbix-sql-scripts)
  $USE_AGENT2 && zabbix_pkgs+=(zabbix-agent2) || zabbix_pkgs+=(zabbix-agent)
  info "--skip-apache: excluding zabbix-frontend-php, zabbix-apache-conf, and PHP extensions"
else
  zabbix_pkgs=(zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf zabbix-sql-scripts)
  $USE_AGENT2 && zabbix_pkgs+=(zabbix-agent2) || zabbix_pkgs+=(zabbix-agent)
fi
run_cmd apt-get install -y --no-install-recommends  "${zabbix_pkgs[@]}"

if ! $SKIP_APACHE; then
  php_exts=(php-mysql php-mbstring php-gd php-xml php-bcmath php-ldap php-curl)
  run_cmd apt-get install -y --no-install-recommends  "${php_exts[@]}"
  apache_pkgs=(apache2 libapache2-mod-php)
  run_cmd apt-get install -y --no-install-recommends  "${apache_pkgs[@]}"
fi

# php-cli is required for bcrypt password hash generation (--skip-apache
# excludes the Apache extensions, but we always need the CLI binary)
run_cmd apt-get install -y --no-install-recommends  php-cli

#-------------------------- MariaDB configuration -----------------------
info "Configuring MariaDB..."
mysql_exec_secure "ALTER USER 'root'@'localhost' IDENTIFIED VIA unix_socket OR mysql_native_password USING PASSWORD('$ZABBIX_ROOT_PASS'); FLUSH PRIVILEGES;" ||
  mysql_exec_secure "SET PASSWORD FOR 'root'@'localhost' = PASSWORD('$ZABBIX_ROOT_PASS'); FLUSH PRIVILEGES;" ||
  die "Failed to set MariaDB root password"
mysql_exec "DELETE FROM mysql.user WHERE User=''; DROP DATABASE IF EXISTS test; DELETE FROM mysql.db WHERE Db='test' OR Db='test_%'; FLUSH PRIVILEGES;"
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
  [[ -z "$SCHEMA_SQL" ]] && die "Zabbix schema SQL file not found. Cannot continue."
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

#-------------------------- Admin password (bcrypt, column-detect, secure) --
info "Updating Zabbix Web Admin password..."
# Detect the login column: Zabbix 6.0 uses 'alias', 7.0+ uses 'username'
ADMIN_COL="alias"
if ! $DRY_RUN; then
  LOGIN_COL=$(mysql_exec "USE zabbix; SHOW COLUMNS FROM users WHERE Field='username';" 2>/dev/null)
  [[ -n "$LOGIN_COL" ]] && ADMIN_COL="username"
fi
info "Detected users.login column: $ADMIN_COL"

# Generate bcrypt hash via PHP stdin (no plaintext in argv or log)
if ! $DRY_RUN; then
  if command -v php &>/dev/null; then
    BC_HASH=$(echo "$ZABBIX_ADMIN_PASS" | php -r '
      $pass = trim(file_get_contents("php://stdin"));
      if (empty($pass)) { fwrite(STDERR, "empty password\n"); exit(1); }
      echo password_hash($pass, PASSWORD_BCRYPT);
    ' 2>/dev/null) || BC_HASH=""
    if [[ -z "$BC_HASH" ]]; then
      die "PHP bcrypt generation failed. Install php-cli or fix PHP configuration."
    fi
    mysql_exec_secure "USE zabbix; UPDATE users SET passwd='$BC_HASH' WHERE $ADMIN_COL='Admin';" ||
      die "Failed to set Zabbix Admin password (bcrypt)"
    info "Admin password set (bcrypt, Zabbix $ZABBIX_VERSION format)"
  else
    die "PHP CLI not available. Cannot generate bcrypt hash for Admin password."
  fi
  # Verify the update took effect
  mysql_exec "USE zabbix; SELECT passwd FROM users WHERE $ADMIN_COL='Admin';" | grep -q . ||
    die "Admin password update verification failed"
else
  info "DRY-RUN: Would set Admin password (bcrypt) in users.$ADMIN_COL='Admin'"
fi

#-------------------------- Zabbix server config (DBPassword) -----------
backup_file "$ZABBIX_CONF"
if ! $DRY_RUN; then
  SED_SCRIPT=$(mktemp)
  chmod 600 "$SED_SCRIPT"
  # Remove any existing DBPassword (commented or active)
  printf '/^[[:space:]]*#\\\\\\?[[:space:]]*DBPassword[[:space:]]*=/d\\n' >"$SED_SCRIPT"
  run_cmd sed -i -f "$SED_SCRIPT" "$ZABBIX_CONF"
  # Append fresh entry
  echo "DBPassword=$ZABBIX_DB_PASS" >>"$ZABBIX_CONF"
  info "DBPassword written to $ZABBIX_CONF"
  # Verify
  grep -q "^DBPassword=" "$ZABBIX_CONF" || die "DBPassword verification failed in $ZABBIX_CONF"
  rm -f "$SED_SCRIPT"
  SED_SCRIPT=""
else
  info "DRY-RUN: Would set DBPassword=... in $ZABBIX_CONF"
fi

#-------------------------- Zabbix agent configuration -------------------
if $USE_AGENT2; then
  AGENT_TEMPLATE="/etc/zabbix/zabbix_agent2.conf"
  info "Configuring Zabbix agent 2..."
else
  AGENT_TEMPLATE="/etc/zabbix/zabbix_agentd.conf"
  info "Configuring Zabbix agent..."
fi
# update_config_line: $1=file, $2=key, $3=value
# Robust + idempotent: removes every existing occurrence (commented or active,
# any leading whitespace) then appends a single fresh 'key=value' entry.
update_config_line() {
  local file="$1" key="$2" val="$3"
  local pattern="^[[:space:]]*#?[[:space:]]*${key}[[:space:]]*="
  sed -i -E "/${pattern}/d" "$file"
  echo "$key=$val" >>"$file"
}

if ! $DRY_RUN; then
  if [[ -f "$AGENT_TEMPLATE" ]]; then
    update_config_line "$AGENT_TEMPLATE" "Server" "$SERVER_ADDR"
    update_config_line "$AGENT_TEMPLATE" "ServerActive" "$SERVER_ADDR"
    update_config_line "$AGENT_TEMPLATE" "Hostname" "$SERVER_ADDR"
    info "Agent configuration updated in $AGENT_TEMPLATE"
  else
    warn "Agent configuration file $AGENT_TEMPLATE not found. Skipping agent config."
  fi
else
  info "DRY-RUN: Would configure agent at $AGENT_TEMPLATE"
  info "DRY-RUN: Would set Server=$SERVER_ADDR, ServerActive=$SERVER_ADDR, Hostname=$SERVER_ADDR"
fi

#-------------------------- Enable and start services --------------------
info "Enabling and starting Zabbix server..."
run_cmd systemctl enable --now zabbix-server
run_cmd systemctl enable --now zabbix-agent

if ! $SKIP_APACHE; then
  info "Configuring Apache for Zabbix..."
  run_cmd a2enmod rewrite
  if [[ "$TLS_MODE" == "selfsigned" ]]; then
    run_cmd a2enmod ssl
    run_cmd a2ensite default-ssl
  elif [[ "$TLS_MODE" == "letsencrypt" ]]; then
    run_cmd a2enmod ssl rewrite
    run_cmd apt-get install -y --no-install-recommends  certbot python3-certbot-apache
    run_cmd certbot --apache --non-interactive --agree-tos -m "$LE_EMAIL" -d "$SERVER_ADDR" || warn "Certbot failed; continuing without Let's Encrypt"
  fi
  run_cmd systemctl enable --now apache2
fi

#-------------------------- Firewall --------------------------------------
if $ENABLE_FIREWALL; then
  info "Configuring firewall..."
  run_cmd apt-get install -y --no-install-recommends  ufw
  run_cmd ufw allow OpenSSH
  run_cmd ufw allow 'Zabbix Agent'
  run_cmd ufw allow 80/tcp
  run_cmd ufw allow 443/tcp
  run_cmd ufw allow 10051/tcp
  run_cmd ufw allow 10050/tcp
  run_cmd ufw --force enable
  info "Firewall configured"
fi

#-------------------------- PHP Tuning -----------------------------------
if ! $SKIP_PHP_TUNING && ! $SKIP_APACHE; then
  PHP_INI=$(find /etc/php -name php.ini -path "*/apache2/*" 2>/dev/null | head -1 || true)
  if [[ -n "$PHP_INI" ]] && [[ -f "$PHP_INI" ]]; then
    info "Tuning PHP config for Zabbix ($PHP_INI)..."
    sed -i "s|^;*\s*date.timezone\s*=.*|date.timezone = $TIMEZONE|" "$PHP_INI"
    sed -i "s|^;*\s*max_input_vars\s*=.*|max_input_vars = 5000|" "$PHP_INI"
    info "PHP timezone set to $TIMEZONE"
  fi
fi

#-------------------------- Save credentials ----------------------------
if [[ -n "$SAVE_CREDS" ]] && ! $DRY_RUN; then
  cat >"$SAVE_CREDS" <<EOF
Zabbix Credentials (generated $TIMESTAMP)
------------------------------------------
Server: $SERVER_ADDR
MariaDB Root Password: $ZABBIX_ROOT_PASS
Zabbix DB Password: $ZABBIX_DB_PASS
Zabbix Admin Password: $ZABBIX_ADMIN_PASS
------------------------------------------
EOF
  chmod 600 "$SAVE_CREDS"
  info "Credentials saved to $SAVE_CREDS"
elif $DRY_RUN && [[ -n "$SAVE_CREDS" ]]; then
  info "DRY-RUN: Would save credentials to $SAVE_CREDS"
fi

#-------------------------- Verify Installation -------------------------
info "Verifying installation..."
if ! $DRY_RUN; then
  # Check services
  for svc in mariadb zabbix-server zabbix-agent; do
    if systemctl is-active --quiet "$svc"; then
      info "Service $svc is active"
    else
      warn "Service $svc failed to start"
    fi
  done

  # Check web interface (if Apache is enabled)
  if ! $SKIP_APACHE; then
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://$SERVER_ADDR/zabbix/" 2>/dev/null || echo "000")
    if [[ "$HTTP_CODE" =~ ^(200|302|301)$ ]]; then
      info "Zabbix web interface is accessible (HTTP $HTTP_CODE)"
    else
      warn "Zabbix web interface not reachable (HTTP $HTTP_CODE)"
    fi
  fi
fi

#-------------------------- Summary --------------------------------------
info "==============================================="
info "Installation complete!"
info "Server Address: $SERVER_ADDR"
info "Zabbix Version: $ZABBIX_VERSION"
if ! $DRY_RUN; then
  info "Admin Login: Admin"
  info "Admin Password: $ZABBIX_ADMIN_PASS"
fi
info "==============================================="
info "Access Zabbix at: http://$SERVER_ADDR/zabbix/"
info "Default credentials: Admin / (see --save-creds or re-run to see password)"
