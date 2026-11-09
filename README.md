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
t3ctl worktrees --project olta --sort size
t3ctl worktree <id> info
t3ctl worktrees clean --project olta --older-than 2w   # drop node_modules/.next/... keep code + git
t3ctl worktrees remove --safe --older-than 30d         # git worktree remove, only if nothing can be lost
t3ctl worktree <id> remove --force                     # abandoned work: discard it too
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

### One grammar

Listing and every action share the same *selection* syntax. A selection is IDs
(comma or space separated) and/or filters; everything combines with AND.

```text
t3ctl worktrees [list]  [selection] [--sort size|age|project|commit] [-r] [--no-size]
t3ctl worktrees info    [selection]
t3ctl worktrees clean   [selection] [--dry-run]
t3ctl worktrees remove  [selection] [--dry-run] [--force]
t3ctl worktree <id>[,id...] info|clean|remove ...      # same thing, by ID
```

| Filter | Selects worktrees whose... |
|---|---|
| `--all` | (actions only) everything |
| `--project NAME[,NAME]` | project directory matches; case-insensitive globs, e.g. `--project 'olta*'` |
| `--name GLOB` | directory name matches |
| `--branch GLOB` | checked-out branch matches |
| `--older-than DUR` / `--newer-than DUR` | last activity is at least / less than `DUR` (`12h`, `7d`, `2w`, `3mo`) |
| `--before YYYY-MM-DD` | last activity is before local midnight on that date |
| `--larger-than SIZE` | size exceeds `SIZE` (`500M`, `2G`); needs sizes, so not with `--no-size` |
| `--pushed` / `--unpushed` | HEAD is / is not contained in a locally known remote branch |
| `--dirty` / `--clean` | has / has no uncommitted changes (modified or untracked) |
| `--safe`, `--status safe,risk,blocked` | removal verdict (see below) |

Repeating a filter (or comma-separating values) means OR *within* that filter:
`--project olta,app --older-than 2w` is "(olta or app) and older than two weeks".
Unknown values never match, so a worktree with unknown age is not "old". A
`--project` that matches nothing is an error that lists the known projects, so
a typo cannot silently select nothing. `--yes` is accepted anywhere, including
after the command. Pushed status uses existing remote-tracking refs and does not
fetch; dates refer to last activity, including the HEAD reflog.

### Listing

```text
$ t3ctl worktrees --project olta
Filters: project=olta
ID      PROJECT  NAME             SIZE          ACTIVE  COMMIT  CHANGES  SYNC     REMOVE   BRANCH
────────────────────────────────────────────────────────────────────────────────────────────────────
324fdb  olta     t3code-029011b7  2.0G  ████████  1d      1d      clean    in sync  ● safe   OLTA-603
63e4c3  olta     t3code-b85788c0  141M  █░░░░░░░  3d      7d      3M2U     ↑2       ▲ force  t3code/review
9d02aa  olta     main-checkout    1.1G  ████░░░░  2w      2w      clean    pushed   ✖ blocked main

3 of 8 worktree(s) · 3.2G summed
  ● 1 safe to remove   ▲ 1 need --force   ✖ 1 blocked

PROJECT  COUNT  SAFE  FORCE  BLOCKED  SIZE
───────────────────────────────────────────────────────────
olta         3     1      1        1  3.2G  ████████████
```

* **ACTIVE**: time since the last file change, ignoring `.git` and artifact
  dirs (the reflog counts too). **COMMIT**: age of HEAD.
* **CHANGES**: `clean`, or counts such as `3M2U` (modified, untracked).
* **SYNC**: `in sync`, `↑2` / `↓1` (ahead / behind upstream), `local` (no
  upstream and HEAD is on no remote branch) or `pushed` (no upstream, but HEAD
  is on a remote branch).
* **REMOVE** is the verdict `remove` would reach:

| Verdict | Meaning | What happens |
|---|---|---|
| `● safe` | nothing can be lost | `remove` works |
| `▲ force` | uncommitted or unpublished work exists | `remove` refuses; `remove --force` discards it |
| `✖ blocked` | main checkout, locked or broken git state | never removable (processes running inside are checked at removal time and also block) |

* Unknown values are `?`, never 0. `--no-size` skips `du` (a cold-cache `du`
  over dozens of worktrees can take a minute).
* Glyphs fall back to ASCII (`o ! x # .`) in non-UTF-8 locales or with
  `T3CTL_ASCII=1`; colours are off when piped or when `NO_COLOR` is set.

SIZE is measured per worktree. Package managers such as bun and pnpm hard-link
files across worktrees, so the summed sizes overstate real usage.
`t3ctl disk` reports the real total (hard links counted once).

