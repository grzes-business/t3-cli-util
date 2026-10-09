#!/usr/bin/env bash
# Remove the t3ctl symlink created by install.sh. Leaves config untouched.
#   ./uninstall.sh [BIN_DIR]
set -euo pipefail

src_dir=$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)
target="$src_dir/bin/t3ctl"
bin_dir=${1:-${T3CTL_BIN_DIR:-$HOME/bin}}
link="$bin_dir/t3ctl"

if [[ -L $link && $(readlink -- "$link") == "$target" ]]; then
  rm -- "$link"
  echo "Removed $link"
elif [[ -e $link || -L $link ]]; then
  echo "$link does not point to this checkout; leaving it alone." >&2
  exit 1
else
  echo "Not installed: $link"
fi
