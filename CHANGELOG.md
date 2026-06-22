# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

### Added

- Configuration file for persistent defaults: a `key = value` file at
  `$TOOLBOXER_CONFIG`, else `$XDG_CONFIG_HOME/toolboxer/config`, else
  `~/.config/toolboxer/config`. Keys mirror the CLI options (`mount`,
  `ai_agents`, `assumeyes`, `privileged`, `isolated`, `image`, `distro`,
  `release`, `container_name`, `authfile`). Settings resolve by precedence:
  CLI flags > environment variables > config file > built-in defaults
- `--no-ai-agents`, `--no-assumeyes`, `--no-privileged`, and `--no-isolated`
  flags to switch off a default enabled in the config file for a single run
- `config` command to print the effective configuration (config file location
  and the resolved settings)
- `SRC:DEST` mount specs: `-m`, `MOUNT_DIRS`, and the config `mount` key now
  accept `source:dest` to mount a directory at a custom target path inside the
  container (like `podman -v`), in addition to the bare `DIR` form (mounted at
  the same path). The first mount's target is the working directory on `enter`.
- Provision script: a bash script run inside a new container on first start
  (and on demand via the new `provision` command) to install packages or prepare
  it without maintaining a custom image. Resolved from `$TOOLBOXER_PROVISION`,
  else the `provision_script` config key, else a `provision.sh` beside the config
  file. Runs as the host user with passwordless sudo, with `TOOLBOXER_DISTRO`
  and `TOOLBOXER_RELEASE` in the environment; failures warn but don't abort.

### Changed

- `MOUNT_DIRS` and the config `mount` key now separate multiple mounts with a
  **comma**, not a colon. Colon is reserved for `SRC:DEST`. **Breaking:** an
  existing `MOUNT_DIRS=~/a:~/b` must become `MOUNT_DIRS=~/a,~/b` (it would
  otherwise be read as a single mount of `~/a` at target `~/b`).

### Fixed

- `enter`/`run`/`stop`/`rm` with a pinned distro/release or name no longer
  silently fall back to the only existing container when the requested one is
  absent. Previously `toolboxer enter -d ubuntu -r 24.04` would enter an
  existing Fedora container; now the requested container is reported missing
  (and `enter` offers to create it).
- Generic images that ship a stock account at the host's UID/GID — Ubuntu's
  `ubuntu:1000` being the common case — are now renamed to the host user
  instead of being left in place. The previous `useradd` collided on the
  in-use UID and was silently skipped, so the in-container login stayed
  `ubuntu`, did not match the host, and (since the sudoers drop-in was written
  for the host username) left `sudo` prompting for a password. The sudoers file
  is now also validated with `visudo`, warning if it doesn't parse.
- The container's idle PID 1 (`sleep infinity`) now runs as root rather than the
  host user. Under `--userns=keep-id` it otherwise ran as the host user, so on
  first start the account was "in use" and the setup `usermod`/rename failed with
  `user … is currently used by process`. `run`/`enter` still exec as the host
  user, so this is invisible in normal use.
- `sudo` is now installed via `zypper` on openSUSE images too (previously only
  `dnf`/`apt`/`pacman` were handled, so `--distro opensuse-*` had no sudo).
- Slow `sudo` (and other hostname lookups) inside the container. The container
  hostname (`toolboxer`) had no `/etc/hosts` entry — the host's `/etc/hosts` was
  bind-mounted over podman's generated one — so resolving it fell through to DNS
  and waited for a timeout. toolboxer no longer bind-mounts `/etc/hosts` (podman
  still merges the host's entries) and adds a `127.0.0.1 toolboxer` self-mapping.
- `run` no longer forces a pseudo-TTY. It allocated `-t` unconditionally, so
  output captured or piped from `toolboxer run …` came back with `\r\n` line
  endings; a TTY is now requested only when stdin and stdout are both terminals.

## [0.1.0] - 2026-06-20

First release. A container is isolated by a file boundary — only the
directories you mount are visible — and the looser, more integrated behaviour
is opt-in rather than the default.

### Added

- Commands: `create`, `enter`, `run`, `list`, `stop`, `rm`, `rmi`, `help`
- Restricted mounts — only selected directories are bind-mounted
  (`-m`/`--mount`, repeatable; `MOUNT_DIRS`); the home directory is never
  mounted. This file boundary is the main isolation and holds in every mode
- Three modes: the default (toolbox-style host integration); `--privileged`
  (opt-in, needed to run podman/docker inside the container — reduces
  isolation); and `--isolated` (a hardened sandbox for untrusted code —
  SELinux-confined, private namespaces, no host integration)
- Full host integration (default mode): X11, Wayland, D-Bus, SSH agent, XDG
  runtime dir, systemd journal, and udev, plus config sync (`resolv.conf`,
  `hosts`, `localtime`, `hostname`, `machine-id`, …)
- A matching user with passwordless sudo, UID/GID preserved via `--userns=keep-id`
- Multi-distro images — Fedora, RHEL, CentOS, Rocky, Ubuntu, Debian, Arch, and
  openSUSE. The default image matches the host (`/etc/os-release`); unrecognised
  distros are mapped via `ID_LIKE` (derivatives to their base, RHEL clones to Rocky)
- Nested rootless podman-in-podman via `--privileged`, with no required host
  devices (host networking, native overlay, and runtime isolation from the
  host's podman state)
- `-A`/`--ai-agents` to share AI agent config dirs (Claude Code, Codex, Gemini,
  Aider, …) into the container
- Container resolution by `-d`/`--distro` and `-r`/`--release` in `rm` and `stop`
- A magenta hexagon prompt marker, like toolbox
- toolbox CLI parity: `create --authfile`, `run --preserve-fds`, and the global
  `-y`/`--assumeyes`
- Bash completion
- Smoke tests and a GitHub Actions CI workflow (shellcheck + tests on Fedora)
- `install.sh` and a `Makefile` for installation

[Unreleased]: https://github.com/csmart/toolboxer/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/csmart/toolboxer/releases/tag/v0.1.0
