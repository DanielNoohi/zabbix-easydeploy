# Zabbix EasyDeploy

**One command. Production-ready Zabbix Server on Ubuntu.**

A hardened Bash installer that provisions Zabbix Server, MariaDB, Apache, and Agent — with secure credentials, idempotent re-runs, TLS options, and CI-backed quality checks.

[![CI](https://github.com/DanielNoohi/zabbix-easydeploy/actions/workflows/ci.yml/badge.svg)](https://github.com/DanielNoohi/zabbix-easydeploy/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![ShellCheck](https://img.shields.io/badge/ShellCheck-clean-brightgreen.svg)](https://www.shellcheck.net/)
[![Zabbix](https://img.shields.io/badge/Zabbix-6.0%20%7C%207.0%20%7C%207.2%20%7C%207.4-red.svg)](https://www.zabbix.com/)
[![Ubuntu](https://img.shields.io/badge/Ubuntu-22.04%20%7C%2024.04%20%7C%2026.04-E95420.svg)](https://ubuntu.com/)

---

## Quick start

```bash
curl -sSL https://raw.githubusercontent.com/DanielNoohi/zabbix-easydeploy/main/zabbix-auto-install.sh \
  | tr -d '\r' > zabbix-auto-install.sh \
  && chmod +x zabbix-auto-install.sh \
  && sudo ./zabbix-auto-install.sh
```

The installer prompts for:

| Prompt | Default |
|--------|---------|
| Server IP / hostname | *(required)* |
| Timezone | `UTC` |
| TLS mode (`none` / `selfsigned` / `letsencrypt`) | `none` |
| Let's Encrypt email | only if TLS = `letsencrypt` |

Everything else installs automatically. When it finishes, open:

```text
http://<your-server>/zabbix/
```

Log in as `Admin` with the password printed once at the end of the run.

> **Note:** EasyDeploy brings the platform up. It monitors the local server out of the box — add remote hosts (or discovery rules) in the Zabbix UI afterward.

---

## Why EasyDeploy

| | |
|---|---|
| **Idempotent** | Safe to re-run. Reuses DB passwords, skips schema import when present, backs up configs. |
| **Secret-safe** | Passwords never appear in argv or logs. Temp SQL / MySQL option files; bcrypt via PHP stdin; logs mask secrets as `[REDACTED]`. |
| **TLS-ready** | Plain HTTP, self-signed, or Let's Encrypt. |
| **Firewall-aware** | Optional UFW — opens detected SSH ports, HTTP/HTTPS, and Zabbix agent/server ports. Configured before certbot so HTTP-01 is never blocked. |
| **Agent choice** | Agent 1 or Agent 2. Unused unit disabled; co-located agent binds to `127.0.0.1`. |
| **CI-tested** | ShellCheck, shfmt, Bats, and containerized Ubuntu integration runs. |

---

## Requirements

- **Ubuntu** 22.04, 24.04, or 26.04 LTS (20.04 works with a warning; 18.04 is rejected)
- **Root** privileges (`sudo`)
- **Internet** access for package downloads
- For Let's Encrypt: a publicly resolvable hostname pointing at the server

**Supported Zabbix versions:** 6.0 LTS · 7.0 LTS · 7.2 · 7.4 (default **7.0**)

> Zabbix 6.0 and 7.2 have no packages for Ubuntu 26.04 — those combinations are rejected upfront.

---

## Unattended / CI usage

### Minimal

```bash
sudo ./zabbix-auto-install.sh \
  --non-interactive \
  --ip 192.168.1.10 \
  --zabbix-ver 7.0 \
  --save-creds ~/zabbix-creds.txt
```

### Let's Encrypt

```bash
sudo ./zabbix-auto-install.sh \
  --non-interactive \
  --ip zabbix.example.com \
  --tls letsencrypt \
  --le-email admin@example.com \
  --zabbix-ver 7.0 \
  --save-creds ~/zabbix-creds.txt
```

### External web server + Agent 2

```bash
sudo ./zabbix-auto-install.sh \
  --non-interactive \
  --ip 10.0.0.5 \
  --skip-apache \
  --agent2 \
  --zabbix-ver 7.4 \
  --save-creds ~/zabbix-creds.txt
```

### Dry run (zero system changes)

```bash
sudo ./zabbix-auto-install.sh \
  --dry-run \
  --non-interactive \
  --ip 192.168.1.10
```

### Common flags

| Flag | Purpose |
|------|---------|
| `-n, --non-interactive` | No prompts (requires `--ip`) |
| `-i, --ip ADDRESS` | Server IP or hostname |
| `-z, --zabbix-ver VER` | `6.0` \| `7.0` \| `7.2` \| `7.4` |
| `-l, --tls MODE` | `none` \| `selfsigned` \| `letsencrypt` |
| `-e, --le-email EMAIL` | Required with Let's Encrypt |
| `-s, --save-creds FILE` | Persist credentials (`chmod 600`) |
| `-d, --dry-run` | Print the plan; change nothing |
| `-f, --force` | Rotate passwords on re-run / skip pre-flight |
| `--agent2` | Install Zabbix Agent 2 |
| `--skip-apache` | Skip Apache / frontend packages |
| `--no-firewall` | Skip UFW configuration |
| `-h, --help` | Full option list |

---

## Security model

- **32-character hex passwords** for MariaDB root, Zabbix DB user, and web Admin
- **No secrets in argv** — MySQL via option/SQL temp files; bcrypt via stdin
- **Logs never store plaintext passwords**; Admin password is shown **once** on the console
- **Least privilege** — `zabbix` DB user scoped to the `zabbix` database only
- **MariaDB hardening** — anonymous users removed, `test` DB dropped, `unix_socket` kept for `sudo mysql`
- **Agent hardening** — listens on `127.0.0.1`; unused agent unit disabled
- **Config backups** before every mutation (`*.bak.<timestamp>`)
- **`zabbix_server.conf`** forced to `640` / group `zabbix` after writing `DBPassword`

---

## What gets installed

```text
┌─────────────────────────────────────────────────────────┐
│  Pre-flight → apt → MariaDB → Zabbix repo & packages    │
│       ↓                                                 │
│  Schema (if needed) → bcrypt Admin → server/agent conf  │
│       ↓                                                 │
│  UFW → Apache/TLS → enable services → health checks     │
│       ↓                                                 │
│  Print Admin password + optional --save-creds file      │
└─────────────────────────────────────────────────────────┘
```

1. Pre-flight (root, conflicting services — skippable with `--force`)
2. System packages + MariaDB
3. Official Zabbix `latest` release package for your Ubuntu / Zabbix version
4. Server, SQL scripts, Agent (1 or 2), optional frontend + Apache
5. Database + schema (skipped if already present)
6. Credential generation or reuse from `zabbix_server.conf`
7. Agent / server config, firewall, TLS, PHP timezone
8. Service enablement + HTTP/HTTPS verification (localhost fallback for NAT)
9. Summary with one-time Admin password

Logs: `/var/log/zabbix-easydeploy.log`

---

## Testing

```bash
sudo apt-get install -y shellcheck shfmt bats

shellcheck zabbix-auto-install.sh
shfmt -d -l -i 2 zabbix-auto-install.sh
bats test/
```

GitHub Actions runs lint, Bats, and systemd-container integration tests on Ubuntu 22.04 / 24.04 with Zabbix 7.0 and 7.4.

---

## License

[MIT](LICENSE) © [DanielNoohi](https://github.com/DanielNoohi)
