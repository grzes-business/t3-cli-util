# shellcheck shell=bash
# Worktree discovery, inspection, artifact cleanup and guarded removal.
# Every action runs one pipeline: select -> plan -> confirm once -> execute -> report.
#
# Functions prefixed with `_wt_` run as the agent user (shipped through
# run_fn_as_agent), so git and the filesystem are only ever touched as the
# owner of the tree. They are self-contained: they may only call other `_wt_`
# functions and must not rely on caller globals.

# Every agent-side function, shipped together.
WT_AGENT_FNS="_wt_id _wt_err _wt_discover _wt_under_root _wt_inspect_one _wt_inspect
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

# Reasons a worktree must not be removed, one per line as "<class>\t<text>".
#   H = hard: can never be overridden (wrong kind of checkout, broken or
#       locked git state)
#   S = soft: work could be lost; only an explicit --force overrides it
# Empty output means the worktree can be removed without --force.
#   _wt_safety_reasons kind state modified untracked upstream ahead published [branch]
_wt_safety_reasons() {
  local kind=$1 state=$2 mod=$3 unt=$4 up=$5 ahead=$6 pub=$7 branch=${8:-}
  [[ $kind == main ]] && printf 'H\t%s\n' "main repository checkout, not a linked worktree"
  case $state in
    ok) ;;
    in-progress:*) printf 'S\t%s\n' "git state: $state" ;;
    *) printf 'H\t%s\n' "git state: $state" ;;
  esac
  if [[ $mod == '?' ]]; then
    printf 'S\t%s\n' "cannot determine tracked changes"
  elif ((mod > 0)); then
    printf 'S\t%s\n' "modified files: $mod"
  fi
  if [[ $unt == '?' ]]; then
    printf 'S\t%s\n' "cannot determine untracked files"
  elif ((unt > 0)); then
    printf 'S\t%s\n' "untracked files: $unt"
  fi
  if [[ $up != '-' ]]; then
    if [[ $ahead == '?' ]]; then
      printf 'S\t%s\n' "cannot compare with upstream $up"
    elif ((ahead > 0)); then
      printf 'S\t%s\n' "branch ahead of $up: $ahead"
    fi
  else
    case $pub in
      yes) ;;
      no)
        printf 'S\t%s\n' "no upstream, and HEAD is not on any remote branch (unpublished commits)"
        [[ $branch == '(detached)' ]] &&
          printf 'S\t%s\n' "detached HEAD: its unpublished commits are on no branch and would be orphaned"
        ;;
      *) printf 'S\t%s\n' "no upstream, and cannot determine whether HEAD is published" ;;
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

# Re-validate and remove a worktree with git. Exit 3 + tagged reasons if the
# removal is not allowed. Hard reasons (and running processes) always refuse;
# soft reasons only refuse when force is 0.
#   _wt_remove root wt expected_id force
_wt_remove() {
  local root=$1 wt=$2 want=$3 force=${4:-0}
  local croot rec id p size branch head cts ats mod unt up ahead behind pub state kind common reasons procs line
  local blocked=0 shown=''
  croot=$(realpath -e -- "$root") || return 1
  if [[ $(realpath -e -- "$wt" 2>/dev/null) != "$wt" ]] || ! _wt_under_root "$croot" "$wt"; then
    printf 'H\tpath is not strictly beneath %s\n' "$croot"
    return 3
  fi
  [[ $(_wt_id "$wt") == "$want" ]] || {
    printf 'H\tworktree ID mismatch\n'
    return 3
  }
  rec=$(_wt_inspect_one "$wt" 0)
  IFS=$'\t' read -r id p size branch head cts ats mod unt up ahead behind pub state kind common <<<"$rec"
  reasons=$(_wt_safety_reasons "$kind" "$state" "$mod" "$unt" "$up" "$ahead" "$pub" "$branch")
  procs=$(_wt_procs "$wt")
  if [[ -n $procs ]]; then
    reasons+=${reasons:+$'\n'}"H"$'\t'"processes running inside: $(awk '{print $2 "(" $1 ")"}' <<<"$procs" | paste -sd' ' -)"
  fi
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    shown+=$line$'\n'
    if [[ $line == H$'\t'* || $force != 1 ]]; then blocked=1; fi
  done <<<"$reasons"
  if ((blocked)); then
    printf '%s' "$shown"
    return 3
  fi
  if [[ $force == 1 ]]; then
    git --git-dir="$common" worktree remove --force "$wt" || return 1
  else
    git --git-dir="$common" worktree remove "$wt" || return 1
  fi
  git --git-dir="$common" worktree prune || true
  [[ ! -e $wt ]]
}

# ----------------------------------------------------------- caller side

wt_prune_names() { printf '%s ' "${SAFE_CLEAN_DIRS[@]}"; }

# Run an agent-side function with all _wt_ helpers available.
wt_agent() { run_fn_as_agent "$WT_AGENT_FNS" "$@"; }

wt_reset_state() {
  WT_IDS=() WT_ALL=() WT_SELECTED=()
  declare -gA WT_PATH=() WT_SIZE=() WT_BRANCH=() WT_HEAD=() WT_CTS=() WT_ATS=() WT_MOD=() WT_UNT=() \
    WT_UP=() WT_AHEAD=() WT_BEHIND=() WT_PUB=() WT_STATE=() WT_KIND=() WT_COMMON=()
  # Per-worktree artifact plans (see wt_plan_load).
  declare -gA CP_DEL=() CP_ROWS=() CP_KEPT=() CP_KB=() CP_N=()
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

wt_title() { printf '%s/%s' "$(wt_project "$1")" "$(wt_name "$1")"; }

# Canonical worktree root as the agent sees it (needed to display paths).
wt_canonical_root() {
  local r
  r=$(run_as_agent realpath -e -- "$WORKTREE_ROOT" 2>/dev/null) || die "worktree root not found: $WORKTREE_ROOT"
  WORKTREE_ROOT=$r
}

wt_size_label() {
  if [[ $1 == '-' ]]; then printf -- '-'; else human_kb "$1"; fi
}

wt_age_of() {
  local ts=$1
  [[ $ts =~ ^[0-9]+$ ]] || {
    printf '?'
    return
  }
  human_age $((NOW - ts))
}

fmt_ts() {
  [[ $1 =~ ^[0-9]+$ ]] || {
    printf '?'
    return
  }
  printf '%s ago (%s)' "$(human_age $((NOW - $1)))" "$(date -d "@$1" '+%Y-%m-%d %H:%M')"
}

wt_procs_text() { awk '{print $2 "(" $1 ")"}' <<<"$1" | paste -sd' ' -; }

# ---------------------------------------------------------------- verdicts
#
#   safe     nothing can be lost; removable as is
#   risk     work could be lost; removable only with --force
#   blocked  never removable (main checkout, locked or broken git state)

# Split the removal reasons of one worktree into REASONS_HARD / REASONS_SOFT
# (newline separated). Running processes are checked separately, right
# before acting.
wt_classify() {
  local id=$1 cls txt
  REASONS_HARD='' REASONS_SOFT=''
  while IFS=$'\t' read -r cls txt; do
    [[ -n $cls ]] || continue
    if [[ $cls == H ]]; then
      REASONS_HARD+=${REASONS_HARD:+$'\n'}$txt
    else
      REASONS_SOFT+=${REASONS_SOFT:+$'\n'}$txt
    fi
  done < <(_wt_safety_reasons "${WT_KIND[$id]}" "${WT_STATE[$id]}" "${WT_MOD[$id]}" "${WT_UNT[$id]}" \
    "${WT_UP[$id]}" "${WT_AHEAD[$id]}" "${WT_PUB[$id]}" "${WT_BRANCH[$id]}")
}

wt_verdict() {
  wt_classify "$1"
  if [[ -n $REASONS_HARD ]]; then
    printf blocked
  elif [[ -n $REASONS_SOFT ]]; then
    printf risk
  else
    printf safe
  fi
}

wt_verdict_cell() {
  case $1 in
    safe) printf '{g}%s safe' "$U_OK" ;;
    risk) printf '{y}%s force' "$U_RISK" ;;
    *) printf '{r}%s blocked' "$U_NO" ;;
  esac
}

