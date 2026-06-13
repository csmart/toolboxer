# toolboxer

A drop-in replacement for Fedora's [toolbox/toolbx](https://containertoolbx.org/) command, written in Bash. It creates Podman containers for development work but restricts volume mounts to only the directories you specify, rather than exposing your entire home directory.

## Features

- **Restricted mounts** — only selected directories are bind-mounted into the container (default: `~/code`). Your home directory is never mounted.
- **Full host integration** — X11, Wayland, D-Bus, SSH agent, PulseAudio, and XDG runtime dir are all passed through via discrete socket mounts.
- **User environment** — a matching user account with sudo access is created inside the container, with your UID/GID preserved.
- **Config sync** — `/etc/resolv.conf`, `/etc/hosts`, `/etc/localtime`, `/etc/hostname`, and other host config files are bind-mounted read-only.
- **Nested podman** — rootless podman-in-podman works out of the box, with no required host devices (see [Running podman inside the container](#running-podman-inside-the-container)).
- **Multiple mount directories** — pass `-m` multiple times or set `MOUNT_DIRS` (colon-separated).
- **toolbox-compatible CLI** — commands and flags match `toolbox` (`create`, `enter`, `run`, `list`, `rm`, `rmi`) with the same `-d`/`-r`/`-i`/`-c` flags.
- **Multi-distro** — supports Fedora, RHEL, CentOS, Rocky, Ubuntu, Debian, Arch, and openSUSE images via `--distro`/`--release`. The default image **matches your host** (read from `/etc/os-release`), and unrecognised distros are mapped to a base via `ID_LIKE` — derivatives (Mint, Pop!_OS, Manjaro, …) to their parent, and any RHEL-family clone (AlmaLinux, etc.) to Rocky Linux (a binary-compatible image, unlike Fedora).
- **Auto-detect** — running `toolboxer` with no command enters the default container; if only one container exists, it is used automatically.

## Requirements

- [Podman](https://podman.io/) (rootless)
- Bash 4.0+

## Installation

### Clone the repo

```bash
git clone https://github.com/csmart/toolboxer.git
cd toolboxer
```

### Quick install

```bash
./install.sh
```

Or using make:

```bash
make install
```

To uninstall:

```bash
make uninstall
```

### Option 1: Symlink into a directory already on your PATH

```bash
ln -s "$(pwd)/toolboxer" ~/.local/bin/toolboxer
```

### Option 2: Copy it directly

```bash
cp toolboxer ~/.local/bin/toolboxer
chmod +x ~/.local/bin/toolboxer
```

### Option 3: Custom location

If you place `toolboxer` somewhere that isn't on your `PATH`, add that directory:

```bash
# Add to ~/.bashrc or ~/.bash_profile
export PATH="$PATH:/path/to/toolboxer/directory"
```

Then reload your shell:

```bash
source ~/.bashrc
```

### Installing bash completion

Copy the completion file to the system or user completions directory:

```bash
# System-wide (requires root)
sudo cp completions/toolboxer.bash /etc/bash_completion.d/toolboxer

# Or user-local
mkdir -p ~/.local/share/bash-completion/completions
cp completions/toolboxer.bash ~/.local/share/bash-completion/completions/toolboxer
```

Then start a new shell or source it manually:

```bash
source completions/toolboxer.bash
```

## Usage

```
toolboxer [--mount DIR] <command> [args...]
```

Running `toolboxer` with no command defaults to `enter`.

### Commands

| Command | Description |
|---------|-------------|
| `create` | Create the container |
| `enter` | Enter the container (starts it if stopped) |
| `run <cmd>` | Run a single command inside the container |
| `list` | Show all toolboxer containers and images |
| `stop` | Stop the container |
| `rm` | Remove the container(s) |
| `rmi` | Remove toolbox image(s) |
| `help` | Show help |

### `create` options

| Option | Description |
|--------|-------------|
| `-d`, `--distro DISTRO` | Use a different distro (incompatible with `--image`) |
| `-i`, `--image NAME` | Use a custom image (incompatible with `--distro`/`--release`) |
| `-r`, `--release RELEASE` | Use a different release (incompatible with `--image`) |
| `-m`, `--mount DIR` | Directory to mount (repeatable) |
| `[CONTAINER]` | Container name (positional) |

### `enter` options

| Option | Description |
|--------|-------------|
| `-d`, `--distro DISTRO` | Enter container for a different distro |
| `-r`, `--release RELEASE` | Enter container for a different release |
| `[CONTAINER]` | Container name (positional) |

### `run` options

| Option | Description |
|--------|-------------|
| `-c`, `--container NAME` | Run in a specific container |
| `-d`, `--distro DISTRO` | Run in container for a different distro |
| `-r`, `--release RELEASE` | Run in container for a different release |

### `list` options

| Option | Description |
|--------|-------------|
| `-c`, `--containers` | Show only containers |
| `-i`, `--images` | Show only images |

### `rm` options

| Option | Description |
|--------|-------------|
| `-a`, `--all` | Remove all toolboxer containers |
| `-f`, `--force` | Force removal of running containers |
| `-d`, `--distro DISTRO` | Remove the container for a different distro |
| `-r`, `--release RELEASE` | Remove the container for a different release |
| `[CONTAINER...]` | Container name(s) (positional) |

With no name, `rm` (like `enter`/`run`/`stop`) resolves the container from `-d`/`-r` (or the host defaults), so `toolboxer rm -r 44` removes `fedora-toolbox-44` without typing the full name.

### `rmi` options

| Option | Description |
|--------|-------------|
| `-a`, `--all` | Remove all toolbox images |
| `-f`, `--force` | Force removal, including dependent containers |
| `[IMAGE...]` | Image name(s) (positional) |

### Global options

| Option | Description |
|--------|-------------|
| `-m`, `--mount DIR` | Directory to mount — repeatable (default: `~/code`) |
| `-h`, `--help` | Show help |

### Environment variables

These are the lowest priority — CLI flags override them.

| Variable | Description |
|----------|-------------|
| `CONTAINER_NAME` | Container name |
| `IMAGE` | Image to use |
| `MOUNT_DIRS` | Colon-separated list of directories to mount |

### Examples

```bash
# Create and enter a default container (mounts ~/code)
toolboxer create
toolboxer enter

# Just run toolboxer with no args to enter the default container
toolboxer

# Create with a custom image
toolboxer create --image fedora:41

# Create a container for a different distro/release
toolboxer create --distro ubuntu --release 24.04

# Create a container that mounts two directories
toolboxer -m ~/code -m ~/documents create

# Give the container a custom name
toolboxer create my-project

# Enter a specific container by name
toolboxer enter my-project

# Run a single command
toolboxer run gcc -o hello hello.c

# Run in a specific container
toolboxer run --container my-project make test

# List all toolboxer containers and images
toolboxer list

# List only containers (no images)
toolboxer list --containers

# Stop and remove
toolboxer stop
toolboxer rm

# Remove a specific container
toolboxer rm my-project

# Remove all containers (including running ones)
toolboxer rm --all --force

# Remove all toolbox images
toolboxer rmi --all
```

## Host integration

The following host resources are passed into the container automatically (none of these require mounting `$HOME`):

| Resource | Mount | Mode |
|----------|-------|------|
| DNS, hostname, timezone | `/etc/resolv.conf`, `/etc/hosts`, `/etc/localtime`, etc. | read-only |
| X11 display | `/tmp/.X11-unix` | read-only |
| Wayland, PulseAudio | `$XDG_RUNTIME_DIR` | read-write |
| D-Bus session bus | `$DBUS_SESSION_BUS_ADDRESS` socket | read-write |
| SSH agent | `$SSH_AUTH_SOCK` socket | read-write |
| systemd journal | `/run/systemd/journal` | read-only |
| udev database | `/run/udev/data` | read-only |
| FUSE / TUN devices | `/dev/fuse`, `/dev/net/tun` | device (if present) |

Environment variables (`DISPLAY`, `WAYLAND_DISPLAY`, `DBUS_SESSION_BUS_ADDRESS`, `SSH_AUTH_SOCK`, `TERM`, `LANG`, `XDG_RUNTIME_DIR`) are forwarded into the container.

## Running podman inside the container

Rootless **podman-in-podman** works out of the box, with **no required host
devices**:

```bash
toolboxer run podman run hello-world
```

This is achieved with the fewest possible host requirements:

- **Networking** — on first start, toolboxer drops a containers.conf drop-in
  (`/etc/containers/containers.conf.d/90-toolboxer-nested.conf`) that defaults
  the nested podman to **host networking** (`netns=host`). Because the toolbox
  itself already runs with `--network host`, nested containers share the host
  network and need no `/dev/net/tun` (so no pasta/slirp4netns, and no `tun`
  kernel module). Override per-container with `podman run --network pasta …` if
  you have `/dev/net/tun` available.
- **Storage** — on a modern kernel, the nested podman uses native rootless
  overlay, so `/dev/fuse` isn't required. `/dev/fuse` and `/dev/net/tun` are
  still passed through *when present* on the host (harmless), which lets
  fuse-overlayfs and bridged/pasta networking work if you opt back into them.
- **Capabilities** — the toolbox is created `--privileged`. In *rootless*
  podman this grants no real host privilege (the container stays confined to
  your rootless user namespace); it just gives the container the capabilities
  you already have and unmasks `/proc`. Without it, the nested podman — which
  falls back to single-UID mapping here (no subuid ranges) and so inherits
  toolboxer's capped-down set — fails privileged-in-userns operations such as
  mounting a fresh `procfs` (`crun: mount proc: Operation not permitted`) and
  `sethostname` (`crun: sethostname: Operation not permitted`). This is the
  same approach [distrobox](https://github.com/89luca89/distrobox) takes.
- **Runtime isolation** — toolboxer bind-mounts your `$XDG_RUNTIME_DIR` (for
  the Wayland/PulseAudio/D-Bus sockets), but shadows podman's own state dirs
  inside it (`$XDG_RUNTIME_DIR/containers` and `.../libpod`) with empty
  container-local tmpfs. This keeps the nested podman's runroot and
  pause-process pid file separate from the host's. Without it, the nested
  podman would overwrite the host's `…/libpod/tmp/pause.pid` with a pause
  process living in the container's mount namespace, and — because the toolbox
  runs with `--pid host` — subsequent **host** podman commands would join that
  namespace and break with `stat …/.config: no such file or directory` until
  the pause process was killed. (Trade-off: nested podman does not see host
  registry logins, since `auth.json` lives under the shadowed `containers`
  dir — run `podman login` again inside the toolbox for private registries.)

Note on user namespaces: the in-container user does not have its own
`/etc/subuid`/`/etc/subgid` ranges, so the nested podman falls back to
*single-UID mapping* (everything runs as your UID). This is fine for most
images. Images that need multiple UIDs inside (e.g. that create and switch to a
separate user) require subuid/subgid ranges, which interact with
`--userns=keep-id` and are deliberately not configured automatically.

## Testing

Run the smoke tests:

```bash
./tests/test_toolboxer.bash
```

CLI tests run without Podman. Integration tests (create, run, sudo, rm) require a working rootless Podman setup.

## Linting

```bash
shellcheck toolboxer
```

## How it differs from toolbox

| | `toolbox` | `toolboxer` |
|-|-----------|-------------|
| Home directory | Entire `$HOME` mounted | Only specified directories mounted |
| Host integration | Full | Full (X11, Wayland, D-Bus, SSH, DNS, etc.) |
| User setup | Via init-container | Via `useradd` + sudoers on first `enter`/`run` |
| Extra global option | — | `-m/--mount` for restricted volume control |
| Extra command | — | `stop` |
| Implementation | Go binary | Single Bash script |
| Container label | `com.github.containers.toolbox` | `toolbox=true` + `toolboxer=true` |

## License

This project is licensed under the [GNU General Public License v3.0](LICENSE).
