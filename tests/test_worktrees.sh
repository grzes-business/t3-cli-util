#!/usr/bin/env bash
# Worktree discovery, IDs, safety checks, cleaning and removal (sandboxed).
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

make_project app
write_config
W="$T/worktrees/app"

t3() { "$T3CTL" "$@" 2>&1; }

test_deterministic_id() {
  make_worktree app wt-id
  local id1 id2
  id1=$(t3 worktrees --no-size | awk '$3 == "wt-id" {print $1}')
  id2=$(t3 worktrees --no-size --sort project | awk '$3 == "wt-id" {print $1}')
  assert_eq "$id1" "$(wt_id_of "$W/wt-id")" "ID derived from canonical path"
  assert_eq "$id2" "$id1" "ID stable across sorts"
  [[ $id1 =~ ^[0-9a-f]{6}$ ]] || fail "ID format: $id1"
}

test_unknown_id() {
  local out rc=0
  out=$(t3 worktree abcdef info) || rc=$?
  assert_eq "$rc" 4 "exit code"
  assert_contains "$out" "no worktree with ID 'abcdef'"
  out=$(t3 worktree '../etc' info) || true
  assert_contains "$out" "invalid worktree ID"
}

test_list_columns_and_unknowns() {
  make_worktree app wt-list
  echo change >>"$W/wt-list/src/index.js"
  touch "$W/wt-list/new.txt"
  local out
  out=$(t3 worktrees)
  assert_contains "$out" "ID      PROJECT"
  assert_contains "$(grep ' wt-list ' <<<"$out")" "1M1U"
  assert_contains "$(grep ' wt-list ' <<<"$out")" " no "
  assert_contains "$out" "worktree(s)"
}

test_clean_worktree_is_removable() {
  make_worktree app wt-clean
  local id out
  id=$(wt_id_of "$W/wt-clean")
  out=$(t3 worktree "$id" info)
  assert_contains "$out" "Removal: SAFE"
  out=$(t3 --yes worktree "$id" remove)
  assert_contains "$out" "Removed worktree $id"
  assert_missing "$W/wt-clean"
  git -C "$T/repos/app" rev-parse -q --verify refs/heads/wt-clean >/dev/null || fail "branch must be kept"
  [[ -z $(git -C "$T/repos/app" worktree list | grep wt-clean) ]] || fail "worktree still registered"
}

test_id_prefix() {
  make_worktree app wt-prefix
  local id out
  id=$(wt_id_of "$W/wt-prefix")
  out=$(t3 worktree "${id:0:5}" info)
  assert_contains "$out" "Worktree $id"
}

test_refuse_modified() {
  make_worktree app wt-mod
  echo dirty >>"$W/wt-mod/src/index.js"
  local id out rc=0
  id=$(wt_id_of "$W/wt-mod")
  out=$(t3 --yes worktree "$id" remove) || rc=$?
  assert_eq "$rc" 3 "exit code"
  assert_contains "$out" "REFUSING TO REMOVE $id"
  assert_contains "$out" "modified files: 1"
  assert_contains "$out" "t3ctl worktree $id info"
  assert_exists "$W/wt-mod/src/index.js"
}

test_refuse_untracked() {
  make_worktree app wt-untr
  echo notes >"$W/wt-untr/notes.md"
  local id out rc=0
  id=$(wt_id_of "$W/wt-untr")
  out=$(t3 --yes worktree "$id" remove) || rc=$?
  assert_eq "$rc" 3 "exit code"
  assert_contains "$out" "untracked files: 1"
  assert_exists "$W/wt-untr/notes.md"
}

test_refuse_ahead() {
  make_worktree app wt-ahead
  (cd "$W/wt-ahead" && echo x >>src/index.js && git commit -qam ahead)
  local id out rc=0
  id=$(wt_id_of "$W/wt-ahead")
  out=$(t3 --yes worktree "$id" remove) || rc=$?
  assert_eq "$rc" 3 "exit code"
  assert_contains "$out" "branch ahead of origin/wt-ahead: 1"
  assert_exists "$W/wt-ahead"
}

