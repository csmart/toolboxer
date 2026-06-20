# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/).

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

[0.1.0]: https://github.com/csmart/toolboxer/releases/tag/v0.1.0
