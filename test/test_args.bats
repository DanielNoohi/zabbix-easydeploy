#!/usr/bin/env bats
# zabbix-auto-install tests — self-contained, no external helpers required

# Inline assert helpers (no bats-support/bats-assert dependency)
assert_success() {
  if [ "$status" -ne 0 ]; then
    echo "expected success but status=$status" >&2
    echo "output: $output" >&2
    return 1
  fi
}

assert_failure() {
  if [ "$status" -eq 0 ]; then
    echo "expected failure but status=0" >&2
    echo "output: $output" >&2
    return 1
  fi
}

assert_output() {
  local pattern="$1"
  case "${2:-partial}" in
    partial)
      if [[ "$output" != *"$pattern"* ]]; then
        echo "expected output to contain: $pattern" >&2
        echo "actual output: $output" >&2
        return 1
      fi
      ;;
    exact)
      if [ "$output" != "$pattern" ]; then
        echo "expected output: $pattern" >&2
        echo "actual output: $output" >&2
        return 1
      fi
      ;;
  esac
}

refute_output() {
  local pattern="$1"
  if [[ "$output" == *"$pattern"* ]]; then
    echo "expected output NOT to contain: $pattern" >&2
    echo "actual output: $output" >&2
    return 1
  fi
}

# Helper to run the script
run_script() {
  run ./zabbix-auto-install.sh "$@"
}

# ==================== Argument Parsing Tests ====================

@test "Help option returns success and displays usage" {
  run_script --help
  assert_success
  assert_output "Usage:"
  assert_output "Options:"
}

@test "Non-interactive mode without IP fails" {
  run_script --non-interactive
  assert_failure
  assert_output "Non-interactive mode requires --ip"
}

@test "LetsEncrypt mode without email fails" {
  run_script --non-interactive --ip 1.2.3.4 --tls letsencrypt
  assert_failure
  assert_output "Let's Encrypt mode requires --le-email"
}

@test "Conflicting TLS options (letsencrypt and skip-ssl) fail" {
  run_script --non-interactive --ip 1.2.3.4 --tls letsencrypt --skip-ssl
  assert_failure
  assert_output "Conflicting TLS options"
}

@test "LetsEncrypt mode with email passes argument check" {
  run_script --non-interactive --ip 1.2.3.4 --tls letsencrypt --le-email test@example.com --dry-run
  assert_success
  refute_output "Let's Encrypt mode requires --le-email"
}

@test "Accepts zabbix version 6.0" {
  run_script --zabbix-ver 6.0 --help
  assert_success
}

@test "Accepts zabbix version 7.0" {
  run_script --zabbix-ver 7.0 --help
  assert_success
}

@test "Rejects invalid zabbix version" {
  run_script --zabbix-ver 9.9 --non-interactive --ip 1.2.3.4 --tls none
  assert_failure
  assert_output "Unsupported Zabbix version"
}

@test "Accepts ubuntu version override" {
  run_script --ubuntu-ver 22.04 --help
  assert_success
}

@test "Accepts timezone" {
  run_script --timezone "Europe/London" --help
  assert_success
}

@test "Accepts save-creds option" {
  run_script --save-creds /tmp/test.txt --help
  assert_success
}

@test "Accepts non-interactive flag" {
  run_script --non-interactive --help
  assert_success
}

@test "Accepts force flag" {
  run_script --force --help
  assert_success
}

@test "Accepts dry-run flag" {
  run_script --dry-run --help
  assert_success
}

@test "Accepts no-firewall flag" {
  run_script --no-firewall --help
  assert_success
}

@test "Accepts skip-ssl flag" {
  run_script --skip-ssl --help
  assert_success
}

@test "Accepts agent2 flag" {
  run_script --agent2 --help
  assert_success
}

@test "Accepts skip-apache flag" {
  run_script --skip-apache --help
  assert_success
}

@test "Accepts skip-php-tuning flag" {
  run_script --skip-php-tuning --help
  assert_success
}

# ==================== Dry-Run & Idempotency Tests ====================

@test "Dry-run mode works without actual installation" {
  run_script --dry-run --non-interactive --ip 10.0.0.50
  assert_success
  assert_output "DRY-RUN:"
  refute_output "ERROR"
}

@test "Rejects invalid server address format" {
  run_script --ip "invalid..host**" --non-interactive --dry-run
  assert_failure
  assert_output "Invalid server address"
}

@test "Can combine agent2 and skip-apache flags" {
  run_script --agent2 --skip-apache --help
  assert_success
}

@test "Accepts non-interactive with agent2" {
  run_script --agent2 --non-interactive --ip 10.0.0.52 --dry-run
  assert_success
  assert_output "zabbix-agent2"
}

@test "Dry-run HTTP mode configures Apache by default" {
  run_script --dry-run --non-interactive --ip 10.0.0.80
  assert_success
  assert_output "apache2"
  assert_output "a2enmod"
}

@test "Dry-run with self-signed TLS includes SSL" {
  run_script --dry-run --non-interactive --ip 10.0.0.81 --tls selfsigned
  assert_success
  assert_output "openssl"
  assert_output "SSL"
}

@test "Dry-run with letsencrypt" {
  run_script --dry-run --non-interactive --ip 10.0.0.82 --tls letsencrypt --le-email admin@example.com
  assert_success
  assert_output "certbot"
}

@test "Dry-run with --skip-apache skips Apache packages" {
  run_script --dry-run --non-interactive --ip 10.0.0.83 --skip-apache
  assert_success
  refute_output "a2enmod"
}

@test "Dry-run does not write credentials file" {
  CREDS_TMP=$(mktemp -u)
  rm -f "$CREDS_TMP"
  [ ! -f "$CREDS_TMP" ]
  run_script --dry-run --non-interactive --ip 10.0.0.84 --save-creds "$CREDS_TMP"
  assert_success
  assert_output "DRY-RUN: Would write credentials to"
  [ ! -f "$CREDS_TMP" ]
  rm -f "$CREDS_TMP"
}

@test "Secrets are masked in dry-run output" {
  run_script --dry-run --non-interactive --ip 10.0.0.87
  assert_success
  assert_output "[REDACTED]"
}

@test "Skip-ssl conflicts with tls selfsigned" {
  run_script --skip-ssl --tls selfsigned --non-interactive --ip 10.0.0.89
  assert_failure
  assert_output "Conflicting TLS options"
}

@test "Help works without --ip" {
  run_script --help --non-interactive
  assert_success
}

@test "Can run non-interactive with tls none in dry-run" {
  run_script --dry-run --non-interactive --ip 192.168.1.100 --tls none
  assert_success
  assert_output "TLS mode: none"
}

@test "Can run non-interactive with tls selfsigned in dry-run" {
  run_script --dry-run --non-interactive --ip 192.168.1.101 --tls selfsigned
  assert_success
  assert_output "TLS mode: selfsigned"
}

@test "Can run non-interactive with tls letsencrypt in dry-run" {
  run_script --dry-run --non-interactive --ip example.com --tls letsencrypt --le-email test@example.com
  assert_success
  assert_output "TLS mode: letsencrypt"
}