# Would a --force removal destroy something that is not on any branch?
wt_force_loss() {
  local id=$1
  [[ ${WT_MOD[$id]} != 0 || ${WT_UNT[$id]} != 0 ]] && return 0
  [[ ${WT_BRANCH[$id]} == '(detached)' && ${WT_PUB[$id]} != yes ]] && return 0
  [[ ${WT_STATE[$id]} == in-progress:* ]] && return 0
  return 1
}

# One-line description of what --force discards (and what survives).
wt_discard_note() {
  local id=$1 out='' keeps=''
  local b=${WT_BRANCH[$id]} nmod=${WT_MOD[$id]} nunt=${WT_UNT[$id]}
  local -a lost=()
  [[ $nmod == '?' || $nunt == '?' ]] && lost+=("changes of unknown size")
  [[ $nmod =~ ^[1-9] ]] && lost+=("$nmod modified")
  [[ $nunt =~ ^[1-9] ]] && lost+=("$nunt untracked")
  [[ ${WT_STATE[$id]} == in-progress:* ]] && lost+=("${WT_STATE[$id]#in-progress:} state")
  ((${#lost[@]})) && out="discards $(printf '%s, ' "${lost[@]}")" && out=${out%, }
  if [[ $b == '(detached)' ]]; then
    [[ ${WT_PUB[$id]} != yes ]] && keeps="orphans unpublished commits (detached HEAD)"
  elif [[ ${WT_UP[$id]} == '-' && ${WT_PUB[$id]} != yes ]] || [[ ${WT_AHEAD[$id]} =~ ^[1-9] ]]; then
    keeps="branch $b keeps its unpublished commits"
  fi
  printf '%s' "$out${out:+${keeps:+; }}$keeps"
}

# ------------------------------------------------------------------ labels

wt_changes_cell() {
  local nmod=${WT_MOD[$1]} nunt=${WT_UNT[$1]} out=''
  if [[ $nmod == '?' || $nunt == '?' ]]; then
    printf '{y}?'
    return
  fi
  ((nmod > 0)) && out+="${nmod}M"
  ((nunt > 0)) && out+="${nunt}U"
  if [[ -n $out ]]; then printf '{y}%s' "$out"; else printf '{d}clean'; fi
}

wt_sync_cell() {
  local id=$1 a=${WT_AHEAD[$1]} b=${WT_BEHIND[$1]} out=''
  if [[ ${WT_UP[$id]} == '-' ]]; then
    case ${WT_PUB[$id]} in
      yes) printf '{d}pushed' ;;
      no) printf '{y}local' ;;
      *) printf '?' ;;
    esac
    return
  fi
  if [[ ! $a =~ ^[0-9]+$ || ! $b =~ ^[0-9]+$ ]]; then
    printf '?'
    return
  fi
  ((a > 0)) && out+="$U_UP$a"
  ((b > 0)) && out+="${out:+ }$U_DOWN$b"
  if [[ -n $out ]]; then printf '{y}%s' "$out"; else printf '{d}in sync'; fi
}

# ----------------------------------------------------------------- options
#
# One option grammar for listing and for every action:
#
#   selection   IDs (comma separated, unique prefixes) and/or filters
#   filters     --project --name --branch --older-than --newer-than --before
#               --larger-than --pushed --unpushed --dirty --clean --safe --status
#   modifiers   --all --dry-run --force --no-size --sort -r --yes
#
# Filters combine with AND; values of --project/--name/--branch are
# comma-separated, case-insensitive globs combined with OR.

wt_reset_opts() {
  WT_ACTION='' WT_ARGIDS=()
  F_PROJECTS=() F_NAMES=() F_BRANCHES=() F_DESC=()
  F_OLDER='' F_NEWER='' F_BEFORE='' F_LARGER='' F_PUB='' F_DIRTY='' F_STATUS=''
  F_ALL=0 F_DRY=0 F_FORCE=0 F_SIZE=1 F_SORT=age F_SORT_SET=0 F_REVERSE=0 F_FILTERED=0
}

wt_before_timestamp() {
  [[ $1 =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
  date -d "$1 00:00:00" +%s 2>/dev/null
}

wt_add_globs() {
  local -n _arr=$1
  local v=$2
  local -a parts
  [[ $v != ,* && $v != *, && $v != *,,* ]] || die "empty entry in list '$v'"
  IFS=, read -r -a parts <<<"$v"
  _arr+=("${parts[@]}")
}

wt_set_value() {
  local name=$1 v=$2
  case $name in
    --project)
      wt_add_globs F_PROJECTS "$v"
      F_DESC+=("project=$v")
      ;;
    --name)
      wt_add_globs F_NAMES "$v"
      F_DESC+=("name=$v")
      ;;
    --branch)
      wt_add_globs F_BRANCHES "$v"
      F_DESC+=("branch=$v")
      ;;
    --older-than)
      F_OLDER=$(parse_duration "$v") || die "invalid duration '$v' (examples: 12h, 7d, 2w, 3mo)"
      F_DESC+=("older-than=$v")
      ;;
    --newer-than)
      F_NEWER=$(parse_duration "$v") || die "invalid duration '$v' (examples: 12h, 7d, 2w, 3mo)"
      F_DESC+=("newer-than=$v")
      ;;
    --before)
      F_BEFORE=$(wt_before_timestamp "$v") || die "invalid date '$v' (expected YYYY-MM-DD)"
      F_DESC+=("before=$v")
      ;;
    --larger-than)
      F_LARGER=$(parse_size_kb "$v") || die "invalid size '$v' (examples: 500M, 2G)"
      F_DESC+=("larger-than=$v")
      ;;
    --status)
      local s
      local -a parts
      IFS=, read -r -a parts <<<"$v"
      for s in "${parts[@]}"; do
        [[ $s == safe || $s == risk || $s == blocked ]] || die "invalid status '$s' (use safe, risk or blocked)"
      done
      [[ -z $F_STATUS ]] || die "--safe and --status cannot be combined"
      F_STATUS=",$v,"
      F_DESC+=("status=$v")
      ;;
    --sort)
      [[ $v =~ ^(size|age|project|commit)$ ]] || die "--sort must be size, age, project or commit"
      F_SORT=$v F_SORT_SET=1
      ;;
  esac
}

