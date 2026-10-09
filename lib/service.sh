# shellcheck shell=bash
# Agent user-systemd plumbing and service commands.
#
# Chain of dependencies, checked in this order:
#   agent account -> linger -> user@<uid>.service -> /run/user/<uid>/bus
#     -> $T3_SERVICE -> listening port

linger_enabled() {
  resolve_agent
  [[ -e ${T3CTL_LINGER_DIR:-/var/lib/systemd/linger}/$AGENT_USER ]] && return 0
  [[ $(loginctl show-user "$AGENT_USER" -p Linger --value 2>/dev/null) == yes ]]
}

user_manager_unit() {
  resolve_agent
  printf 'user@%s.service\n' "$AGENT_UID"
}

user_manager_active() { systemctl is-active --quiet "$(user_manager_unit)"; }

user_bus_present() { [[ -S $(agent_bus_path) ]]; }

# Poll a command until it succeeds or the timeout (seconds) elapses.
wait_for() {
  local timeout=$1
  shift
  local deadline=$((SECONDS + timeout))
  while :; do
    "$@" && return 0
    ((SECONDS >= deadline)) && return 1
    sleep 0.5
  done
}

ensure_linger() {
  linger_enabled && return 0
  note "Linger is disabled for $AGENT_USER; enabling (sudo loginctl enable-linger $AGENT_USER)."
  as_root loginctl enable-linger "$AGENT_USER"
}

ensure_user_manager() {
  user_manager_active && return 0
  local unit
  unit=$(user_manager_unit)
  note "$unit is not active; starting it (sudo systemctl start $unit)."
  as_root systemctl start "$unit"
}

# Make sure the agent's user bus exists, attempting a bounded recovery.
ensure_user_bus() {
  user_bus_present && return 0
  note "User bus $(agent_bus_path) is missing; attempting recovery."
  ensure_linger || die "could not enable linger for $AGENT_USER"
  ensure_user_manager || die "could not start $(user_manager_unit)"
  if wait_for "$BUS_WAIT_SECONDS" user_bus_present; then
    note "User bus is back: $(agent_bus_path)"
    return 0
  fi
  die "user bus $(agent_bus_path) still missing after ${BUS_WAIT_SECONDS}s; check: systemctl status $(user_manager_unit)"
}

# Print the service ActiveState (active, inactive, failed, ...). Never fails.
service_state() {
  local s
  s=$(run_agent_systemctl is-active "$T3_SERVICE" 2>/dev/null) || true
  printf '%s\n' "${s:-unknown}"
}

service_is_active() { [[ $(service_state) == active ]]; }

# Listening sockets on the configured port (empty if none).
port_listeners() {
  [[ -n $T3_PORT ]] || return 0
  ss -Hltn "sport = :$T3_PORT" 2>/dev/null | awk '{print $4}' | sort -u | paste -sd' ' -
}

port_listening() { [[ -n $(port_listeners) ]]; }

# Wait for the service (and port, if configured) to come up.
wait_service_healthy() {
  if ! wait_for "$START_TIMEOUT_SECONDS" service_is_active; then
    return 1
  fi
  if [[ -n $T3_PORT ]]; then
    wait_for "$START_TIMEOUT_SECONDS" port_listening || return 2
  fi
  return 0
}

# Names of agent-session processes (claude, codex, ...) running inside the
# service's cgroup. They are children of T3 and die with stop/restart.
service_agent_sessions() {
  local cg pids
  cg=$(run_agent_systemctl show -p ControlGroup --value "$T3_SERVICE" 2>/dev/null) || return 0
  [[ -n $cg && -d ${T3CTL_CGROUP_ROOT:-/sys/fs/cgroup}$cg ]] || return 0
  pids=$(find "${T3CTL_CGROUP_ROOT:-/sys/fs/cgroup}$cg" -name cgroup.procs -exec cat {} + 2>/dev/null | paste -sd, -)
  [[ -n $pids ]] || return 0
  ps -o comm= -p "$pids" 2>/dev/null | grep -E "$AGENT_PROCESS_PATTERN" | sort | uniq -c |
    awk '{printf "%s%s x%s", (NR > 1 ? ", " : ""), $2, $1} END {if (NR) print ""}'
}

