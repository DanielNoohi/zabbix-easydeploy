# 🖥️ Zabbix EasyDeploy

*A production-ready, secure, and fully automated Bash script for installing Zabbix Server on Ubuntu with advanced features.*

---

## 🚀 Features

*   **Interactive & Unattended Modes** – Run interactively or via CLI flags for CI/CD.
*   **Dry‑Run Mode** – Preview actions without executing (`--dry-run`).
*   **Idempotent & Safe** – Safe to re-run; backs up configs before changes.
*   **Secure Credential Handling** – Uses temporary `MYSQL_PWD`; strong 32‑char random passwords.
*   **TLS Options** – No TLS, self‑signed certificate, or Let's Encrypt (if `certbot` available).
*   **Firewall** – Optional UFW configuration for HTTP/HTTPS and Zabbix ports.
*   **Zabbix Versions** – Supports Zabbix 6.0 LTS and 7.0 LTS (default 7.0).
*   **Agent Choice** – Install Zabbix Agent 1 or Agent 2 (`--agent2`).
*   **Web Server Choice** – Skip Apache if using external web server (`--skip-apache`).
*   **PHP Tuning** – Optional timezone and module configuration.
*   **Post‑Install Health Check** – Verifies services and HTTP/HTTPS endpoints.
*   **Comprehensive Logging** – Detailed logs to `/var/log/zabbix-easydeploy.log`.
*   **Credential Output** – Optionally save generated credentials to a file (`--save-creds <file>`).
*   **Audit‑Ready** – Includes ShellCheck, shfmt, and Bats testing configurations.

---

## ⚡ Quick Start (Interactive)

```bash
curl -sSL https://raw.githubusercontent.com/DanielNoohi/zabbix-easydeploy/main/zabbix-auto-install.sh | tr -d '\r' > zabbix-auto-install.sh && chmod +x zabbix-auto-install.sh && sudo ./zabbix-auto-install.sh
```

The script will prompt for your server's IP/hostname and optional settings.

---

## 🎮 Advanced Usage (Unattended / CI/CD)

### Basic Non‑Interactive

```bash
sudo ./zabbix-auto-install.sh \
  --non-interactive \
  --ip 192.168.1.10 \
  --zabbix-ver 7.0 \
  --save-creds ~/zabbix-creds.txt
```

### With Let's Encrypt TLS

```bash
sudo ./zabbix-auto-install.sh \
  --non-interactive \
  --ip zabbix.example.com \
  --tls letsencrypt \
  --le-email admin@example.com \
  --zabbix-ver 7.0 \
  --save-creds ~/zabbix-creds.txt
```

### Skip Apache & Use Existing Web Server

```bash
sudo ./zabbix-auto-install.sh \
  --non-interactive \
  --ip 10.0.0.5 \
  --skip-apache \
  --zabbix-ver 6.0 \
  --agent2 \
  --save-creds ~/zabbix-creds-6-agent2.txt
```

### Dry Run (See What Would Happen)

```bash
sudo ./zabbix-auto-install.sh \
  --dry-run \
  --non-interactive \
  --ip 192.168.1.10
```

---

## 🔐 Security Features

*   **Strong Passwords** – 32‑character random passwords for:
    *   MariaDB `root`
    *   Zabbix database user (`zabbix`)
    *   Zabbix web admin (`Admin`)
*   **Secure MySQL Handling** – Uses `MYSQL_PWD` environment variable (not command line).
*   **Least Privilege** – Database user only has privileges on the `zabbix` database.
*   **Service Hardening** – Removes anonymous MySQL users and the `test` database.
*   **File Backups** – Backs up modified config files with timestamps.
*   **Least Privilege for Credentials** – If `--save-creds` is used, file is set to `chmod 600`.
*   **No Hardcoded Secrets** – All passwords are generated at runtime.
*   **Configurable TLS** – Optionally secure the web interface with HTTPS.

---

## 📋 Requirements

*   Ubuntu 24.04 LTS, 22.04 LTS, 20.04 LTS, or 18.04 LTS
*   Root privileges (`sudo`)
*   Internet access for package downloads
*   For Let's Encrypt: a publicly resolvable domain name pointing to the server

---

## 🛠️ What the Script Does

1.   **Pre‑flight Checks** – Verifies root, checks for existing services/ports (skippable with `--force`).
2.   **Package Installation** – Installs Apache/MariaDB/PHP (unless skipped) and required PHP extensions.
3.   **Zabbix Repository** – Adds the official Zabbix repository for the chosen version and Ubuntu codename.
4.   **Zabbix Components** – Installs server, frontend, agent (v1 or v2), and SQL scripts.
5.   **Database Setup** – Creates the `zabbix` database and user, imports initial schema.
6.   **Credential Generation** – Creates strong random passwords for root, database, and admin user.
7.   **MariaDB Hardening** – Sets root password (using `mysql_native_password`), removes anonymous users, drops `test` DB.
8.   **Zabbix Configuration** – Sets database password in `zabbix_server.conf`.
9.   **Agent Configuration** – Configures agent to listen on `127.0.0.1` and sets hostname.
10.  **Web Server Setup** (if Apache not skipped):
    *   Enables `rewrite`, `ssl`, `headers` modules.
    *   Sets PHP timezone (default `UTC`, configurable).
    *   Optionally creates SSL virtual host (self-signed or Let's Encrypt).
11.  **Firewall** (if enabled) – Opens ports 80, 443 (if TLS), 10050 (agent), 10051 (server) via UFW.
12.  **Service Management** – Restarts and enables Zabbix server, agent, and Apache.
13.  **Health Check** – Verifies services are active and queries the web interface (HTTP/HTTPS).
14.  **Output** – Displays access information and optionally saves credentials to a file.

---

## 🧪 Testing & Quality Assurance

This project includes:

*   **ShellCheck** – Static shell script analysis (`.shellcheckrc`).
*   **shfmt** – Shell script formatter (`.shfmt`).
*   **Bats** – Bash Automated Testing System (see `tests/` directory).
*   **GitHub Actions** – CI workflow that runs on every push and pull request.

### Running Tests Locally

Install the test dependencies:

```bash
# On Ubuntu/Debian
sudo apt-get install -y shellcheck shfmt bats
```

Then run:

```bash
# ShellCheck
shellcheck zabbix-auto-install.sh

# shfmt
shfmt -d -l -i 2 zabbix-auto-install.sh

# Bats (from the repository root)
bats test/
```

---

## 📄 License

Distributed under the [MIT License](LICENSE).

---

**Made with ❤️ by [DanielNoohi](https://github.com/DanielNoohi)**