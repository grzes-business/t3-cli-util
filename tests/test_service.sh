#!/usr/bin/env bash
# Service plumbing against mock systemctl/loginctl/sudo/ss/journalctl.
# The real systemd is never contacted: mocks shadow the binaries on PATH.
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

MOCK="$T/mockbin"
MOCK_STATE="$T/state"
MOCK_LOG="$T/calls.log"
UID_SELF=$(id -u)
BUS="$T/run/$UID_SELF/bus"
export MOCK_STATE MOCK_LOG BUS
mkdir -p "$MOCK" "$MOCK_STATE" "$T/run/$UID_SELF" "$T/linger" "$T/worktrees"

cat >"$MOCK/mkbus" <<'EOF'
#!/usr/bin/env bash
python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$1"
EOF

cat >"$MOCK/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $* | XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-} DBUS=${DBUS_SESSION_BUS_ADDRESS:-}" >>"$MOCK_LOG"
case "$*" in
  "--user is-active "*)
    s=$(cat "$MOCK_STATE/service" 2>/dev/null || echo inactive)
    echo "$s"
    [[ $s == active ]]
    exit ;;
  "is-active --quiet user@"*)
    [[ -e $MOCK_STATE/manager ]]
    exit ;;
  "start user@"*)
    touch "$MOCK_STATE/manager"
    [[ -e $MOCK_STATE/bus_on_manager_start ]] && mkbus "$BUS"
    exit 0 ;;
  "--user start "* | "--user restart "*)
    [[ -e $MOCK_STATE/start_fails ]] && exit 1
    echo active >"$MOCK_STATE/service"
    [[ -e $MOCK_STATE/no_listen ]] || touch "$MOCK_STATE/listening" ;;
  "--user stop "*)
    echo inactive >"$MOCK_STATE/service"
    rm -f "$MOCK_STATE/listening" ;;
  "--user show -p ControlGroup --value "*) cat "$MOCK_STATE/cgroup" 2>/dev/null ;;
  "--user status "*) echo "mock status output" ;;
esac
exit 0
EOF

cat >"$MOCK/loginctl" <<'EOF'
#!/usr/bin/env bash
echo "loginctl $*" >>"$MOCK_LOG"
case $1 in
  enable-linger) touch "$T3CTL_LINGER_DIR/$2" ;;
  show-user) echo no ;;
esac
EOF

cat >"$MOCK/sudo" <<'EOF'
#!/usr/bin/env bash
echo "sudo $*" >>"$MOCK_LOG"
[[ $1 == -u ]] && shift 2
[[ $1 == -- ]] && shift
exec "$@"
EOF

cat >"$MOCK/ss" <<'EOF'
#!/usr/bin/env bash
[[ -e $MOCK_STATE/listening ]] && echo "LISTEN 0 511 127.0.0.1:3773 0.0.0.0:*"
exit 0
EOF

cat >"$MOCK/journalctl" <<'EOF'
#!/usr/bin/env bash
echo "journalctl $*" >>"$MOCK_LOG"
echo "mock journal line"
EOF

cat >"$MOCK/t3-update" <<'EOF'
#!/usr/bin/env bash
printf 'update HOME=%s runtime=%s args:' "$HOME" "$XDG_RUNTIME_DIR" >>"$MOCK_LOG"
printf ' <%s>' "$@" >>"$MOCK_LOG"
printf '\n' >>"$MOCK_LOG"
[[ ! -e $MOCK_STATE/update_fails ]]
EOF

for f in pkill killall kill; do
  printf '#!/usr/bin/env bash\necho "FORBIDDEN %s $*" >>"$MOCK_LOG"\n' "$f" >"$MOCK/$f"
