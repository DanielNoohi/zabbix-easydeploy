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
  assert_output "7.2"
  assert_output "7.4"
}

@test "Version option returns success" {
  run_script --version
  assert_success
  assert_output "zabbix-auto-install.sh"
}

@test "Non-interactive mode without IP fails" {
  run_script --non-interactive
  assert_failure
  assert_output "Non-interactive mode requires --ip"
}

@test "Option requiring a value fails when value is missing" {
  run_script --non-interactive --ip
  assert_failure
  assert_output "requires a value"
}

@test "Option requiring a value fails when next token is another flag" {
  run_script --non-interactive --ip --agent2
  assert_failure
  assert_output "requires a value"
}

@test "LetsEncrypt mode without email fails" {
  run_script --non-interactive --ip 1.2.3.4 --tls letsencrypt
  assert_failure
  assert_output "Let's Encrypt mode requires --le-email"
}

@test "Conflicting TLS options fail" {
  run_script --non-interactive --ip 1.2.3.4 --tls letsencrypt --skip-ssl
  assert_failure
  assert_output "Conflicting TLS options"
}

@test "Invalid TLS mode fails" {
  run_script --non-interactive --ip 1.2.3.4 --tls bogus
  assert_failure
  assert_output "Invalid TLS mode"
}

@test "Accepts valid zabbix versions" {
  for ver in 6.0 7.0 7.2 7.4; do
    run_script --dry-run --non-interactive --ip 1.2.3.4 --zabbix-ver "$ver" --skip-apache --no-firewall
    assert_success
    assert_output "Zabbix Version: $ver"
  done
}

@test "Rejects invalid zabbix version" {
  run_script --zabbix-ver 9.9 --non-interactive --ip 1.2.3.4
  assert_failure
  assert_output "Unsupported Zabbix version"
}

@test "Rejects Ubuntu 18.04" {
  run_script --dry-run --non-interactive --ip 1.2.3.4 --ubuntu-ver 18.04
  assert_failure
  assert_output "18.04 is no longer supported"
}

@test "Dry-run uses latest meta-package URL" {
  run_script --dry-run --non-interactive --ip 1.2.3.4 --zabbix-ver 7.4 --ubuntu-ver 24.04 --skip-apache --no-firewall
  assert_success
  assert_output "zabbix-release_latest_7.4+ubuntu24.04_all.deb"
  assert_output "/release/ubuntu/pool/main/z/zabbix-release/"
}

# ==================== Dry-Run Safety & Output ====================

@test "Dry-run mode makes zero system changes" {
  # Run a full dry-run
  run_script --dry-run --non-interactive --ip 1.2.3.4 --agent2
  assert_success
  assert_output "DRY-RUN:"

  # Verify no temp files left in /tmp from our script
  run ls /tmp/zabbix-* /tmp/sed-*
  # We expect ls to fail (no files found) or return nothing
  if [ "$status" -eq 0 ] && [ -n "$output" ]; then
    echo "Dry-run left temp files: $output" >&2
    return 1
  fi
}

@test "Dry-run shows bcrypt password generation" {
  run_script --dry-run --non-interactive --ip 1.2.3.4
  assert_success
  assert_output "Admin password (bcrypt)"
}

@test "Dry-run shows agent configuration plan" {
  run_script --dry-run --non-interactive --ip 1.2.3.4 --agent2
  assert_success
  assert_output "Configuring Zabbix agent 2"
  assert_output "zabbix_agent2.conf"
  assert_output "Server=1.2.3.4"
  assert_output "ListenIP=127.0.0.1"
  assert_output "Would disable unused agent unit zabbix-agent"
}

@test "Dry-run with --skip-apache skips web firewall ports plan" {
  run_script --dry-run --non-interactive --ip 1.2.3.4 --skip-apache --no-firewall
  assert_success
  assert_output "Apache skipped"
}

# ==================== Mock-based Logic Tests ====================

@test "Agent config update handles existing keys and comments" {
  CONF_FILE=$(mktemp)
  cat >"$CONF_FILE" <<EOF
# Server=127.0.0.1
Server=old.ip
  ServerActive = 127.0.0.1
Hostname=Zabbix server
EOF

  # Source just the function from the script (exit immediately after)
  eval "$(sed -n '/^update_config_line()/,/^}/p' ./zabbix-auto-install.sh)"

  update_config_line "$CONF_FILE" "Server" "1.2.3.4"
  update_config_line "$CONF_FILE" "ServerActive" "1.2.3.4"
  update_config_line "$CONF_FILE" "ListenIP" "127.0.0.1"

  run grep "^Server=1.2.3.4" "$CONF_FILE"
  assert_success

  run grep -c "^Server=" "$CONF_FILE"
  [ "$output" -eq 1 ]

  run grep "^ServerActive=1.2.3.4" "$CONF_FILE"
  assert_success

  run grep "^ListenIP=127.0.0.1" "$CONF_FILE"
  assert_success

  rm -f "$CONF_FILE"
}

@test "sql_escape doubles single quotes" {
  eval "$(sed -n '/^sql_escape()/,/^}/p' ./zabbix-auto-install.sh)"
  run sql_escape "O'Reilly"
  assert_success
  [ "$output" = "O''Reilly" ]
}

@test "zabbix_release_url picks legacy vs release layout" {
  eval "$(sed -n '/^zabbix_release_url()/,/^}/p' ./zabbix-auto-install.sh)"
  run zabbix_release_url 7.0 24.04
  assert_success
  [[ "$output" == *"/zabbix/7.0/ubuntu/pool/"* ]]
  [[ "$output" == *"zabbix-release_latest_7.0+ubuntu24.04_all.deb" ]]

  run zabbix_release_url 7.4 24.04
  assert_success
  [[ "$output" == *"/zabbix/7.4/release/ubuntu/pool/"* ]]
  [[ "$output" == *"zabbix-release_latest_7.4+ubuntu24.04_all.deb" ]]
}

@test "Dry-run output contains no password material" {
  run bash -n zabbix-auto-install.sh
  [ "$status" -eq 0 ]
  # Run the script in dry-run mode and capture output
  run ./zabbix-auto-install.sh --dry-run --non-interactive --ip 127.0.0.1 --zabbix-ver 7.0 --skip-apache --agent2 --no-firewall
  # The output should NOT contain any password values
  # (passwords are generated per-run, so we check for absence of patterns)
  [[ ! "$output" =~ "PASSWORD(" ]]
  [[ ! "$output" =~ "IDENTIFIED BY '" ]]
  [[ ! "$output" =~ "Admin Password:" ]] || [[ "$output" =~ "(see --save-creds" ]]
}
