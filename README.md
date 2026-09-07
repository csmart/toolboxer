# toolboxer

A Bash wrapper for local, rootless Podman development containers, with selected
host directories instead of an automatic whole-home mount. It provides a
toolbox-style CLI, a matching user with passwordless sudo, and optional desktop
and AI-agent configuration sharing.

The default integrated mode is for trusted development tools. Restricting home
mounts does **not** make a container a security sandbox.

## Requirements and installation

Use Linux with Bash 4.4+, GNU coreutils, awk, and util-linux's `flock`. Podman
must already work rootlessly as your normal user. Remote Podman connections and
running toolboxer as root are unsupported. Use `crun` to preserve supplementary
host-group access; other runtimes produce a warning when that access may be lost.

The host target is any modern Linux distribution with these dependencies, not
only the distro names supported by `--distro` (those select container images).
Desktop integration is optional and uses the available host paths and sockets;
SELinux handling follows Podman's reported host capabilities.

```bash
git clone https://github.com/csmart/toolboxer.git
cd toolboxer
make install
# Or, without make:
./install.sh
```

Both install to `~/.local/bin` and the user bash-completion directory. Ensure
`~/.local/bin` is on PATH. For another location, use
`make install PREFIX=/your/prefix`; `DESTDIR` and `COMPDIR` are also supported.
Uninstall using the same settings with `make uninstall`. Containers, images,
configuration, and host files are not removed by uninstalling.

A symlink to the repository's `toolboxer` script also works. Completion requires
the host's bash-completion package; restart your shell after installation.

If Podman reports a UID-mapping error, fix the host's rootless setup first.
Toolboxer checks local `/etc/subuid` and `/etc/subgid` as a diagnostic hint, not
as the authority for NSS-managed systems. Ask the administrator to allocate
sufficient, **non-overlapping** subordinate ranges for your account. Do not copy
another user's range or recursively change container-storage ownership. Changing
mappings may require Podman migration/recreation and coordination with running
workloads.

## Getting started

```bash
toolboxer create -d ubuntu -r 24.04 -m ~/code/project:/work dev
toolboxer enter dev
toolboxer run -c dev make test
toolboxer stop dev
toolboxer rm dev
```

With no command, toolboxer defaults to `enter`. It uses the configured/default
container, or the sole toolboxer container if no name, distro, or release was
explicitly selected. Only `enter` offers to create a missing container;
`-y` accepts that prompt. Explicit selections never fall back to another name.

`create` creates a stopped container. First use starts it and initializes the
matching account, writable container-local home, passwordless sudo, and profile.
Setup is checked before recording success and retried after a failure. The idle
process runs as container root; user commands run with your host UID/GID and
explicit HOME. Both login shells and `run` expose `~/.local/bin`.

If sudo's image files appear user-owned or lack setuid, setup repairs root
ownership and safe permissions on the container-local executable, configuration,
and direct sudoers fragments. It preserves their contents, does not delete or
recursively rebuild directories, and refuses repairs through host bind mounts.
Metadata and passwordless sudo are verified before setup is marked complete.
This does not repair the host's container storage or UID/GID allocation.

Concurrent setup and provisioning are serialized per container. A contended
invocation prints a lock-wait message; Ctrl-C cancels the waiter. Older versions
could leak the lock to the container monitor (`conmon`), making subsequent
`enter`, `run`, or `provision` commands wait indefinitely. After updating, cancel
blocked invocations and save any work in the affected container, then run
`podman stop NAME` and retry with the updated script. Stopping ends running
container processes but preserves the container and its files. Do not delete
the lock file: that could allow simultaneous setup against different locks.

`run` preserves payload stdout and exit status; setup and provisioning output go
to stderr. Wrapper options end at the command, so its arguments are not reparsed.
It does not source login profiles. Use `run -c dev bash -lc '...'` when needed.
`--preserve-fds N` forwards additional inherited descriptors where supported by
the installed Podman/runtime.