test_behind_is_removable() {
  make_worktree app wt-behind
  # Advance the remote branch from another clone.
  git clone -q "$T/repos/app.git" "$T/other" 2>/dev/null
  (cd "$T/other" && git checkout -q wt-behind && echo y >>src/index.js && git commit -qam remote &&
    git push -q origin wt-behind 2>/dev/null)
  git -C "$W/wt-behind" fetch -q
  local id out
  id=$(wt_id_of "$W/wt-behind")
  out=$(t3 worktree "$id" info)
  assert_contains "$out" "ahead 0, behind 1"
  assert_contains "$out" "Removal: SAFE"
  out=$(t3 --yes worktree "$id" remove)
  assert_missing "$W/wt-behind"
}

test_refuse_no_upstream_unpublished() {
  mkdir -p "$W"
  git -C "$T/repos/app" worktree add -q -b local-only "$W/wt-local" 2>/dev/null
  (cd "$W/wt-local" && echo z >>src/index.js && git commit -qam local)
  local id out rc=0
  id=$(wt_id_of "$W/wt-local")
  out=$(t3 worktrees --no-size)
  assert_contains "$(grep ' wt-local ' <<<"$out")" "local"
  out=$(t3 --yes worktree "$id" remove) || rc=$?
  assert_eq "$rc" 3 "exit code"
  assert_contains "$out" "no upstream, and HEAD is not on any remote branch"
  assert_exists "$W/wt-local"
}

test_no_upstream_but_published_is_removable() {
  mkdir -p "$W"
  # New branch at a commit that exists on origin/main; no upstream configured.
  git -C "$T/repos/app" worktree add -q -b no-up "$W/wt-noup" origin/main 2>/dev/null
  git -C "$W/wt-noup" branch -q --unset-upstream 2>/dev/null || true
  local id out
  id=$(wt_id_of "$W/wt-noup")
  out=$(t3 worktree "$id" info)
  assert_contains "$out" "upstream       none"
  assert_contains "$out" "HEAD is contained in a remote branch"
  assert_contains "$out" "Removal: SAFE"
}

test_refuse_main_checkout() {
  mkdir -p "$T/worktrees/mainproj"
  git clone -q "$T/repos/app.git" "$T/worktrees/mainproj/checkout" 2>/dev/null
  local id out rc=0
  id=$(wt_id_of "$T/worktrees/mainproj/checkout")
  out=$(t3 --yes worktree "$id" remove) || rc=$?
  assert_eq "$rc" 3 "exit code"
  assert_contains "$out" "main repository checkout"
  assert_exists "$T/worktrees/mainproj/checkout/.git"
  rm -rf "$T/worktrees/mainproj"
}

test_stale_metadata_refused() {
  make_worktree app wt-stale
  local id out rc=0
  id=$(wt_id_of "$W/wt-stale")
  # Simulate stale/broken metadata: the admin dir in the main repo is gone.
  rm -rf "$T/repos/app/.git/worktrees/wt-stale"
  out=$(t3 worktree "$id" info)
  assert_contains "$out" "git state      broken"
  out=$(t3 --yes worktree "$id" remove) || rc=$?
  assert_eq "$rc" 3 "exit code"
  assert_contains "$out" "git state: broken"
  assert_exists "$W/wt-stale"
}

test_escaping_symlink_not_discovered() {
  mkdir -p "$T/outside"
  git -C "$T/repos/app" worktree add -q -b outside "$T/outside/wt-out" 2>/dev/null
  ln -s "$T/outside/wt-out" "$W/wt-link"
  ln -s "$T/outside" "$T/worktrees/linkproj"
  local out rc=0
  out=$(t3 worktrees --no-size)
  assert_not_contains "$out" "wt-link"
  assert_not_contains "$out" "wt-out"
  out=$(t3 worktree "$(wt_id_of "$T/outside/wt-out")" remove) || rc=$?
  assert_eq "$rc" 4 "outside worktree is not addressable"
  assert_exists "$T/outside/wt-out"
  rm -f "$W/wt-link" "$T/worktrees/linkproj"
}