# Warn (and confirm) before an action that terminates live agent sessions.
confirm_session_impact() {
  local action=$1 sessions
  sessions=$(service_agent_sessions)
  [[ -n $sessions ]] || return 0
  note "${C_YEL}Note:${C_RST} $action $T3_SERVICE terminates agent sessions running under it: $sessions"
  note "(Other $AGENT_USER processes outside the service are not touched.)"
  confirm "Continue?" || die "aborted"
}

status_line() {
  local label=$1 level=$2 msg=$3 color=
  case $level in
    OK) color=$C_GRN ;;
    WARN) color=$C_YEL ;;
    FAIL | CRIT) color=$C_RED ;;
    *) color=$C_DIM ;;
  esac
  printf '  %-20s %s%-4s%s %s\n' "$label" "$color" "$level" "$C_RST" "$msg"
}

# Print runtime chain checks. Returns number of failed checks.
runtime_report() {
  local fails=0 state listeners
  resolve_agent
  status_line "agent account" OK "$AGENT_USER (uid $AGENT_UID)"
  if linger_enabled; then
    status_line "linger" OK "enabled"
  else
    status_line "linger" FAIL "disabled  (fix: sudo loginctl enable-linger $AGENT_USER)"
    fails=$((fails + 1))
  fi
  if user_manager_active; then
    status_line "user manager" OK "active ($(user_manager_unit))"
  else
    status_line "user manager" FAIL "$(user_manager_unit) not active"
    fails=$((fails + 1))
  fi
  if user_bus_present; then
    status_line "user bus" OK "$(agent_bus_path)"
    state=$(service_state)
    if [[ $state == active ]]; then
      status_line "$T3_SERVICE" OK "$state"
    else
      status_line "$T3_SERVICE" FAIL "$state"
      fails=$((fails + 1))
    fi
  else
    status_line "user bus" FAIL "$(agent_bus_path) missing"
    status_line "$T3_SERVICE" '?' "unknown (no user bus)"
    fails=$((fails + 2))
  fi
  if [[ -n $T3_PORT ]]; then
    listeners=$(port_listeners)
    if [[ -n $listeners ]]; then
      status_line "port $T3_PORT" OK "listening ($listeners)"
    else
      status_line "port $T3_PORT" FAIL "not listening"
      fails=$((fails + 1))
    fi
  fi
  return "$fails"
}

cmd_service_status() {
  local rc=0
  printf '%sRuntime%s\n' "$C_BLD" "$C_RST"
  runtime_report || rc=$?
  if user_bus_present; then
    echo
    run_agent_systemctl status --no-pager --lines=10 "$T3_SERVICE" || true
  fi
  if ((rc)); then
    echo
    note "Unhealthy. Try: t3ctl reset   (or t3ctl doctor for more detail)"
    return 3
  fi
}

show_failure_context() {
  echo
  note "Recent service journal:"
  run_agent_journalctl -u "$T3_SERVICE" -n 15 --no-pager 2>&1 | sed 's/^/  /' >&2 || true
  if run_as_agent test -r "$T3_LOG_FILE" 2>/dev/null; then
    note "Tail of $T3_LOG_FILE:"
    run_as_agent tail -n 15 -- "$T3_LOG_FILE" 2>&1 | sed 's/^/  /' >&2 || true
  fi
}

# start/restart share the post-action verification.
verify_started() {
  local rc=0
  wait_service_healthy || rc=$?
  case $rc in
    0) printf '%s is active%s.\n' "$T3_SERVICE" "${T3_PORT:+ and listening on port $T3_PORT}" ;;
    1)
      note "$T3_SERVICE did not become active within ${START_TIMEOUT_SECONDS}s (state: $(service_state))."
      show_failure_context
      return 1
      ;;
    2)
      note "$T3_SERVICE is active but port $T3_PORT is not listening after ${START_TIMEOUT_SECONDS}s."
      show_failure_context
      return 1
      ;;
  esac
}

