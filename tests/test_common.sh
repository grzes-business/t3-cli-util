#!/usr/bin/env bash
# Pure helpers, configuration hardening, installer and static safety checks.
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=../lib/common.sh
source "$T3CTL_REPO/lib/common.sh"

test_parse_duration() {
  assert_eq "$(parse_duration 30m)" 1800
  assert_eq "$(parse_duration 12h)" 43200
  assert_eq "$(parse_duration 7d)" 604800
  assert_eq "$(parse_duration 7)" 604800 "bare number means days"
  assert_eq "$(parse_duration 2w)" 1209600
  assert_eq "$(parse_duration 3mo)" 7776000
  assert_eq "$(parse_duration 08d)" 691200 "leading zero is decimal"
  local bad
  for bad in '' 7x -1d 1.5d 'd' '7 d' '$(id)'; do
    parse_duration "$bad" >/dev/null && fail "accepted invalid duration '$bad'"
  done
  return 0
}

test_human_formats() {
  assert_eq "$(human_kb 512)" "512K"
  assert_eq "$(human_kb 1536)" "1.5M"
  assert_eq "$(human_kb 2202010)" "2.1G"
  assert_eq "$(human_kb '?')" "?"
  assert_eq "$(human_age 90)" "1m"
  assert_eq "$(human_age 7200)" "2h"
  assert_eq "$(human_age 432000)" "5d"
  assert_eq "$(human_age 1814400)" "3w"
  assert_eq "$(human_age x)" "?"
}

test_agent_uid_is_resolved() {
  write_config
  (
    load_config
    assert_eq "$(resolve_agent_uid)" "$(id -u)"
    assert_eq "$(agent_bus_address)" "unix:path=/run/user/$(id -u)/bus"
  )
}

test_config_must_not_be_writable_by_others() {
  write_config
  chmod 666 "$T3CTL_CONFIG"
  local out
  out=$("$T3CTL" disk 2>&1)
  assert_contains "$out" "refusing group/world-writable config"
  chmod 600 "$T3CTL_CONFIG"
}

test_config_rejects_unsafe_clean_names() {
  local n out
  for n in '../x' '/' '.git' '..' 'a/b'; do
    write_config "SAFE_CLEAN_DIRS=(node_modules '$n')"
    out=$("$T3CTL" worktrees 2>&1)
    assert_contains "$out" "invalid SAFE_CLEAN_DIRS entry" "name '$n'"
  done
  write_config 'AGENT_USER="agent; rm -rf /"'
  out=$("$T3CTL" status 2>&1)
  assert_contains "$out" "invalid AGENT_USER"
  write_config
}

test_missing_explicit_config() {
  local out
  out=$(T3CTL_CONFIG="$T/nope" "$T3CTL" status 2>&1)
  assert_contains "$out" "config file not found"
}

test_usage_and_unknown_command() {
  local out rc=0
  out=$("$T3CTL" --help)
  assert_contains "$out" "worktree <id> clean"
  out=$("$T3CTL" frobnicate 2>&1) || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "unknown command"
}

test_install_is_idempotent() {
  local bin="$T/bin" out
  out=$("$T3CTL_REPO/install.sh" "$bin")
  assert_contains "$out" "Installed"
  out=$("$T3CTL_REPO/install.sh" "$bin")
  assert_contains "$out" "Already installed"
  assert_eq "$(readlink "$bin/t3ctl")" "$T3CTL_REPO/bin/t3ctl"
  out=$("$bin/t3ctl" --version)
  assert_contains "$out" "t3ctl "
  out=$("$T3CTL_REPO/uninstall.sh" "$bin")
  assert_contains "$out" "Removed"
  assert_missing "$bin/t3ctl"
}

# --- static checks over the shipped code -----------------------------------

shipped() { cat "$T3CTL_REPO/bin/t3ctl" "$T3CTL_REPO"/lib/*.sh; }

test_no_eval() {
  local hits
  hits=$(shipped | grep -nE '(^|[^A-Za-z_])eval([^A-Za-z_]|$)' | grep -v '^\s*#')
  assert_eq "$hits" "" "eval must not be used"
}

test_no_broad_process_killing() {
  local hits
  hits=$(shipped | grep -nE '\b(pkill|killall)\b|kill +-[0-9A-Z]* *-1|loginctl +(kill-user|terminate-user)')
  assert_eq "$hits" "" "no broad process termination"
}

test_no_hardcoded_uid() {
  local hits
  hits=$(shipped | grep -nE '/run/user/[0-9]|user@[0-9]+|\b1002\b')
  assert_eq "$hits" "" "UID must be resolved dynamically"
}

test_no_raw_rm_of_worktrees() {
  # The only rm -rf is the artifact cleanup, which deletes "$wt/$rel".
  local hits
  hits=$(shipped | grep -n 'rm -rf' | grep -v -- '--one-file-system -- "${wt:?}/$rel"')
  assert_eq "$hits" "" "unexpected rm -rf"
}

run_tests
finish
