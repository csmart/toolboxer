#!/usr/bin/env bash
# Collect a shareable toolboxer diagnostic log without reading credentials or
# dumping arbitrary environment/configuration values.
# Quoted scripts below expand variables in the target shell, not this one.
# shellcheck disable=SC2016

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINER_NAME="${CONTAINER_NAME:-coding}"
OUTPUT="${TOOLBOXER_DIAGNOSTICS_LOG:-}"
WRITE_PROBES=false
AGENT_VERSIONS=false
TOOLBOXER_BIN=""
POSITIONAL_CONTAINER=""
PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

usage() {
    cat <<EOF
Usage: $(basename "$0") [options] [CONTAINER]

Collect host and container diagnostics in a shareable log. The collector does
not read agent credentials, auth files, shell history, or provision contents.

Options:
  -c, --container NAME  Container to inspect (default: $CONTAINER_NAME)
  -o, --output FILE     New log file (default: a unique file beside this script)
      --write-probes    Create and remove temporary files to test writability
      --agent-versions  Run installed agents with --version (executes their code)
  -h, --help            Show this help

Example:
  $(basename "$0") coding
  $(basename "$0") -c coding -o ~/code/toolboxer-diagnostics.log
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--container)
            [[ $# -ge 2 ]] || { echo "Error: $1 requires a name." >&2; exit 2; }
            CONTAINER_NAME="$2"
            shift 2
            ;;
        -o|--output)
            [[ $# -ge 2 ]] || { echo "Error: $1 requires a path." >&2; exit 2; }
            OUTPUT="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --write-probes) WRITE_PROBES=true; shift ;;
        --agent-versions) AGENT_VERSIONS=true; shift ;;
        -*)
            echo "Error: unknown option '$1'." >&2
            usage >&2
            exit 2
            ;;
        *)
            if [[ -n "$POSITIONAL_CONTAINER" ]]; then
                echo "Error: only one container may be specified." >&2
                exit 2
            fi
            POSITIONAL_CONTAINER="$1"
            CONTAINER_NAME="$1"
            shift
            ;;
    esac
done

umask 077
if [[ -z "$OUTPUT" ]]; then
    OUTPUT="$(mktemp "$SCRIPT_DIR/toolboxer-diagnostics.XXXXXX.log")" || exit 1
