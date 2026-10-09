#!/usr/bin/env bash
# Install t3ctl by symlinking it into a bin directory (default: ~/bin).
# Idempotent: re-running is safe. `git pull` updates the installed command.
#   ./install.sh [BIN_DIR]
set -euo pipefail

src_dir=$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)
target="$src_dir/bin/t3ctl"
bin_dir=${1:-${T3CTL_BIN_DIR:-$HOME/bin}}
link="$bin_dir/t3ctl"

chmod +x "$target"
mkdir -p -- "$bin_dir"

if [[ -L $link ]]; then
  if [[ $(readlink -- "$link") == "$target" ]]; then
    echo "Already installed: $link -> $target"
  else
    ln -sfn -- "$target" "$link"
    echo "Updated: $link -> $target"
  fi
elif [[ -e $link ]]; then
  echo "Refusing to overwrite non-symlink $link; remove it first." >&2
  exit 1
else
  ln -s -- "$target" "$link"
  echo "Installed: $link -> $target"
fi

case ":$PATH:" in
  *":$bin_dir:"*) ;;
  *) echo "Note: $bin_dir is not in PATH. Add to your shell profile:  export PATH=\"$bin_dir:\$PATH\"" ;;
esac
