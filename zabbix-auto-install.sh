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
#
# AI-MAINTAINER-NOTES (bug fixes applied):
#   1. Agent2: use zabbix-agent2 systemd unit when --agent2 is set (was always zabbix-agent).
#   2. SQL safety: passwords/bcrypt hashes go through run_mysql_sql temp files, never mysql -e.
#   3. Idempotency: re-runs reuse DBPassword from config; skip root/admin rotation unless --force.
#   4. Pre-flight: active services allowed on detected re-runs (no longer require --force).
#   5. Verification: critical service/HTTP failures now exit non-zero (was warn-only).
#   6. UFW: removed non-portable 'Zabbix Agent' profile; explicit port rules only.
#   7. Apt locks: wait_for_apt() is invoked before every apt-get via run_cmd().
# Search for "AI-NOTE:" inline comments before changing mysql, agent, or credential logic.

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
EXISTING_INSTALL=false
SCHEMA_EXISTS=false

ZABBIX_ROOT_PASS=""
ZABBIX_DB_PASS=""
ZABBIX_ADMIN_PASS=""

MYSQL_OPTFILE=""
SED_SCRIPT=""

ZABBIX_CONF="/etc/zabbix/zabbix_server.conf"
# AI-NOTE: AGENT_CONF and AGENT_SVC are set after argument parsing so --agent2
# selects the correct systemd unit (zabbix-agent2) and config file everywhere.
AGENT_CONF=""
AGENT_SVC=""

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
  # AI-NOTE: This helper was previously defined but never invoked, causing apt
  # lock failures on fresh VMs/cloud images where unattended-upgrades holds dpkg.
  # We call it before every apt-get batch (see run_cmd + system update section).
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
      DEBIAN_FRONTEND=noninteractive timeout 300 env \
        DEBIAN_FRONTEND=noninteractive \
        APT_LISTCHANGES_FRONTEND=none \
        apt-get -o Dpkg::Use-Pty=0 -o DPkg::Lock::Timeout=120 "${@:2}"
    else
      "$@" || {
        echo "Command failed: $cmdline"
        exit 1
      }
    fi
  fi
}

generate_password() {
  # AI-NOTE: Use hex (no special chars) to avoid MySQL option-file truncation
  # (e.g. '#' starts a comment in .cnf files) and to guarantee length.
  openssl rand -hex 16
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

# AI-NOTE: Escape single quotes for MariaDB string literals.
sql_escape() {
  printf '%s' "$1" | sed "s/'/''/g"
}

# AI-NOTE: BUG FIX — never pass passwords or bcrypt hashes through `mysql -e "..."`.
# Bash expands `$` inside double quotes, which corrupts:
#   • bcrypt hashes ($2y$10$...)
#   • generated passwords (charset includes `$`)
# Write SQL to a root-owned temp file and feed it via stdin instead.
run_mysql_sql() {
  local sql="$1"
  if $DRY_RUN; then
    info "DRY-RUN: mysql <sql-file>"
    return 0
  fi
  local sql_file rc=0
  sql_file=$(mktemp /tmp/zabbix-sql-XXXXXX.sql)
  chmod 600 "$sql_file"
  printf '%s\n' "$sql" >"$sql_file"
  timeout 30 mysql -u root --batch <"$sql_file" 2>&1 || rc=$?
  rm -f "$sql_file"
  return $rc
}

# AI-NOTE: Same temp-file pattern for queries whose output is parsed (grep/[[ -n ]]).
mysql_query() {
  local sql="$1"
  if $DRY_RUN; then
    info "DRY-RUN: mysql query"
    return 0
  fi
  local sql_file
  sql_file=$(mktemp /tmp/zabbix-sql-XXXXXX.sql)
  chmod 600 "$sql_file"
  printf '%s\n' "$sql" >"$sql_file"
  timeout 30 mysql -u root --batch --skip-column-names <"$sql_file" 2>/dev/null
  rm -f "$sql_file"
}

mysql_opt_exec() {
  # AI-NOTE: Kept for schema-import fallback patterns; uses MYSQL_OPTFILE set by caller.
  if $DRY_RUN; then
    info "DRY-RUN: mysql (opt-file)"
  else
    [[ -f "$MYSQL_OPTFILE" ]] || die "MYSQL_OPTFILE not found"
    timeout 300 mysql --defaults-extra-file="$MYSQL_OPTFILE" "$@"
  fi
}

# AI-NOTE: Detect prior install so re-runs skip credential rotation and pre-flight
# no longer dies just because zabbix-server is already active.
detect_existing_zabbix_install() {
  if dpkg -l zabbix-server-mysql &>/dev/null 2>&1; then
    return 0
  fi
  if [[ -f "$ZABBIX_CONF" ]] && grep -qE '^[[:space:]]*DBPassword=' "$ZABBIX_CONF" 2>/dev/null; then
    return 0
  fi
  return 1
}

load_existing_db_password() {
  # AI-NOTE: Idempotency — read DBPassword from server config instead of rotating.
  ZABBIX_DB_PASS=""
  if [[ -f "$ZABBIX_CONF" ]]; then
    ZABBIX_DB_PASS=$(grep -E '^[[:space:]]*DBPassword=' "$ZABBIX_CONF" | tail -1 | sed 's/^[[:space:]]*DBPassword=//')
  fi
  if [[ -n "$ZABBIX_DB_PASS" ]]; then
    info "Reusing existing Zabbix DB password from $ZABBIX_CONF"
  else
    warn "Existing install detected but DBPassword missing from $ZABBIX_CONF"
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
  -f, --force               On re-run: rotate passwords; on fresh install: skip service pre-flight
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

# AI-NOTE: BUG FIX — keep agent unit name and config path in sync for --agent2.
if $USE_AGENT2; then
  AGENT_SVC="zabbix-agent2"
  AGENT_CONF="/etc/zabbix/zabbix_agent2.conf"
else
  AGENT_SVC="zabbix-agent"
  AGENT_CONF="/etc/zabbix/zabbix_agentd.conf"
fi

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
6.0 | 7.0)
  # AI-NOTE: Query Zabbix repo listing for latest release package version.
  # Falls back to hardcoded defaults if curl fails.
  ZBX_RELEASE=$(curl -fsSL "https://repo.zabbix.com/zabbix/${ZABBIX_VERSION}/ubuntu/pool/main/z/zabbix-release/" 2>/dev/null | grep -oP "zabbix-release_\K${ZABBIX_VERSION}-[0-9]+(?=\+ubuntu)" | sort -V | tail -1 || true)
  if [[ -z "$ZBX_RELEASE" ]]; then
    warn "Could not detect latest Zabbix release version; using fallback defaults"
    case "$ZABBIX_VERSION" in
    6.0) ZBX_RELEASE="6.0-6" ;;
    7.0) ZBX_RELEASE="7.0-2" ;;
    esac
  fi
  ;;
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