else
    [[ "$OUTPUT" == /* ]] || OUTPUT="$PWD/$OUTPUT"
    mkdir -p "$(dirname "$OUTPUT")" || exit 1
    if ! (set -o noclobber; : > "$OUTPUT"); then
        echo "Error: cannot create '$OUTPUT'; choose a new log path." >&2
        exit 1
    fi
fi
exec > >(tee -a "$OUTPUT") 2>&1

section() {
    printf '\n===== %s =====\n' "$1"
}

pass() {
    ((PASS_COUNT++)) || true
    printf 'PASS: %s\n' "$1"
}

warn() {
    ((WARN_COUNT++)) || true
    printf 'WARN: %s\n' "$1"
}

fail() {
    ((FAIL_COUNT++)) || true
    printf 'FAIL: %s\n' "$1"
}

show_command() {
    local label="$1"
    shift
    printf '\n-- %s --\n' "$label"
    "$@"
    local status=$?
    if [[ $status -ne 0 ]]; then
        warn "$label exited with status $status"
    fi
    return 0
}

container_write_probe() {
    local directory="$1" uid_gid="$2" container_home="$3"
    if podman exec --user "$uid_gid" --env "HOME=$container_home" \
        "$CONTAINER_NAME" sh -c '
            directory="$1"
            [ -d "$directory" ] || exit 2
            probe="$(umask 077; mktemp "$directory/.toolboxer-write-probe.XXXXXX")" || exit 1
            rm -f -- "$probe"
        ' sh "$directory"; then
        pass "write probe: $directory"
    else
        local status=$?
        if [[ $status -eq 2 ]]; then
            warn "write probe skipped; directory missing: $directory"
        else
            fail "write probe: $directory"
        fi
    fi
}

print_summary() {
    section "Summary"
    printf 'PASS=%d WARN=%d FAIL=%d\n' "$PASS_COUNT" "$WARN_COUNT" "$FAIL_COUNT"
    printf 'log=%s\n' "$OUTPUT"
}

section "Collector"
printf 'timestamp=%s\n' "$(date --iso-8601=seconds 2>/dev/null || date)"
printf 'script=%s\n' "$0"
printf 'container=%s\n' "$CONTAINER_NAME"
printf 'output=%s\n' "$OUTPUT"
printf 'privacy=No credential, auth, history, or provision-script contents collected.\n'

if [[ -f /run/.containerenv ]]; then
    current_container="$(awk -F= '$1 == "name" { gsub(/^"|"$/, "", $2); print $2; exit }' /run/.containerenv 2>/dev/null)"
    warn "collector appears to be running inside container '${current_container:-unknown}'; run it on the host if '$CONTAINER_NAME' is not visible"
else
    pass "collector is running outside a detectable container"
fi

section "Host"
show_command "identity" id
show_command "kernel" uname -a
if [[ -r /etc/os-release ]]; then
    show_command "operating system" sh -c \
        '. /etc/os-release; printf "ID=%s\nVERSION_ID=%s\nPRETTY_NAME=%s\n" "${ID:-}" "${VERSION_ID:-}" "${PRETTY_NAME:-}"'
fi
printf 'HOME=%s\n' "$HOME"
printf 'SHELL=%s\n' "${SHELL:-unknown}"
printf 'XDG_RUNTIME_DIR=%s\n' "${XDG_RUNTIME_DIR:-unset}"

section "Toolboxer"
if command -v toolboxer >/dev/null 2>&1; then
    TOOLBOXER_BIN="$(command -v toolboxer)"
elif [[ -x "$SCRIPT_DIR/toolboxer" ]]; then
    TOOLBOXER_BIN="$SCRIPT_DIR/toolboxer"
fi

if [[ -n "$TOOLBOXER_BIN" ]]; then
    pass "toolboxer executable found: $TOOLBOXER_BIN"
    show_command "resolved executable" readlink -f "$TOOLBOXER_BIN"
    if command -v sha256sum >/dev/null 2>&1; then
        show_command "toolboxer checksums" sha256sum "$TOOLBOXER_BIN" "$SCRIPT_DIR/toolboxer"
    fi
    printf 'toolboxerConfigPath=%s\n' "${TOOLBOXER_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/toolboxer/config}"
else
    fail "toolboxer executable not found"
fi

if command -v git >/dev/null 2>&1 && git -C "$SCRIPT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    show_command "repository revision" git -C "$SCRIPT_DIR" log -1 --oneline --decorate
    show_command "repository status" git -C "$SCRIPT_DIR" status --short
fi

for subid_file in /etc/subuid /etc/subgid; do
    if [[ -r "$subid_file" ]]; then
        show_command "$subid_file metadata" stat -c '%A %u:%g %n' "$subid_file"
        printf -- '-- entries for current user --\n'
        awk -F: -v name="$(id -un)" -v uid="$(id -u)" \
            '$1 == name || $1 == uid { print }' "$subid_file"
    else
        warn "$subid_file is absent or unreadable"
    fi
done

section "Podman"
PODMAN_BIN="$(type -P podman || true)"
if [[ -z "$PODMAN_BIN" ]]; then
    fail "podman is not installed or not in PATH"
    print_summary
    exit 1
fi

if ! command -v timeout >/dev/null 2>&1; then
    fail 'timeout is required for bounded Podman diagnostics'
    print_summary
    exit 1
fi
podman() { command timeout -k 2s 10s "$PODMAN_BIN" "$@"; }
pass "podman executable found: $PODMAN_BIN"
show_command "podman version" podman version
show_command "selected podman host/storage information" podman info --format \
    'rootless={{.Host.Security.Rootless}} cgroupVersion={{.Host.CgroupsVersion}} cgroupManager={{.Host.CgroupManager}} graphDriver={{.Store.GraphDriverName}} graphRoot={{.Store.GraphRoot}} runRoot={{.Store.RunRoot}} networkBackend={{.Host.NetworkBackend}}'
show_command "toolboxer containers" podman ps -a \
    --filter label=toolboxer=true \
    --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'

if ! podman container exists "$CONTAINER_NAME"; then
    fail "container '$CONTAINER_NAME' does not exist in this Podman context"
    print_summary
    exit 1
fi
pass "container '$CONTAINER_NAME' exists"

state="$(podman inspect --format '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null)"
printf 'state=%s\n' "${state:-unknown}"
show_command "container identity/configuration" podman inspect --format \
    'name={{.Name}} image={{.ImageName}} created={{.Created}} status={{.State.Status}} configUser={{.Config.User}} workingDir={{.Config.WorkingDir}} privileged={{.HostConfig.Privileged}} usernsMode={{.HostConfig.UsernsMode}} networkMode={{.HostConfig.NetworkMode}} pidMode={{.HostConfig.PidMode}} ipcMode={{.HostConfig.IpcMode}} securityOpt={{.HostConfig.SecurityOpt}} idMappings={{.HostConfig.IDMappings}}' \
    "$CONTAINER_NAME"

if saved_env="$(podman inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$CONTAINER_NAME")"; then
    printf '%s\n' "$saved_env" | awk '/^(HOME|PATH)=/'
else
    warn 'could not inspect saved HOME/PATH'
fi
unset saved_env

show_command "mounts" podman inspect --format \
    '{{range .Mounts}}{{printf "%s\tRW=%v\t%s <- %s\n" .Type .RW .Destination .Source}}{{end}}' \
    "$CONTAINER_NAME"

if [[ "$state" != running ]]; then
    warn "container is not running; exec-based checks were skipped"
    print_summary
    [[ $FAIL_COUNT -eq 0 ]] && exit 0 || exit 1
fi
pass "container is running"

section "Container user and mappings"
host_uid="$(id -u)"
host_gid="$(id -g)"
uid_gid="$host_uid:$host_gid"
passwd_line="$(podman exec --user 0 "$CONTAINER_NAME" getent passwd "$host_uid" 2>/dev/null || true)"
if [[ -n "$passwd_line" ]]; then
    printf 'passwd=%s\n' "$passwd_line"
    container_user="${passwd_line%%:*}"
    container_home="$(cut -d: -f6 <<< "$passwd_line")"
    container_shell="$(cut -d: -f7 <<< "$passwd_line")"
else
    container_user="$(id -un)"
    container_home="$HOME"
    container_shell="unknown"
    fail "no passwd entry for host UID $host_uid"
fi
printf 'expectedUidGid=%s\ncontainerUser=%s\ncontainerHome=%s\ncontainerShell=%s\n' \
    "$uid_gid" "$container_user" "$container_home" "$container_shell"

user_identity="$(podman exec --user "$uid_gid" --env "HOME=$container_home" \
    "$CONTAINER_NAME" id 2>&1 || true)"
printf 'userIdentity=%s\n' "$user_identity"
if [[ "$user_identity" == *"uid=$host_uid("* && "$user_identity" == *"gid=$host_gid("* ]]; then
    pass "container user UID/GID match the host"
else
    fail "container user UID/GID do not match the host"
fi

show_command "root exec uid_map/gid_map" podman exec --user 0 "$CONTAINER_NAME" sh -c \
    'printf "uid_map:\n"; cat /proc/self/uid_map; printf "gid_map:\n"; cat /proc/self/gid_map'

section "Home ownership and writability"
show_command "path metadata" podman exec --user 0 "$CONTAINER_NAME" sh -c '
    for path do
        if [ -e "$path" ] || [ -L "$path" ]; then
            stat -c "%A %u:%g %n" "$path"
        else
            printf "MISSING %s\n" "$path"
        fi
    done
' sh \
    "$container_home" \
    "$container_home/.local" \
    "$container_home/.local/bin" \
    "$container_home/.local/share" \
    "$container_home/.local/share/claude" \
    "$container_home/.cache" \
    "$container_home/.config" \
    "$container_home/.claude" \
    "$container_home/.codex" \
    "/etc/sudoers" \
    "/etc/sudoers.d" \
    "/etc/sudoers.d/$container_user" \
    "/etc/sudoers.d/toolboxer" \
    "/etc/.toolboxer-setup-v1" \
    "/etc/.toolboxer-provisioned-v1" \
    "/etc/.toolboxer-home-repaired-v2" \
    "/etc/profile.d/toolboxer.sh"

if podman exec --user 0 "$CONTAINER_NAME" sh -c 'command -v namei' >/dev/null 2>&1; then
    show_command "home path ancestors" podman exec --user 0 "$CONTAINER_NAME" \
        namei -l "$container_home/.local/share/claude"
fi

for probe_directory in \
    "$container_home" \
    "$container_home/.local" \
    "$container_home/.local/bin" \
    "$container_home/.local/share" \
    "$container_home/.cache"; do
    if [[ "$WRITE_PROBES" == true ]]; then
        container_write_probe "$probe_directory" "$uid_gid" "$container_home"
    elif podman exec --user "$uid_gid" "$CONTAINER_NAME" test -w "$probe_directory"; then
        pass "writability permission check: $probe_directory"
    else
        warn "directory missing or not writable: $probe_directory"
    fi
done

section "Sudo and shell environment"
show_command "sudo executable metadata" podman exec --user 0 "$CONTAINER_NAME" sh -c '
    sudo_bin="$(command -v sudo)" || exit 1
    printf "sudo=%s\n" "$sudo_bin"
    stat -c "%F %u:%g %a %n" "$sudo_bin" || exit
    stat -Lc "%F %u:%g %a %n" "$sudo_bin"
'
if podman exec --user "$uid_gid" --env "HOME=$container_home" \
    "$CONTAINER_NAME" sudo -n true >/dev/null 2>&1; then
    pass "passwordless sudo works"
else
    fail "passwordless sudo failed"
fi

show_command "exec HOME/PATH (without loading shell profiles)" podman exec --user "$uid_gid" \
    --env "HOME=$container_home" "$CONTAINER_NAME" bash --noprofile --norc -c \
    'printf "HOME=%s\nPATH=%s\n" "$HOME" "$PATH"'

section "AI agent commands"
for agent_command in claude codex agent; do
    agent_path="$(podman exec --user "$uid_gid" --env "HOME=$container_home" \
        "$CONTAINER_NAME" sh -c \
        'PATH="$HOME/.local/bin:$PATH"; command -v "$1"' sh "$agent_command" 2>/dev/null || true)"
    if [[ -z "$agent_path" ]]; then
        warn "$agent_command is not installed or not in user PATH"
        continue
    fi
    pass "$agent_command found: $agent_path"
    [[ "$AGENT_VERSIONS" == true ]] || continue
    printf -- '-- %s --version --\n' "$agent_command"
    version_output="$(podman exec --user "$uid_gid" \
        --env "HOME=$container_home" "$CONTAINER_NAME" sh -c \
        'PATH="$HOME/.local/bin:$PATH"; exec "$1" --version' sh "$agent_command" \
        2>&1)"
    version_status=$?
    printf '%s\n' "$version_output" | sed -n '1,5p'
    if [[ $version_status -ne 0 ]]; then
        warn "$agent_command --version exited with status $version_status"
    fi
done

section "Runtime essentials"
for required_command in bash sh curl git; do
    if podman exec --user "$uid_gid" "$CONTAINER_NAME" \
        sh -c 'command -v "$1"' sh "$required_command" >/dev/null 2>&1; then
        pass "container command available: $required_command"
    else
        warn "container command missing: $required_command"
    fi
done
show_command "home filesystem usage" podman exec --user "$uid_gid" \
    "$CONTAINER_NAME" df -h "$container_home"

for hostname in claude.ai chatgpt.com cursor.com; do
    if podman exec --user "$uid_gid" "$CONTAINER_NAME" \
        getent ahosts "$hostname" >/dev/null 2>&1; then
        pass "container DNS resolves: $hostname"
    else
        warn "container DNS did not resolve within 10 seconds: $hostname"
    fi
done

print_summary
if [[ $FAIL_COUNT -eq 0 ]]; then
    printf 'result=healthy (review WARN entries for optional/missing components)\n'
    exit 0
fi
printf 'result=problems detected\n'
exit 1
