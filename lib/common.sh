# shellcheck shell=bash disable=SC2034  # globals are consumed by other lib files
# Shared helpers: output, configuration, user/privilege plumbing.

T3CTL_VERSION="0.1.0"

# ---------------------------------------------------------------- output

if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
  C_RED=$'\e[31m' C_YEL=$'\e[33m' C_GRN=$'\e[32m' C_DIM=$'\e[2m' C_BLD=$'\e[1m' C_RST=$'\e[0m'
else
  C_RED='' C_YEL='' C_GRN='' C_DIM='' C_BLD='' C_RST=''
fi

die() {
  printf 't3ctl: %s\n' "$*" >&2
  exit 1
}

warn() { printf 't3ctl: warning: %s\n' "$*" >&2; }

note() { printf '%s\n' "$*" >&2; }

# Ask a yes/no question; default is No. Honours T3CTL_ASSUME_YES (--yes).
confirm() {
  local prompt=$1 reply
  if [[ ${T3CTL_ASSUME_YES:-0} == 1 ]]; then
    return 0
  fi
  if [[ ! -t 0 ]]; then
    note "Not a terminal and --yes not given; aborting."
    return 1
  fi
  read -r -p "$prompt [y/N] " reply || return 1
  [[ $reply == [yY] || $reply == [yY][eE][sS] ]]
}

# Human-readable size from KiB.
human_kb() {
  local kb=$1
  if [[ ! $kb =~ ^[0-9]+$ ]]; then
    printf '?'
    return
  fi
  awk -v k="$kb" 'BEGIN {
    split("K M G T", u, " "); i = 1; v = k
    while (v >= 1024 && i < 4) { v /= 1024; i++ }
    if (i == 1 || v >= 100) printf "%d%s", v + 0.5, u[i]
    else printf "%.1f%s", v, u[i]
  }'
}

# Human-readable age from a number of seconds.
human_age() {
  local s=$1
  if [[ ! $s =~ ^-?[0-9]+$ ]]; then
    printf '?'
    return
  fi
  ((s < 0)) && s=0
  if ((s < 3600)); then
    printf '%dm' $((s / 60))
  elif ((s < 86400)); then
    printf '%dh' $((s / 3600))
  elif ((s < 86400 * 14)); then
    printf '%dd' $((s / 86400))
  elif ((s < 86400 * 70)); then
    printf '%dw' $((s / 604800))
  else
    printf '%dmo' $((s / 2592000))
  fi
}

# Parse a duration such as 30m, 12h, 7d, 2w, 3mo into seconds.
parse_duration() {
  local v=$1 n unit
  if [[ $v =~ ^([0-9]+)(s|m|h|d|w|mo)?$ ]]; then
    n=$((10#${BASH_REMATCH[1]}))
    unit=${BASH_REMATCH[2]:-d}
  else
    return 1
  fi
  case $unit in
    s) printf '%d' "$n" ;;
    m) printf '%d' $((n * 60)) ;;
    h) printf '%d' $((n * 3600)) ;;
    d) printf '%d' $((n * 86400)) ;;
    w) printf '%d' $((n * 604800)) ;;
    mo) printf '%d' $((n * 2592000)) ;;
  esac
}

# ---------------------------------------------------------- configuration