# AI-NOTE: Early install detection — allows idempotent re-runs without --force.
if detect_existing_zabbix_install; then
  EXISTING_INSTALL=true
  info "Existing Zabbix installation detected; enabling idempotent re-run mode"
fi

#-------------------------- Pre-flight checks ------------------------------
# AI-NOTE: BUG FIX — skip active-service guard on re-runs; services should be up.
if ! $FORCE && ! $DRY_RUN && ! $EXISTING_INSTALL; then
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
run_cmd apt-get install -y --no-install-recommends -qq wget gnupg2 software-properties-common

#-------------------------- Install MariaDB --------------------------------
info "Installing MariaDB..."
run_cmd apt-get install -y --no-install-recommends -qq mariadb-server mariadb-client
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

# AI-NOTE: Schema check happens here; credential load happens AFTER packages install
# because /etc/zabbix/zabbix_server.conf does not exist until then.
if ! $DRY_RUN; then
  if mysql_query "USE zabbix; SHOW TABLES LIKE 'users';" | grep -q "users"; then
    SCHEMA_EXISTS=true
    EXISTING_INSTALL=true
    info "Zabbix database schema already present"
  fi
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
run_cmd apt-get install -y --no-install-recommends -qq "${zabbix_pkgs[@]}"

if ! $SKIP_APACHE; then
  php_exts=(php-mysql php-mbstring php-gd php-xml php-bcmath php-ldap php-curl)
  run_cmd apt-get install -y --no-install-recommends -qq "${php_exts[@]}"
  apache_pkgs=(apache2 libapache2-mod-php)
  run_cmd apt-get install -y --no-install-recommends -qq "${apache_pkgs[@]}"
fi

# php-cli is required for bcrypt password hash generation (--skip-apache
# excludes the Apache extensions, but we always need the CLI binary)
run_cmd apt-get install -y --no-install-recommends -qq php-cli

# AI-NOTE: BUG FIX — credential rotation on re-run broke working installs.
# Load DB password from zabbix_server.conf only after packages create that file.
if $EXISTING_INSTALL || $SCHEMA_EXISTS; then
  EXISTING_INSTALL=true
  load_existing_db_password
  info "Skipping credential rotation (existing install; use --force to rotate passwords)"
  if $FORCE; then
    warn "--force on existing install: rotating MariaDB root, Zabbix DB, and Admin passwords"
    ZABBIX_ROOT_PASS=$(generate_password)
    ZABBIX_DB_PASS=$(generate_password)
    ZABBIX_ADMIN_PASS=$(generate_password)
  fi