test_clean_artifacts_preserves_source() {
  make_worktree app wt-art
  local wt="$W/wt-art" id out
  id=$(wt_id_of "$wt")
  mkdir -p "$wt/node_modules/pkg" "$wt/apps/web/.next/cache" "$wt/apps/web/node_modules/x" "$wt/dist"
  head -c 300000 /dev/zero >"$wt/node_modules/pkg/big.bin"
  head -c 100000 /dev/zero >"$wt/apps/web/.next/cache/c.bin"
  echo 1 >"$wt/apps/web/node_modules/x/i.js"
  echo 1 >"$wt/dist/out.js"
  # Dirty source must survive.
  echo 'dirty edit' >>"$wt/src/index.js"
  echo 'untracked' >"$wt/src/new.js"
  # Tracked 'build' dir must be kept; un-ignored 'coverage' must be kept.
  mkdir -p "$wt/coverage" && echo c >"$wt/coverage/lcov.info"
  # Symlinked artifact pointing outside must not be followed.
  mkdir -p "$T/precious" && echo keep >"$T/precious/file"
  ln -s "$T/precious" "$wt/apps/.turbo"

  out=$(t3 worktree "$id" info)
  assert_contains "$out" "reclaimable:"

  out=$(t3 --yes worktree "$id" clean)
  assert_contains "$out" "Estimated reclaim:"
  assert_contains "$out" "Before:"
  assert_contains "$out" "Freed:"
  assert_contains "$out" "build  (kept: contains tracked files)"
  assert_contains "$out" "coverage  (kept: not ignored by git)"
  assert_missing "$wt/node_modules"
  assert_missing "$wt/apps/web/.next"
  assert_missing "$wt/apps/web/node_modules"
  assert_missing "$wt/dist"
  assert_exists "$wt/build/make.sh"
  assert_exists "$wt/coverage/lcov.info"
  assert_exists "$T/precious/file"
  assert_exists "$wt/apps/.turbo"
  assert_contains "$(cat "$wt/src/index.js")" "dirty edit"
  assert_exists "$wt/src/new.js"
  assert_eq "$(git -C "$wt" status --porcelain | sort | tr '\n' ' ')" " M src/index.js ?? apps/ ?? coverage/ ?? src/new.js " "git status unchanged"

  out=$(t3 --yes worktree "$id" clean)
  assert_contains "$out" "Nothing to clean."
}

test_clean_requires_confirmation() {
  make_worktree app wt-conf
  mkdir -p "$W/wt-conf/node_modules" && echo 1 >"$W/wt-conf/node_modules/a"
  local out rc=0
  out=$(t3 worktree "$(wt_id_of "$W/wt-conf")" clean </dev/null) || rc=$?
  assert_eq "$rc" 1 "exit code"
  assert_contains "$out" "Aborted."
  assert_exists "$W/wt-conf/node_modules/a"
}

test_refuse_while_process_inside() {
  make_worktree app wt-busy
  local id out rc=0 pid
  id=$(wt_id_of "$W/wt-busy")
  (cd "$W/wt-busy" && exec sleep 30) &
  pid=$!
  sleep 0.3
  out=$(t3 --yes worktree "$id" remove) || rc=$?
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  assert_eq "$rc" 3 "exit code"
  assert_contains "$out" "processes running inside"
  assert_exists "$W/wt-busy"
}

test_older_than_filter() {
  make_worktree app wt-old
  find "$W/wt-old" -exec touch -h -d '20 days ago' {} +
  touch -d '20 days ago' "$T/repos/app/.git/worktrees/wt-old/logs/HEAD"
  local out
  out=$(t3 worktrees --no-size --older-than 2w)
  assert_contains "$out" "wt-old"
  assert_not_contains "$out" "wt-prefix"
  out=$(t3 worktrees --older-than 7x)
  assert_contains "$out" "invalid duration"
}

test_no_files_owned_by_others() {
  local bad
  bad=$(find "$T/worktrees" "$T/repos" ! -user "$(id -un)" 2>/dev/null | head -n1)
  assert_eq "$bad" "" "files not owned by agent user"
}

run_tests
finish
