#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

# Helper function to run the script with given arguments
run_script() {
  run ./zabbix-auto-install.sh "$@"
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
  # Verify zabbix-agent2 is selected in dry-run mode
  assert_output --partial "zabbix-agent2"
}

@test "Dry-run HTTP mode configures Apache by default" {
  run_script --dry-run --non-interactive --ip 10.0.0.80
  assert_success
  # Apache packages should be installed (when TLS=none)
  assert_output --partial "apache2"
  assert_output --partial "libapache2-mod-php"
  assert_output --partial "a2enmod"
}

@test "Dry-run with self-signed TLS includes SSL" {
  run_script --dry-run --non-interactive --ip 10.0.0.81 --tls selfsigned
  assert_success
  # Should output openssl and SSL-related messages
  assert_output --partial "openssl"
  assert_output --partial "SSL"
}

@test "Dry-run with letsencrypt" {
  run_script --dry-run --non-interactive --ip 10.0.0.82 --tls letsencrypt --le-email admin@example.com
  assert_success
  # certbot packages should be mentioned in apt-get install
  assert_output --partial "certbot"
}

@test "Dry-run with --skip-apache skips Apache packages" {
  run_script --dry-run --non-interactive --ip 10.0.0.83 --skip-apache
  assert_success
  # Apache package install should not appear in the dry-run plan
  refute_output --partial "a2enmod"
}

@test "Dry-run does not write credentials file" {
  CREDS_TMP=$(mktemp -u)
  rm -f "$CREDS_TMP"
  # File must not exist before
  [ ! -f "$CREDS_TMP" ]
  run_script --dry-run --non-interactive --ip 10.0.0.84 --save-creds "$CREDS_TMP"
  assert_success
  assert_output --partial "DRY-RUN: Would write credentials to"
  # File should NOT exist when dry-run (it was only a planned write)
  [ ! -f "$CREDS_TMP" ]
  rm -f "$CREDS_TMP"
}

@test "Secrets are masked in dry-run output" {
  run_script --dry-run --non-interactive --ip 10.0.0.87
  assert_success
  # Mask markers should appear instead
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