# Validate a directory *name* used for artifact cleanup.
valid_clean_name() {
  local n=$1
  [[ -n $n && $n != */* && $n != . && $n != .. && $n != .git && $n != *[[:space:]]* ]]
}

load_config() {
  unset AGENT_UID AGENT_HOME
  AGENT_USER="agent"
  T3_SERVICE="t3code.service"
  T3_PORT="3773"
  T3_LOG_FILE=""
  WORKTREE_ROOT=""
  WORKTREE_SCAN_DEPTH=4
  SAFE_CLEAN_DIRS=(node_modules .next .turbo dist build coverage)
  AGENT_STORAGE_DIRS=(.t3/worktrees .cache .bun .local .codex .cursor .npm)
  DISK_WARN_PCT=85
  DISK_CRIT_PCT=95
  BUS_WAIT_SECONDS=10
  START_TIMEOUT_SECONDS=30
  AGENT_PROCESS_PATTERN='^(claude|codex|cursor|cursor-agent|gemini|opencode|aider|amp)$'

  local cfg=${T3CTL_CONFIG:-${HOME:-}/.config/t3ctl/config}
  if [[ -n ${T3CTL_CONFIG:-} && ! -f $cfg ]]; then
    die "config file not found: $cfg"
  fi
  if [[ -f $cfg ]]; then
    local owner mode
    owner=$(stat -c %u -- "$cfg") || die "cannot stat config: $cfg"
    mode=$(stat -c %a -- "$cfg")
    if [[ $owner != "$(id -u)" && $owner != 0 ]]; then
      die "refusing config not owned by you or root: $cfg"
    fi
    if ((8#$mode & 8#022)); then
      die "refusing group/world-writable config: $cfg"
    fi
    # shellcheck source=/dev/null
    source "$cfg"
  fi

  [[ $AGENT_USER =~ ^[a-z_][a-z0-9_-]*\$?$ ]] || die "invalid AGENT_USER: $AGENT_USER"
  [[ $T3_SERVICE =~ ^[A-Za-z0-9@_.:-]+$ ]] || die "invalid T3_SERVICE: $T3_SERVICE"
  [[ -z $T3_PORT || $T3_PORT =~ ^[0-9]+$ ]] || die "invalid T3_PORT: $T3_PORT"
  [[ $WORKTREE_SCAN_DEPTH =~ ^[1-9]$ ]] || die "invalid WORKTREE_SCAN_DEPTH: $WORKTREE_SCAN_DEPTH"
  local n
  for n in "${SAFE_CLEAN_DIRS[@]}"; do
    valid_clean_name "$n" || die "invalid SAFE_CLEAN_DIRS entry: '$n'"
  done
}

# Resolve the agent account. Sets AGENT_UID and AGENT_HOME, plus defaults that
# depend on the home directory. Never hardcodes a UID.
resolve_agent() {
  [[ -n ${AGENT_UID:-} ]] && return 0
  AGENT_UID=$(id -u -- "$AGENT_USER" 2>/dev/null) || die "unknown user: $AGENT_USER"
  AGENT_HOME=$(getent passwd "$AGENT_USER" | cut -d: -f6)
  [[ -n $AGENT_HOME ]] || die "cannot determine home directory of $AGENT_USER"
  : "${WORKTREE_ROOT:=$AGENT_HOME/.t3/worktrees}"
  : "${T3_LOG_FILE:=$AGENT_HOME/.t3/userdata/logs/boot-service.log}"
}

resolve_agent_uid() {
  resolve_agent
  printf '%s\n' "$AGENT_UID"
}

agent_runtime_dir() {
  resolve_agent
  printf '%s/%s\n' "${T3CTL_RUNTIME_BASE:-/run/user}" "$AGENT_UID"
}

agent_bus_path() { printf '%s/bus\n' "$(agent_runtime_dir)"; }

agent_bus_address() { printf 'unix:path=%s\n' "$(agent_bus_path)"; }

is_agent_user() { [[ $(id -un) == "$AGENT_USER" ]]; }

# Run a command as root (directly when already root).
as_root() {
  if ((EUID == 0)); then
    "$@"
  else
    sudo -- "$@"
  fi
}

# Run a command as the agent user with the environment needed to reach its
# systemd user manager. This is the single place that crosses users.
run_as_agent() {
  resolve_agent
  local rt
  rt=$(agent_runtime_dir)
  local -a envv=(
    "HOME=$AGENT_HOME"
    "XDG_RUNTIME_DIR=$rt"
    "DBUS_SESSION_BUS_ADDRESS=unix:path=$rt/bus"
    "GIT_OPTIONAL_LOCKS=0"
    "LC_ALL=C"
  )
  if is_agent_user; then
    env "${envv[@]}" "$@"
  else
    # cd / so the agent never inherits a cwd it cannot read.
    (cd / && sudo -u "$AGENT_USER" -- env "${envv[@]}" "$@")
  fi
}

# Run shell functions (defined in this process) as the agent user.
#   run_fn_as_agent "fn1 fn2 ..." entry_fn args...
# Function bodies are shipped with `declare -f`; arguments are passed as
# positional parameters, never interpolated into code.
run_fn_as_agent() {
  local fns=$1 entry=$2
  shift 2
  local code f
  code='set -o pipefail'$'\n'
  for f in $fns $entry; do
    code+="$(declare -f "$f")"$'\n'
  done
  code+="$entry \"\$@\""
  run_as_agent bash -c "$code" t3ctl "$@"
}

run_agent_systemctl() { run_as_agent systemctl --user "$@"; }

run_agent_journalctl() { run_as_agent journalctl --user "$@"; }
