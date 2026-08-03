#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

# Helper function to run the script with given arguments
run_script() {
  run ./zabbix-auto-install.sh "$@"
}

# Test that the help option returns 0 and prints usage
@test "Help option returns success and displays usage" {
  run_script --help
  assert_success
  assert_output --partial "Usage:"
  assert_output --partial "Options:"
}

# Test that non-interactive mode without IP fails
@test "Non-interactive mode without IP fails" {
  run_script --non-interactive
  assert_failure
  assert_output --partial "Non-interactive mode requires --ip"
}

# Test that invalid TLS mode requires email for letsencrypt
@test "LetsEncrypt mode without email fails" {
  run_script --non-interactive --ip 1.2.3.4 --tls letsencrypt
  assert_failure
  assert_output --partial "Let's Encrypt mode requires --le-email"
}

# Test that conflicting TLS options fail
@test "Conflicting TLS options (letsencrypt and skip-ssl) fail" {
  run_script --non-interactive --ip 1.2.3.4 --tls letsencrypt --skip-ssl
  assert_failure
  assert_output --partial "Conflicting TLS options"
}

# Test that LetsEncrypt mode with email passes argument check
@test "LetsEncrypt mode with email passes argument check" {
  run_script --non-interactive --ip 1.2.3.4 --tls letsencrypt --le-email test@example.com --dry-run
  assert_success
  refute_output --partial "Let's Encrypt mode requires --le-email"
}

# Test that the script accepts valid zabbix versions
@test "Accepts zabbix version 6.0" {
  run_script --zabbix-ver 6.0 --help
  assert_success
}

@test "Accepts zabbix version 7.0" {
  run_script --zabbix-ver 7.0 --help
  assert_success
}

# Test that invalid zabbix version is rejected
@test "Rejects invalid zabbix version" {
  run_script --zabbix-ver 9.9 --non-interactive --ip 1.2.3.4 --tls none
  assert_failure
  assert_output --partial "Unsupported Zabbix version"
}

# Test that the script accepts ubuntu version override
@test "Accepts ubuntu version override" {
  run_script --ubuntu-ver 22.04 --help
  assert_success
}

# Test that the script accepts timezone
@test "Accepts timezone" {
  run_script --timezone "Europe/London" --help
  assert_success
}

# Test that the script accepts save-creds option
@test "Accepts save-creds option" {
  run_script --save-creds /tmp/test.txt --help
  assert_success
}

# Test that the script accepts non-interactive flag
@test "Accepts non-interactive flag" {
  run_script --non-interactive --help
  assert_success
}

# Test that the script accepts force flag
@test "Accepts force flag" {
  run_script --force --help
  assert_success
}

# Test that the script accepts dry-run flag
@test "Accepts dry-run flag" {
  run_script --dry-run --help
  assert_success
}

# Test that the script accepts no-firewall flag
@test "Accepts no-firewall flag" {
  run_script --no-firewall --help
  assert_success
}

# Test that the script accepts skip-ssl flag
@test "Accepts skip-ssl flag" {
  run_script --skip-ssl --help
  assert_success
}

# Test that the script accepts agent2 flag
@test "Accepts agent2 flag" {
  run_script --agent2 --help
  assert_success
}

# Test that the script accepts skip-apache flag
@test "Accepts skip-apache flag" {
  run_script --skip-apache --help
  assert_success
}

# Test that the script accepts skip-php-tuning flag
@test "Accepts skip-php-tuning flag" {
  run_script --skip-php-tuning --help
  assert_success
}

# -------------------------
# Idempotency & Dry-Run Tests
# -------------------------

@test "Dry-run mode works without actual installation" {
  run_script --dry-run --non-interactive --ip 10.0.0.50
  assert_success
  assert_output --partial "DRY-RUN:"
  refute_output --partial "ERROR"
}

@test "Rejects invalid server address format" {
  run_script --ip "invalid..host**" --non-interactive --dry-run
  assert_failure
  assert_output --partial "Invalid server address"
}

@test "Can combine agent2 and skip-apache flags" {
  run_script --agent2 --skip-apache --help
  assert_success
}

@test "Accepts non-interactive with agent2" {
  run_script --agent2 --non-interactive --ip 10.0.0.52 --dry-run
  assert_success
  assert_output --partial "zabbix-agent2"
}

@test "Dry-run HTTP mode configures Apache by default" {
  run_script --dry-run --non-interactive --ip 10.0.0.80
  assert_success
  assert_output --partial "apache2"
  assert_output --partial "libapache2-mod-php"
  assert_output --partial "a2enmod"
}

@test "Dry-run with self-signed TLS includes SSL" {
  run_script --dry-run --non-interactive --ip 10.0.0.81 --tls selfsigned
  assert_success
  assert_output --partial "openssl"
  assert_output --partial "SSL"
}

@test "Dry-run with letsencrypt" {
  run_script --dry-run --non-interactive --ip 10.0.0.82 --tls letsencrypt --le-email admin@example.com
  assert_success
  assert_output --partial "certbot"
}

@test "Dry-run with --skip-apache skips Apache packages" {
  run_script --dry-run --non-interactive --ip 10.0.0.83 --skip-apache
  assert_success
  refute_output --partial "a2enmod"
}

@test "Dry-run does not write credentials file" {
  CREDS_TMP=$(mktemp -u)
  rm -f "$CREDS_TMP"
  [ ! -f "$CREDS_TMP" ]
  run_script --dry-run --non-interactive --ip 10.0.0.84 --save-creds "$CREDS_TMP"
  assert_success
  assert_output --partial "DRY-RUN: Would write credentials to"
  [ ! -f "$CREDS_TMP" ]
  rm -f "$CREDS_TMP"
}

@test "Secrets are masked in dry-run output" {
  run_script --dry-run --non-interactive --ip 10.0.0.87
  assert_success
  assert_output --partial "[REDACTED]"
}

@test "Skip-ssl conflicts with tls selfsigned" {
  run_script --skip-ssl --tls selfsigned --non-interactive --ip 10.0.0.89
  assert_failure
  assert_output --partial "Conflicting TLS options"
}

@test "Help works without --ip" {
  run_script --help --non-interactive
  assert_success
}

@test "Can run non-interactive with tls none in dry-run" {
  run_script --dry-run --non-interactive --ip 192.168.1.100 --tls none
  assert_success
  assert_output --partial "TLS mode: none"
}

@test "Can run non-interactive with tls selfsigned in dry-run" {
  run_script --dry-run --non-interactive --ip 192.168.1.101 --tls selfsigned
  assert_success
  assert_output --partial "TLS mode: selfsigned"
}

@test "Can run non-interactive with tls letsencrypt in dry-run" {
  run_script --dry-run --non-interactive --ip example.com --tls letsencrypt --le-email test@example.com
  assert_success
  assert_output --partial "TLS mode: letsencrypt"
}
