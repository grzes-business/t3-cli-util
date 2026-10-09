# shellcheck shell=bash
# Minimal test helpers. Each test file is run in its own bash process.
set -uo pipefail

T3CTL_REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
T3CTL="$T3CTL_REPO/bin/t3ctl"
TESTS_FAILED=0
TESTS_RUN=0
CURRENT_TEST=''

T=$(mktemp -d "${TMPDIR:-/tmp}/t3ctl-test.XXXXXX")
trap 'rm -rf -- "$T"' EXIT

export NO_COLOR=1 GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com \
  GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
export HOME="$T/home"
mkdir -p "$HOME"
git config --global init.defaultBranch main
git config --global advice.detachedHead false

fail() {
  printf '    FAIL: %s\n' "$*"
  TESTS_FAILED=$((TESTS_FAILED + 1))
}

assert_eq() {
  [[ $1 == "$2" ]] || fail "${3:-assert_eq}: expected [$2], got [$1]"
}

assert_contains() {
  [[ $1 == *"$2"* ]] || fail "${3:-assert_contains}: [$2] not found in output:"$'\n'"$1"
}

assert_not_contains() {
  [[ $1 != *"$2"* ]] || fail "${3:-assert_not_contains}: [$2] unexpectedly found in output:"$'\n'"$1"
}

assert_exists() { [[ -e $1 || -L $1 ]] || fail "expected to exist: $1"; }
assert_missing() { [[ ! -e $1 && ! -L $1 ]] || fail "expected to be gone: $1"; }

# Run each function named test_* in this file.
run_tests() {
  local t
  for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
    CURRENT_TEST=$t
    TESTS_RUN=$((TESTS_RUN + 1))
    local before=$TESTS_FAILED
    "$t"
    if ((TESTS_FAILED > before)); then
      printf '  not ok  %s\n' "$t"
    else
      printf '  ok      %s\n' "$t"
    fi
  done
  ((TESTS_FAILED == 0))
}

# Write a config pointing t3ctl at the sandbox. Extra lines may be appended.
write_config() {
  T3CTL_CONFIG="$T/t3ctl.conf"
  export T3CTL_CONFIG
  {
    printf 'AGENT_USER=%q\n' "$(id -un)"
    printf 'WORKTREE_ROOT=%q\n' "$T/worktrees"
    printf 'T3_LOG_FILE=%q\n' "$T/service.log"
    printf '%s\n' "$@"
  } >"$T3CTL_CONFIG"
  chmod 600 "$T3CTL_CONFIG"
}

# Origin (bare) + main clone of a project with a .gitignore and some files.
make_project() {
  local name=$1
  mkdir -p "$T/repos"
  git init -q --bare "$T/repos/$name.git"
  git clone -q "$T/repos/$name.git" "$T/repos/$name" 2>/dev/null
  (
    cd "$T/repos/$name" || exit 1
    printf 'node_modules/\n.next/\ndist/\n' >.gitignore
    mkdir -p src build
    echo 'console.log(1)' >src/index.js
    echo 'tracked build script' >build/make.sh
    git add -A && git commit -qm init && git push -q origin HEAD 2>/dev/null
  )
}

# Linked worktree under $T/worktrees/<project>/<name> on a new branch pushed
# with upstream tracking (so it starts clean and in sync).
make_worktree() {
  local project=$1 name=$2 branch=${3:-$2}
  mkdir -p "$T/worktrees/$project"
  git -C "$T/repos/$project" worktree add -q -b "$branch" "$T/worktrees/$project/$name" 2>/dev/null
  git -C "$T/worktrees/$project/$name" push -q -u origin "$branch" 2>/dev/null
}

wt_id_of() { printf '%s' "$(realpath -e -- "$1")" | sha1sum | cut -c1-6; }

finish() {
  printf '  %d test(s), %d failure(s)\n' "$TESTS_RUN" "$TESTS_FAILED"
  ((TESTS_FAILED == 0))
}