# Parse the argv of `worktrees` / `worktree`. Sets WT_ACTION, WT_ARGIDS and
# the F_* options.
wt_parse_args() {
  wt_reset_opts
  local a name val has_val step part
  local -a parts
  while (($#)); do
    a=$1 name=$1 val='' has_val=0 step=1
    if [[ $a == --*=* ]]; then
      name=${a%%=*}
      val=${a#*=}
      has_val=1
    fi
    case $name in
      --project | --name | --branch | --older-than | --newer-than | --before | --larger-than | --status | --sort)
        if ((!has_val)); then
          (($# >= 2)) || die "$name needs a value"
          val=$2
          step=2
        fi
        [[ -n $val ]] || die "$name needs a value"
        wt_set_value "$name" "$val"
        [[ $name == --sort ]] || F_FILTERED=1
        ;;
      --pushed | --unpushed)
        local want=yes
        [[ $name == --unpushed ]] && want=no
        [[ -z $F_PUB || $F_PUB == "$want" ]] || die "--pushed and --unpushed cannot be combined"
        F_PUB=$want F_FILTERED=1
        F_DESC+=("${name#--}")
        ;;
      --dirty | --clean)
        local dwant=dirty
        [[ $name == --clean ]] && dwant=clean
        [[ -z $F_DIRTY || $F_DIRTY == "$dwant" ]] || die "--dirty and --clean cannot be combined"
        F_DIRTY=$dwant F_FILTERED=1
        F_DESC+=("${name#--}")
        ;;
      --safe)
        [[ -z $F_STATUS ]] || die "--safe and --status cannot be combined"
        F_STATUS=,safe, F_FILTERED=1
        F_DESC+=("safe")
        ;;
      --all) F_ALL=1 ;;
      -n | --dry-run) F_DRY=1 ;;
      --force) F_FORCE=1 ;;
      --no-size) F_SIZE=0 ;;
      -r | --reverse) F_REVERSE=1 ;;
      -y | --yes) export T3CTL_ASSUME_YES=1 ;;
      -*) die "unknown option: $a (see t3ctl --help)" ;;
      info | clean | remove | list | ls)
        [[ -z $WT_ACTION ]] || die "specify one worktree action (info, clean, remove)"
        WT_ACTION=$name
        ;;
      *)
        [[ -n $a && $a != ,* && $a != *, && $a != *,,* ]] || die "invalid worktree ID list '$a'"
        IFS=, read -r -a parts <<<"$a"
        for part in "${parts[@]}"; do WT_ARGIDS+=("$part"); done
        ;;
    esac
    shift "$step"
  done
  [[ $WT_ACTION == ls ]] && WT_ACTION=list
  if [[ -n $F_LARGER && $F_SIZE == 0 ]]; then die "--larger-than needs sizes; drop --no-size"; fi
  return 0
}

# ---------------------------------------------------------------- selection

# Case-insensitive glob match: wt_glob PATTERN VALUE
wt_glob() {
  local had=0 rc=1
  shopt -q nocasematch && had=1
  shopt -s nocasematch
  # shellcheck disable=SC2053
  [[ $2 == $1 ]] && rc=0
  ((had)) || shopt -u nocasematch
  return "$rc"
}

# Does VALUE match any of the globs? wt_glob_any VALUE GLOB...
wt_glob_any() {
  local v=$1 g
  shift
  for g in "$@"; do wt_glob "$g" "$v" && return 0; done
  return 1
}

