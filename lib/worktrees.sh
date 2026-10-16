# shellcheck shell=bash
# Worktree discovery, inspection, artifact cleanup and guarded removal.
#
# Functions prefixed with `_wt_` run as the agent user (shipped through
# run_fn_as_agent), so git and the filesystem are only ever touched as the
# owner of the tree. They are self-contained: they may only call other `_wt_`
# functions and must not rely on caller globals.

# Every agent-side function, shipped together.
WT_AGENT_FNS="_wt_id _wt_err _wt_discover _wt_find_id _wt_under_root _wt_inspect_one _wt_inspect
  _wt_safety_reasons _wt_procs _wt_clean_candidates _wt_clean_check _wt_clean_plan _wt_clean_exec
  _wt_remove _wt_du _wt_status_short"

# ------------------------------------------------------------ agent side

# Deterministic short ID from a canonical path.
_wt_id() { printf '%s' "$1" | sha1sum | cut -c1-6; }

_wt_err() { printf 't3ctl: %s\n' "$*" >&2; }

# Succeeds if canonical path $2 is strictly beneath canonical root $1.
_wt_under_root() {
  local croot=$1 p=$2
  [[ -n $croot && $croot == /* && $p == "$croot"/* && $p != *'/../'* && $p != *'/./'* ]]
}

# Print canonical worktree paths found beneath root, one per line.
#   _wt_discover root depth prune-name...
_wt_discover() {
  local root=$1 depth=$2
  shift 2
  local croot p rp a skip n
  local -a pr=() accepted=()
  croot=$(realpath -e -- "$root" 2>/dev/null) || {
    _wt_err "worktree root not found: $root"
    return 1
  }
  for n in "$@"; do pr+=(-o -name "$n"); done
  while IFS= read -r -d '' p; do
    if [[ $p == *$'\n'* || $p == *$'\t'* ]]; then
      _wt_err "skipping path with control characters under $croot"
      continue
    fi
    rp=$(realpath -e -- "$p" 2>/dev/null) || continue
    _wt_under_root "$croot" "$rp" || continue
    skip=0
    for a in "${accepted[@]}"; do
      if [[ $rp == "$a" || $rp == "$a"/* ]]; then
        skip=1
        break
      fi
    done
    ((skip)) || accepted+=("$rp")
  done < <(find "$croot" -mindepth 2 -maxdepth "$((depth + 1))" \
    \( -false "${pr[@]}" \) -prune -o -name .git -printf '%h\0' -prune 2>/dev/null | sort -z)
  ((${#accepted[@]})) && printf '%s\n' "${accepted[@]}"
  return 0
}

# Print "<id>\t<path>" for the worktree whose ID starts with the given prefix.
#   _wt_find_id root depth prefix prune-name...
_wt_find_id() {
  local root=$1 depth=$2 prefix=$3
  shift 3
  local p id
  local -a hits=()
  while IFS= read -r p; do
    [[ -n $p ]] || continue
    id=$(_wt_id "$p")
    if [[ $id == "$prefix" ]]; then
      hits=("$id"$'\t'"$p")
      break
    fi
    [[ $id == "$prefix"* ]] && hits+=("$id"$'\t'"$p")
  done < <(_wt_discover "$root" "$depth" "$@")
  case ${#hits[@]} in
    0)
      _wt_err "no worktree with ID '$prefix' (see: t3ctl worktrees)"
      return 4
      ;;
    1) printf '%s\n' "${hits[0]}" ;;
    *)
      _wt_err "ID '$prefix' is ambiguous:"
      printf '  %s\n' "${hits[@]}" >&2
      return 4
      ;;
  esac
}

_wt_du() {
  local s
  s=$(du -sk -- "$1" 2>/dev/null | cut -f1)
  [[ $s =~ ^[0-9]+$ ]] && printf '%s\n' "$s" || printf '?\n'
}

# Inspect one worktree and print a single tab-separated record:
#   id path size branch head commit_ts activity_ts modified untracked
#   upstream ahead behind published state kind common_dir
# Unknown values are '?', not-applicable values are '-'. Never fails.
#   _wt_inspect_one path with_size prune-name...
_wt_inspect_one() {
  local p=$1 with_size=$2
  shift 2
  local size='-' branch='?' head='?' cts='?' ats='?' mod='?' unt='?' up='-' ahead='?' behind='?'
  local pub='?' state=ok kind=linked gitdir='' common='-' top s x n back
  local -a pr=()
  for n in "$@"; do pr+=(-o -name "$n"); done

  [[ $with_size == 1 ]] && size=$(_wt_du "$p")
  ats=$(find "$p" \( -name .git "${pr[@]}" \) -prune -o -type f -printf '%T@\n' 2>/dev/null |
    awk 'BEGIN { m = 0 } { t = int($1); if (t > m) m = t } END { print (m ? m : "?") }')

  if gitdir=$(git -C "$p" rev-parse --absolute-git-dir 2>/dev/null) &&
    common=$(git -C "$p" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) &&
    top=$(git -C "$p" rev-parse --show-toplevel 2>/dev/null) &&
    [[ $(realpath -e -- "$top" 2>/dev/null) == "$p" ]]; then
    gitdir=$(realpath -e -- "$gitdir")
    common=$(realpath -e -- "$common")
    if [[ $gitdir == "$common" ]]; then
      kind=main
    else
      back=''
      [[ -r $gitdir/gitdir ]] && back=$(<"$gitdir/gitdir")
      if [[ -z $back || $(realpath -m -- "${back%/.git}") != "$p" ]]; then
        state=unregistered
      elif [[ -e $gitdir/locked ]]; then
        state=locked
      fi
    fi
    for x in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG; do
      if [[ -e $gitdir/$x ]]; then
        [[ $state == ok ]] && state="in-progress:$x"
        break
      fi
    done
    if [[ -f $gitdir/logs/HEAD ]]; then
      x=$(stat -c %Y -- "$gitdir/logs/HEAD" 2>/dev/null) || x=0
      [[ $ats == '?' || $x -gt $ats ]] && ats=$x
    fi

    branch=$(git -C "$p" symbolic-ref -q --short HEAD 2>/dev/null) || branch='(detached)'
    head=$(git -C "$p" rev-parse -q --verify --short HEAD 2>/dev/null) || head='?'
    if [[ $head != '?' ]]; then
      cts=$(git -C "$p" log -1 --format=%ct HEAD 2>/dev/null) || cts='?'
      [[ -n $cts ]] || cts='?'
    fi
    if s=$(git -C "$p" status --porcelain=v1 --untracked-files=normal 2>/dev/null); then
      if [[ -z $s ]]; then
        mod=0 unt=0
      else
        unt=$(grep -c '^??' <<<"$s")
        mod=$(grep -vc '^??' <<<"$s")
      fi
    else
      state=broken
    fi
    if up=$(git -C "$p" rev-parse -q --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null) && [[ -n $up ]]; then
      if x=$(git -C "$p" rev-list --left-right --count 'HEAD...@{upstream}' 2>/dev/null); then
        read -r ahead behind <<<"$x"
      fi
    else
      up='-'
    fi
    if [[ $head != '?' ]]; then
      if x=$(git -C "$p" for-each-ref --count=1 --contains HEAD --format='%(refname)' refs/remotes 2>/dev/null); then
        [[ -n $x ]] && pub=yes || pub=no
      fi
    fi
  else
    state=broken
    common='-'
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(_wt_id "$p")" "$p" "$size" "$branch" "$head" "$cts" "$ats" "$mod" "$unt" \
    "$up" "${ahead:-?}" "${behind:-?}" "$pub" "$state" "$kind" "$common"
}

# Inspect many worktrees.  _wt_inspect with_size "prune names" path...
_wt_inspect() {
  local with_size=$1 prunes=$2
  shift 2
  local p i=0 total=$#
  local -a names
  read -r -a names <<<"$prunes"
  for p in "$@"; do
    i=$((i + 1))
    [[ -t 2 ]] && printf '\rInspecting worktrees %d/%d...' "$i" "$total" >&2
    _wt_inspect_one "$p" "$with_size" "${names[@]}"
  done
  [[ -t 2 ]] && printf '\r\033[K' >&2
  return 0
}

# Reasons a worktree must not be removed (one per line; empty = removable).
#   _wt_safety_reasons kind state modified untracked upstream ahead published
_wt_safety_reasons() {
  local kind=$1 state=$2 mod=$3 unt=$4 up=$5 ahead=$6 pub=$7
  [[ $kind == main ]] && echo "main repository checkout, not a linked worktree"
  [[ $state != ok ]] && echo "git state: $state"
  if [[ $mod == '?' ]]; then
    echo "cannot determine tracked changes"
  elif ((mod > 0)); then
    echo "modified files: $mod"
  fi
  if [[ $unt == '?' ]]; then
    echo "cannot determine untracked files"
  elif ((unt > 0)); then
    echo "untracked files: $unt"
  fi
  if [[ $up != '-' ]]; then
    if [[ $ahead == '?' ]]; then
      echo "cannot compare with upstream $up"
    elif ((ahead > 0)); then
      echo "branch ahead of $up: $ahead"
    fi
  else
    case $pub in
      yes) ;;
      no) echo "no upstream, and HEAD is not on any remote branch (unpublished commits)" ;;
      *) echo "no upstream, and cannot determine whether HEAD is published" ;;
    esac
  fi
  return 0
}

# Processes (of the agent user) whose cwd is inside the worktree: "pid comm".
_wt_procs() {
  local p=$1 d cwd pid
  for d in /proc/[0-9]*; do
    cwd=$(readlink -- "$d/cwd" 2>/dev/null) || continue
    if [[ $cwd == "$p" || $cwd == "$p"/* ]]; then
      pid=${d#/proc/}
      [[ $pid == "$$" || $pid == "$BASHPID" ]] && continue
      printf '%s %s\n' "$pid" "$(cat -- "$d/comm" 2>/dev/null)"
    fi
  done
  return 0
}

_wt_status_short() {
  git -C "$1" status --short --untracked-files=normal 2>/dev/null | head -n "${2:-20}"
}

# NUL-separated relative paths of candidate artifact dirs.
#   _wt_clean_candidates wt name...
_wt_clean_candidates() {
  local wt=$1 n
  shift
  local -a m=()
  for n in "$@"; do m+=(-o -name "$n"); done
  (cd -- "$wt" && find . -name .git -prune -o -type d \( -false "${m[@]}" \) -print0 -prune 2>/dev/null) |
    while IFS= read -r -d '' n; do printf '%s\0' "${n#./}"; done
}

# Why a candidate must be kept (empty output = OK to delete).
#   _wt_clean_check wt rel name...
_wt_clean_check() {
  local wt=$1 rel=$2
  shift 2
  local full="$wt/$rel" base=${rel##*/} ok=0 n
  for n in "$@"; do [[ $base == "$n" ]] && ok=1; done
  if ((!ok)); then
    echo "not a configured artifact name"
    return
  fi
  if [[ $rel == /* || $rel == *..* || $rel == *$'\n'* || $rel == *$'\t'* ]]; then
    echo "unsafe path"
    return
  fi
  if [[ -L $full || ! -d $full ]]; then
    echo "not a plain directory"
    return
  fi
  if [[ $(realpath -e -- "$full" 2>/dev/null) != "$full" ]]; then
    echo "path resolves elsewhere (symlinked parent)"
    return
  fi
  if [[ -n $(git --literal-pathspecs -C "$wt" ls-files -- "$rel" 2>/dev/null | head -c1) ]]; then
    echo "contains tracked files"
    return
  fi
  if ! git -C "$wt" check-ignore -q -- "$rel/" 2>/dev/null; then
    echo "not ignored by git"
    return
  fi
}

# Print "delete|keep\tsize_kb\trel\treason" for each artifact candidate.
#   _wt_clean_plan root wt name...
_wt_clean_plan() {
  local root=$1 wt=$2
  shift 2
  local croot rel why
  croot=$(realpath -e -- "$root") || return 1
  if [[ $(realpath -e -- "$wt" 2>/dev/null) != "$wt" ]] || ! _wt_under_root "$croot" "$wt"; then
    _wt_err "refusing: $wt is not strictly beneath $croot"
    return 1
  fi
  while IFS= read -r -d '' rel; do
    why=$(_wt_clean_check "$wt" "$rel" "$@")
    if [[ -z $why ]]; then
      printf 'delete\t%s\t%s\t-\n' "$(_wt_du "$wt/$rel")" "$rel"
    else
      printf 'keep\t%s\t%s\t%s\n' "$(_wt_du "$wt/$rel")" "$rel" "$why"
    fi
  done < <(_wt_clean_candidates "$wt" "$@")
  return 0
}

# Delete the given relative artifact dirs after re-validating each one.
#   _wt_clean_exec root wt "names" rel...
_wt_clean_exec() {
  local root=$1 wt=$2 namestr=$3
  shift 3
  local croot rel why
  local -a nm
  read -r -a nm <<<"$namestr"
  croot=$(realpath -e -- "$root") || return 1
  if [[ $(realpath -e -- "$wt" 2>/dev/null) != "$wt" ]] || ! _wt_under_root "$croot" "$wt"; then
    _wt_err "refusing: $wt is not strictly beneath $croot"
    return 1
  fi
  for rel in "$@"; do
    why=$(_wt_clean_check "$wt" "$rel" "${nm[@]}")
    if [[ -n $why ]]; then
      printf 'skipped\t%s\t%s\n' "$rel" "$why"
      continue
    fi
    if rm -rf --one-file-system -- "${wt:?}/$rel"; then
      printf 'deleted\t%s\t-\n' "$rel"
    else
      printf 'failed\t%s\trm error\n' "$rel"
    fi
  done
}

# Re-validate and remove a worktree with git. Exit 3 + reasons if unsafe.
#   _wt_remove root wt expected_id
_wt_remove() {
  local root=$1 wt=$2 want=$3
  local croot rec id p size branch head cts ats mod unt up ahead behind pub state kind common reasons procs
  croot=$(realpath -e -- "$root") || return 1
  if [[ $(realpath -e -- "$wt" 2>/dev/null) != "$wt" ]] || ! _wt_under_root "$croot" "$wt"; then
    echo "path is not strictly beneath $croot"
    return 3
  fi
  [[ $(_wt_id "$wt") == "$want" ]] || {
    echo "worktree ID mismatch"
    return 3
  }
  rec=$(_wt_inspect_one "$wt" 0)
  IFS=$'\t' read -r id p size branch head cts ats mod unt up ahead behind pub state kind common <<<"$rec"
  reasons=$(_wt_safety_reasons "$kind" "$state" "$mod" "$unt" "$up" "$ahead" "$pub")
  procs=$(_wt_procs "$wt")
  [[ -n $procs ]] && reasons+=${reasons:+$'\n'}"processes running inside: $(awk '{print $2 "(" $1 ")"}' <<<"$procs" | paste -sd' ' -)"
  if [[ -n $reasons ]]; then
    printf '%s\n' "$reasons"
    return 3
  fi
  git --git-dir="$common" worktree remove "$wt" || return 1
  git --git-dir="$common" worktree prune || true
  [[ ! -e $wt ]]
}

# ----------------------------------------------------------- caller side

wt_prune_names() { printf '%s ' "${SAFE_CLEAN_DIRS[@]}"; }

# Run an agent-side function with all _wt_ helpers available.
wt_agent() { run_fn_as_agent "$WT_AGENT_FNS" "$@"; }

# Fill WT_IDS and WT_<field> associative arrays from inspection records.
wt_load() {
  local with_size=$1 rec id p
  local -a paths=()
  resolve_agent
  WT_IDS=()
  declare -gA WT_PATH=() WT_SIZE=() WT_BRANCH=() WT_HEAD=() WT_CTS=() WT_ATS=() WT_MOD=() WT_UNT=() \
    WT_UP=() WT_AHEAD=() WT_BEHIND=() WT_PUB=() WT_STATE=() WT_KIND=() WT_COMMON=()
  mapfile -t paths < <(wt_agent _wt_discover "$WORKTREE_ROOT" "$WORKTREE_SCAN_DEPTH" "${SAFE_CLEAN_DIRS[@]}")
  ((${#paths[@]})) || return 0
  while IFS= read -r rec; do
    [[ -n $rec ]] || continue
    wt_parse_record "$rec"
  done < <(wt_agent _wt_inspect "$with_size" "$(wt_prune_names)" "${paths[@]}")
}

wt_parse_record() {
  local id p size branch head cts ats mod unt up ahead behind pub state kind common
  IFS=$'\t' read -r id p size branch head cts ats mod unt up ahead behind pub state kind common <<<"$1"
  WT_IDS+=("$id")
  WT_PATH[$id]=$p WT_SIZE[$id]=$size WT_BRANCH[$id]=$branch WT_HEAD[$id]=$head WT_CTS[$id]=$cts
  WT_ATS[$id]=$ats WT_MOD[$id]=$mod WT_UNT[$id]=$unt WT_UP[$id]=$up WT_AHEAD[$id]=$ahead
  WT_BEHIND[$id]=$behind WT_PUB[$id]=$pub WT_STATE[$id]=$state WT_KIND[$id]=$kind WT_COMMON[$id]=$common
}

# Project = first path component under the root; name = the rest.
wt_project() {
  local rel=${WT_PATH[$1]#"$WORKTREE_ROOT"/}
  if [[ $rel == */* ]]; then printf '%s' "${rel%%/*}"; else printf '-'; fi
}

wt_name() {
  local rel=${WT_PATH[$1]#"$WORKTREE_ROOT"/}
  printf '%s' "${rel#*/}"
}

wt_reasons() {
  local id=$1
  _wt_safety_reasons "${WT_KIND[$id]}" "${WT_STATE[$id]}" "${WT_MOD[$id]}" "${WT_UNT[$id]}" \
    "${WT_UP[$id]}" "${WT_AHEAD[$id]}" "${WT_PUB[$id]}"
}

wt_dirty_label() {
  local nmod=${WT_MOD[$1]} nunt=${WT_UNT[$1]} out=''
  if [[ $nmod == '?' || $nunt == '?' ]]; then
    printf '?'
    return
  fi
  ((nmod > 0)) && out+="${nmod}M"
  ((nunt > 0)) && out+="${nunt}U"
  printf '%s' "${out:-no}"
}

wt_ahead_label() {
  local id=$1
  if [[ ${WT_UP[$id]} == '-' ]]; then
    case ${WT_PUB[$id]} in
      yes) printf 'pushed' ;;
      no) printf 'local' ;;
      *) printf '?' ;;
    esac
  else
    printf '%s' "${WT_AHEAD[$id]}"
  fi
}