## Mounts and working directories

The default mount is `~/code`. Each `-m/--mount` is either `PATH` (same path
inside) or `SOURCE:/absolute/target`. CLI mounts replace the default/configured
list rather than adding to it. Repeated flags support paths containing spaces:

```bash
toolboxer create -m "$HOME/work project:/work" -m "$HOME/.gitconfig:/etc/gitconfig" dev
MOUNT_DIRS="$HOME/code,$HOME/documents:/docs" toolboxer create docs
```

Sources are resolved to absolute paths. Missing sources are created as directories;
create a file yourself before mounting it as a file. Destinations must be absolute.
Empty/invalid specs, duplicate targets, mounts over `/`, and tabs/newlines are
rejected. This is not Podman's full volume-option syntax: `:ro`, `:Z`, named
volumes, and colon-containing paths are not accepted. Commas delimit lists; use
repeated CLI flags for paths containing commas.

The first **directory** target is saved as the container workdir; file-only
mounts use `/tmp`. On later `run`/`enter`, a host cwd inside a mounted directory
maps to its corresponding container path, using the most specific mount.
Otherwise the saved workdir is used, independent of the current config.

Mounts are read-write. Toolboxer repairs ownership only in the container-local
home, pruning bind-mounted paths. Host bind sources remain after container removal.
A directly bind-mounted file cannot reliably be replaced using an atomic rename;
mount its parent directory when you need that behavior, considering the additional
files this exposes.

## Modes and security

| Mode | Namespaces and host integration | SELinux |
| --- | --- | --- |
| Default | Host network, PID and IPC; selected desktop/service sockets and host configuration | Container labeling disabled |
| `--privileged` | Integrated mode with additional privileges/devices for trusted nested-container workloads | Container labeling disabled |
| `--isolated` | Private network, PID, IPC and UTS; init process; no automatic host-service mounts | Requests `container_t` when enabled; mounts relabeled with shared `:z` |

Integrated mode forwards available X11, Wayland, D-Bus, SSH-agent and audio
connections. It also mounts selected host configuration, journal and udev paths.
The runtime directory itself is a private tmpfs; toolboxer no longer automatically
binds the entire host runtime directory or the host Podman socket. Socket paths
and environment are captured at creation; recreate after incompatible session
changes.

These services confer real authority. SSH-agent access permits authentication,
D-Bus/X11 expose desktop capabilities, and host namespaces expose host processes
and services. Treat integrated and privileged containers as trusted host tools.
The narrower mount list is a convenience, not a protection against malicious code.

Isolated mode checks the saved mode, privileges, namespace settings, process label
when applicable, and actual bind mounts before use. Unexpected bind mounts from
Podman configuration cause an error. It is **not offline**, it shares the host
kernel, and writable mounts remain writable. SELinux is only effective when the
host enables and enforces it; on disabled/permissive hosts there is no enforcing
SELinux boundary. Relabeling alters host labels and may affect other services:
`:z` recursively relabels each shared tree, so isolated create fails on any file
you do not own, and with `--agent`/`-A` it relabels your live agent credential
directories too. Do not share credentials or sensitive mounts with untrusted
code. Use a separate VM for workloads requiring a stronger boundary.