# A typo in --project should say so, not silently select nothing.
wt_validate_projects() {
  local pat id proj found
  local -A known=()
  ((${#F_PROJECTS[@]})) || return 0
  for id in "${WT_ALL[@]}"; do known[$(wt_project "$id")]=1; done
  for pat in "${F_PROJECTS[@]}"; do
    found=0
    for proj in "${!known[@]}"; do
      if wt_glob "$pat" "$proj"; then
        found=1
        break
      fi
    done
    ((found)) || die "no project matches '$pat' (projects: $(printf '%s\n' "${!known[@]}" | sort | paste -sd, - | sed 's/,/, /g'))"
  done
}

# Resolve ID prefixes against the discovered worktrees into WT_CAND.
wt_resolve_ids() {
  local prefix id
  local -a hits
  local -A seen=()
  WT_CAND=()
  for prefix in "${WT_ARGIDS[@]}"; do
    [[ $prefix =~ ^[0-9a-f]{3,40}$ ]] || die "invalid worktree ID '$prefix' (expected hex, e.g. a83f21)"
    hits=()
    for id in "${WT_ALL[@]}"; do
      if [[ $id == "$prefix" ]]; then
        hits=("$id")
        break
      fi
      [[ $id == "$prefix"* ]] && hits+=("$id")
    done
    case ${#hits[@]} in
      0)
        printf "t3ctl: no worktree with ID '%s' (see: t3ctl worktrees)\n" "$prefix" >&2
        exit 4
        ;;
      1)
        if [[ -z ${seen[${hits[0]}]:-} ]]; then
          WT_CAND+=("${hits[0]}")
          seen[${hits[0]}]=1
        fi
        ;;
      *)
        printf "t3ctl: ID '%s' is ambiguous:\n" "$prefix" >&2
        for id in "${hits[@]}"; do printf '  %s  %s\n' "$id" "${WT_PATH[$id]}" >&2; done
        exit 4
        ;;
    esac
  done
}

# Filters on inspected data. Unknown values never satisfy a filter.
wt_matches() {
  local id=$1 ts=${WT_ATS[$1]} nmod=${WT_MOD[$1]} nunt=${WT_UNT[$1]} sz=${WT_SIZE[$1]}
  if [[ -n $F_OLDER ]]; then
    [[ $ts =~ ^[0-9]+$ ]] && ((NOW - ts >= F_OLDER)) || return 1
  fi
  if [[ -n $F_NEWER ]]; then
    [[ $ts =~ ^[0-9]+$ ]] && ((NOW - ts < F_NEWER)) || return 1
  fi
  if [[ -n $F_BEFORE ]]; then
    [[ $ts =~ ^[0-9]+$ ]] && ((ts < F_BEFORE)) || return 1
  fi
  if ((${#F_BRANCHES[@]})); then
    wt_glob_any "${WT_BRANCH[$id]}" "${F_BRANCHES[@]}" || return 1
  fi
  [[ -z $F_PUB || ${WT_PUB[$id]} == "$F_PUB" ]] || return 1
  if [[ -n $F_DIRTY ]]; then
    [[ $nmod =~ ^[0-9]+$ && $nunt =~ ^[0-9]+$ ]] || return 1
    if [[ $F_DIRTY == dirty ]]; then
      ((nmod + nunt > 0)) || return 1
    else
      ((nmod + nunt == 0)) || return 1
    fi
  fi
  if [[ -n $F_LARGER ]]; then
    [[ $sz =~ ^[0-9]+$ ]] && ((sz > F_LARGER)) || return 1
  fi
  if [[ -n $F_STATUS ]]; then
    [[ $F_STATUS == *",$(wt_verdict "$id"),"* ]] || return 1
  fi
  return 0
}

# Discover, resolve IDs, narrow by path-derived filters (before the slow
# inspection), inspect, then apply the remaining filters. Fills WT_* for the
# inspected worktrees and WT_SELECTED with the final selection.
#   wt_collect with_size
wt_collect() {
  local with_size=$1 p id rec
  local -a paths=() cand=()
  resolve_agent
  wt_canonical_root
  NOW=$(date +%s)
  wt_reset_state
  mapfile -t paths < <(wt_agent _wt_discover "$WORKTREE_ROOT" "$WORKTREE_SCAN_DEPTH" "${SAFE_CLEAN_DIRS[@]}")
  for p in "${paths[@]}"; do
    [[ -n $p ]] || continue
    id=$(_wt_id "$p")
    WT_ALL+=("$id")
    WT_PATH[$id]=$p
  done
  ((${#WT_ALL[@]})) || return 0
  wt_validate_projects
  if ((${#WT_ARGIDS[@]})); then
    wt_resolve_ids
    cand=("${WT_CAND[@]}")
  else
    cand=("${WT_ALL[@]}")
  fi
  local -a narrowed=()
  for id in "${cand[@]}"; do
    if ((${#F_PROJECTS[@]})); then wt_glob_any "$(wt_project "$id")" "${F_PROJECTS[@]}" || continue; fi
    if ((${#F_NAMES[@]})); then wt_glob_any "$(wt_name "$id")" "${F_NAMES[@]}" || continue; fi
    narrowed+=("$id")
  done
  ((${#narrowed[@]})) || return 0
  paths=()
  for id in "${narrowed[@]}"; do paths+=("${WT_PATH[$id]}"); done
  while IFS= read -r rec; do
    [[ -n $rec ]] || continue
    wt_parse_record "$rec"
  done < <(wt_agent _wt_inspect "$with_size" "$(wt_prune_names)" "${paths[@]}")
  for id in "${WT_IDS[@]}"; do
    wt_matches "$id" && WT_SELECTED+=("$id")
  done
  return 0
}

wt_filters_line() {
  ((${#F_DESC[@]})) || return 0
  local IFS=$'\n'
  printf '%sFilters: %s%s\n' "$C_DIM" "$(printf '%s\n' "${F_DESC[@]}" | paste -sd'|' - | sed "s/|/ $U_DOT /g")" "$C_RST"
}

# -------------------------------------------------------------------- list

wt_join_tabs() {
  local IFS=$'\t'
  printf '%s\n' "$*"
}

wt_cmd_list() {
  [[ $F_SORT == size && $F_SIZE == 0 ]] && die "--sort size needs sizes; drop --no-size"
  [[ $F_FORCE == 0 && $F_DRY == 0 ]] || die "--force and --dry-run apply to clean/remove actions only"
  wt_collect "$F_SIZE"
  if ((${#WT_ALL[@]} == 0)); then
    echo "No worktrees found under $WORKTREE_ROOT"
    return 0
  fi
  if ((${#WT_SELECTED[@]} == 0)); then
    printf 'No worktrees match (%d under %s).\n' "${#WT_ALL[@]}" "$WORKTREE_ROOT"
    wt_filters_line
    return 0
  fi

  # Sortable lines: key<TAB>id
  local id key ts sz
  local -a lines=()
  for id in "${WT_SELECTED[@]}"; do
    ts=${WT_ATS[$id]}
    case $F_SORT in
      size) key=${WT_SIZE[$id]}; [[ $key =~ ^[0-9]+$ ]] || key=0 ;;
      age) key=$ts; [[ $key =~ ^[0-9]+$ ]] || key=0 ;;
      commit) key=${WT_CTS[$id]}; [[ $key =~ ^[0-9]+$ ]] || key=0 ;;
      project) key="$(wt_project "$id")/$(wt_name "$id")" ;;
    esac
    lines+=("$key"$'\t'"$id")
  done
  # shellcheck disable=SC2054
  local -a sort_opts=(-t $'\t' -k1,1)
  if [[ $F_SORT == project ]]; then
    ((F_REVERSE)) && sort_opts+=(-r)
  else
    sort_opts+=(-n)
    ((F_REVERSE)) || sort_opts+=(-r)
  fi

  local max_kb=0
  for id in "${WT_SELECTED[@]}"; do
    sz=${WT_SIZE[$id]}
    if [[ $sz =~ ^[0-9]+$ ]] && ((sz > max_kb)); then max_kb=$sz; fi
  done

  local with_size=$F_SIZE verdict proj rows='' align=lll
  local total_kb=0 unknown_size=0 n_safe=0 n_risk=0 n_block=0
  local -A p_n=() p_safe=() p_risk=() p_block=() p_kb=()
  local -a cols=(ID PROJECT NAME)
  if ((with_size)); then
    cols+=(SIZE '')
    align=lllrl
  fi
  cols+=(ACTIVE COMMIT CHANGES SYNC REMOVE BRANCH)
  rows=$(wt_join_tabs "${cols[@]}")
  while IFS=$'\t' read -r key id; do
    [[ -n $id ]] || continue
    verdict=$(wt_verdict "$id")
    proj=$(wt_project "$id")
    p_n[$proj]=$((${p_n[$proj]:-0} + 1))
    case $verdict in
      safe)
        n_safe=$((n_safe + 1))
        p_safe[$proj]=$((${p_safe[$proj]:-0} + 1))
        ;;
      risk)
        n_risk=$((n_risk + 1))
        p_risk[$proj]=$((${p_risk[$proj]:-0} + 1))
        ;;
      *)
        n_block=$((n_block + 1))
        p_block[$proj]=$((${p_block[$proj]:-0} + 1))
        ;;
    esac
    sz=${WT_SIZE[$id]}
    if [[ $sz =~ ^[0-9]+$ ]]; then
      total_kb=$((total_kb + sz))
      p_kb[$proj]=$((${p_kb[$proj]:-0} + sz))
    elif [[ $sz == '?' ]]; then
      unknown_size=1
    fi
    cols=("$id" "$proj" "$(ui_trunc "$(wt_name "$id")" 24)")
    if ((with_size)); then cols+=("$(human_kb "$sz")" "{d}$(ui_bar "$sz" "$max_kb" 8)"); fi
    cols+=("$(wt_age_of "${WT_ATS[$id]}")" "$(wt_age_of "${WT_CTS[$id]}")" "$(wt_changes_cell "$id")"
      "$(wt_sync_cell "$id")" "$(wt_verdict_cell "$verdict")" "$(ui_trunc "${WT_BRANCH[$id]}" 32)")
    rows+=$'\n'$(wt_join_tabs "${cols[@]}")
  done < <(printf '%s\n' "${lines[@]}" | sort "${sort_opts[@]}")

  wt_filters_line
  printf '%s\n' "$rows" | ui_table "$align"

  echo
  local summary
  summary="${#WT_SELECTED[@]} of ${#WT_ALL[@]} worktree(s)"
  if ((with_size)); then
    summary+=" $U_DOT $(human_kb "$total_kb") summed"
    ((unknown_size)) && summary+=" (some sizes unknown)"
  fi
  printf '%s\n' "$summary"
  printf '  %s%s%s %d safe to remove   %s%s%s %d need --force   %s%s%s %d blocked\n' \
    "$C_GRN" "$U_OK" "$C_RST" "$n_safe" "$C_YEL" "$U_RISK" "$C_RST" "$n_risk" "$C_RED" "$U_NO" "$C_RST" "$n_block"

  local -a projects
  mapfile -t projects < <(printf '%s\n' "${!p_n[@]}" | sort)
  if ((${#projects[@]} > 1)); then
    echo
    local pmax=0
    for proj in "${projects[@]}"; do
      sz=${p_kb[$proj]:-0}
      ((sz > pmax)) && pmax=$sz
    done
    rows=$(wt_join_tabs PROJECT COUNT SAFE FORCE BLOCKED SIZE '')
    local size_cell bar_cell
    for proj in "${projects[@]}"; do
      sz=${p_kb[$proj]:-0}
      if ((with_size)); then
        size_cell=$(human_kb "$sz")
        bar_cell="{d}$(ui_bar "$sz" "$pmax" 12)"
      else
        size_cell=- bar_cell=''
      fi
      rows+=$'\n'$(wt_join_tabs "$proj" "${p_n[$proj]}" "${p_safe[$proj]:-0}" "${p_risk[$proj]:-0}" \
        "${p_block[$proj]:-0}" "$size_cell" "$bar_cell")
    done
    ((with_size)) && size_cell=$(human_kb "$total_kb") || size_cell=-
    rows+=$'\n@rule'
    rows+=$'\n'$(wt_join_tabs "{b}total" "${#WT_SELECTED[@]}" "$n_safe" "$n_risk" "$n_block" "$size_cell" '')
    printf '%s\n' "$rows" | ui_table lrrrrrl
  fi

  echo
  ((with_size)) && printf '%sSIZE counts files hard-linked between worktrees in each one, so the sum overstates real usage (see: t3ctl disk).%s\n' "$C_DIM" "$C_RST"
  printf '%sACTIVE = last file change (excl. artifacts) | CHANGES: M modified, U untracked | SYNC: %s%s vs upstream; local = unpublished, pushed = on a remote branch%s\n' \
    "$C_DIM" "$U_UP" "$U_DOWN" "$C_RST"
  printf '%sREMOVE: %s safe = nothing to lose | %s force = needs --force | %s blocked = never removable%s\n' \
    "$C_DIM" "$U_OK" "$U_RISK" "$U_NO" "$C_RST"
}

# -------------------------------------------------------------------- info

# Print the artifact rows stored for one worktree (largest first), with bars.
#   wt_plan_print id
wt_plan_print() {
  local id=$1 kb rel why n=0 rest_kb=0 rest_n=0 max=0 line
  local -a sorted=()
  if [[ -z ${CP_ROWS[$id]:-} ]]; then
    echo "  (no generated artifacts found)"
  else
    mapfile -t sorted < <(printf '%s\n' "${CP_ROWS[$id]}" | sort -t $'\t' -k1,1nr)
    IFS=$'\t' read -r max _ <<<"${sorted[0]}"
    for line in "${sorted[@]}"; do
      IFS=$'\t' read -r kb rel <<<"$line"
      n=$((n + 1))
      if ((n <= ${PLAN_SHOW:-8})); then
        printf '  %7s %s%s%s  %s\n' "$(human_kb "$kb")" "$C_DIM" "$(ui_bar "$kb" "$max" 8)" "$C_RST" "$rel"
      else
        rest_n=$((rest_n + 1))
        [[ $kb =~ ^[0-9]+$ ]] && rest_kb=$((rest_kb + kb))
      fi
    done
    if ((rest_n)); then
      printf '  %7s %8s  ... %d more\n' "$(human_kb "$rest_kb")" '' "$rest_n"
    fi
  fi
  if [[ -n ${CP_KEPT[$id]:-} ]]; then
    while IFS=$'\t' read -r kb rel why; do
      printf '  %7s  %s  %s(kept: %s)%s\n' "$(human_kb "$kb")" "$rel" "$C_DIM" "$why" "$C_RST"
    done <<<"${CP_KEPT[$id]}"
  fi
}

# Ask the agent side for the artifact plan of one worktree and store it in
# CP_DEL (relative paths to delete), CP_ROWS ("kb<TAB>rel"), CP_KEPT, CP_KB, CP_N.
#   wt_plan_load id
wt_plan_load() {
  local id=$1 action kb rel why
  CP_DEL[$id]='' CP_ROWS[$id]='' CP_KEPT[$id]='' CP_KB[$id]=0 CP_N[$id]=0
  while IFS=$'\t' read -r action kb rel why; do
    [[ -n $rel ]] || continue
    if [[ $action == delete ]]; then
      CP_DEL[$id]+=${CP_DEL[$id]:+$'\n'}$rel
      CP_ROWS[$id]+=${CP_ROWS[$id]:+$'\n'}$kb$'\t'$rel
      [[ $kb =~ ^[0-9]+$ ]] && CP_KB[$id]=$((CP_KB[$id] + kb))
      CP_N[$id]=$((CP_N[$id] + 1))
    else
      CP_KEPT[$id]+=${CP_KEPT[$id]:+$'\n'}$kb$'\t'$rel$'\t'$why
    fi
  done < <(wt_agent _wt_clean_plan "$WORKTREE_ROOT" "${WT_PATH[$id]}" "${SAFE_CLEAN_DIRS[@]}")
  return 0
}

wt_info() {
  local id=$1 p procs hard soft line
  p=${WT_PATH[$id]}
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
  printf '  %-14s %s\n' size "$(wt_size_label "${WT_SIZE[$id]}")"
  procs=$(wt_agent _wt_procs "$p")
  if [[ -n $procs ]]; then
    printf '  %-14s %s\n' processes "$(wt_procs_text "$procs")"
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
  wt_plan_load "$id"
  wt_plan_print "$id"
  ((${CP_N[$id]})) && printf '  reclaimable: %s\n' "$(human_kb "${CP_KB[$id]}")"

  echo
  wt_classify "$id"
  hard=$REASONS_HARD soft=$REASONS_SOFT
  [[ -n $procs ]] && hard+=${hard:+$'\n'}"processes running inside the worktree"
  if [[ -z $hard && -z $soft ]]; then
    printf 'Removal: %sSAFE%s  (t3ctl worktree %s remove)\n' "$C_GRN" "$C_RST" "$id"
  elif [[ -z $hard ]]; then
    printf 'Removal: %sNEEDS --force%s  (t3ctl worktree %s remove --force)\n' "$C_YEL" "$C_RST" "$id"
  else
    printf 'Removal: %sBLOCKED%s\n' "$C_RED" "$C_RST"
  fi
  while IFS= read -r line; do
    [[ -n $line ]] && printf '  %s%s%s %s\n' "$C_RED" "$U_NO" "$C_RST" "$line"
  done <<<"$hard"
  while IFS= read -r line; do
    [[ -n $line ]] && printf '  %s%s%s %s\n' "$C_YEL" "$U_RISK" "$C_RST" "$line"
  done <<<"$soft"
  [[ -n $hard || -n $soft ]] && printf '  %s%s can be overridden with --force, %s cannot%s\n' "$C_DIM" "$U_RISK" "$U_NO" "$C_RST"
  return 0
}

wt_do_info() {
  local id first=1
  for id in "${WT_SELECTED[@]}"; do
    ((first)) || echo
    first=0
    wt_info "$id"
  done
}

# ------------------------------------------------------------------- clean

wt_do_clean() {
  local id kb procs total_kb=0 n_dirs=0 n_wt=0 name max_kb=0 rows note
  local -A procs_of=() agg_kb=() agg_n=()
  for id in "${WT_SELECTED[@]}"; do
    wt_plan_load "$id"
    procs_of[$id]=$(wt_agent _wt_procs "${WT_PATH[$id]}")
    ((${CP_KB[$id]} > max_kb)) && max_kb=${CP_KB[$id]}
    total_kb=$((total_kb + CP_KB[$id]))
    n_dirs=$((n_dirs + CP_N[$id]))
    ((${CP_N[$id]} > 0)) && n_wt=$((n_wt + 1))
  done

  rows=$(wt_join_tabs ID WORKTREE SIZE ARTIFACTS RECLAIM '' NOTE)
  for id in "${WT_SELECTED[@]}"; do
    note=''
    [[ -n ${procs_of[$id]} ]] && note="{y}processes running inside: $(wt_procs_text "${procs_of[$id]}")"
    ((${CP_N[$id]} == 0)) && note="{d}nothing to clean"
    rows+=$'\n'$(wt_join_tabs "$id" "$(ui_trunc "$(wt_title "$id")" 36)" "$(wt_size_label "${WT_SIZE[$id]}")" \
      "${CP_N[$id]}" "$(human_kb "${CP_KB[$id]}")" "{d}$(ui_bar "${CP_KB[$id]}" "$max_kb" 8)" "$note")
  done
  if ((${#WT_SELECTED[@]} > 1)); then
    rows+=$'\n@rule'
    rows+=$'\n'$(wt_join_tabs "" "{b}total" "" "$n_dirs" "$(human_kb "$total_kb")" '' '')
  fi
  echo
  printf '%s\n' "$rows" | ui_table llrrrll

  if ((n_dirs == 0)); then
    echo
    echo "Nothing to clean."
    return 0
  fi

  # What the reclaimed space is made of.
  local line
  for id in "${WT_SELECTED[@]}"; do
    [[ -n ${CP_ROWS[$id]} ]] || continue
    while IFS=$'\t' read -r kb rel; do
      name=${rel##*/}
      agg_n[$name]=$((${agg_n[$name]:-0} + 1))
      [[ $kb =~ ^[0-9]+$ ]] && agg_kb[$name]=$((${agg_kb[$name]:-0} + kb))
    done <<<"${CP_ROWS[$id]}"
  done
  local amax=0
  for name in "${!agg_kb[@]}"; do ((${agg_kb[$name]} > amax)) && amax=${agg_kb[$name]}; done
  rows=$(wt_join_tabs ARTIFACT DIRS SIZE '')
  while IFS= read -r line; do
    name=${line#*$'\t'}
    rows+=$'\n'$(wt_join_tabs "$name" "${agg_n[$name]}" "$(human_kb "${agg_kb[$name]:-0}")" "{d}$(ui_bar "${agg_kb[$name]:-0}" "$amax" 12)")
  done < <(for name in "${!agg_kb[@]}"; do printf '%s\t%s\n' "${agg_kb[$name]}" "$name"; done | sort -t $'\t' -k1,1nr)
  echo
  printf '%s\n' "$rows" | ui_table lrrl

  if ((${#WT_SELECTED[@]} == 1 || F_DRY)); then
    for id in "${WT_SELECTED[@]}"; do
      ((${CP_N[$id]} + 0 > 0)) || [[ -n ${CP_KEPT[$id]} ]] || continue
      printf '\n%s (%s)\n' "$(wt_title "$id")" "$id"
      wt_plan_print "$id"
    done
  fi
  printf '\nReclaimable: %s\n' "$(human_kb "$total_kb")"
  echo "Source files and git state are not touched; reinstall/rebuild to recreate artifacts."

  if ((F_DRY)); then
    echo
    echo "Dry run: nothing was changed."
    return 0
  fi
  echo
  confirm "Clean generated artifacts in $n_wt worktree(s)?" || {
    echo "Aborted."
    return 1
  }

  local status rel why failed=0 avail_before avail_after before after freed_kb=0 res
  local -a dels
  rows=$(wt_join_tabs ID WORKTREE RESULT BEFORE AFTER FREED)
  avail_before=$(fs_stats "$WORKTREE_ROOT" | awk '{print $3}') || avail_before=''
  local skipmsg=''
  for id in "${WT_SELECTED[@]}"; do
    ((${CP_N[$id]} > 0)) || continue
    mapfile -t dels <<<"${CP_DEL[$id]}"
    res=cleaned
    while IFS=$'\t' read -r status rel why; do
      case $status in
        deleted) ;;
        skipped)
          skipmsg+="  skipped $(wt_title "$id")/$rel: $why"$'\n'
          res=partial
          ;;
        *)
          skipmsg+="  FAILED $(wt_title "$id")/$rel: $why"$'\n'
          res=failed
          failed=1
          ;;
      esac
    done < <(wt_agent _wt_clean_exec "$WORKTREE_ROOT" "${WT_PATH[$id]}" "$(wt_prune_names)" "${dels[@]}")
    before=${WT_SIZE[$id]}
    after=$(wt_agent _wt_du "${WT_PATH[$id]}")
    local freed='?'
    if [[ $before =~ ^[0-9]+$ && $after =~ ^[0-9]+$ ]]; then
      freed=$(human_kb $((before - after)))
      freed_kb=$((freed_kb + before - after))
    fi
    case $res in
      cleaned) res="{g}$U_DONE cleaned" ;;
      partial) res="{y}$U_RISK partial" ;;
      *) res="{r}$U_NO failed" ;;
    esac
    rows+=$'\n'$(wt_join_tabs "$id" "$(ui_trunc "$(wt_title "$id")" 36)" "$res" "$(wt_size_label "$before")" \
      "$(human_kb "$after")" "$freed")
  done
  echo
  printf '%s\n' "$rows" | ui_table lllrrr
  [[ -n $skipmsg ]] && printf '\n%s' "$skipmsg"
  echo
  printf 'Freed:  %s\n' "$(human_kb "$freed_kb")"
  # Hard-linked files shared with other worktrees free no disk space, so
  # also report what the filesystem actually gained.
  avail_after=$(fs_stats "$WORKTREE_ROOT" | awk '{print $3}') || avail_after=''
  if [[ $avail_before =~ ^[0-9]+$ && $avail_after =~ ^[0-9]+$ ]]; then
    printf 'Disk free: %s %s %s' "$(human_kb "$avail_before")" "$U_ARROW" "$(human_kb "$avail_after")"
    if ((avail_after >= avail_before)); then
      printf ' (+%s)\n' "$(human_kb $((avail_after - avail_before)))"
    else
      printf '\n'
    fi
  fi
  return "$failed"
}

# ------------------------------------------------------------------ remove

# "a; b; c" from tagged reasons.
wt_reasons_inline() {
  local cls txt out=''
  while IFS=$'\t' read -r cls txt; do
    [[ -n $cls ]] && out+="${out:+; }$txt"
  done <<<"$1"
  printf '%s' "$out"
}

# Print the tagged agent reasons for one refused removal with a way forward.
#   wt_refusal_block id "tagged reasons"
wt_refusal_block() {
  local id=$1 reasons=$2 cls txt has_hard=0
  printf '\n%sREFUSING TO REMOVE %s%s  %s\n\nSafety checks failed:\n' "$C_RED" "$id" "$C_RST" "$(wt_title "$id")"
  while IFS=$'\t' read -r cls txt; do
    [[ -n $cls ]] || continue
    if [[ $cls == H ]]; then
      has_hard=1
      printf '  %s%s%s %s\n' "$C_RED" "$U_NO" "$C_RST" "$txt"
    else
      printf '  %s%s%s %s\n' "$C_YEL" "$U_RISK" "$C_RST" "$txt"
    fi
  done <<<"$reasons"
  if ((has_hard)); then
    printf '\n%s%s cannot be overridden: resolve it first (for example by unlocking or stopping the process).%s\n' "$C_DIM" "$U_NO" "$C_RST"
  elif ((F_FORCE)); then
    :
  else
    printf '\nDiscard it anyway (branch is kept; uncommitted work is lost):\n\n  t3ctl worktree %s remove --force\n' "$id"
  fi
  printf '\nInspect using:\n\n  t3ctl worktree %s info\n' "$id"
}

wt_do_remove() {
  local id procs hard soft act note n_ok=0 n_force=0 n_ref=0 loss=0 total_kb=0 max_kb=0 rows line
  local -A act_of=() tagged_of=()
  for id in "${WT_SELECTED[@]}"; do
    wt_classify "$id"
    hard=$REASONS_HARD soft=$REASONS_SOFT
    procs=$(wt_agent _wt_procs "${WT_PATH[$id]}")
    [[ -n $procs ]] && hard+=${hard:+$'\n'}"processes running inside: $(wt_procs_text "$procs")"
    tagged_of[$id]=''
    while IFS= read -r line; do
      [[ -n $line ]] && tagged_of[$id]+="H"$'\t'"$line"$'\n'
    done <<<"$hard"
    while IFS= read -r line; do
      [[ -n $line ]] && tagged_of[$id]+="S"$'\t'"$line"$'\n'
    done <<<"$soft"
    if [[ -n $hard ]]; then
      act=refuse
    elif [[ -n $soft ]]; then
      if ((F_FORCE)); then act=force; else act=refuse; fi
    else
      act=remove
    fi
    act_of[$id]=$act
    case $act in
      remove) n_ok=$((n_ok + 1)) ;;
      force)
        n_force=$((n_force + 1))
        wt_force_loss "$id" && loss=$((loss + 1))
        ;;
      *) n_ref=$((n_ref + 1)) ;;
    esac
    if [[ ${WT_SIZE[$id]} =~ ^[0-9]+$ ]]; then
      ((${WT_SIZE[$id]} > max_kb)) && max_kb=${WT_SIZE[$id]}
    fi
  done

  rows=$(wt_join_tabs ID WORKTREE SIZE CHANGES SYNC PLAN NOTE)
  for id in "${WT_SELECTED[@]}"; do
    note=''
    case ${act_of[$id]} in
      remove)
        act="{g}$U_OK remove"
        note="{d}branch ${WT_BRANCH[$id]} is kept"
        ;;
      force)
        act="{y}$U_RISK FORCE"
        note="{y}$(wt_discard_note "$id")"
        ;;
      *)
        act="{r}$U_NO refuse"
        if [[ ${tagged_of[$id]} == *H$'\t'* ]]; then note='{r}'; else note='{y}'; fi
        note+=$(wt_reasons_inline "${tagged_of[$id]}")
        ;;
    esac
    rows+=$'\n'$(wt_join_tabs "$id" "$(ui_trunc "$(wt_title "$id")" 36)" "$(wt_size_label "${WT_SIZE[$id]}")" \
      "$(wt_changes_cell "$id")" "$(wt_sync_cell "$id")" "$act" "$note")
  done
  echo
  printf '%s\n' "$rows" | ui_table llrllll

  if ((n_ref)); then
    if ((${#WT_SELECTED[@]} == 1)); then
      wt_refusal_block "${WT_SELECTED[0]}" "${tagged_of[${WT_SELECTED[0]}]}"
    else
      printf '\n%d worktree(s) refused. ' "$n_ref"
      if ((F_FORCE)); then
        printf '%s%s cannot be overridden%s; inspect with: t3ctl worktree <id> info\n' "$C_DIM" "$U_NO" "$C_RST"
      else
        printf '%sAdd --force to include the ones that only fail on risky checks; inspect with: t3ctl worktree <id> info%s\n' "$C_DIM" "$C_RST"
      fi
    fi
  fi

  local n_act=$((n_ok + n_force))
  if ((n_act == 0)); then
    return 3
  fi
  if ((F_DRY)); then
    echo
    echo "Dry run: nothing was changed."
    return 0
  fi

  echo
  if ((loss)); then
    printf '%sWARNING:%s --force permanently discards uncommitted work in %d worktree(s) (see NOTE above). Branches are kept.\n' \
      "$C_YEL" "$C_RST" "$loss"
    confirm_phrase "Type 'discard' to remove $n_act worktree(s):" discard || {
      echo "Aborted."
      return 1
    }
  else
    confirm "Remove $n_act worktree(s) with 'git worktree remove'?" || {
      echo "Aborted."
      return 1
    }
  fi

  local out rc force worst=0 n_done=0 n_failed=0 n_late=0 detail res avail_before avail_after freed_kb=0
  rows=$(wt_join_tabs ID WORKTREE RESULT DETAIL)
  avail_before=$(fs_stats "$WORKTREE_ROOT" | awk '{print $3}') || avail_before=''
  local late=''
  for id in "${WT_SELECTED[@]}"; do
    [[ ${act_of[$id]} == refuse ]] && continue
    force=0
    [[ ${act_of[$id]} == force ]] && force=1
    rc=0
    out=$(wt_agent _wt_remove "$WORKTREE_ROOT" "${WT_PATH[$id]}" "$id" "$force" 2>&1) || rc=$?
    case $rc in
      0)
        n_done=$((n_done + 1))
        [[ ${WT_SIZE[$id]} =~ ^[0-9]+$ ]] && freed_kb=$((freed_kb + WT_SIZE[$id]))
        res="{g}$U_DONE removed"
        detail="branch ${WT_BRANCH[$id]} kept"
        ;;
      3)
        # State changed between planning and acting; the agent side refused.
        n_late=$((n_late + 1))
        ((worst < 3)) && worst=3
        res="{r}$U_NO refused"
        detail="{d}state changed, see below"
        late+=$(wt_refusal_block "$id" "$out")$'\n'
        ;;
      *)
        n_failed=$((n_failed + 1))
        ((worst < 1)) && worst=1
        res="{r}$U_NO failed"
        detail=$(tail -n1 <<<"$out")
        ;;
    esac
    rows+=$'\n'$(wt_join_tabs "$id" "$(ui_trunc "$(wt_title "$id")" 36)" "$res" "$detail")
  done
  echo
  printf '%s\n' "$rows" | ui_table lll
  [[ -n $late ]] && printf '%s' "$late"
  echo
  printf 'Removed %d, refused %d, failed %d.\n' "$n_done" $((n_ref + n_late)) "$n_failed"
  if ((n_done)); then
    printf 'Worktree sizes summed: %s (hard-linked files may free less)\n' "$(human_kb "$freed_kb")"
    avail_after=$(fs_stats "$WORKTREE_ROOT" | awk '{print $3}') || avail_after=''
    if [[ $avail_before =~ ^[0-9]+$ && $avail_after =~ ^[0-9]+$ ]]; then
      printf 'Disk free: %s %s %s' "$(human_kb "$avail_before")" "$U_ARROW" "$(human_kb "$avail_after")"
      if ((avail_after >= avail_before)); then
        printf ' (+%s)\n' "$(human_kb $((avail_after - avail_before)))"
      else
        printf '\n'
      fi
    fi
  fi
  ((n_ref + n_late > 0 && worst < 3)) && worst=3
  return "$worst"
}

# ---------------------------------------------------------------- dispatch

wt_cmd_action() {
  local action=$WT_ACTION
  [[ $action == remove || $F_FORCE == 0 ]] || die "--force only applies to remove"
  [[ $F_SORT_SET == 0 ]] || die "--sort only applies to listing"
  ((${#WT_ARGIDS[@]} || F_ALL || F_FILTERED)) ||
    die "select worktrees with IDs, --all or filters (--project, --name, --branch, --older-than, --before, --larger-than, --pushed, --unpushed, --dirty, --clean, --safe, --status)"
  wt_collect "$F_SIZE"
  if ((${#WT_SELECTED[@]} == 0)); then
    echo "No worktrees match the selection."
    wt_filters_line
    return 0
  fi
  printf 'Selected %d of %d worktree(s) for %s%s.\n' "${#WT_SELECTED[@]}" "${#WT_ALL[@]}" "$action" \
    "$([[ $F_DRY == 1 ]] && echo ' (dry run)')"
  wt_filters_line
  case $action in
    info) wt_do_info ;;
    clean) wt_do_clean ;;
    remove) wt_do_remove ;;
  esac
}

# t3ctl worktrees [list|info|clean|remove] [IDs] [filters] [options]
cmd_worktrees() {
  wt_parse_args "$@"
  case ${WT_ACTION:-list} in
    list) wt_cmd_list ;;
    *) wt_cmd_action ;;
  esac
}

# Legacy spelling: t3ctl worktree <id> [id...] info|clean|remove [options]
cmd_worktree() {
  wt_parse_args "$@"
  [[ -n $WT_ACTION && $WT_ACTION != list && ${#WT_ARGIDS[@]} -gt 0 ]] ||
    die "usage: t3ctl worktree <id> [id...] info|clean|remove [--dry-run] [--force]"
  wt_cmd_action
}
