# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/).

## [0.1.0] - 2026-06-20

Initial release.

### Added

- Commands: `create`, `enter`, `run`, `list`, `stop`, `rm`, `rmi`, `help`
- Restricted mounts — only selected directories are bind-mounted
  (`-m`/`--mount`, repeatable; `MOUNT_DIRS`); the home directory is never mounted
- Full host integration: X11, Wayland, D-Bus, SSH agent, XDG runtime dir,
  systemd journal, and udev, plus config sync (`resolv.conf`, `hosts`,
  `localtime`, `hostname`, `machine-id`, …)
- A matching user with passwordless sudo, UID/GID preserved via `--userns=keep-id`
- Multi-distro images — Fedora, RHEL, CentOS, Rocky, Ubuntu, Debian, Arch, and
  openSUSE. The default image matches the host (`/etc/os-release`); unrecognised
  distros are mapped via `ID_LIKE` (derivatives to their base, RHEL clones to Rocky)
- Nested rootless podman-in-podman with no required host devices: host
  networking, native overlay, `--privileged`, and runtime isolation from the
  host's podman state
- `-A`/`--ai-agents` to share AI agent config dirs (Claude Code, Codex, Gemini,
  Aider, …) into the container
- Container resolution by `-d`/`--distro` and `-r`/`--release` in `rm` and `stop`
- A magenta hexagon prompt marker, like toolbox
- toolbox CLI parity: `create --authfile`, `run --preserve-fds`, and the global
  `-y`/`--assumeyes`
- Bash completion
- Smoke tests (CLI tests plus podman integration tests)
- `install.sh` and a `Makefile` for installation

[0.1.0]: https://github.com/csmart/toolboxer/releases/tag/v0.1.0