done
chmod +x "$MOCK"/*

export PATH="$MOCK:$PATH"
export T3CTL_RUNTIME_BASE="$T/run" T3CTL_LINGER_DIR="$T/linger" T3CTL_CGROUP_ROOT="$T/cg"
write_config 'T3_PORT=3773' 'BUS_WAIT_SECONDS=1' 'START_TIMEOUT_SECONDS=1' 'AGENT_STORAGE_DIRS=(.t3ctl-test-none)'

reset_mocks() {
  rm -rf "${MOCK_STATE:?}"/* "$BUS" "$T/linger"/*
  : >"$MOCK_LOG"
  touch "$MOCK_STATE/manager" "$T/linger/$(id -un)"
  mkbus "$BUS"
  echo active >"$MOCK_STATE/service"
  touch "$MOCK_STATE/listening"
}

t3() { "$T3CTL" "$@" 2>&1; }

test_restart_sets_bus_environment() {
  reset_mocks
  local out
  out=$(t3 restart)
  assert_contains "$out" "is active and listening on port 3773"
  assert_contains "$(cat "$MOCK_LOG")" "systemctl --user restart t3code.service | XDG_RUNTIME_DIR=$T/run/$UID_SELF DBUS=unix:path=$BUS"
}

test_status_healthy_and_unhealthy() {
  reset_mocks
  local out rc=0
  out=$(t3 status) || rc=$?
  assert_eq "$rc" 0 "healthy exit code"
  assert_contains "$out" "user bus             OK   $BUS"
  assert_contains "$out" "port 3773            OK   listening (127.0.0.1:3773)"
  assert_contains "$out" "mock status output"
  echo failed >"$MOCK_STATE/service"
  rm -f "$MOCK_STATE/listening"
  rc=0
  out=$(t3 service status) || rc=$?
  assert_eq "$rc" 3 "unhealthy exit code"
  assert_contains "$out" "t3code.service       FAIL failed"
  assert_contains "$out" "Try: t3ctl reset"
}

test_missing_bus_recovery() {
  reset_mocks
  rm -f "$BUS" "$MOCK_STATE/manager" "$T/linger"/*
  touch "$MOCK_STATE/bus_on_manager_start"
  local out log
  out=$(t3 restart)
  log=$(cat "$MOCK_LOG")
  assert_contains "$out" "is missing; attempting recovery"
  assert_contains "$log" "sudo -- loginctl enable-linger $(id -un)"
  assert_contains "$log" "sudo -- systemctl start user@$UID_SELF.service"
  assert_contains "$log" "systemctl --user restart t3code.service"
  [[ -S $BUS ]] || fail "bus should exist after recovery"
}

test_missing_bus_gives_up() {
  reset_mocks
  rm -f "$BUS"
  local out rc=0 start=$SECONDS
  out=$(t3 restart) || rc=$?
  assert_eq "$rc" 1 "exit code"
  assert_contains "$out" "still missing after 1s"
  ((SECONDS - start < 10)) || fail "recovery must not loop indefinitely"
  assert_not_contains "$(cat "$MOCK_LOG")" "--user restart"
}

test_status_does_not_recover() {
  reset_mocks
  rm -f "$BUS"
  local out rc=0
  out=$(t3 status) || rc=$?
  assert_eq "$rc" 3 "exit code"
  assert_contains "$out" "user bus             FAIL"
  assert_not_contains "$(cat "$MOCK_LOG")" "start user@"
}

test_reset_sequence() {
  reset_mocks
  echo failed >"$MOCK_STATE/service"
  local out seq
  out=$(t3 reset)
  assert_contains "$out" "[5/5]"
  assert_contains "$out" "is active"
  seq=$(grep -o 'systemctl --user [a-z-]* t3code.service\|systemctl --user daemon-reload' "$MOCK_LOG" |
    grep -v 'is-active\|show' | awk '{print $3}' | paste -sd' ' -)
  assert_eq "$seq" "stop reset-failed daemon-reload start" "reset order"
}

test_start_failure_reports() {
  reset_mocks
  echo inactive >"$MOCK_STATE/service"
  rm -f "$MOCK_STATE/listening"
  touch "$MOCK_STATE/no_listen"
  local out rc=0
  out=$(t3 start) || rc=$?
  assert_eq "$rc" 1 "exit code"
  assert_contains "$out" "port 3773 is not listening"
  assert_contains "$out" "Recent service journal"
}

test_session_warning_requires_confirmation() {
  reset_mocks
  mkdir -p "$T/cg/svc"
  sleep 30 &
  local pid=$! out rc=0
  echo "$pid" >"$T/cg/svc/cgroup.procs"
  echo /svc >"$MOCK_STATE/cgroup"
  write_config 'T3_PORT=3773' 'BUS_WAIT_SECONDS=1' 'START_TIMEOUT_SECONDS=1' 'AGENT_STORAGE_DIRS=(.t3ctl-test-none)' "AGENT_PROCESS_PATTERN='^sleep\$'"
  out=$(t3 restart </dev/null) || rc=$?
  assert_eq "$rc" 1 "aborts without --yes"
  assert_contains "$out" "terminates agent sessions running under it: sleep x1"
  assert_not_contains "$(cat "$MOCK_LOG")" "--user restart"
  out=$(t3 --yes restart)
  assert_contains "$(cat "$MOCK_LOG")" "--user restart"
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  rm -rf "$T/cg"
  write_config 'T3_PORT=3773' 'BUS_WAIT_SECONDS=1' 'START_TIMEOUT_SECONDS=1' 'AGENT_STORAGE_DIRS=(.t3ctl-test-none)'
}

test_logs_journal_and_file() {
  reset_mocks
  printf 'line1\nline2\n' >"$T/service.log"
  local out
  out=$(t3 logs -n 5)
  assert_contains "$out" "mock journal line"
  assert_contains "$out" "line2"
  assert_contains "$(cat "$MOCK_LOG")" "journalctl --user -u t3code.service -n 5 --no-pager"
  out=$(t3 logs --bogus)
  assert_contains "$out" "unknown logs option"
}

test_cross_user_goes_through_sudo() {
  reset_mocks
  # Pretend the agent account is root: we are not root, so sudo -u must be used.
  mkdir -p "$T/run/0" && mkbus "$T/run/0/bus"
  touch "$T/linger/root"
  write_config 'AGENT_USER=root' 'T3_PORT=3773' 'START_TIMEOUT_SECONDS=1'
  t3 restart >/dev/null
  assert_contains "$(cat "$MOCK_LOG")" "sudo -u root -- env HOME=/root XDG_RUNTIME_DIR=$T/run/0 DBUS_SESSION_BUS_ADDRESS=unix:path=$T/run/0/bus"
  # The bus lives in a 0700 dir owned by the agent; it must be checked as the agent.
  assert_contains "$(cat "$MOCK_LOG")" "LC_ALL=C test -S $T/run/0/bus"
  write_config 'T3_PORT=3773' 'BUS_WAIT_SECONDS=1' 'START_TIMEOUT_SECONDS=1' 'AGENT_STORAGE_DIRS=(.t3ctl-test-none)'
}

update_config() {
  write_config 'T3_PORT=3773' 'START_TIMEOUT_SECONDS=1' 'T3_UPDATE_COMMAND=(t3-update "two words" "\$(literal)")'
}

test_update_runs_as_agent_then_restarts() {
  reset_mocks
  update_config
  local out log
  out=$(t3 update)
  log=$(cat "$MOCK_LOG")
  assert_contains "$out" "is active and listening on port 3773"
  assert_contains "$log" 'args: <two words> <$(literal)>'
  assert_contains "$log" "runtime=$T/run/$UID_SELF"
  assert_eq "$(sed -n '/^update /p; /systemctl --user restart /p' "$MOCK_LOG" | sed 's/ .*//' | paste -sd' ' -)" "update systemctl" "update before restart"
  write_config 'T3_PORT=3773' 'START_TIMEOUT_SECONDS=1'
}

