# 🖥️ Zabbix EasyDeploy

*A fully automated, secure, and hassle-free Bash script for installing Zabbix Server on Ubuntu.*

---

## 🚀 Quick Overview

`zabbix-easydeploy` lets you install and configure **Zabbix Server** with a single command. It takes care of:

* ✅ Installation of all prerequisites (Apache, MariaDB, PHP)
* ✅ Secure MariaDB database setup with auto-generated strong passwords
* ✅ Zabbix server and frontend setup
* ✅ Automatic configuration for Zabbix database connection
* ✅ Essential security checks before installation
* ✅ **Zabbix 6.0 or 7.0 support** (configurable)
* ✅ **Self-signed SSL certificate** for immediate HTTPS access
* ✅ **UFW firewall rules** for Zabbix ports
* ✅ **Command-line arguments** for non-interactive/automated deployments
* ✅ **Credential file output** for secure storage

No prior Zabbix or Linux expertise needed!

---

## ⚡ Quick Install

Copy & paste this single line into your Ubuntu terminal:

```bash
curl -sSL https://raw.githubusercontent.com/DanielNoohi/zabbix-easydeploy/main/zabbix-auto-install.sh | tr -d '\r' > zabbix-auto-install.sh && chmod +x zabbix-auto-install.sh && sudo ./zabbix-auto-install.sh
```

The script will prompt you for your server's IP address or domain name and then handle everything else automatically.

---

## 🎮 Advanced Usage

### Non-interactive / Automated Installation

```bash
# Full automated install with Zabbix 7.0, save creds to file
sudo ./zabbix-auto-install.sh -i 192.168.1.10 -z 7.0 -s creds.txt

# Non-interactive mode (requires -i)
sudo ./zabbix-auto-install.sh --non-interactive --ip zabbix.example.com --zabbix-ver 6.0

# Skip firewall and SSL setup
sudo ./zabbix-auto-install.sh -i 10.0.0.5 --no-firewall --no-ssl
```

### Command Line Options

| Option | Long Form | Description |
|--------|-----------|-------------|
| `-h` | `--help` | Show help message |
| `-i` | `--ip ADDRESS` | Server IP or domain (required for non-interactive) |
| `-z` | `--zabbix-ver VER` | Zabbix version: `6.0` or `7.0` (default: `7.0`) |
| `-u` | `--ubuntu-ver VER` | Override Ubuntu version detection |
| `-s` | `--save-creds FILE` | Save credentials to file after installation |
| `-n` | `--non-interactive` | Run without prompts (requires `-i`) |
| `-f` | `--force` | Skip pre-flight checks |
| | `--no-firewall` | Skip UFW firewall configuration |
| | `--no-ssl` | Skip SSL certificate setup |

---

## 🔒 Security Features

* Automatically generates strong, random **16-character** passwords for MariaDB root, Zabbix database user, and Zabbix Admin user.
* Displays passwords securely only once at the end of the installation.
* Checks for existing installations and active ports/services to prevent conflicts.
* Configures UFW firewall rules for Zabbix ports (80, 443, 10050, 10051).
* Creates self-signed SSL certificate for immediate HTTPS access.
* Saves credentials to a `chmod 600` file when requested.

---

## 📌 Requirements

* Ubuntu (24.04 LTS, 22.04 LTS, 20.04 LTS, or 18.04 LTS)
* Root privileges (sudo)
* Internet access for package downloads

---

## 🎯 Post-install Access

After installation completes, access your Zabbix Web Interface:

```
http://your-server-ip-or-domain/zabbix
https://your-server-ip-or-domain/zabbix  (self-signed certificate)
```

**Default Username:** `Admin`

*(The initial admin password is randomly generated and displayed once at the end of installation—please store it safely!)*

---

## 🔧 What's Inside

The script handles the full installation lifecycle:

1. **Pre-flight checks** — verifies root privileges, detects existing Zabbix/Apache/MariaDB services, and ensures port 80 is free
2. **Prerequisite installation** — Apache2, MariaDB, PHP and all required extensions
3. **Database hardening** — sets a strong MariaDB root password, removes anonymous users and the default `test` database
4. **Zabbix database setup** — creates the `zabbix` database and dedicated user with proper privileges
5. **Repository configuration** — automatically selects the correct Zabbix repository for your Ubuntu version
6. **Schema import** — loads the initial Zabbix server schema
7. **Credential hardening** — sets a random password for the default `Admin` web user
8. **Agent configuration** — configures Zabbix agent with hostname
9. **Apache & PHP tuning** — enables modules, sets timezone
10. **Firewall rules** — opens required ports via UFW
11. **SSL certificate** — generates self-signed certificate for HTTPS
12. **Service configuration** — wires up the database password and enables all services to start on boot

---

## 💡 Contribution & Feedback

Any feedback, bug reports, or feature requests are warmly welcomed. Open an issue or pull request and let's improve this together!

---

## 📄 License

Distributed under the [MIT License](LICENSE).

---

**Made with ❤️ by [DanielNoohi](https://github.com/DanielNoohi)**