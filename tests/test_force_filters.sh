#!/usr/bin/env bash
# --force removal, project/name/branch/... filters and the table output.
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

FX=0
# Fresh root with two projects:
#   alpha/clean1  alpha/ahead1 (1 unpushed commit)  alpha/dirty1 (1M 1U)
#   beta/clean2   beta/big (2 MB ignored node_modules)
setup_fx() {
  FX=$((FX + 1))
  R="$T/fx$FX"
  write_config "WORKTREE_ROOT=$R"
  make_project "ra$FX"
  make_project "rb$FX"
  fx_wt alpha "ra$FX" clean1
  fx_wt alpha "ra$FX" ahead1
  fx_wt alpha "ra$FX" dirty1
  fx_wt beta "rb$FX" clean2
  fx_wt beta "rb$FX" big
  (cd "$R/alpha/ahead1" && echo a >>src/index.js && git commit -qam ahead)
  echo edit >>"$R/alpha/dirty1/src/index.js"
  echo new >"$R/alpha/dirty1/notes.txt"
  mkdir -p "$R/beta/big/node_modules"
  head -c 2000000 /dev/zero >"$R/beta/big/node_modules/blob"
  CLEAN1=$(wt_id_of "$R/alpha/clean1") AHEAD1=$(wt_id_of "$R/alpha/ahead1")
  DIRTY1=$(wt_id_of "$R/alpha/dirty1") CLEAN2=$(wt_id_of "$R/beta/clean2") BIG=$(wt_id_of "$R/beta/big")
}

# fx_wt dir-project repo name
fx_wt() {
  mkdir -p "$R/$1"
  git -C "$T/repos/$2" worktree add -q -b "$3" "$R/$1/$3" 2>/dev/null
  git -C "$R/$1/$3" push -qu origin "$3" 2>/dev/null
}

branch_exists() { git -C "$T/repos/$1" rev-parse -q --verify "refs/heads/$2" >/dev/null; }

t3() { "$T3CTL" "$@" 2>&1; }

# ------------------------------------------------------------------ force

test_refusal_points_to_force() {
  setup_fx
  local out rc=0
  out=$(t3 --yes worktree "$AHEAD1" remove) || rc=$?
  assert_eq "$rc" 3
  assert_contains "$out" "REFUSING TO REMOVE $AHEAD1"
  assert_contains "$out" "branch ahead of origin/ahead1: 1"
  assert_contains "$out" "t3ctl worktree $AHEAD1 remove --force"
  assert_exists "$R/alpha/ahead1"
}

test_force_removes_worktree_ahead_of_origin() {
  setup_fx
  local out
  out=$(t3 --yes worktree "$AHEAD1" remove --force)
  assert_contains "$out" "removed"
  assert_missing "$R/alpha/ahead1"
  branch_exists ra$FX ahead1 || fail "branch must be kept"
  assert_exists "$R/alpha/clean1"
}

test_force_removes_dirty_worktree_and_keeps_branch() {
  setup_fx
  local out
  out=$(t3 --yes worktree "$DIRTY1" remove --force)
  assert_contains "$out" "discards 1 modified, 1 untracked"
  assert_missing "$R/alpha/dirty1"
  branch_exists ra$FX dirty1 || fail "branch must be kept"
}

test_force_flag_position_and_dry_run() {
  setup_fx
  local out
  out=$(t3 worktrees remove --force --dry-run --project alpha)
  assert_contains "$out" "Dry run: nothing was changed."
  assert_contains "$out" "FORCE"
  assert_exists "$R/alpha/ahead1"
  assert_exists "$R/alpha/dirty1"
  assert_exists "$R/alpha/clean1"
}

test_force_without_yes_in_non_tty_aborts() {
  setup_fx
  local out rc=0
  out=$(t3 worktree "$DIRTY1" remove --force </dev/null) || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "Aborted."
  assert_exists "$R/alpha/dirty1/notes.txt"
}

test_force_bulk_by_project() {
  setup_fx
  local out rc=0
  out=$(t3 --yes worktrees remove --project alpha --force) || rc=$?
  assert_eq "$rc" 0
  assert_contains "$out" "Removed 3, refused 0, failed 0."
  assert_missing "$R/alpha/clean1"
  assert_missing "$R/alpha/ahead1"
  assert_missing "$R/alpha/dirty1"
  assert_exists "$R/beta/clean2"
  assert_exists "$R/beta/big"
}

