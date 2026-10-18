#!/usr/bin/env bash
# Bulk CLI flows use real, disposable Git worktrees.
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

fixture=0
setup_bulk() {
  fixture=$((fixture + 1))
  local project="bulk$fixture"
  make_project "$project"
  write_config "WORKTREE_ROOT=$T/selection$fixture"
  mkdir -p "$T/selection$fixture/app"
  local name
  for name in old recent local; do
    git -C "$T/repos/$project" worktree add -q -b "$name" "$T/selection$fixture/app/$name" 2>/dev/null
    git -C "$T/selection$fixture/app/$name" push -qu origin "$name"
    mkdir -p "$T/selection$fixture/app/$name/node_modules"
    echo artifact >"$T/selection$fixture/app/$name/node_modules/data"
  done
  B="$T/selection$fixture/app"
  (cd "$B/local" && echo local >>src/index.js && git commit -qam unpublished)
  find "$B/old" "$B/local" -exec touch -h -d '2020-01-01' {} +
  touch -d '2020-01-01' "$T/repos/$project/.git/worktrees/old/logs/HEAD" "$T/repos/$project/.git/worktrees/local/logs/HEAD"
  OLD=$(wt_id_of "$B/old") RECENT=$(wt_id_of "$B/recent") LOCAL=$(wt_id_of "$B/local")
}

t3() { "$T3CTL" "$@" 2>&1; }

test_multiple_ids_info_and_deduplication() {
  setup_bulk
  local out
  out=$(t3 worktree "$OLD,$RECENT" "${OLD:0:5}" info)
  assert_contains "$out" "Worktree $OLD"
  assert_contains "$out" "Worktree $RECENT"
  assert_eq "$(grep -c "Worktree $OLD" <<<"$out")" 1 "deduplicate prefixes"
}

test_multiple_clean_only_selected() {
  setup_bulk
  t3 --yes worktree "$OLD" "$RECENT" clean >/dev/null
  assert_missing "$B/old/node_modules"
  assert_missing "$B/recent/node_modules"
  assert_exists "$B/local/node_modules/data"
  assert_exists "$B/old/src/index.js"
}

test_invalid_id_prevents_partial_clean() {
  setup_bulk
  local out rc=0
  out=$(t3 --yes worktree "$OLD" ffffffffff clean) || rc=$?
  assert_eq "$rc" 4
  assert_exists "$B/old/node_modules/data"
}

test_all_clean_and_dry_run() {
  setup_bulk
  local out
  out=$(t3 worktrees clean --all --dry-run)
  assert_contains "$out" "$OLD"
  assert_contains "$out" "node_modules"
  assert_exists "$B/old/node_modules/data"
  t3 --yes worktrees clean --all >/dev/null
  assert_missing "$B/old/node_modules"
  assert_missing "$B/recent/node_modules"
  assert_missing "$B/local/node_modules"
}

test_filters_intersect_and_listing_matches() {
  setup_bulk
  local out
  out=$(t3 worktrees --no-size --before 2021-01-01 --pushed)
  assert_contains "$out" "$OLD"
  assert_not_contains "$out" "$RECENT"
  assert_not_contains "$out" "$LOCAL"
  t3 --yes worktrees clean --older-than 2w --pushed >/dev/null
  assert_missing "$B/old/node_modules"
  assert_exists "$B/recent/node_modules/data"
  assert_exists "$B/local/node_modules/data"
}

test_remove_continues_after_refusal() {
  setup_bulk
  rm -rf "$B/old/node_modules"
  local out rc=0
  out=$(t3 --yes worktree "$LOCAL" "$OLD" remove) || rc=$?
  assert_eq "$rc" 3
  assert_contains "$out" "REFUSING TO REMOVE $LOCAL"
  assert_contains "$out" "Removed worktree $OLD"
  assert_exists "$B/local/src/index.js"
  assert_missing "$B/old"
}

test_bulk_remove_safe_and_before() {
  setup_bulk
  local out
  # Remove ignored artifacts first: git worktree remove refuses them too.
  t3 --yes worktrees clean --all >/dev/null
  out=$(t3 --yes worktrees remove --before 2021-01-01 --safe)
  assert_contains "$out" "Removed worktree $OLD"
  assert_missing "$B/old"
  assert_exists "$B/local"
  assert_exists "$B/recent"
}

test_bulk_requires_explicit_selection_and_confirmation() {
  setup_bulk
  local out rc=0
  out=$(t3 --yes worktrees clean) || rc=$?
  assert_eq "$rc" 1
  assert_exists "$B/old/node_modules/data"
  rc=0
  out=$(t3 worktrees clean --all </dev/null) || rc=$?
  assert_eq "$rc" 1
  assert_exists "$B/old/node_modules/data"
  rc=0
  out=$(t3 --yes worktrees clean --before not-a-date) || rc=$?
  assert_eq "$rc" 1
  assert_exists "$B/old/node_modules/data"
}

test_unknown_age_excluded_and_no_matches_ok() {
  setup_bulk
  mkdir -p "$T/selection$fixture/app/broken/.git"
  local out
  out=$(t3 worktrees info --before 2021-01-01)
  assert_not_contains "$out" "app/broken"
  out=$(t3 worktrees clean --before 1990-01-01)
  assert_contains "$out" "No worktrees match"
  assert_exists "$B/old/node_modules/data"
}

# Replace only terminal input; exercise the real selection and cleanup code.
run_with_confirmation() (
  source "$T3CTL_REPO/lib/common.sh"
  source "$T3CTL_REPO/lib/worktrees.sh"
  source "$T3CTL_REPO/lib/disk.sh"
  load_config
  confirm() {
    [[ ${T3CTL_ASSUME_YES:-0} == 1 ]] && return 0
    printf '%s\n' "$*" >>"$T/prompts"
    [[ $answer == yes ]]
  }
  case $1 in
    worktrees) shift; cmd_worktrees "$@" ;;
    worktree) shift; cmd_worktree "$@" ;;
  esac
)

test_clean_batch_confirms_once() {
  setup_bulk
  local answer=yes out
  : >"$T/prompts"
  out=$(run_with_confirmation worktrees clean --all)
  assert_eq "$(wc -l <"$T/prompts")" 1 "one confirmation for the batch"
  assert_missing "$B/old/node_modules"
  assert_missing "$B/recent/node_modules"
  assert_missing "$B/local/node_modules"
}

test_clean_multiple_ids_confirms_once() {
  setup_bulk
  local answer=yes out
  : >"$T/prompts"
  out=$(run_with_confirmation worktree "$OLD" "$RECENT" clean)
  assert_eq "$(wc -l <"$T/prompts")" 1 "one confirmation for explicit IDs"
  assert_missing "$B/old/node_modules"
  assert_missing "$B/recent/node_modules"
  assert_exists "$B/local/node_modules/data"
}

test_declining_batch_clean_preserves_every_target() {
  setup_bulk
  local answer=no out rc=0
  : >"$T/prompts"
  out=$(run_with_confirmation worktrees clean --all) || rc=$?
  assert_eq "$rc" 1
  assert_eq "$(wc -l <"$T/prompts")" 1
  assert_contains "$out" "Aborted."
  assert_exists "$B/old/node_modules/data"
  assert_exists "$B/recent/node_modules/data"
  assert_exists "$B/local/node_modules/data"
}

run_tests
finish