wt_age_of() {
  local ts=$1
  [[ $ts =~ ^[0-9]+$ ]] || {
    printf '?'
    return
  }
  human_age $((NOW - ts))
}

# Canonical worktree root as the agent sees it (needed to display paths).
wt_canonical_root() {
  local r
  r=$(run_as_agent realpath -e -- "$WORKTREE_ROOT" 2>/dev/null) || die "worktree root not found: $WORKTREE_ROOT"
  WORKTREE_ROOT=$r
}

# Date cutoffs use local midnight, and always refer to last activity.
wt_before_timestamp() {
  [[ $1 =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
  date -d "$1 00:00:00" +%s 2>/dev/null
}

# Parse one filter option, returning how many argv entries it consumed.
# The caller provides local older/before/published/safe_only variables.
wt_filter_option() {
  FILTER_SHIFT=1
  local value=${1#*=}
  case $1 in
    --older-than | --before)
      [[ -n ${2:-} ]] || die "$1 needs a value"
      value=$2
      FILTER_SHIFT=2
      ;;
  esac
  case $1 in
    --older-than | --older-than=*)
      older=$(parse_duration "$value") || die "invalid duration '$value' (examples: 12h, 7d, 2w, 3mo)"
      ;;
    --before | --before=*)
      before=$(wt_before_timestamp "$value") || die "invalid date '$value' (expected YYYY-MM-DD)"
      ;;
    --pushed | --unpushed)
      local want=yes
      [[ $1 == --unpushed ]] && want=no
      [[ -z $published || $published == "$want" ]] || die "--pushed and --unpushed cannot be combined"
      published=$want
      ;;
    --safe) safe_only=1 ;;
    *) die "unknown option: $1" ;;
  esac
}

