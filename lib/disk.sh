# shellcheck shell=bash
# Disk diagnostics and the doctor command.

# Print "total_kb used_kb avail_kb pct inode_pct mount source" for a path.
fs_stats() {
  local path=$1 line iline
  line=$(run_as_agent df -P -k -- "$path" 2>/dev/null | awk 'NR == 2') || return 1
  iline=$(run_as_agent df -P -i -- "$path" 2>/dev/null | awk 'NR == 2') || iline=''
  [[ -n $line ]] || return 1
  local src total used avail pct mnt ipct
  read -r src total used avail pct mnt <<<"$line"
  ipct=$(awk '{print $5}' <<<"$iline")
  [[ -n $ipct && $ipct != - ]] || ipct='?'
  printf '%s %s %s %s %s %s %s\n' "$total" "$used" "$avail" "${pct%\%}" "${ipct%\%}" "$mnt" "$src"
}

pct_level() {
  local pct=$1
  if [[ ! $pct =~ ^[0-9]+$ ]]; then
    echo '?'
  elif ((pct >= DISK_CRIT_PCT)); then
    echo CRIT
  elif ((pct >= DISK_WARN_PCT)); then
    echo WARN
  else
    echo OK
  fi
}

level_color() {
  case $1 in
    OK) printf '%s' "$C_GRN" ;;
    WARN) printf '%s' "$C_YEL" ;;
    CRIT | FAIL) printf '%s' "$C_RED" ;;
  esac
}

# Agent-side: worktree root usage, counting hard-linked files once
# ("total<TAB>kb"), then each worktree measured on its own ("kb<TAB>path") so
# the figures match `t3ctl worktrees`.
_disk_wt_usage() {
  local root=$1 p
  shift
  [[ -d $root ]] || return 0
  printf 'total\t%s\n' "$(du -sk -- "$root" 2>/dev/null | cut -f1)"
  for p in "$@"; do
    du -sk -- "$p" 2>/dev/null
  done
  return 0
}

# Agent-side: "kb<TAB>name" for each storage dir under home (skips missing).
_disk_home_usage() {
  local home=$1 d s
  shift
  for d in "$@"; do
    [[ -e $home/$d ]] || continue
    s=$(du -sk -- "$home/$d" 2>/dev/null | cut -f1)
    printf '%s\t%s\n' "${s:-?}" "$d"
  done
  return 0
}

