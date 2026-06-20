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

### Changed

- `MOUNT_DIRS` and the config `mount` key now separate multiple mounts with a
  **comma**, not a colon. Colon is reserved for `SRC:DEST`. **Breaking:** an
  existing `MOUNT_DIRS=~/a:~/b` must become `MOUNT_DIRS=~/a,~/b` (it would
  otherwise be read as a single mount of `~/a` at target `~/b`).

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