test_force_cannot_override_main_checkout() {
  setup_fx
  mkdir -p "$R/gamma"
  git clone -q "$T/repos/ra$FX.git" "$R/gamma/checkout" 2>/dev/null
  local id out rc=0
  id=$(wt_id_of "$R/gamma/checkout")
  out=$(t3 --yes worktree "$id" remove --force) || rc=$?
  assert_eq "$rc" 3
  assert_contains "$out" "main repository checkout"
  assert_contains "$out" "cannot be overridden"
  assert_exists "$R/gamma/checkout/.git"
}

test_force_cannot_override_locked_worktree() {
  setup_fx
  git -C "$T/repos/ra$FX" worktree lock "$R/alpha/dirty1"
  local out rc=0
  out=$(t3 --yes worktree "$DIRTY1" remove --force) || rc=$?
  assert_eq "$rc" 3
  assert_contains "$out" "git state: locked"
  assert_exists "$R/alpha/dirty1/notes.txt"
  git -C "$T/repos/ra$FX" worktree unlock "$R/alpha/dirty1"
}

test_force_cannot_override_running_process() {
  setup_fx
  local out rc=0 pid
  (cd "$R/alpha/dirty1" && exec sleep 30) &
  pid=$!
  sleep 0.3
  out=$(t3 --yes worktree "$DIRTY1" remove --force) || rc=$?
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  assert_eq "$rc" 3
  assert_contains "$out" "processes running inside"
  assert_exists "$R/alpha/dirty1/notes.txt"
}

test_force_only_applies_to_remove() {
  setup_fx
  local out rc=0
  out=$(t3 --yes worktree "$CLEAN1" clean --force) || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "--force only applies to remove"
  rc=0
  out=$(t3 worktrees --force) || rc=$?
  assert_eq "$rc" 1
}

test_force_detached_head_warns_about_orphaned_commits() {
  setup_fx
  git -C "$T/repos/ra$FX" worktree add -q --detach "$R/alpha/detached" 2>/dev/null
  (cd "$R/alpha/detached" && echo d >>src/index.js && git commit -qam orphan)
  local id out
  id=$(wt_id_of "$R/alpha/detached")
  out=$(t3 worktree "$id" remove --force --dry-run)
  assert_contains "$out" "orphans unpublished commits"
  out=$(t3 worktree "$id" info)
  assert_contains "$out" "detached HEAD"
  assert_contains "$out" "NEEDS --force"
}

# Replace only the terminal prompts; exercise the real selection/removal code.
run_with_prompts() (
  source "$T3CTL_REPO/lib/common.sh"
  source "$T3CTL_REPO/lib/ui.sh"
  source "$T3CTL_REPO/lib/worktrees.sh"
  source "$T3CTL_REPO/lib/disk.sh"
  load_config
  confirm() {
    [[ ${T3CTL_ASSUME_YES:-0} == 1 ]] && return 0
    printf 'confirm: %s\n' "$*" >>"$T/prompts"
    [[ $answer == yes ]]
  }
  confirm_phrase() {
    [[ ${T3CTL_ASSUME_YES:-0} == 1 ]] && return 0
    printf 'phrase: %s\n' "$*" >>"$T/prompts"
    [[ $answer == discard ]]
  }
  cmd_worktrees "$@"
)

test_force_losing_work_needs_the_discard_phrase_once() {
  setup_fx
  local answer=yes out rc=0
  : >"$T/prompts"
  out=$(run_with_prompts remove --project alpha --force) || rc=$?
  assert_eq "$rc" 1 "'yes' is not the phrase"
  assert_contains "$out" "Aborted."
  assert_eq "$(wc -l <"$T/prompts")" 1 "one prompt for the whole batch"
  assert_contains "$(cat "$T/prompts")" "phrase:"
  assert_exists "$R/alpha/dirty1/notes.txt"
  answer=discard rc=0
  : >"$T/prompts"
  out=$(run_with_prompts remove --project alpha --force) || rc=$?
  assert_eq "$rc" 0
  assert_eq "$(wc -l <"$T/prompts")" 1
  assert_missing "$R/alpha/dirty1"
  assert_missing "$R/alpha/ahead1"
}

