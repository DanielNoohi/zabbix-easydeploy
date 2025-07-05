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

No prior Zabbix or Linux expertise needed!

---

## ⚡ Quick Install

Copy & paste this single line into your Ubuntu terminal:

```bash
curl -O https://raw.githubusercontent.com/DanielNoohi/zabbix-easydeploy/main/zabbix-auto-install.sh && chmod +x ./zabbix-auto-install.sh && sudo ./zabbix-auto-install.sh
```

The script will prompt you for your server's IP address or domain name and then handle everything else automatically.

---

## 🔒 Security Features

* Automatically generates strong, random passwords for MariaDB root and Zabbix database user.
* Displays passwords securely only once at the end of the installation.
* Checks for existing installations and active ports/services to prevent conflicts.

---

## 📌 Requirements

* Ubuntu (22.04 LTS or 20.04 LTS recommended)
* Root privileges (sudo)

---

## 🎯 Post-install Access

After installation completes, access your Zabbix Web Interface:

```
http://your-server-ip-or-domain/zabbix
```

**Default Username:** `Admin`

*(The initial admin password is randomly generated and displayed once at the end of installation—please store it safely!)*

---

## 💡 Contribution & Feedback

Any feedback, bug reports, or feature requests are warmly welcomed. Open an issue or pull request and let's improve this together!

---

## 📄 License

Distributed under the [MIT License](LICENSE).

---

**Made with ❤️ by [DanielNoohi](https://github.com/DanielNoohi)**