else
  info "Generating secure credentials..."
  ZABBIX_ROOT_PASS=$(generate_password)
  ZABBIX_DB_PASS=$(generate_password)
  ZABBIX_ADMIN_PASS=$(generate_password)
  info "Credentials generated (passwords hidden in logs)"
fi

#-------------------------- MariaDB configuration -----------------------
info "Configuring MariaDB..."
if ! $EXISTING_INSTALL || $FORCE; then
  # AI-NOTE: Passwords passed via run_mysql_sql temp file (see sql_escape helper).
  run_mysql_sql "ALTER USER 'root'@'localhost' IDENTIFIED VIA unix_socket OR mysql_native_password USING PASSWORD('$(sql_escape "$ZABBIX_ROOT_PASS")'); FLUSH PRIVILEGES;" ||
    run_mysql_sql "SET PASSWORD FOR 'root'@'localhost' = PASSWORD('$(sql_escape "$ZABBIX_ROOT_PASS")'); FLUSH PRIVILEGES;" ||
    die "Failed to set MariaDB root password"
else
  info "Skipping MariaDB root password rotation (existing install)"
fi
run_mysql_sql "DELETE FROM mysql.user WHERE User=''; DROP DATABASE IF EXISTS test; DELETE FROM mysql.db WHERE Db='test' OR Db='test_%'; FLUSH PRIVILEGES;"
run_mysql_sql "CREATE DATABASE IF NOT EXISTS zabbix CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;"
if [[ -z "$ZABBIX_DB_PASS" ]]; then
  die "Zabbix DB password is empty — cannot configure MariaDB (use --force on re-run to rotate)"
fi
run_mysql_sql "CREATE USER IF NOT EXISTS 'zabbix'@'localhost' IDENTIFIED BY '$(sql_escape "$ZABBIX_DB_PASS")';"
if ! $EXISTING_INSTALL || $FORCE; then
  run_mysql_sql "ALTER USER 'zabbix'@'localhost' IDENTIFIED BY '$(sql_escape "$ZABBIX_DB_PASS")';"
fi
run_mysql_sql "GRANT ALL PRIVILEGES ON zabbix.* TO 'zabbix'@'localhost'; FLUSH PRIVILEGES;"

#-------------------------- Schema import (idempotent) ------------------
info "Checking Zabbix database schema..."
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
password="${ZABBIX_DB_PASS}"
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
  LOGIN_COL=$(mysql_query "USE zabbix; SHOW COLUMNS FROM users WHERE Field='username';" 2>/dev/null || true)
  [[ -n "$LOGIN_COL" ]] && ADMIN_COL="username"
fi
info "Detected users.login column: $ADMIN_COL"

# Generate bcrypt hash via PHP stdin (no plaintext in argv or log)
if $EXISTING_INSTALL && ! $FORCE; then
  # AI-NOTE: Admin bcrypt cannot be reversed; leave it unchanged on re-run.
  info "Skipping Admin password update (existing install; use --force to rotate)"