`info` shows branch, HEAD, upstream ahead/behind, whether HEAD is published,
changes, processes whose cwd is inside the worktree, the artifact cleanup plan,
and the removal verdict with its reasons (`▲` can be forced, `✖` cannot).

### Plan, confirm once, execute, report

`clean` and `remove` always work in the same four steps, for one worktree or a
hundred:

1. **Plan**: a table of the selection with what would happen to each one.
2. **Confirm**: one prompt for the whole batch (`--yes` skips it). `--dry-run`
   stops here.
3. **Execute**: each worktree is re-validated right before acting. A refusal or
   failure is reported for that worktree and the batch continues.
4. **Report**: a result table, plus freed space and the filesystem's real
   free-space change.

Exit status is the highest per-worktree code: `0` ok, `1` failure or aborted,
`3` refused, `4` unknown/ambiguous ID. An empty selection succeeds with a
message.

```bash
t3ctl worktrees clean --all --dry-run
t3ctl worktrees clean --project olta --older-than 2w
t3ctl worktrees remove --project olta --safe --dry-run
t3ctl worktrees remove --pushed --clean --older-than 30d --yes
t3ctl worktrees remove --project olta --branch 'OLTA-6*' --force
```

### clean

This deletes only directories that meet all of these conditions:

* the name is in `SAFE_CLEAN_DIRS`, and it was found by `find` without
  following symlinks,
* it is a real directory, not a symlink, with no symlinked parents,
* git ignores it (`git check-ignore`),
* it contains no tracked files (`git ls-files`).

Anything else is listed as `kept` with the reason. For example, a tracked
`build/` folder is kept. A dirty worktree can still be cleaned, because source
files and git state are never touched. The plan shows reclaimable space per
worktree and per artifact type (`node_modules`, `.next`, ...) with bars; the
report shows before/after size and the actual change in filesystem free space.
Freed space can be smaller than the size shown when files are hard-linked
elsewhere.

### remove

`remove` classifies every blocker as **soft** (work could be lost) or **hard**
(never overridable):

| Blocker | Class | `--force` |
|---|---|---|
| tracked modifications or untracked files | soft | discards them |
| branch ahead of its upstream | soft | allowed; the branch (and its commits) is kept |
| no upstream and HEAD on no remote branch | soft | allowed; the branch is kept |
| detached HEAD with unpublished commits | soft | allowed; **those commits become orphaned** |
| mid rebase/merge/cherry-pick/bisect | soft | allowed |
| unknown changes or upstream state | soft | allowed |
| main checkout instead of a linked worktree | hard | refused |
| git state broken, unregistered or **locked** | hard | refused (unlock it first) |
| processes running inside | hard | refused |
| path outside the root, ID mismatch | hard | refused |

#### `--force`

For a worktree whose work was abandoned (for example ahead of origin after the
PR was discarded):

```bash
t3ctl worktree a83f21 remove --force
t3ctl worktrees remove --project olta --unpushed --force --dry-run   # review first
```

Without `--force`, a refusal tells you exactly this:

```text
REFUSING TO REMOVE a83f21  olta/t3code-029011b7

Safety checks failed:
  ▲ branch ahead of origin/feat/foo: 1
  ▲ modified files: 3

Discard it anyway (branch is kept; uncommitted work is lost):

  t3ctl worktree a83f21 remove --force
```

With `--force` the plan names what is thrown away and what survives:

```text
ID      WORKTREE      SIZE  CHANGES  SYNC     PLAN     NOTE
a83f21  olta/feat-a   2.9M  clean    ↑1       ▲ FORCE  branch feat-a keeps its unpublished commits
c93c03  olta/feat-b   804K  3M2U     in sync  ▲ FORCE  discards 3 modified, 2 untracked
```

* `--force` runs `git worktree remove --force`. It never deletes branches, so
  committed work stays reachable through the branch. Only uncommitted changes
  (and detached-HEAD commits) are lost.
* If the batch would destroy uncommitted work, you must type `discard` at one
  prompt (non-interactive use needs `--yes`). If only branch-safe commits are
  involved, the normal `y/N` prompt applies.
* `--force` is long-form only, applies to `remove` only, and does not skip the
  hard blockers above. Combine it with `--dry-run` to preview.

Right before acting, the agent-side removal re-runs every check as the agent
user, so state that changed since the plan is caught.

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
lib/ui.sh          glyphs, bars and aligned tables (ASCII fallback)
lib/worktrees.sh   discovery, inspection, clean, remove (_wt_* run as agent)
lib/disk.sh        disk + doctor
```

Non-goals: automatic or scheduled cleanup, daemons, databases, a TUI, deleting
branches, and git pushes/commits. Force deletion exists only as the explicit,
previewable `remove --force` described above.
