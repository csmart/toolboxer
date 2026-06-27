# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

### Changed

- Container setup now reports clearly when `sudo` could not be installed
  (a failed package install, or a custom `--image` whose package manager isn't
  one toolboxer handles): it prints a "could not install sudo" warning instead of
  silently producing a sudo-less container. The misleading "passwordless-sudo
  setup did not validate" warning — which is about a malformed sudoers file, not
  missing sudo — is no longer shown when the real cause is that sudo isn't there.

## [0.5.0] - 2026-06-26

### Added

- `--distro` aliases: `opensuse`/`suse`/`leap` map to `opensuse-leap`
  (openSUSE's stable point release), `tumbleweed` to `opensuse-tumbleweed`, and
  `archlinux` to `arch`. They canonicalise to the same container as the full
  name, so `-d opensuse` no longer falls through to the host's `ID_LIKE`
  default — which, off a non-SUSE host, silently built Fedora.

### Changed

- An unrecognised `--distro` now fails with the list of supported distros,
  instead of silently building Fedora via the host's `ID_LIKE` fallback — so a
  typo like `-d bubuntu` is caught rather than quietly giving you the wrong OS.
  (An unrecognised *host* distro, with no `--distro`, still maps via `ID_LIKE`.)
- A pinned `--release` is used verbatim in the image tag. A point release the
  registry doesn't publish (e.g. `rocky:8.10` — Rocky ships only major tags) now
  fails the pull with a clear explanation instead of silently using the major
  (`rockylinux:8`, which could be any 8.x); point releases that do exist (e.g.
  `debian:12.8`) are now honoured rather than rounded down to `debian:12`. A
  pinned `--release` on a rolling distro (`arch`, `opensuse-tumbleweed`), which
  has no versioned tags, is now rejected (e.g. `arch:2022` errors) instead of
  silently returning today's `:latest`.

### Fixed

- `--distro` without `--release` no longer inherits the host's version for a
  *different* distro. On a Fedora 44 host, `create -d opensuse-leap` resolved to
  the nonexistent `opensuse/leap:44` (and other non-host distros to tags like
  `ubuntu:44`, `rockylinux:44`); each distro now falls back to its own current
  tag — `latest`, or a recent major for the RHEL family — and the host release
  is used only for the host's own distro. The container name tracks the same
  default, so it matches the image pulled (e.g. `ubuntu-toolbox-latest`). RHEL
  also defaults to `ubiN/toolbox:latest`, as `ubiN/toolbox` has no bare `:N` tag.

## [0.4.0] - 2026-06-24

### Changed

- `rm` now requires an explicit target, matching `toolbox`: a bare `toolboxer rm`
  errors with "missing argument" instead of defaulting to the host container.
  A name, `--all`, or `-d`/`-r` still works. Unlike `enter`/`run`/`stop`, `rm`
  never falls back to the host default or the only existing container, so it
  can't remove one you didn't name.

### Fixed

- `--ai-agents` now also mounts `~/.config/cursor`, where Cursor keeps its login,
  so it carries into the container instead of prompting to sign in again
  (previously only `~/.cursor` was mounted).

## [0.3.0] - 2026-06-23

### Fixed

- The container's home directory is now writable. The user's home is usually the
  parent of the mounts (`~` when you mount `~/code`), which podman auto-creates
  root-owned — so the user couldn't write to its own home, and `~/.bashrc`,
  `~/.config`, and provision scripts that touch `$HOME` all failed. Setup now
  creates `$HOME` and hands it to the user (non-recursive, so the mounted dirs
  inside keep their owners); it is left empty, so bring dotfiles via a mount or
  the provision script.

## [0.2.0] - 2026-06-23

### Added

- Provision script: a bash script run inside a new container on first start
  (and on demand via the new `provision` command) to install packages or prepare
  it without maintaining a custom image. Resolved from `$TOOLBOXER_PROVISION`,
  else the `provision_script` config key, else a `provision.sh` beside the config
  file. Runs as the host user with passwordless sudo, with `TOOLBOXER_DISTRO`
  and `TOOLBOXER_RELEASE` in the environment; failures warn but don't abort.

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
- `SRC:DEST` mount specs: `-m`, `MOUNT_DIRS`, and the config `mount` key accept
  `source:dest` to mount a directory at a custom target path inside the container
  (like `podman -v`), as well as a bare `DIR` (mounted at the same path). Several
  mounts are comma-separated — colon is reserved for `source:dest`. The first
  mount's target is the working directory on `enter`

[Unreleased]: https://github.com/csmart/toolboxer/compare/v0.5.0...HEAD
[0.5.0]: https://github.com/csmart/toolboxer/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/csmart/toolboxer/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/csmart/toolboxer/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/csmart/toolboxer/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/csmart/toolboxer/releases/tag/v0.1.0