# Load worktree root usage into WT_ROOT_KB, WT_COUNT and LARGEST (sorted
# "kb<TAB>id<TAB>project/name").
disk_load_worktrees() {
  local kb p id
  local -A du_of=()
  local -a paths=() rows=()
  WT_ROOT_KB='?'
  LARGEST=()
  wt_canonical_root
  mapfile -t paths < <(wt_agent _wt_discover "$WORKTREE_ROOT" "$WORKTREE_SCAN_DEPTH" "${SAFE_CLEAN_DIRS[@]}")
  WT_COUNT=${#paths[@]}
  while IFS=$'\t' read -r kb p; do
    [[ -n $p ]] || continue
    if [[ $kb == total ]]; then
      [[ $p =~ ^[0-9]+$ ]] && WT_ROOT_KB=$p
    else
      du_of[$p]=$kb
    fi
  done < <(run_fn_as_agent "" _disk_wt_usage "$WORKTREE_ROOT" "${paths[@]}")
  for p in "${paths[@]}"; do
    id=$(printf '%s' "$p" | sha1sum | cut -c1-6)
    rows+=("${du_of[$p]:-0}"$'\t'"$id"$'\t'"${p#"$WORKTREE_ROOT"/}")
  done
  ((${#rows[@]})) && mapfile -t LARGEST < <(printf '%s\n' "${rows[@]}" | sort -t $'\t' -k1,1nr)
  return 0
}

print_fs() {
  local label=$1 path=$2 total used avail pct ipct mnt src lvl ilvl
  read -r total used avail pct ipct mnt src < <(fs_stats "$path") || {
    printf '%s\n  (unavailable for %s)\n' "$label" "$path"
    return
  }
  lvl=$(pct_level "$pct")
  ilvl=$(pct_level "$ipct")
  printf '%sFilesystem%s %s (%s on %s)\n' "$C_BLD" "$C_RST" "$label" "$mnt" "$src"
  printf '  %-8s %8s\n' total "$(human_kb "$total")"
  printf '  %-8s %8s  %s%s%% %s%s\n' used "$(human_kb "$used")" "$(level_color "$lvl")" "$pct" "$lvl" "$C_RST"
  printf '  %-8s %8s\n' free "$(human_kb "$avail")"
  printf '  %-8s %8s  %s%s%s\n' inodes "$ipct%" "$(level_color "$ilvl")" "$ilvl" "$C_RST"
  FS_USED_KB=$used
}

cmd_disk() {
  (($# == 0)) || die "usage: t3ctl disk"
  resolve_agent
  local root_mnt wt_mnt kb name share row id title shown=0
  FS_USED_KB=0
  print_fs "/" /
  root_mnt=$(df -P / | awk 'NR == 2 {print $6}')
  wt_mnt=$(fs_stats "$WORKTREE_ROOT" 2>/dev/null | awk '{print $6}') || wt_mnt=''
  if [[ -n $wt_mnt && $wt_mnt != "$root_mnt" ]]; then
    echo
    print_fs "worktrees" "$WORKTREE_ROOT"
  fi
  local fs_used=$FS_USED_KB

  [[ -t 2 ]] && printf 'Measuring agent storage...' >&2
  disk_load_worktrees
  local -a home_rows=()
  local -a dirs=()
  for name in "${AGENT_STORAGE_DIRS[@]}"; do
    # The worktree root was already measured in the single walk above.
    [[ $AGENT_HOME/$name == "$WORKTREE_ROOT" ]] && continue
    dirs+=("$name")
  done
  ((${#dirs[@]})) && mapfile -t home_rows < <(run_fn_as_agent "" _disk_home_usage "$AGENT_HOME" "${dirs[@]}")
  [[ -t 2 ]] && printf '\r\033[K' >&2

  echo
  printf '%sAgent storage%s (%s)\n' "$C_BLD" "$C_RST" "$AGENT_HOME"
  {
    printf '%s\t%s\n' "$WT_ROOT_KB" "${WORKTREE_ROOT#"$AGENT_HOME"/}  [worktrees]"
    if ((${#home_rows[@]})); then printf '%s\n' "${home_rows[@]}"; fi
  } | sort -t $'\t' -k1,1nr | while IFS=$'\t' read -r kb name; do
    share=''
    if [[ $kb =~ ^[0-9]+$ ]] && ((fs_used > 0)); then
      share=$(awk -v a="$kb" -v b="$fs_used" 'BEGIN { printf "%d%% of used", a * 100 / b }')
    fi
    printf '  %8s  %-26s %s%s%s\n' "$(human_kb "$kb")" "$name" "$C_DIM" "$share" "$C_RST"
  done

  echo
  printf '%sLargest worktrees%s (%d total)\n' "$C_BLD" "$C_RST" "${WT_COUNT:-0}"
  for row in "${LARGEST[@]}"; do
    IFS=$'\t' read -r kb id title <<<"$row"
    printf '  %8s  %s  %s\n' "$(human_kb "$kb")" "$id" "$title"
    shown=$((shown + 1))
    ((shown >= 8)) && break
  done
  ((shown)) || echo "  (none)"
  ((shown == 0)) || printf '  %sEach size counts files hard-linked with other worktrees; the [worktrees] total counts them once.%s\n' "$C_DIM" "$C_RST"

  if [[ $WT_ROOT_KB =~ ^[0-9]+$ ]] && ((fs_used > 0 && WT_ROOT_KB * 100 / fs_used >= WORKTREE_WARN_PCT)); then
    echo
    printf '%sWorktrees account for %d%% of used disk space.%s\n' "$C_YEL" $((WT_ROOT_KB * 100 / fs_used)) "$C_RST"
    echo "  t3ctl worktrees --sort size          # find candidates"
    echo "  t3ctl worktree <id> clean            # drop node_modules/.next/... keep code"
    echo "  t3ctl worktree <id> remove           # remove a fully pushed, clean worktree"
  fi
}

cmd_doctor() {
  (($# == 0)) || die "usage: t3ctl doctor"
  resolve_agent
  local worst=0 runtime_fails=0
  local -a suggest=()

  printf '%sT3CTL Doctor%s\n\n' "$C_BLD" "$C_RST"
  printf 'Runtime\n'
  runtime_report || runtime_fails=$?
  if ((runtime_fails)); then
    worst=2
    if ! linger_enabled; then
      suggest+=("sudo loginctl enable-linger $AGENT_USER   (or: t3ctl reset)")
    fi
    suggest+=("t3ctl reset            # recover the user manager, bus and $T3_SERVICE")
    suggest+=("t3ctl logs             # inspect why it failed")
  fi

  echo
  printf 'Storage\n'
  local total used avail pct ipct mnt src lvl
  if read -r total used avail pct ipct mnt src < <(fs_stats /); then
    lvl=$(pct_level "$pct")
    status_line "root disk" "$lvl" "$pct% used ($(human_kb "$used") of $(human_kb "$total"))"
    status_line "free space" "$lvl" "$(human_kb "$avail")"
    status_line "inode usage" "$(pct_level "$ipct")" "$ipct%"
    case $lvl in
      CRIT) worst=2 ;;
      WARN) ((worst < 1)) && worst=1 ;;
    esac
    case $(pct_level "$ipct") in
      CRIT) worst=2 ;;
      WARN) ((worst < 1)) && worst=1 ;;
    esac
  else
    status_line "root disk" '?' "df failed"
    used=0
  fi

  [[ -t 2 ]] && printf 'Measuring worktrees...' >&2
  disk_load_worktrees
  [[ -t 2 ]] && printf '\r\033[K' >&2
  local wlvl=OK wpct=0 kb id title
  if [[ $WT_ROOT_KB =~ ^[0-9]+$ ]]; then
    ((used > 0)) && wpct=$((WT_ROOT_KB * 100 / used))
    if [[ $lvl != OK ]] || ((wpct >= WORKTREE_WARN_PCT)); then
      wlvl=WARN
    fi
    status_line "worktrees" "$wlvl" "$(human_kb "$WT_ROOT_KB") in ${WT_COUNT:-0} worktrees ($wpct% of used)"
  else
    status_line "worktrees" '?' "$WORKTREE_ROOT not readable"
  fi
  if ((${#LARGEST[@]})); then
    IFS=$'\t' read -r kb id title <<<"${LARGEST[0]}"
    status_line "largest worktree" "$wlvl" "$(human_kb "$kb") $title ($id)"
  fi
  if [[ $wlvl == WARN || ${lvl:-OK} != OK ]]; then
    ((worst < 1)) && worst=1
    suggest+=("t3ctl worktrees --sort size")
    [[ -n ${id:-} ]] && suggest+=("t3ctl worktree $id info")
  fi

  echo
  if ((${#suggest[@]})); then
    echo "Suggested action:"
    printf '  %s\n' "${suggest[@]}"
  else
    printf '%sAll checks passed.%s\n' "$C_GRN" "$C_RST"
  fi
  return "$worst"
}
