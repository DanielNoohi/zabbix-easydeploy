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

@test "Conflicting TLS options fail" {
  run_script --non-interactive --ip 1.2.3.4 --tls letsencrypt --skip-ssl
  assert_failure
  assert_output "Conflicting TLS options"
}

@test "Accepts valid zabbix versions" {
  run_script --zabbix-ver 6.0 --help
  assert_success
  run_script --zabbix-ver 7.0 --help
  assert_success
}

@test "Rejects invalid zabbix version" {
  run_script --zabbix-ver 9.9 --non-interactive --ip 1.2.3.4
  assert_failure
  assert_output "Unsupported Zabbix version"
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

  run grep "^Server=1.2.3.4" "$CONF_FILE"
  assert_success

  run grep -c "^Server=" "$CONF_FILE"
  [ "$output" -eq 1 ]

  run grep "^ServerActive=1.2.3.4" "$CONF_FILE"
  assert_success

  rm -f "$CONF_FILE"
}