cmd_service_start() {
  ensure_user_bus
  run_agent_systemctl start "$T3_SERVICE"
  verify_started
}

cmd_service_stop() {
  ensure_user_bus
  confirm_session_impact "Stopping"
  run_agent_systemctl stop "$T3_SERVICE"
  printf '%s: %s\n' "$T3_SERVICE" "$(service_state)"
}

cmd_service_restart() {
  ensure_user_bus
  confirm_session_impact "Restarting"
  note "Restarting $T3_SERVICE as $AGENT_USER..."
  run_agent_systemctl restart "$T3_SERVICE"
  verify_started
}

# Systemd-level recovery. Never kills unrelated agent processes and never
# touches worktrees, state or configuration.
cmd_service_reset() {
  note "[1/5] Ensuring linger, user manager and user bus"
  ensure_linger || die "could not enable linger"
  ensure_user_manager || die "could not start $(user_manager_unit)"
  ensure_user_bus
  confirm_session_impact "Resetting"
  note "[2/5] Stopping $T3_SERVICE"
  run_agent_systemctl stop "$T3_SERVICE" || warn "stop returned an error; continuing"
  note "[3/5] Clearing failed state and reloading units"
  run_agent_systemctl reset-failed "$T3_SERVICE" 2>/dev/null || true
  run_agent_systemctl daemon-reload || warn "daemon-reload failed; continuing"
  note "[4/5] Starting $T3_SERVICE"
  run_agent_systemctl start "$T3_SERVICE" || {
    show_failure_context
    die "start failed"
  }
  note "[5/5] Waiting for service${T3_PORT:+ and port $T3_PORT}"
  verify_started || return 1
  echo
  runtime_report || true
}

cmd_service_logs() {
  local lines=100 follow=0 src=auto since=
  while (($#)); do
    case $1 in
      -f | --follow) follow=1 ;;
      -n | --lines)
        [[ ${2:-} =~ ^[0-9]+$ ]] || die "-n needs a number"
        lines=$2
        shift
        ;;
      --since)
        [[ -n ${2:-} ]] || die "--since needs a value"
        since=$2
        shift
        ;;
      --journal) src="journal" ;;
      --file) src="file" ;;
      *) die "unknown logs option: $1 (use -n N, -f, --since T, --journal, --file)" ;;
    esac
    shift
  done
  resolve_agent

  local -a jargs=(-u "$T3_SERVICE" -n "$lines" --no-pager)
  [[ -n $since ]] && jargs+=(--since "$since")
  local have_file=0
  run_as_agent test -r "$T3_LOG_FILE" 2>/dev/null && have_file=1

  if [[ $src == file && $have_file == 0 ]]; then
    die "log file not readable: $T3_LOG_FILE"
  fi

  if ((follow)); then
    if [[ $src == journal || ($src == auto && $have_file == 0) ]]; then
      run_agent_journalctl "${jargs[@]}" -f
    else
      run_as_agent tail -n "$lines" -F -- "$T3_LOG_FILE"
    fi
    return
  fi

  if [[ $src != file ]]; then
    printf '%s== journal: %s ==%s\n' "$C_BLD" "$T3_SERVICE" "$C_RST"
    run_agent_journalctl "${jargs[@]}" || true
  fi
  if [[ $src != journal && $have_file == 1 ]]; then
    [[ $src == auto ]] && echo
    printf '%s== %s ==%s\n' "$C_BLD" "$T3_LOG_FILE" "$C_RST"
    run_as_agent tail -n "$lines" -- "$T3_LOG_FILE"
  fi
}

service_dispatch() {
  local sub=$1
  shift
  resolve_agent
  case $sub in
    status) cmd_service_status "$@" ;;
    start) cmd_service_start "$@" ;;
    stop) cmd_service_stop "$@" ;;
    restart) cmd_service_restart "$@" ;;
    reset) cmd_service_reset "$@" ;;
    logs) cmd_service_logs "$@" ;;
    *) die "unknown service command: $sub" ;;
  esac
}