# Filters are ANDed. Unknown values never satisfy a filter.
wt_matches() {
  local id=$1 older=$2 before=$3 published=$4 safe_only=$5 ts
  ts=${WT_ATS[$id]}
  if [[ -n $older ]]; then
    [[ $ts =~ ^[0-9]+$ ]] && ((NOW - ts >= older)) || return 1
  fi
  if [[ -n $before ]]; then
    [[ $ts =~ ^[0-9]+$ ]] && ((ts < before)) || return 1
  fi
  [[ -z $published || ${WT_PUB[$id]} == "$published" ]] || return 1
  if ((safe_only)); then
    [[ -z $(wt_reasons "$id") ]] || return 1
  fi
  return 0
}

cmd_worktrees() {
  case ${1:-} in
    info | clean | remove) cmd_worktrees_action "$@"; return ;;
  esac
  local sort=age older='' before='' published='' safe_only=0 with_size=1 reverse=0
  while (($#)); do
    case $1 in
      --sort)
        sort=${2:-}
        [[ $sort =~ ^(size|age|project|commit)$ ]] || die "--sort must be size, age, project or commit"
        shift
        ;;
      --sort=*)
        sort=${1#*=}
        [[ $sort =~ ^(size|age|project|commit)$ ]] || die "--sort must be size, age, project or commit"
        ;;
      --older-than | --older-than=* | --before | --before=* | --pushed | --unpushed | --safe)
        wt_filter_option "$1" "${2:-}"
        shift "$((FILTER_SHIFT - 1))"
        ;;
      --no-size) with_size=0 ;;
      -r | --reverse) reverse=1 ;;
      *) die "unknown option: $1" ;;
    esac
    shift
  done
  [[ $sort == size && $with_size == 0 ]] && die "--sort size needs sizes; drop --no-size"

  resolve_agent
  wt_canonical_root
  NOW=$(date +%s)
  wt_load "$with_size"
  if ((${#WT_IDS[@]} == 0)); then
    echo "No worktrees found under $WORKTREE_ROOT"
    return 0
  fi

  # Build sortable lines: key<TAB>id
  local id key ts lines=() total_kb=0 shown=0 safe=0 unknown_size=0
  for id in "${WT_IDS[@]}"; do
    ts=${WT_ATS[$id]}
    wt_matches "$id" "$older" "$before" "$published" "$safe_only" || continue
    case $sort in
      size) key=${WT_SIZE[$id]}; [[ $key =~ ^[0-9]+$ ]] || key=0 ;;
      age) key=$ts; [[ $key =~ ^[0-9]+$ ]] || key=0 ;;
      commit) key=${WT_CTS[$id]}; [[ $key =~ ^[0-9]+$ ]] || key=0 ;;
      project) key="$(wt_project "$id")/$(wt_name "$id")" ;;
    esac
    lines+=("$key"$'\t'"$id")
  done

  # shellcheck disable=SC2054
  local -a sort_opts=(-t $'\t' -k1,1)
  if [[ $sort == project ]]; then
    ((reverse)) && sort_opts+=(-r)
  else
    sort_opts+=(-n)
    ((reverse)) || sort_opts+=(-r)
  fi

  local fmt='%-7s %-10s %-26s %6s %5s %6s %-6s %-6s %-5s %s\n'
  # shellcheck disable=SC2059
  printf "$C_BLD$fmt$C_RST" ID PROJECT NAME SIZE AGE COMMIT DIRTY AHEAD SAFE BRANCH
  local name safe_label sz
  while IFS=$'\t' read -r key id; do
    [[ -n $id ]] || continue
    name=$(wt_name "$id")
    ((${#name} > 26)) && name="${name:0:25}~"
    if [[ -z $(wt_reasons "$id") ]]; then
      safe_label=yes
      safe=$((safe + 1))
    else
      safe_label=no
    fi
    sz=${WT_SIZE[$id]}
    if [[ $sz =~ ^[0-9]+$ ]]; then
      total_kb=$((total_kb + sz))
    elif [[ $sz == '?' ]]; then
      unknown_size=1
    fi
    [[ $sz == '-' ]] && sz='-' || sz=$(human_kb "$sz")
    # shellcheck disable=SC2059
    printf "$fmt" "$id" "$(wt_project "$id")" "$name" "$sz" "$(wt_age_of "${WT_ATS[$id]}")" \
      "$(wt_age_of "${WT_CTS[$id]}")" "$(wt_dirty_label "$id")" "$(wt_ahead_label "$id")" "$safe_label" \
      "${WT_BRANCH[$id]}"
    shown=$((shown + 1))
  done < <(((${#lines[@]})) && printf '%s\n' "${lines[@]}" | sort "${sort_opts[@]}")

  echo
  local summary="$shown worktree(s)"
  if ((with_size)); then
    summary+=", $(human_kb "$total_kb") summed"
    ((unknown_size)) && summary+=" (some sizes unknown)"
  fi
  summary+=", $safe safe to remove"
  printf '%s\n' "$summary"
  ((with_size)) && printf '%sSIZE counts files hard-linked between worktrees in each one, so the sum overstates real usage (see: t3ctl disk).%s\n' "$C_DIM" "$C_RST"
  printf '%sAGE = last file change (excl. artifacts); DIRTY: M modified, U untracked; AHEAD: commits ahead of upstream, local = no upstream and not pushed, pushed = no upstream but on a remote branch%s\n' "$C_DIM" "$C_RST"
}

# Resolve an ID (or unique prefix) to "id<TAB>path" and load its record.
wt_select() {
  local prefix=$1 with_size=$2 hit rec
  [[ $prefix =~ ^[0-9a-f]{3,40}$ ]] || die "invalid worktree ID '$prefix' (expected hex, e.g. a83f21)"
  resolve_agent
  wt_canonical_root
  hit=$(wt_agent _wt_find_id "$WORKTREE_ROOT" "$WORKTREE_SCAN_DEPTH" "$prefix" "${SAFE_CLEAN_DIRS[@]}") || exit 4
  SEL_ID=${hit%%$'\t'*}
  SEL_PATH=${hit#*$'\t'}
  WT_IDS=()
  declare -gA WT_PATH=() WT_SIZE=() WT_BRANCH=() WT_HEAD=() WT_CTS=() WT_ATS=() WT_MOD=() WT_UNT=() \
    WT_UP=() WT_AHEAD=() WT_BEHIND=() WT_PUB=() WT_STATE=() WT_KIND=() WT_COMMON=()
  rec=$(wt_agent _wt_inspect_one "$SEL_PATH" "$with_size" "${SAFE_CLEAN_DIRS[@]}")
  wt_parse_record "$rec"
  [[ $SEL_ID == "${WT_IDS[0]}" ]] || die "internal error: ID mismatch for $SEL_PATH"
}

fmt_ts() {
  [[ $1 =~ ^[0-9]+$ ]] || {
    printf '?'
    return
  }
  printf '%s ago (%s)' "$(human_age $((NOW - $1)))" "$(date -d "@$1" '+%Y-%m-%d %H:%M')"
}

wt_title() { printf '%s/%s' "$(wt_project "$1")" "$(wt_name "$1")"; }

# Print the artifact plan (largest first, top PLAN_SHOW entries); sets
# PLAN_DELETE (relative paths) and PLAN_KB.
wt_show_plan() {
  local id=$1 action kb rel why n=0 rest_kb=0 rest_n=0 sz
  PLAN_DELETE=()
  PLAN_KB=0
  local -a kept=() rows=()
  while IFS=$'\t' read -r action kb rel why; do
    [[ -n $rel ]] || continue
    if [[ $action == delete ]]; then
      PLAN_DELETE+=("$rel")
      [[ $kb =~ ^[0-9]+$ ]] && PLAN_KB=$((PLAN_KB + kb))
      rows+=("$kb"$'\t'"$rel")
    else
      kept+=("$(printf '  %7s  %s  %s(kept: %s)%s' "$(human_kb "$kb")" "$rel" "$C_DIM" "$why" "$C_RST")")
    fi
  done < <(wt_agent _wt_clean_plan "$WORKTREE_ROOT" "${WT_PATH[$id]}" "${SAFE_CLEAN_DIRS[@]}")
  if ((${#rows[@]} == 0)); then
    echo "  (no generated artifacts found)"
  else
    while IFS=$'\t' read -r kb rel; do
      n=$((n + 1))
      if ((n <= ${PLAN_SHOW:-8})); then
        printf '  %7s  %s\n' "$(human_kb "$kb")" "$rel"
      else
        rest_n=$((rest_n + 1))
        [[ $kb =~ ^[0-9]+$ ]] && rest_kb=$((rest_kb + kb))
      fi
    done < <(printf '%s\n' "${rows[@]}" | sort -t $'\t' -k1,1nr)
    if ((rest_n)); then
      sz=$(human_kb "$rest_kb")
      printf '  %7s  ... %d more\n' "$sz" "$rest_n"
    fi
  fi
  ((${#kept[@]})) && printf '%s\n' "${kept[@]}"
  return 0
}

cmd_worktree_info() {
  local id=$SEL_ID p procs reasons
  p=${WT_PATH[$id]}
  NOW=$(date +%s)
  printf '%sWorktree %s%s  %s\n' "$C_BLD" "$id" "$C_RST" "$(wt_title "$id")"
  printf '  %-14s %s\n' path "$p"
  printf '  %-14s %s\n' repository "${WT_COMMON[$id]}"
  printf '  %-14s %s\n' kind "$([[ ${WT_KIND[$id]} == main ]] && echo 'main checkout' || echo 'linked worktree')"
  printf '  %-14s %s\n' "git state" "${WT_STATE[$id]}"
  printf '  %-14s %s\n' branch "${WT_BRANCH[$id]}"
  printf '  %-14s %s, committed %s\n' HEAD "${WT_HEAD[$id]}" "$(fmt_ts "${WT_CTS[$id]}")"
  printf '  %-14s %s\n' "last activity" "$(fmt_ts "${WT_ATS[$id]}")"
  if [[ ${WT_UP[$id]} == '-' ]]; then
    printf '  %-14s none\n' upstream
  else
    printf '  %-14s %s (ahead %s, behind %s)\n' upstream "${WT_UP[$id]}" "${WT_AHEAD[$id]}" "${WT_BEHIND[$id]}"
  fi
  case ${WT_PUB[$id]} in
    yes) printf '  %-14s HEAD is contained in a remote branch\n' published ;;
    no) printf '  %-14s %sHEAD is not on any remote branch%s\n' published "$C_YEL" "$C_RST" ;;
    *) printf '  %-14s unknown\n' published ;;
  esac
  printf '  %-14s %s modified, %s untracked\n' changes "${WT_MOD[$id]}" "${WT_UNT[$id]}"
  printf '  %-14s %s\n' size "$(human_kb "${WT_SIZE[$id]}")"
  procs=$(wt_agent _wt_procs "$p")
  if [[ -n $procs ]]; then
    printf '  %-14s %s\n' processes "$(awk '{print $2 "(" $1 ")"}' <<<"$procs" | paste -sd' ' -)"
  else
    printf '  %-14s none\n' processes
  fi

  if [[ ${WT_MOD[$id]} =~ ^[1-9] || ${WT_UNT[$id]} =~ ^[1-9] ]]; then
    echo
    echo "Changes (first 20):"
    wt_agent _wt_status_short "$p" 20 | sed 's/^/  /'
  fi

  echo
  echo "Generated artifacts (t3ctl worktree $id clean):"
  wt_show_plan "$id"
  ((${#PLAN_DELETE[@]})) && printf '  reclaimable: %s\n' "$(human_kb "$PLAN_KB")"

  echo
  reasons=$(wt_reasons "$id")
  [[ -n $procs ]] && reasons+=${reasons:+$'\n'}"processes running inside the worktree"
  if [[ -z $reasons ]]; then
    printf 'Removal: %sSAFE%s  (t3ctl worktree %s remove)\n' "$C_GRN" "$C_RST" "$id"
  else
    printf 'Removal: %sBLOCKED%s\n' "$C_RED" "$C_RST"
    sed 's/^/  - /' <<<"$reasons"
  fi
}

cmd_worktree_clean() {
  local id=$SEL_ID p before after status rel why procs
  p=${WT_PATH[$id]}
  before=${WT_SIZE[$id]}
  printf 'Worktree: %s (%s)\n\nGenerated artifacts:\n' "$(wt_title "$id")" "$id"
  wt_show_plan "$id"
  if ((${#PLAN_DELETE[@]} == 0)); then
    echo
    echo "Nothing to clean."
    return 0
  fi
  printf '\nEstimated reclaim: %s\n' "$(human_kb "$PLAN_KB")"
  procs=$(wt_agent _wt_procs "$p")
  if [[ -n $procs ]]; then
    printf '%sWarning:%s processes are running inside this worktree: %s\n' "$C_YEL" "$C_RST" \
      "$(awk '{print $2 "(" $1 ")"}' <<<"$procs" | paste -sd' ' -)"
  fi
  echo "Source files and git state are not touched; reinstall/rebuild to recreate artifacts."
  echo
  confirm "Continue?" || {
    echo "Aborted."
    return 1
  }

  local failed=0 avail_before avail_after
  avail_before=$(fs_stats "$p" | awk '{print $3}') || avail_before=''
  while IFS=$'\t' read -r status rel why; do
    case $status in
      deleted) ;;
      skipped) echo "  skipped $rel: $why" ;;
      *)
        echo "  FAILED $rel: $why"
        failed=1
        ;;
    esac
  done < <(wt_agent _wt_clean_exec "$WORKTREE_ROOT" "$p" "$(wt_prune_names)" "${PLAN_DELETE[@]}")

  after=$(wt_agent _wt_du "$p")
  echo
  printf 'Before: %s\nAfter:  %s\n' "$(human_kb "$before")" "$(human_kb "$after")"
  if [[ $before =~ ^[0-9]+$ && $after =~ ^[0-9]+$ ]]; then
    printf 'Freed:  %s\n' "$(human_kb $((before - after)))"
  fi
  # Hard-linked files shared with other worktrees free no disk space, so
  # also report what the filesystem actually gained.
  avail_after=$(fs_stats "$p" | awk '{print $3}') || avail_after=''
  if [[ $avail_before =~ ^[0-9]+$ && $avail_after =~ ^[0-9]+$ ]]; then
    printf 'Disk free: %s -> %s' "$(human_kb "$avail_before")" "$(human_kb "$avail_after")"
    if ((avail_after >= avail_before)); then
      printf ' (+%s)\n' "$(human_kb $((avail_after - avail_before)))"
    else
      printf '\n'
    fi
  fi
  return "$failed"
}

cmd_worktree_remove() {
  local id=$SEL_ID p out rc=0 reasons
  p=${WT_PATH[$id]}
  reasons=$(wt_reasons "$id")
  if [[ -z $reasons ]]; then
    printf 'Worktree: %s (%s)\n  path:   %s\n  branch: %s (kept; only the worktree directory is removed)\n  size:   %s\n\n' \
      "$(wt_title "$id")" "$id" "$p" "${WT_BRANCH[$id]}" "$(human_kb "${WT_SIZE[$id]}")"
    confirm "Remove this worktree with 'git worktree remove'?" || {
      echo "Aborted."
      return 1
    }
  fi
  # The agent side re-checks everything immediately before acting.
  if [[ -z $reasons ]]; then
    out=$(wt_agent _wt_remove "$WORKTREE_ROOT" "$p" "$id" 2>&1) || rc=$?
  else
    out=$reasons
    rc=3
  fi
  if ((rc == 3)); then
    printf '%sREFUSING TO REMOVE %s%s\n\nSafety checks failed:\n' "$C_RED" "$id" "$C_RST"
    sed 's/^/  /' <<<"$out"
    printf '\nInspect using:\n\n  t3ctl worktree %s info\n' "$id"
    return 3
  elif ((rc != 0)); then
    printf '%s\n' "$out" >&2
    die "git worktree remove failed for $p"
  fi
  [[ -n $out ]] && printf '%s\n' "$out"
  printf 'Removed worktree %s (%s). Branch %s still exists in %s.\n' "$id" "$p" "${WT_BRANCH[$id]}" "${WT_COMMON[$id]}"
}

# Each action gets a fresh inspection and an isolated shell: a refusal or
# failure on one target does not prevent the remaining targets being handled.
wt_run_batch() {
  local action=$1 dry_run=$2 id rc=0 one_rc
  shift 2
  if (($# == 0)); then
    echo "No worktrees match the selection."
    return 0
  fi
  printf 'Selected %d worktree(s) for %s%s.\n' "$#" "$action" "$([[ $dry_run == 1 ]] && echo ' (dry run)')"
  for id in "$@"; do
    if (
      wt_select "$id" 1
      NOW=$(date +%s)
      if ((dry_run)); then
        cmd_worktree_info
      else
        case $action in
          info) cmd_worktree_info ;;
          clean) cmd_worktree_clean ;;
          remove) cmd_worktree_remove ;;
        esac
      fi
    ); then
      :
    else
      one_rc=$?
      ((one_rc > rc)) && rc=$one_rc
    fi
  done
  return "$rc"
}

cmd_worktrees_action() {
  local action=$1 older='' before='' published='' safe_only=0 all=0 dry_run=0 id
  local -a selected=()
  shift
  while (($#)); do
    case $1 in
      --all) all=1; shift ;;
      --dry-run) dry_run=1; shift ;;
      *) wt_filter_option "$1" "${2:-}"; shift "$FILTER_SHIFT" ;;
    esac
  done
  [[ $all == 1 || -n $older || -n $before || -n $published || $safe_only == 1 ]] ||
    die "select worktrees with --all, --older-than, --before, --pushed, --unpushed or --safe"
  resolve_agent
  wt_canonical_root
  NOW=$(date +%s)
  wt_load 0
  for id in "${WT_IDS[@]}"; do
    wt_matches "$id" "$older" "$before" "$published" "$safe_only" && selected+=("$id")
  done
  wt_run_batch "$action" "$dry_run" "${selected[@]}"
}

cmd_worktree() {
  local action='' dry_run=0 arg prefix
  local -a prefixes=() parts=() selected=()
  local -A seen=()
  for arg in "$@"; do
    case $arg in
      info | clean | remove)
        [[ -z $action ]] || die "specify one worktree action (info, clean, remove)"
        action=$arg
        ;;
      --dry-run) dry_run=1 ;;
      -*) die "unknown option: $arg" ;;
      *)
        [[ -n $arg && $arg != ,* && $arg != *, && $arg != *,,* ]] || die "invalid worktree ID list '$arg'"
        IFS=, read -r -a parts <<<"$arg"
        prefixes+=("${parts[@]}")
        ;;
    esac
  done
  [[ -n $action && ${#prefixes[@]} -gt 0 ]] || die "usage: t3ctl worktree <id> [id...] info|clean|remove [--dry-run]"
  # Resolve every ID before any mutation; invalid/ambiguous input cannot leave
  # an earlier target already cleaned or removed. Deduplicate full IDs.
  for prefix in "${prefixes[@]}"; do
    wt_select "$prefix" 0
    if [[ -z ${seen[$SEL_ID]:-} ]]; then
      selected+=("$SEL_ID")
      seen[$SEL_ID]=1
    fi
  done
  wt_run_batch "$action" "$dry_run" "${selected[@]}"
}