test_force_without_uncommitted_loss_uses_plain_confirmation() {
  setup_fx
  local answer=yes out
  : >"$T/prompts"
  out=$(run_with_prompts remove "$AHEAD1" --force)
  assert_contains "$(cat "$T/prompts")" "confirm:"
  assert_not_contains "$(cat "$T/prompts")" "phrase:"
  assert_missing "$R/alpha/ahead1"
}

test_remove_batch_confirms_once() {
  setup_fx
  local answer=yes out
  : >"$T/prompts"
  out=$(run_with_prompts remove "$CLEAN1" "$CLEAN2")
  assert_eq "$(wc -l <"$T/prompts")" 1
  assert_missing "$R/alpha/clean1"
  assert_missing "$R/beta/clean2"
}

# ---------------------------------------------------------------- filters

test_project_filter_lists_only_that_project() {
  setup_fx
  local out
  out=$(t3 worktrees --no-size --project alpha)
  assert_contains "$out" "$CLEAN1"
  assert_contains "$out" "$AHEAD1"
  assert_not_contains "$out" "$CLEAN2"
  assert_contains "$out" "Filters: project=alpha"
  assert_contains "$out" "3 of 5 worktree(s)"
}

test_project_filter_globs_case_and_lists() {
  setup_fx
  local out
  out=$(t3 worktrees --no-size --project 'AL*')
  assert_contains "$out" "$CLEAN1"
  assert_not_contains "$out" "$CLEAN2"
  out=$(t3 worktrees --no-size --project=alpha,beta)
  assert_contains "$out" "$CLEAN1"
  assert_contains "$out" "$CLEAN2"
  out=$(t3 worktrees --no-size --project alpha --project beta)
  assert_contains "$out" "$CLEAN2"
}

test_unknown_project_names_the_known_ones() {
  setup_fx
  local out rc=0
  out=$(t3 worktrees --project nope) || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "no project matches 'nope'"
  assert_contains "$out" "projects: alpha, beta"
  out=$(t3 --yes worktrees remove --project nope --force) || true
  assert_contains "$out" "no project matches"
  assert_exists "$R/alpha/dirty1"
}

test_remove_by_project_refuses_risky_ones_without_force() {
  setup_fx
  local out rc=0
  out=$(t3 --yes worktrees remove --project alpha) || rc=$?
  assert_eq "$rc" 3
  assert_contains "$out" "Removed 1, refused 2"
  assert_missing "$R/alpha/clean1"
  assert_exists "$R/alpha/ahead1"
  assert_exists "$R/alpha/dirty1"
  assert_exists "$R/beta/clean2"
}

test_name_and_branch_filters() {
  setup_fx
  local out
  out=$(t3 worktrees --no-size --name 'clean*')
  assert_contains "$out" "$CLEAN1"
  assert_contains "$out" "$CLEAN2"
  assert_not_contains "$out" "$BIG"
  out=$(t3 worktrees --no-size --branch 'ahead*')
  assert_contains "$out" "$AHEAD1"
  assert_not_contains "$out" "$CLEAN1"
  out=$(t3 worktrees --no-size --project alpha --name 'clean*')
  assert_contains "$out" "$CLEAN1"
  assert_not_contains "$out" "$CLEAN2"
}

test_dirty_and_clean_filters() {
  setup_fx
  local out
  out=$(t3 worktrees --no-size --dirty)
  assert_contains "$out" "$DIRTY1"
  assert_not_contains "$out" "$CLEAN1"
  out=$(t3 worktrees --no-size --clean --project alpha)
  assert_contains "$out" "$CLEAN1"
  assert_contains "$out" "$AHEAD1"
  assert_not_contains "$out" "$DIRTY1"
  out=$(t3 worktrees --dirty --clean) || true
  assert_contains "$out" "cannot be combined"
}

test_larger_than_filter() {
  setup_fx
  local out
  out=$(t3 worktrees --larger-than 1M)
  assert_contains "$out" "$BIG"
  assert_not_contains "$out" "$CLEAN1"
  out=$(t3 worktrees --larger-than 5x) || true
  assert_contains "$out" "invalid size"
  out=$(t3 worktrees --larger-than 1M --no-size) || true
  assert_contains "$out" "needs sizes"
}