test_update_requires_configuration() {
  reset_mocks
  write_config 'T3_PORT=3773'
  local out rc=0
  out=$(t3 update) || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "T3_UPDATE_COMMAND"
  assert_not_contains "$(cat "$MOCK_LOG")" "--user restart"
}

test_update_failure_does_not_restart() {
  reset_mocks
  update_config
  touch "$MOCK_STATE/update_fails"
  local out rc=0
  out=$(t3 service update) || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "update command failed"
  assert_not_contains "$(cat "$MOCK_LOG")" "--user restart"
  write_config 'T3_PORT=3773' 'START_TIMEOUT_SECONDS=1'
}

test_update_rejects_extra_arguments() {
  reset_mocks
  update_config
  local out rc=0
  out=$(t3 update --bogus) || rc=$?
  assert_eq "$rc" 1
  assert_not_contains "$(cat "$MOCK_LOG")" "update HOME="
  write_config 'T3_PORT=3773' 'START_TIMEOUT_SECONDS=1'
}

test_update_verifies_port() {
  reset_mocks
  update_config
  rm -f "$MOCK_STATE/listening"
  touch "$MOCK_STATE/no_listen"
  local out rc=0
  out=$(t3 update) || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "port 3773 is not listening"
  assert_contains "$out" "Recent service journal"
  write_config 'T3_PORT=3773' 'START_TIMEOUT_SECONDS=1'
}

test_update_confirms_sessions_before_installing() {
  reset_mocks
  mkdir -p "$T/cg/svc"
  sleep 30 &
  local pid=$! out rc=0
  echo "$pid" >"$T/cg/svc/cgroup.procs"
  echo /svc >"$MOCK_STATE/cgroup"
  write_config 'T3_PORT=3773' 'START_TIMEOUT_SECONDS=1' 'T3_UPDATE_COMMAND=(t3-update)' "AGENT_PROCESS_PATTERN='^sleep\$'"
  out=$(t3 update </dev/null) || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "terminates agent sessions"
  assert_not_contains "$(cat "$MOCK_LOG")" "update HOME="
  out=$(t3 --yes update)
  assert_contains "$out" "is active"
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  rm -rf "$T/cg"
  write_config 'T3_PORT=3773' 'START_TIMEOUT_SECONDS=1'
}

test_never_kills_processes() {
  assert_not_contains "$(cat "$MOCK_LOG")" "FORBIDDEN"
}

test_doctor_reports_runtime_and_storage() {
  reset_mocks
  local out rc=0
  out=$(t3 doctor) || rc=$?
  assert_contains "$out" "Runtime"
  assert_contains "$out" "Storage"
  assert_contains "$out" "root disk"
  assert_contains "$out" "inode usage"
  assert_contains "$out" "worktrees"
  rm -f "$BUS"
  rc=0
  out=$(t3 doctor) || rc=$?
  assert_eq "$rc" 2 "doctor exit code on failure"
  assert_contains "$out" "t3ctl reset"
  assert_not_contains "$(cat "$MOCK_LOG")" "start user@" "doctor must not repair"
}

test_disk_command() {
  reset_mocks
  local out
  out=$(t3 disk)
  assert_contains "$out" "Filesystem / "
  assert_contains "$out" "Agent storage"
  assert_contains "$out" "Largest worktrees"
}

run_tests
finish
