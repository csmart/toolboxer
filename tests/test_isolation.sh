#!/usr/bin/env bash
# Live regressions: requires a working local rootless Podman host.
set -euo pipefail

if [[ -n "${TOOLBOXER_SKIP_PODMAN:-}" ]]; then
    echo 'SKIP: live isolation tests require rootless Podman'
    exit 0
fi

TOOLBOXER="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/toolboxer"
[[ "$(podman info --format '{{.Host.Security.Rootless}}')" == true ]] || exit 1
fixture="$(mktemp -d -t toolboxer-isolation.XXXXXXXX)"
suffix="${fixture##*.}"
containers=()
cleanup() {
    local name
    for name in "${containers[@]}"; do
        podman rm --force --volumes "$name" >/dev/null 2>&1 || true
    done
    rm -rf -- "$fixture"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

export TOOLBOXER_CONFIG=/dev/null
export TOOLBOXER_PROVISION="$fixture/provision.sh"
export XDG_STATE_HOME="$fixture/state" CODEX_HOME="$fixture/codex"
unset IMAGE CONTAINER_NAME MOUNT_DIRS CONTAINER_HOST CONTAINER_CONNECTION
mkdir -p "$fixture/project/child"
printf 'host-only\n' > "$fixture/secret"
cat > "$TOOLBOXER_PROVISION" <<'PROVISION'
set -euo pipefail
echo provisioned >> /work/provision-count
PROVISION

create_test_container() {
    local name="$1" status=0
    shift
    # Never pre-delete a preexisting name. Record the reservation before create
    # so cleanup also handles failures after Podman has created the container.
    podman container exists "$name" || status=$?
    if [[ "$status" != 1 ]]; then
        echo "Cannot reserve test name '$name' (exists or Podman unavailable)." >&2
        exit 1
    fi
    containers+=("$name")
    "$TOOLBOXER" create --image "${TOOLBOXER_TEST_IMAGE:-docker.io/library/ubuntu:24.04}" "$@" "$name"
}

isolated="toolboxer-isolation-$suffix"
create_test_container "$isolated" --isolated --agent codex -m "$fixture/project:/work"

# First-use setup and provisioning must serialize across independent processes.
"$TOOLBOXER" run -c "$isolated" printf first > "$fixture/first.out" 2> "$fixture/first.err" &
first=$!
"$TOOLBOXER" run -c "$isolated" printf second > "$fixture/second.out" 2> "$fixture/second.err" &
second=$!
status=0
wait "$first" || status=1
wait "$second" || status=1
if [[ "$status" != 0 ]]; then
    cat "$fixture/first.err" "$fixture/second.err" >&2
    exit 1
fi
[[ "$(< "$fixture/first.out")" == first && "$(< "$fixture/second.out")" == second ]]
[[ "$(wc -l < "$fixture/project/provision-count")" == 1 ]]
echo 'PASS: concurrent initialization provisions once and preserves stdout'

[[ "$(cd "$fixture" && "$TOOLBOXER" run -c "$isolated" pwd)" == /work ]]
[[ "$(cd "$fixture/project/child" && "$TOOLBOXER" run -c "$isolated" pwd)" == /work/child ]]
"$TOOLBOXER" run -c "$isolated" test ! -e "$fixture/secret"
"$TOOLBOXER" run -c "$isolated" sudo -n true
# Expand HOME in the container, not in this test process.
# shellcheck disable=SC2016
"$TOOLBOXER" run -c "$isolated" sh -c 'echo persisted > "$HOME/.codex/fixture"'
[[ "$(< "$CODEX_HOME/fixture")" == persisted ]]
echo 'PASS: saved/mapped workdirs, unmounted host path, sudo and agent-directory sharing'

for namespace in net pid ipc uts; do
    host_ns="$(readlink "/proc/self/ns/$namespace")"
    container_ns="$("$TOOLBOXER" run -c "$isolated" readlink "/proc/self/ns/$namespace")"
    [[ "$host_ns" != "$container_ns" ]]
done
[[ "$(podman inspect --format '{{.HostConfig.Privileged}}' "$isolated")" == false ]]
if [[ "$(podman info --format '{{.Host.Security.SELinuxEnabled}}')" == true ]]; then
    [[ "$(podman inspect --format '{{.ProcessLabel}}' "$isolated")" == *:container_t:* ]]
    echo "PASS: SELinux process label (host mode: $(getenforce))"
else
    echo 'SKIP: SELinux label/enforcement checks need an SELinux-enabled host'
fi
echo 'PASS: isolated namespaces differ from the host'

status=0
"$TOOLBOXER" run -c "$isolated" sh -c 'exit 37' || status=$?
[[ "$status" == 37 ]]
"$TOOLBOXER" provision "$isolated"
[[ "$(wc -l < "$fixture/project/provision-count")" == 2 ]]

integrated="toolboxer-integrated-$suffix"
create_test_container "$integrated" -m "$fixture/project:/work"
if "$TOOLBOXER" --isolated run -c "$integrated" true; then
    echo 'FAIL: --isolated accepted an integrated container' >&2
    exit 1
fi
[[ "$(podman inspect --format '{{.State.Status}}' "$integrated")" == configured || \
   "$(podman inspect --format '{{.State.Status}}' "$integrated")" == created ]]
echo 'PASS: mode mismatch rejected without starting the container'

# Integrated runtime tmpfs must be usable by the non-root user on first start,
# after a toolboxer start, and after a direct Podman restart (tmpfs is recreated).
runtime_dir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
for startup in first toolboxer external; do
    if [[ "$startup" == toolboxer ]]; then
        # Reproduce host-owned image sudo metadata with a valid keep-id map.
        # Only this suite's disposable integrated container is modified.
        # shellcheck disable=SC2016
        podman exec --user 0 "$integrated" sh -eu -c '
            sudo_bin="$(command -v sudo)"
            printf "# preserve existing policy\n" > /etc/sudoers.d/toolboxer-test-policy
            for path in "$sudo_bin" /etc/sudoers /etc/sudo.conf /etc/sudoers.d /etc/sudoers.d/toolboxer-test-policy; do
                [ ! -e "$path" ] || chown "$1" "$path"
            done
            chmod 0111 "$sudo_bin"
            chmod 0750 /etc/sudoers.d
            rm /etc/.toolboxer-setup-v1
        ' sh "$(id -u):$(id -g)"
    fi
    if [[ "$startup" != first ]]; then
        podman stop --time 1 "$integrated" >/dev/null
    fi
    if [[ "$startup" == external ]]; then
        podman start "$integrated" >/dev/null
    fi
    [[ "$("$TOOLBOXER" run -c "$integrated" stat -c '%u:%g %a' "$runtime_dir")" == "$(id -u):$(id -g) 700" ]]
    # shellcheck disable=SC2016
    "$TOOLBOXER" run -c "$integrated" sh -eu -c 'touch "$1/toolboxer-test"; rm "$1/toolboxer-test"' sh "$runtime_dir"
    "$TOOLBOXER" run -c "$integrated" test ! -e "$runtime_dir/podman/podman.sock"
done
echo 'PASS: integrated runtime is private and user-writable across restarts'
[[ "$(podman exec --user 0 "$integrated" cat /etc/sudoers.d/toolboxer-test-policy)" == '# preserve existing policy' ]]
"$TOOLBOXER" run -c "$integrated" sudo -n true
echo 'PASS: host-owned execute-only sudo metadata is repaired without deleting existing policy'

export TOOLBOXER_PROVISION=/nonexistent/toolboxer-provision
file_only="toolboxer-file-only-$suffix"
create_test_container "$file_only" --isolated -m "$fixture/secret:/fixture-file"
[[ "$(cd "$fixture" && "$TOOLBOXER" run -c "$file_only" pwd)" == /tmp ]]
[[ "$("$TOOLBOXER" run -c "$file_only" cat /fixture-file)" == host-only ]]
echo 'PASS: file-only mounts have a usable workdir'

echo 'All live isolation regressions passed.'
