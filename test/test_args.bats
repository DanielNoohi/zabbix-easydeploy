#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

# Helper function to run the script with given arguments and capture output and status
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

# Test that invalid email format is not caught (we don't validate email format, just presence)
# We can test that the script proceeds when email is provided for letsencrypt (but will fail later due to missing domain, etc.)
# We are only testing argument parsing, so we expect it to pass the argument check and move on.
# However, note that the script will still fail because it's not actually installing, but we are only testing the argument parsing.
# We'll change the test to expect that the script does not fail on the argument check for missing email when we provide one.
@test "LetsEncrypt mode with email passes argument check" {
  # We expect the script to fail later (due to missing domain, etc.) but not due to missing email
  run_script --non-interactive --ip 1.2.3.4 --tls letsencrypt --le-email test@example.com
  # We don't assert success because the script will try to run and fail due to missing actual installation
  # But we can assert that it doesn't fail with the email error.
  refute_output --partial "Let's Encrypt mode requires --le-email"
}

# Test that the script accepts valid zabbix versions
@test "Accepts zabbix version 6.0" {
  run_script --help
  assert_success
  # We can't easily test the version without running the script, but we can check that the option is accepted in help
  run_script --zabbix-ver 6.0 --help
  assert_success
}

@test "Accepts zabbix version 7.0" {
  run_script --zabbix-ver 7.0 --help
  assert_success
}

# Test that invalid zabbix version is rejected
@test "Rejects invalid zabbix version" {
  run_script --zabbix-ver 9.9 --help
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

# Test that the script accepts save-creds
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