test_status_filter_and_safe_alias() {
  setup_fx
  local out
  out=$(t3 worktrees --no-size --status risk)
  assert_contains "$out" "$AHEAD1"
  assert_contains "$out" "$DIRTY1"
  assert_not_contains "$out" "$CLEAN1"
  out=$(t3 worktrees --no-size --safe)
  assert_contains "$out" "$CLEAN1"
  assert_not_contains "$out" "$AHEAD1"
  out=$(t3 worktrees --no-size --status safe,risk --project alpha)
  assert_contains "$out" "$DIRTY1"
  assert_contains "$out" "$CLEAN1"
  out=$(t3 worktrees --status bogus) || true
  assert_contains "$out" "invalid status"
}

test_newer_than_filter() {
  setup_fx
  find "$R/beta/clean2" -exec touch -h -d '30 days ago' {} +
  touch -d '30 days ago' "$T/repos/rb$FX/.git/worktrees/clean2/logs/HEAD"
  local out
  out=$(t3 worktrees --no-size --newer-than 7d)
  assert_contains "$out" "$CLEAN1"
  assert_not_contains "$out" "$CLEAN2"
}

test_ids_and_filters_intersect() {
  setup_fx
  local out
  out=$(t3 worktrees --no-size "$CLEAN1,$CLEAN2" --project beta)
  assert_contains "$out" "$CLEAN2"
  assert_not_contains "$out" "$CLEAN1"
  out=$(t3 --yes worktrees remove "$CLEAN1" "$CLEAN2" --project beta)
  assert_missing "$R/beta/clean2"
  assert_exists "$R/alpha/clean1"
}

test_yes_flag_is_accepted_after_the_command() {
  setup_fx
  local out
  out=$(t3 worktrees remove --project beta --name 'clean*' --yes)
  assert_contains "$out" "Removed 1"
  assert_missing "$R/beta/clean2"
  assert_exists "$R/beta/big"
}

test_actions_need_a_selection() {
  setup_fx
  local out rc=0
  out=$(t3 --yes worktrees remove) || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "select worktrees with"
  assert_exists "$R/alpha/clean1"
  out=$(t3 worktrees remove --bogus) || true
  assert_contains "$out" "unknown option: --bogus"
  out=$(t3 worktrees --project) || true
  assert_contains "$out" "--project needs a value"
}

# ----------------------------------------------------------------- output

test_listing_columns_verdicts_and_project_summary() {
  setup_fx
  local out
  out=$(t3 worktrees)
  assert_contains "$out" "REMOVE"
  assert_contains "$(grep " clean1 " <<<"$out")" "o safe"
  assert_contains "$(grep " ahead1 " <<<"$out")" "! force"
  assert_contains "$(grep " dirty1 " <<<"$out")" "1M1U"
  assert_contains "$(grep " ahead1 " <<<"$out")" "+1"
  assert_contains "$out" "3 safe to remove"
  assert_contains "$out" "2 need --force"
  assert_contains "$out" "PROJECT  COUNT"
  assert_contains "$(grep '^total' <<<"$out")" "5"
}

test_main_checkout_is_blocked_in_listing() {
  setup_fx
  mkdir -p "$R/gamma"
  git clone -q "$T/repos/ra$FX.git" "$R/gamma/checkout" 2>/dev/null
  local out
  out=$(t3 worktrees --no-size --status blocked)
  assert_contains "$out" "x blocked"
  assert_not_contains "$out" "$CLEAN1"
}

test_ascii_and_unicode_output() {
  setup_fx
  local out
  out=$(T3CTL_ASCII=1 LC_ALL=C.UTF-8 t3 worktrees --no-size)
  assert_not_contains "$out" "●"
  out=$(env -u T3CTL_ASCII LC_ALL=C.UTF-8 "$T3CTL" worktrees 2>&1)
  assert_contains "$out" "●"
  assert_contains "$out" "█"
  out=$(env -u T3CTL_ASCII LC_ALL=C "$T3CTL" worktrees --no-size 2>&1)
  assert_not_contains "$out" "●"
}

test_clean_shows_reclaim_by_artifact() {
  setup_fx
  local out
  out=$(t3 worktrees clean --project beta --dry-run)
  assert_contains "$out" "ARTIFACT"
  assert_contains "$out" "node_modules"
  assert_contains "$out" "Reclaimable:"
  assert_exists "$R/beta/big/node_modules/blob"
  out=$(t3 --yes worktrees clean --project beta)
  assert_contains "$out" "cleaned"
  assert_contains "$out" "Freed:"
  assert_missing "$R/beta/big/node_modules"
}

run_tests
finish