These behaviors build on [Podman's namespace, volume and privilege options](https://docs.podman.io/en/latest/markdown/podman-create.1.html).
Toolboxer does not audit every possible host policy, image hook, or runtime setting.

Creation settings cannot reconfigure an existing container. Explicit incompatible
mode/agent flags or absent requested mounts fail with a recreation message.
Existing containers retain their original mounts and privileges: recreate older
containers to get runtime-mount changes. Legacy containers claiming isolation but
lacking the new validation metadata may also need recreation. Back up useful
container-local files before removing them.

A configured `isolated = true` is enforced when you enter or run an existing container: it must be an isolated container or the command fails.
A configured `privileged = true` is not enforced that way; only an explicit `--privileged`, `--no-privileged`, or `--no-isolated` on the command line is checked against an existing container.
This keeps a configured isolation boundary from being bypassed silently, while leaving privileged a per-command choice.

For nested Podman, explicitly select `--privileged` and install Podman inside
the container. Toolboxer configures nested networking to use the outer container's
network. Nested storage stays in the container home unless you explicitly mount
it. Nested containers still depend on the host's kernel, mapping, cgroup, and
storage support; privileged mode is not a universal compatibility guarantee.

## Images and commands

Supported distro keys are `fedora`, `rhel`, `centos`, `rocky`, `ubuntu`,
`debian`, `arch`, `opensuse-leap`, and `opensuse-tumbleweed`. Aliases:
`opensuse/suse/leap` select Leap, `tumbleweed` selects Tumbleweed, and
`archlinux` selects Arch. Unknown explicit distros are rejected.

The host distro/release determines defaults; RHEL-family and Debian hosts default
to their major version instead of a point-release tag. Non-host distros generally use
`latest`, while the RHEL family defaults to major 9. Derivative-host detection
uses `ID_LIKE`; specify a known distro and release for predictable selection.
Explicit releases are not silently rounded or substituted on pull failure.
Rolling distros accept only `latest`. RHEL maps major N to `ubiN/toolbox:latest`
and point N.M to `ubiN/toolbox:N.M`; CentOS uses `centos:streamN`.

Use `create --image IMAGE NAME` for a custom image; it conflicts with explicit
distro/release flags. Images must supply Bash, standard GNU/Linux account tools
(`getent`, `groupadd`, `useradd`, `usermod`), standard filesystem utilities,
and `sleep infinity`. Sudo must be installed already or installable through
dnf, apt, pacman, or zypper. Arch installation performs a full upgrade rather
than a partial package upgrade. Unsupported minimal images fail setup clearly.
The image entrypoint is replaced; application-specific initialization is not run.

`list` shows containers labeled `toolboxer=true` and tracked images.
`list -c` and `list -i` select sections; together they show both.
Images are tracked by immutable ID under `$XDG_STATE_HOME/toolboxer/images`
(default `~/.local/state/toolboxer/images`), supplemented by existing managed
containers. Thus base/custom images remain discoverable after removing their
containers. Images orphaned before tracking was introduced need explicit names.

`rm` requires explicit names, distro/release selectors, or `--all`; a bare
command never removes a default target. It removes anonymous volumes with the
container, but not host sources or named volumes. Running containers need `-f`.
`rmi IMAGE...` targets explicit local images; `rmi --all` selects only tracked
IDs. Force removes dependent **toolboxer** containers, but refuses images used
by unrelated containers. It never forwards Podman's broad forced-image deletion;
see [Podman's force semantics](https://docs.podman.io/en/latest/markdown/podman-rmi.1.html).
Failures return nonzero. Neither command silently reports failed removals as success.

See `toolboxer help COMMAND` for individual options. Toolboxer is not a complete
drop-in for Toolbx: it does not implement every flag, lifecycle hook, or internal
command, and does not adopt arbitrary existing Toolbx/Podman containers.

## Configuration and provisioning

Configuration is read from `$TOOLBOXER_CONFIG`, otherwise
`$XDG_CONFIG_HOME/toolboxer/config`, otherwise `~/.config/toolboxer/config`.
Precedence is CLI flags > environment > config > built-in defaults.

```ini
mount = ~/code/project:/work
agents = codex,claude
isolated = true
distro = ubuntu
release = 24.04
container_name = coding
provision_script = ~/.config/toolboxer/provision.sh
```

Other keys: `image`, `authfile`, `ai_agents`, `assumeyes`, and `privileged`.
Mount keys can repeat or contain comma-separated lists. Leading `~` expands;
this is not shell code and does not expand arbitrary variables or commands.
`#` starts a comment; quote a value (`"..."` or `'...'`) to keep a literal `#`.
Boolean options accept true/false, yes/no, on/off, 1/0;
CLI `--no-...` overrides a config boolean. `IMAGE`, `CONTAINER_NAME`, and
`MOUNT_DIRS` override corresponding config values. `toolboxer config` shows
effective settings without contacting Podman or creating mounts.

The provision script is chosen by `$TOOLBOXER_PROVISION`, then
`provision_script`, then `provision.sh` beside the config file. For example:

```bash
#!/usr/bin/env bash
set -euo pipefail
case "$TOOLBOXER_DISTRO" in
    ubuntu|debian)
        sudo apt-get update
        sudo apt-get install -y git make
        ;;
esac
```

It runs under Bash as the matching user, with sudo available. Its shebang is
ignored; set your own failure policy. `TOOLBOXER_DISTRO` and
`TOOLBOXER_RELEASE` describe the actual container image. New containers provision
on first use, once after success; failed automatic attempts warn and retry next
time. `toolboxer provision NAME` reruns once explicitly and fails if the script
is missing or fails. Concurrent first starts serialize initialization.

Upgrading an initialized legacy container revalidates account/sudo setup, but
does not automatically rerun its old provision script. Legacy success cannot be
reconstructed; use explicit provisioning if needed. Adding a script after a
container has initialized also requires an explicit provision request.

## AI-agent configuration

Use `--agent NAME` repeatedly to select only the configurations you want:

```bash
toolboxer create --agent codex --agent claude -m ~/code/project:/work coding
```

Names: `claude codex gemini qwen cursor grok continue copilot goose opencode crush
aider llm sgpt interpreter`. `-A/--ai-agents` without a configured selection
shares all supported paths. A config `agents = codex,claude` both selects and
enables sharing; `--no-ai-agents` disables it.

Selected config/data **directories** are bind-mounted read-write; missing ones
are created on the host so logins persist. Individual files such as
`.claude.json` and Aider configuration are private **creation-time snapshots**.
They support atomic replacement inside the container, but changes are not synced
back and are lost on removal unless exported first. Missing individual files
are skipped. Explicit mounts covering those paths take precedence.

Source discovery honors `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `CODEX_HOME`, and
`CLAUDE_CONFIG_DIR`; targets use normal paths under the container home.
Agents themselves must be installed inside the container. Paths are conventions,
not guaranteed support for every version or authentication method. Sharing grants
access to stored credentials and sessions; select narrowly and trust the container.

## Diagnostics and tests

`./diagnose.sh CONTAINER` collects a private, uniquely named log beside the
script. Use `-o NEW_FILE` to choose a new path; existing files are never overwritten.
Default checks avoid login profiles, credential/config dumps, agent execution,
and write probes. `--write-probes` creates/removes temporary probe files;
`--agent-versions` executes installed agent code. Podman commands are time-bounded.
Logs still include usernames, paths, process/mount metadata, and command output:
review before sharing. Stopped containers are inspected without starting them.

```bash
make test                 # Safe unit/regression tests; never calls real Podman
make lint                 # ShellCheck plus Bash syntax checks
./tests/test_toolboxer.sh  # Live integration; pulls images and creates containers
./tests/test_isolation.sh # Live isolation/workdir/concurrency and integrated-runtime regressions
```

Python 3.9+ is required for regression tests, and ShellCheck for linting. The live
tests require working rootless Podman and use temporary fixtures. Pulled images
are retained. CI is configured to run the supported container-image matrix on
a single Ubuntu 24.04 host with its packaged Podman, without retrying entire
failed suites. This is not a cross-distribution host certification: Fedora,
Debian, Arch, openSUSE, and other hosts need live runs too. Run isolation tests on
an enforcing SELinux host as well as a non-SELinux host; Ubuntu-only CI cannot
validate enforcement.

## License

MIT — see [LICENSE](LICENSE).
