# t3ctl

A small operations CLI for long-running coding-agent hosts. It manages the
agent's systemd **user** service, lists agent Git worktrees, and frees disk
space without losing work.

Defaults target a host where an unprivileged `agent` account runs
[T3 Code](https://github.com/pingdotgg/t3code) as `t3code.service`, with
worktrees under `~agent/.t3/worktrees`. An administrative account (e.g.
`ubuntu`) operates it over SSH. Every T3-specific value is configurable.

```text
t3ctl doctor                      # first thing to run when something is off
t3ctl status | restart | reset | logs
t3ctl update                      # update T3 using your configured updater
t3ctl disk
t3ctl worktrees --sort size
t3ctl worktree <id> info
t3ctl worktree <id> clean         # drop node_modules/.next/... keep code + git
t3ctl worktree <id> remove        # git worktree remove, only if nothing can be lost
```

## Why

**User-systemd across users.** `systemctl --user` talks to the per-user
manager over `$XDG_RUNTIME_DIR/bus`. If you run `sudo -iu agent` from another
account, or use a non-login shell, that environment often doesn't come along,
and the call fails. t3ctl handles this in one place (`run_as_agent` in
`lib/common.sh`):

```bash
sudo -u agent env XDG_RUNTIME_DIR=/run/user/<uid> \
  DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/<uid>/bus systemctl --user ...
```

The UID is always resolved with `id -u agent`; it is never hardcoded.

**Worktree sprawl.** Agents create one worktree per task. Each one gets its
own `node_modules`, `.next` and build output (1.5–2 GB each). That fills a
45–80 GB VM quickly.

## Install

```bash
git clone https://github.com/grzes-business/t3-cli-util ~/src/t3ctl
~/src/t3ctl/install.sh            # symlinks ~/bin/t3ctl -> ~/src/t3ctl/bin/t3ctl
```

`install.sh [BIN_DIR]` is idempotent. A `git pull` updates the installed
command. `uninstall.sh` removes the symlink only.

Requirements: bash ≥ 4.4, git ≥ 2.31, coreutils, findutils, iproute2 (`ss`),
systemd. The operator needs `sudo` rights to run commands as the agent user,
plus root for the linger/user-manager recovery steps. Nothing else is needed.

### Redeploy on a remote server

Once the changes are available in the branch your server uses, SSH in as the
operator account and update the existing checkout:

```bash
ssh ubuntu@YOUR_SERVER
cd ~/src/t3ctl                    # use your actual clone location
git pull --ff-only
./install.sh                     # idempotent; refreshes the ~/bin symlink
~/bin/t3ctl --version
~/bin/t3ctl --help
```

The symlink points into this checkout, so there is no build step and no T3
restart needed to redeploy **t3ctl**. If `git pull` reports local changes or a
diverged branch, resolve those before proceeding; do not discard them blindly.
To locate an existing installation, run `readlink -f "$(command -v t3ctl)"`.

## Configuration

Optional: `~/.config/t3ctl/config` (or set `$T3CTL_CONFIG`). The file is sourced
by bash, so t3ctl refuses to load it unless it is owned by you or root and not
group/world-writable. See [`config/t3ctl.conf.example`](config/t3ctl.conf.example).

| Variable | Default |
|---|---|
| `AGENT_USER` | `agent` |
| `T3_SERVICE` | `t3code.service` |
| `T3_UPDATE_COMMAND` | `()` (must be configured before `update`) |
| `T3_PORT` | `3773` (empty disables the port check) |
| `T3_LOG_FILE` | `<agent home>/.t3/userdata/logs/boot-service.log` |
| `WORKTREE_ROOT` | `<agent home>/.t3/worktrees` |
| `WORKTREE_SCAN_DEPTH` | `4` |
| `SAFE_CLEAN_DIRS` | `(node_modules .next .turbo dist build coverage)` |
| `AGENT_STORAGE_DIRS` | `(.t3/worktrees .cache .bun .local .codex .cursor .npm)` |
| `DISK_WARN_PCT` / `DISK_CRIT_PCT` | `85` / `95` |
| `WORKTREE_WARN_PCT` | `50` (share of used disk) |
| `AGENT_PROCESS_PATTERN` | `^(claude\|codex\|cursor\|cursor-agent\|gemini\|opencode\|aider\|amp)$` |

## Service commands

The dependency chain is checked in this order:

```text
agent account -> linger -> user@<uid>.service -> /run/user/<uid>/bus -> t3code.service -> port 3773
```

* `status`: shows the chain plus `systemctl --user status`. Exit code 3 if
  unhealthy. It only reports and never repairs.
* `start`, `stop`, `restart`: if the bus is missing, they first try a bounded
  recovery (`loginctl enable-linger`, `systemctl start user@<uid>.service`, then
  wait `BUS_WAIT_SECONDS`). After a start they wait for `active` and for the
  port.
* `reset`: ensure linger, user manager and bus → `stop` → `reset-failed` →
  `daemon-reload` → `start` → wait for active and port → print the report.
  It does not kill other processes, delete worktrees, or touch T3 state or
  config.
* `logs [-n N] [-f] [--since T] [--journal|--file]`: shows the systemd journal
  for the unit and the tail of `T3_LOG_FILE`. T3 writes its own output there,
  not to the journal. `-f` follows the file, or the journal if the file doesn't
  exist.

> **Note:** T3 launches agent sessions (`claude`, `codex`, …) as children.
> They live in `t3code.service`'s cgroup, so systemd ends them on
> stop/restart/reset/update. Before these actions, t3ctl lists any such sessions and
> asks for confirmation (pass `--yes` to skip the prompt). Processes of the
> agent user *outside* the service are never touched. t3ctl never uses
> `pkill -u agent` or anything similar.

### Update the T3 service

`t3ctl update` (or `t3ctl service update`) executes `T3_UPDATE_COMMAND` as the
agent account, then restarts `T3_SERVICE` and waits for the service and its
configured port. Configure the updater to match the installation used by the
unit; inspect its launch command by running
`systemctl --user cat t3code.service` as the agent with its user-bus environment.

Add a bash array to the operator's `~/.config/t3ctl/config`, for example:

```bash
T3_UPDATE_COMMAND=(/home/agent/bin/update-t3)
```

This executable script must perform the package update or checkout/build for
your installation and exit nonzero on failure. Use absolute paths for tools
that are absent from the operator's PATH. The updater runs from the agent's
home with no login shell; arguments are passed literally, so put pipes,
redirections, and multiple commands in the script. No installation method is
assumed by default.

```bash
t3ctl update
# For unattended use after checking active sessions:
t3ctl --yes update
```

Before updating, t3ctl warns and asks for confirmation if the restart will end
active agent sessions. If the updater fails, t3ctl returns an error and does
not restart the service. An updater may partially change installed files;
there is no automatic package rollback. If the restart or health check fails,
t3ctl reports recent logs. It does not edit the unit or reload its definition;
unit-file changes should use `t3ctl reset` afterward.

## Worktrees

Discovery walks `WORKTREE_ROOT` (default layout: `<root>/<project>/<name>`).
A directory counts as a worktree only if it contains `.git`. Symlinks are not
followed. Every path is canonicalised and must lie strictly beneath the root.

Each worktree gets a **stable ID**: the first 6 hex characters of
`sha1(canonical path)`. Commands take an ID or any unique prefix of at least 3
characters, never a path.

`t3ctl worktrees [--sort size|age|project|commit] [--older-than 7d|2w|12h|3mo] [--no-size] [-r]`

```text
ID      PROJECT    NAME                        SIZE   AGE COMMIT DIRTY  AHEAD  SAFE  BRANCH
324fdb  olta       t3code-029011b7             2.0G    1d     1d no     0      yes   OLTA-603
63e4c3  olta       t3code-b85788c0             141M    3d     7d no     pushed yes   t3code/review-...
```

* **AGE**: time since the last file change, ignoring `.git` and artifact dirs
  (the reflog counts too). **COMMIT**: age of HEAD.
* **DIRTY**: `no`, or counts such as `3M2U` (modified, untracked).
* **AHEAD**: commits ahead of upstream. `local` means no upstream and HEAD is
  on no remote branch. `pushed` means no upstream, but HEAD is on a remote
  branch.
* **SAFE**: whether `remove` would be allowed.
* Unknown values are shown as `?`, never as 0.
* `--no-size` skips `du`. A cold-cache `du` over dozens of worktrees can take
  a minute or more.

Each worktree's SIZE is measured on its own. Package managers such as bun and
pnpm hard-link files across worktrees, so the summed sizes overstate real
usage. `t3ctl disk` reports the real total (hard links counted once).

`t3ctl worktree <id> info` shows branch, HEAD, upstream ahead/behind, whether
HEAD is published, changes, processes whose cwd is inside the worktree, the
artifact cleanup plan, and the removal verdict with reasons.

### clean

This deletes only directories that meet all of these conditions:

* the name is in `SAFE_CLEAN_DIRS`, and it was found by `find` without
  following symlinks,
* it is a real directory, not a symlink, with no symlinked parents,
* git ignores it (`git check-ignore`),
* it contains no tracked files (`git ls-files`).

Anything else is listed as `kept` with the reason. For example, a tracked
`build/` folder is kept. A dirty worktree can still be cleaned, because source
files and git state are never touched. The output shows before/after size and
the actual change in filesystem free space. Freed space can be smaller than the
size shown when files are hard-linked elsewhere.

### remove

`remove` refuses if any of these hold:

* tracked modifications or untracked files,
* the branch is ahead of its upstream,
* there is no upstream and HEAD is not on any remote branch,
* git state is broken, unregistered, locked, or mid rebase/merge/cherry-pick/bisect,
* it is a main checkout rather than a linked worktree,
* processes are running inside it,
* the path is outside the root.

Example refusal:

```text
REFUSING TO REMOVE a83f21

Safety checks failed:
  modified files: 3
  untracked files: 2
  branch ahead of origin/feat/foo: 1

Inspect using:

  t3ctl worktree a83f21 info
```

Right before acting, all checks run again as the agent user. Removal itself is
`git worktree remove <path>` (no `--force`) followed by `git worktree prune`.
The branch is kept. There is deliberately no force option.

## disk / doctor

`t3ctl disk` shows filesystem size/used/free/inode usage (warning at 85%,
critical at 95%), the agent storage directories with their share of used space,
and the largest worktrees.

`t3ctl doctor` reports the runtime chain and storage health, then suggests the
next command. It only diagnoses and never repairs. Exit codes: `0` all OK,
`1` warnings, `2` failures.

## Safety model

* No state of its own. systemd, git and the filesystem are the only sources
  of truth.
* All git and filesystem work on the agent tree runs as the agent user
  (`sudo -u agent`, `GIT_OPTIONAL_LOCKS=0`). Files under `/home/agent` never
  end up owned by root or ubuntu, and a destructive step can never do more than
  the agent account itself could.
* Agent-side logic is shipped as shell functions (`declare -f`) with arguments
  passed as positional parameters. t3ctl never uses `eval` and never builds
  shell code from user input.
* Only `loginctl enable-linger` and `systemctl start user@<uid>.service` run
  as root, and only during bus recovery.

## Development

```bash
tests/run.sh                 # all tests; or tests/run.sh test_worktrees.sh
shellcheck -x bin/t3ctl lib/*.sh install.sh uninstall.sh tests/*.sh
```

The tests build throwaway repositories under `$TMPDIR`. They put mock
`systemctl`/`loginctl`/`sudo`/`ss`/`journalctl` binaries first on `PATH` and
redirect the runtime/linger/cgroup paths (`T3CTL_RUNTIME_BASE`,
`T3CTL_LINGER_DIR`, `T3CTL_CGROUP_ROOT`). They never touch the real service or
the real worktrees.

```text
bin/t3ctl          argument parsing + dispatch
lib/common.sh      output helpers, config, agent/privilege plumbing
lib/service.sh     user-systemd chain, status/start/stop/restart/reset/update/logs
lib/worktrees.sh   discovery, inspection, clean, remove (_wt_* run as agent)
lib/disk.sh        disk + doctor
```

Non-goals for v1: automatic or scheduled cleanup, daemons, databases, a TUI,
force deletion, deleting branches, and git pushes/commits.