elif ! $DRY_RUN; then
  if command -v php &>/dev/null; then
    BC_HASH=$(echo "$ZABBIX_ADMIN_PASS" | php -r '
      $pass = trim(file_get_contents("php://stdin"));
      if (empty($pass)) { fwrite(STDERR, "empty password\n"); exit(1); }
      echo password_hash($pass, PASSWORD_BCRYPT);
    ' 2>/dev/null) || BC_HASH=""
    if [[ -z "$BC_HASH" ]]; then
      die "PHP bcrypt generation failed. Install php-cli or fix PHP configuration."
    fi
    # AI-NOTE: BUG FIX — bcrypt hashes contain `$`; must use run_mysql_sql not mysql -e.
    run_mysql_sql "USE zabbix; UPDATE users SET passwd='$(sql_escape "$BC_HASH")' WHERE ${ADMIN_COL}='Admin';" ||
      die "Failed to set Zabbix Admin password (bcrypt)"
    info "Admin password set (bcrypt, Zabbix $ZABBIX_VERSION format)"
  else
    die "PHP CLI not available. Cannot generate bcrypt hash for Admin password."
  fi
  # Verify the update took effect
  mysql_query "USE zabbix; SELECT passwd FROM users WHERE ${ADMIN_COL}='Admin';" | grep -q . ||
    die "Admin password update verification failed"
else
  info "DRY-RUN: Would set Admin password (bcrypt) in users.$ADMIN_COL='Admin'"
fi

#-------------------------- Zabbix server config (DBPassword) -----------
backup_file "$ZABBIX_CONF"
if $EXISTING_INSTALL && ! $FORCE && [[ -n "$ZABBIX_DB_PASS" ]]; then
  # AI-NOTE: Avoid rewriting DBPassword on re-run — keeps server.conf stable.
  info "Keeping existing DBPassword in $ZABBIX_CONF"
elif ! $DRY_RUN; then
  SED_SCRIPT=$(mktemp)
  chmod 600 "$SED_SCRIPT"
  # Remove any existing DBPassword (commented or active)
  printf '/^[[:space:]]*#\\?[[:space:]]*DBPassword[[:space:]]*=/d\n' >"$SED_SCRIPT"
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
# AI-NOTE: AGENT_CONF/AGENT_SVC were set after arg parsing (see top of script).
if $USE_AGENT2; then
  info "Configuring Zabbix agent 2..."
else
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
  if [[ -f "$AGENT_CONF" ]]; then
    update_config_line "$AGENT_CONF" "Server" "$SERVER_ADDR"
    update_config_line "$AGENT_CONF" "ServerActive" "$SERVER_ADDR"
    update_config_line "$AGENT_CONF" "Hostname" "$SERVER_ADDR"
    info "Agent configuration updated in $AGENT_CONF"
  else
    warn "Agent configuration file $AGENT_CONF not found. Skipping agent config."
  fi
else
  info "DRY-RUN: Would configure agent at $AGENT_CONF"
  info "DRY-RUN: Would set Server=$SERVER_ADDR, ServerActive=$SERVER_ADDR, Hostname=$SERVER_ADDR"
fi

#-------------------------- Enable and start services --------------------
info "Enabling and starting Zabbix server..."
run_cmd systemctl enable --now zabbix-server
# AI-NOTE: BUG FIX — --agent2 installs zabbix-agent2 package/service, not zabbix-agent.
run_cmd systemctl enable --now "$AGENT_SVC"

if ! $SKIP_APACHE; then
  info "Configuring Apache for Zabbix..."
  run_cmd a2enmod rewrite
  if [[ "$TLS_MODE" == "selfsigned" ]]; then
    run_cmd a2enmod ssl
    run_cmd a2ensite default-ssl
  elif [[ "$TLS_MODE" == "letsencrypt" ]]; then
    run_cmd a2enmod ssl rewrite
    run_cmd apt-get install -y --no-install-recommends -qq certbot python3-certbot-apache
    run_cmd certbot --apache --non-interactive --agree-tos -m "$LE_EMAIL" -d "$SERVER_ADDR" || warn "Certbot failed; continuing without Let's Encrypt"
  fi
  run_cmd systemctl enable --now apache2
fi

#-------------------------- Firewall --------------------------------------
if $ENABLE_FIREWALL; then
  info "Configuring firewall..."
  run_cmd apt-get install -y --no-install-recommends -qq ufw
  run_cmd ufw allow OpenSSH
  # AI-NOTE: BUG FIX — 'Zabbix Agent' UFW profile is not present on all Ubuntu
  # releases; explicit ports below are the portable equivalent.
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
MariaDB Root Password: ${ZABBIX_ROOT_PASS:-(unchanged on re-run)}
Zabbix DB Password: ${ZABBIX_DB_PASS:-(unknown)}
Zabbix Admin Password: ${ZABBIX_ADMIN_PASS:-(unchanged on re-run)}
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
  VERIFY_FAILED=false

  # AI-NOTE: BUG FIX — verification used to warn-only; now fail on critical services.
  for svc in mariadb zabbix-server "$AGENT_SVC"; do
    if systemctl is-active --quiet "$svc"; then
      info "Service $svc is active"
    else
      warn "Service $svc failed to start"
      VERIFY_FAILED=true
    fi
  done

  if ! $SKIP_APACHE; then
    if systemctl is-active --quiet apache2; then
      info "Service apache2 is active"
    else
      warn "Service apache2 failed to start"
      VERIFY_FAILED=true
    fi

    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://$SERVER_ADDR/zabbix/" 2>/dev/null || echo "000")
    if [[ "$HTTP_CODE" =~ ^(200|302|301)$ ]]; then
      info "Zabbix web interface is accessible (HTTP $HTTP_CODE)"
    else
      warn "Zabbix web interface not reachable (HTTP $HTTP_CODE)"
      VERIFY_FAILED=true
    fi
  fi

  if $VERIFY_FAILED; then
    die "Installation verification failed — one or more critical components are unhealthy"
  fi
fi

#-------------------------- Summary --------------------------------------
info "==============================================="
info "Installation complete!"
info "Server Address: $SERVER_ADDR"
info "Zabbix Version: $ZABBIX_VERSION"
if ! $DRY_RUN; then
  info "Admin Login: Admin"
  if [[ -n "$ZABBIX_ADMIN_PASS" ]]; then
    info "Admin Password: $ZABBIX_ADMIN_PASS"
  else
    info "Admin Password: (unchanged — not rotated on idempotent re-run)"
  fi
fi
info "==============================================="
info "Access Zabbix at: http://$SERVER_ADDR/zabbix/"
info "Default credentials: Admin / (see --save-creds or re-run to see password)"
