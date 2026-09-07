#!/usr/bin/env bash
# Basic smoke tests for toolboxer
# Requires podman to be installed and working (rootless)
set -euo pipefail

# Unit tests must never reach the host's Podman, including EXIT cleanup.
# Only the explicitly selected integration section restores the real command.
podman() { return 127; }
export -f podman
export TOOLBOXER_CONFIG=/dev/null TOOLBOXER_PROVISION=/nonexistent/toolboxer-provision
unset CONTAINER_NAME IMAGE MOUNT_DIRS

TOOLBOXER="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/toolboxer"
TEST_SUFFIX="$-$RANDOM-$RANDOM"
TEST_NAME="toolboxer-test-$TEST_SUFFIX"
TEST_CONTAINERS=()
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Colours
RED='\033[0;31m'
GREEN='\033[0;32m'
RESET='\033[0m'

pass() {
    # `((x++))` returns the *old* value, so when the counter is 0 it returns 0
    # → exit code 1 → set -e kills the script. The `|| true` neutralises that.
    ((TESTS_PASSED++)) || true
    echo -e "  ${GREEN}PASS${RESET}: $1"
}

fail() {
    ((TESTS_FAILED++)) || true
    echo -e "  ${RED}FAIL${RESET}: $1"
    [[ -n "${2:-}" ]] && echo "        $2"
    # Always succeed: a failing last command (the [[ ]] above when $2 is unset)
    # would otherwise abort the whole suite under 'set -e' on the first failure.
    return 0
}

run_test() {
    ((TESTS_RUN++)) || true
}

# Exact point releases and codenames must match. Integer requests allow the
# floating minor of that major (e.g. Rocky 9 -> 9.3).
release_matches() {
    local cver="$1" ccode="$2" req="$3"
    if [[ "$cver" == "$req" ]] \
        || [[ -n "$ccode" && "$ccode" == "$req" ]] \
        || [[ "$req" =~ ^[0-9]+$ && "${cver%%.*}" == "$req" ]]; then
        return 0
    fi
    return 1
}

reserve_test_name() {
    local name="$1" status=0
    podman container exists "$name" || status=$?
    if [[ "$status" != 1 ]]; then
        echo "Cannot reserve test name '$name' (exists or Podman unavailable)." >&2
        exit 1
    fi
    TEST_CONTAINERS+=("$name")
}

cleanup() {
    local name
    for name in "${TEST_CONTAINERS[@]}"; do
        podman rm --force --volumes "$name" >/dev/null 2>&1 || true
    done
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
echo "=== CLI tests (no podman needed) ==="

run_test
if output="$("$TOOLBOXER" --help 2>&1)" && grep -q "Commands:" <<< "$output"; then
    pass "--help shows usage"
else
    fail "--help shows usage"
fi

run_test
if output="$("$TOOLBOXER" help 2>&1)" && grep -q "Commands:" <<< "$output"; then
    pass "help command shows usage"
else
    fail "help command shows usage"
fi

run_test
DIAGNOSE="$(dirname "$TOOLBOXER")/diagnose.sh"
diagnose_help="$("$DIAGNOSE" --help 2>&1 || true)"
if bash -n "$DIAGNOSE" && grep -q "shareable log" <<< "$diagnose_help"; then
    pass "diagnostic collector parses and shows help"
else
    fail "diagnostic collector parses and shows help"
fi

run_test
if output="$("$TOOLBOXER" create --help 2>&1)" && grep -q -- "--distro" <<< "$output"; then
    pass "create --help shows --distro"
else
    fail "create --help shows --distro"
fi

run_test
if output="$("$TOOLBOXER" enter --help 2>&1)" && grep -q -- "--release" <<< "$output"; then
    pass "enter --help shows --release"
else
    fail "enter --help shows --release"
fi

run_test
if output="$("$TOOLBOXER" run --help 2>&1)" && grep -q -- "--container" <<< "$output"; then
    pass "run --help shows --container"
else
    fail "run --help shows --container"
fi

run_test
# `|| true` so the non-zero exit from toolboxer doesn't trip pipefail on the
# `... | grep` pipeline below — we only care whether the error message printed.
output="$("$TOOLBOXER" badcommand 2>&1 || true)"
if grep -q "Unknown command" <<<"$output"; then
    pass "unknown command prints error"
else
    fail "unknown command prints error"
fi

run_test
output="$("$TOOLBOXER" create --image foo --distro fedora 2>&1 || true)"
if grep -q "incompatible" <<<"$output"; then
    pass "--image and --distro are incompatible"
else
    fail "--image and --distro are incompatible"
fi

run_test
# An unrecognised --distro is rejected (before any pull), not silently resolved
# to Fedora via the host-ID_LIKE fallback. A known alias must still be accepted.
output="$("$TOOLBOXER" create -d bubuntu 2>&1 || true)"
if grep -q "unknown distro 'bubuntu'" <<<"$output"; then
    pass "unknown --distro is rejected"
else
    fail "unknown --distro is rejected"
fi

run_test
# The same validation lives in finalize_names, so it applies to every command
# that takes -d, not just create.
output="$("$TOOLBOXER" enter -d bubuntu 2>&1 || true)"
if grep -q "unknown distro 'bubuntu'" <<<"$output"; then
    pass "unknown --distro is rejected by other commands too (enter)"
else
    fail "unknown --distro is rejected by other commands too (enter)"
fi

run_test
# A pinned release on a rolling distro (no versioned tags) is rejected, rather
# than quietly handing over today's :latest under a stale version. (The release-
# less positive case is covered below and by the arch entry in the matrix.)
output="$("$TOOLBOXER" create -d arch -r 2022 2>&1 || true)"
if grep -qi "rolling release" <<<"$output"; then
    pass "rolling distro rejects a pinned release"
else
    fail "rolling distro rejects a pinned release"
fi

run_test
# The other rolling distro, reached via an alias — proves the rolling check runs
# after canonicalisation (tumbleweed -> opensuse-tumbleweed).
output="$("$TOOLBOXER" create -d tumbleweed -r 20240101 2>&1 || true)"
if grep -qi "rolling release" <<<"$output"; then
    pass "rolling distro rejects a pinned release via an alias (tumbleweed)"
else
    fail "rolling distro rejects a pinned release via an alias (tumbleweed)"
fi

run_test
if output="$("$TOOLBOXER" --help 2>&1)" && grep -q "config" <<< "$output"; then
    pass "--help lists the config command"
else
    fail "--help lists the config command"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Host subuid/subgid preflight (no podman needed) ==="

# Source the helpers (same pattern as the image-resolution tests) so we can
# assert mapping logic without going through create. Paths are temp files we
# own; ownership-by-root is covered via the CLI check on empty files below.
SUBID_SRC="$(mktemp)"
sed -n \
    '/^SUBID_MIN_COUNT=/p; /^subid_file_maps_user() {/,/^}/p; /^subid_file_root_owned() {/,/^}/p; /^host_subid_range_ok() {/,/^}/p' \
    "$TOOLBOXER" > "$SUBID_SRC"
# shellcheck source=/dev/null
source "$SUBID_SRC"
rm -f "$SUBID_SRC"

SUBID_TMP="$(mktemp -d)"
cleanup_subid() { rm -rf "$SUBID_TMP"; }
trap 'cleanup; cleanup_subid' EXIT

me="$(id -un)"
myuid="$(id -u)"

run_test
: > "$SUBID_TMP/empty"
if ! subid_file_maps_user "$SUBID_TMP/empty"; then
    pass "subid mapping rejects an empty file"
else
    fail "subid mapping rejects an empty file"
fi

run_test
echo "otheruser:100000:65536" > "$SUBID_TMP/other"
if ! subid_file_maps_user "$SUBID_TMP/other"; then
    pass "subid mapping rejects a range for a different user"
else
    fail "subid mapping rejects a range for a different user"
fi

run_test
echo "$me:100000:1" > "$SUBID_TMP/tiny"
if ! subid_file_maps_user "$SUBID_TMP/tiny"; then
    pass "subid mapping rejects a too-small range"
else
    fail "subid mapping rejects a too-small range"
fi

run_test
echo "$me:100000:65536" > "$SUBID_TMP/ok"
if subid_file_maps_user "$SUBID_TMP/ok"; then
    pass "subid mapping accepts a 65536-UID range by name"
else
    fail "subid mapping accepts a 65536-UID range by name"
fi

run_test
echo "$myuid:100000:65536" > "$SUBID_TMP/byuid"
if subid_file_maps_user "$SUBID_TMP/byuid"; then
    pass "subid mapping accepts a range keyed by numeric uid"
else
    fail "subid mapping accepts a range keyed by numeric uid"
fi

run_test
# create must warn (and still proceed) when the host range is unusable. Empty
# user-owned files reproduce the Fedora case (uid-owned /etc/subuid). Clean up
# in case Podman is present and create continues past the warning.
: > "$SUBID_TMP/subuid"
: > "$SUBID_TMP/subgid"
output="$(SUBUID_FILE="$SUBID_TMP/subuid" SUBGID_FILE="$SUBID_TMP/subgid" \
    TOOLBOXER_CONFIG=/nonexistent "$TOOLBOXER" create -m "$SUBID_TMP/mount" subid-preflight-test 2>&1 || true)"
"$TOOLBOXER" rm -f subid-preflight-test >/dev/null 2>&1 || true
if grep -q "no usable subuid/subgid range" <<<"$output" \
    && grep -q "usermod --add-subuids" <<<"$output" \
    && grep -qi "warning" <<<"$output"; then
    pass "create warns with a host-side subuid fix when the range is missing"
else
    fail "create warns with a host-side subuid fix when the range is missing"
fi

run_test
# Validation that does not need a container still runs first: an unknown
# --distro must not be masked by the subuid check.
output="$(SUBUID_FILE="$SUBID_TMP/subuid" SUBGID_FILE="$SUBID_TMP/subgid" \
    "$TOOLBOXER" create -d bubuntu 2>&1 || true)"
if grep -q "unknown distro 'bubuntu'" <<<"$output"; then
    pass "unknown --distro is still rejected before the subuid check"
else
    fail "unknown --distro is still rejected before the subuid check"
fi

run_test
if output="$("$TOOLBOXER" provision --help 2>&1)" && grep -q "provision script" <<< "$output"; then
    pass "provision --help shows usage"
else
    fail "provision --help shows usage"
fi

# rm needs an explicit target (like toolbox): a bare 'rm' errors before podman
# is touched, while a name/-d/-r resolves a target and gets past that guard.
run_test
output="$(TOOLBOXER_CONFIG=/nonexistent "$TOOLBOXER" rm 2>&1 || true)"
if grep -q "missing argument" <<<"$output"; then
    pass "bare rm errors with missing argument"
else
    fail "bare rm errors with missing argument"
fi

run_test
output="$(TOOLBOXER_CONFIG=/nonexistent "$TOOLBOXER" rm -r 44 2>&1 || true)"
if ! grep -q "missing argument" <<<"$output"; then
    pass "rm -r resolves a target (no missing-argument error)"
else
    fail "rm -r resolves a target (no missing-argument error)"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== File mounts (no podman needed) ==="

ENSURE_SRC="$(mktemp)"
sed -n '/^ensure_mount_source() {/,/^}/p' "$TOOLBOXER" > "$ENSURE_SRC"
# shellcheck source=/dev/null
source "$ENSURE_SRC"
rm -f "$ENSURE_SRC"

MOUNT_TMP="$(mktemp -d)"
cleanup_mounttmp() { rm -rf "$MOUNT_TMP"; }
trap 'cleanup; cleanup_subid; cleanup_mounttmp' EXIT

run_test
mkdir -p "$MOUNT_TMP/missing/parent"
ensure_mount_source "$MOUNT_TMP/missing/parent/newdir"
if [[ -d "$MOUNT_TMP/missing/parent/newdir" ]]; then
    pass "ensure_mount_source creates a missing directory"
else
    fail "ensure_mount_source creates a missing directory"
fi

run_test
echo contents > "$MOUNT_TMP/gitconfig"
if ensure_mount_source "$MOUNT_TMP/gitconfig" \
    && [[ -f "$MOUNT_TMP/gitconfig" ]] \
    && [[ "$(cat "$MOUNT_TMP/gitconfig")" == contents ]]; then
    pass "ensure_mount_source leaves an existing file intact"
else
    fail "ensure_mount_source leaves an existing file intact"
fi

run_test
mkdir -p "$MOUNT_TMP/already"
if ensure_mount_source "$MOUNT_TMP/already" && [[ -d "$MOUNT_TMP/already" ]]; then
    pass "ensure_mount_source accepts an existing directory"
else
    fail "ensure_mount_source accepts an existing directory"
fi


# ---------------------------------------------------------------------------
echo ""
echo "=== AI agent paths (no podman needed) ==="

AGENT_SRC="$(mktemp)"
sed -n '/^ensure_ai_agent_source() {/,/^}/p; /^AI_AGENT_PATHS=(/,/^)$/p; /^build_ai_agent_args() {/,/^}/p; /^agent_selected() {/,/^}/p; /^agent_source() {/,/^}/p; /^validate_agent_source() {/,/^}/p; /^mount_covers() {/,/^}/p' "$TOOLBOXER" > "$AGENT_SRC"
# shellcheck source=/dev/null
source "$AGENT_SRC"
# Used by the sourced mount_covers helper.
# shellcheck disable=SC2034
MOUNT_SPECS=()
rm -f "$AGENT_SRC"

AGENT_TMP="$(mktemp -d)"
cleanup_agenttmp() { rm -rf "$AGENT_TMP"; }
trap 'cleanup; cleanup_subid; cleanup_mounttmp; cleanup_agenttmp' EXIT

run_test
ensure_ai_agent_source "$AGENT_TMP/.codex" ".codex"
if [[ -d "$AGENT_TMP/.codex" ]]; then
    pass "ensure_ai_agent_source creates a missing directory (.codex)"
else
    fail "ensure_ai_agent_source creates a missing directory (.codex)"
fi

run_test
ensure_ai_agent_source "$AGENT_TMP/.config/cursor" ".config/cursor"
if [[ -d "$AGENT_TMP/.config/cursor" ]]; then
    pass "ensure_ai_agent_source creates nested missing directories"
else
    fail "ensure_ai_agent_source creates nested missing directories"
fi

run_test
ensure_ai_agent_source "$AGENT_TMP/.claude.json" ".claude.json"
if [[ ! -e "$AGENT_TMP/.claude.json" ]]; then
    pass "ensure_ai_agent_source does not create a missing file as a directory"
else
    fail "ensure_ai_agent_source does not create a missing file as a directory"
fi

run_test
ensure_ai_agent_source "$AGENT_TMP/.aider.conf.yml" ".aider.conf.yml"
if [[ ! -e "$AGENT_TMP/.aider.conf.yml" ]]; then
    pass "ensure_ai_agent_source skips missing .yml agent files"
else
    fail "ensure_ai_agent_source skips missing .yml agent files"
fi

run_test
ensure_ai_agent_source "$AGENT_TMP/.config/io.datasette.llm" ".config/io.datasette.llm"
if [[ -d "$AGENT_TMP/.config/io.datasette.llm" ]]; then
    pass "ensure_ai_agent_source creates dotted directory names"
else
    fail "ensure_ai_agent_source creates dotted directory names"
fi

run_test
mkdir -p "$AGENT_TMP/.existing-codex"
echo keep > "$AGENT_TMP/.existing-codex/auth.json"
ensure_ai_agent_source "$AGENT_TMP/.existing-codex" ".codex"
if [[ -d "$AGENT_TMP/.existing-codex" ]] \
    && [[ "$(cat "$AGENT_TMP/.existing-codex/auth.json")" == keep ]]; then
    pass "ensure_ai_agent_source leaves an existing directory intact"
else
    fail "ensure_ai_agent_source leaves an existing directory intact"
fi

run_test
echo '{"ok":true}' > "$AGENT_TMP/.claude.json"
ensure_ai_agent_source "$AGENT_TMP/.claude.json" ".claude.json"
if [[ -f "$AGENT_TMP/.claude.json" ]] \
    && [[ "$(cat "$AGENT_TMP/.claude.json")" == '{"ok":true}' ]]; then
    pass "ensure_ai_agent_source leaves an existing file intact"
else
    fail "ensure_ai_agent_source leaves an existing file intact"
fi

run_test
# --ai-agents must mkdir missing dirs then emit a volume for them, and must
# not mkdir (or mount) missing files such as .claude.json.
fresh="$(mktemp -d)"
# The sourced builder calls this fixture override.
# shellcheck disable=SC2329
output="$(agent_source() { printf '%s/%s\n' "$fresh" "$1"; }; build_ai_agent_args)" || true
if [[ -d "$fresh/.codex" ]] \
    && grep -Fq -- "--volume" <<<"$output" \
    && grep -Fq -- "$fresh/.codex:$HOME/.codex" <<<"$output" \
    && [[ ! -e "$fresh/.claude.json" ]] \
    && ! grep -Fq -- "claude.json" <<<"$output"; then
    pass "build_ai_agent_args creates and mounts missing agent directories"
else
    fail "build_ai_agent_args creates and mounts missing agent directories"
fi
rm -rf "$fresh"

run_test
# Home repair must cover old root-owned content such as ~/.cache while pruning
# paths backed by host mounts. Mock chown so this remains an unprivileged unit
# test and inspect exactly which paths the recursive walk selected.
REPAIR_HOME_SRC="$AGENT_TMP/repair-home-tree.sh"
sed -n '/^repair_home_tree() {/,/^}/p' "$TOOLBOXER" > "$REPAIR_HOME_SRC"
repair_root="$AGENT_TMP/repair-home"
mkdir -p \
    "$repair_root/.cache/downloads" \
    "$repair_root/.local/bin" \
    "$repair_root/.local/share/goose" \
    "$repair_root/.ssh/agent"
touch \
    "$repair_root/.cache/downloads/archive" \
    "$repair_root/.local/share/goose/session" \
    "$repair_root/.ssh/agent/socket"
output="$({
    # shellcheck source=/dev/null
    source "$REPAIR_HOME_SRC"
    # Invoked by the sourced repair_home_tree helper.
    # shellcheck disable=SC2329
    chown() {
        local last=""
        for last in "$@"; do :; done
        printf '<%s>\n' "$last"
    }
    repair_home_tree 123 456 "$repair_root" \
        "$repair_root/.ssh" \
        "$repair_root/.local/share/goose" \
        ""
} 2>&1)"
if grep -Fq "<$repair_root>" <<<"$output" \
    && grep -Fq "<$repair_root/.cache>" <<<"$output" \
    && grep -Fq "<$repair_root/.cache/downloads/archive>" <<<"$output" \
    && grep -Fq "<$repair_root/.local>" <<<"$output" \
    && grep -Fq "<$repair_root/.local/share>" <<<"$output" \
    && ! grep -Fq "<$repair_root/.ssh>" <<<"$output" \
    && ! grep -Fq "<$repair_root/.ssh/agent/socket>" <<<"$output" \
    && ! grep -Fq "<$repair_root/.local/share/goose>" <<<"$output" \
    && ! grep -Fq "<$repair_root/.local/share/goose/session>" <<<"$output"; then
    pass "home repair recurses locally and prunes host mounts"
else
    fail "home repair recurses locally and prunes host mounts" "$output"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Config file tests (no podman needed) ==="

CONFIG_TMP="$(mktemp -d)"
cleanup_config() { rm -rf "$CONFIG_TMP"; }
# Chain config cleanup onto the existing container-cleanup EXIT trap.
trap 'cleanup; cleanup_config; cleanup_subid; cleanup_mounttmp; cleanup_agenttmp' EXIT

# Capture combined output before grepping: `... | grep -q` can SIGPIPE the
# toolboxer process when the match is on an early line, which trips pipefail.
run_test
output="$(TOOLBOXER_CONFIG="$CONFIG_TMP/none" "$TOOLBOXER" config 2>&1 || true)"
if grep -q "not found" <<<"$output"; then
    pass "config reports a missing config file"
else
    fail "config reports a missing config file"
fi

cat > "$CONFIG_TMP/cfg" <<EOF
# toolboxer test config
mount = $CONFIG_TMP/code
ai_agents = true
privileged = true
EOF

run_test
output="$(TOOLBOXER_CONFIG="$CONFIG_TMP/cfg" "$TOOLBOXER" config 2>&1 || true)"
if grep -qE "ai_agents +true" <<<"$output"; then
    pass "config file enables ai_agents"
else
    fail "config file enables ai_agents"
fi

run_test
output="$(TOOLBOXER_CONFIG="$CONFIG_TMP/cfg" "$TOOLBOXER" config 2>&1 || true)"
if grep -qE "privileged +true" <<<"$output"; then
    pass "config file enables privileged"
else
    fail "config file enables privileged"
fi

run_test
output="$(TOOLBOXER_CONFIG="$CONFIG_TMP/cfg" "$TOOLBOXER" config 2>&1 || true)"
if grep -qF "$CONFIG_TMP/code" <<<"$output"; then
    pass "config file sets the mount directory"
else
    fail "config file sets the mount directory"
fi

run_test
# A CLI --no-privileged switches off a config-enabled default.
output="$(TOOLBOXER_CONFIG="$CONFIG_TMP/cfg" "$TOOLBOXER" --no-privileged config 2>&1 || true)"
if grep -qE "privileged +false" <<<"$output"; then
    pass "--no-privileged overrides config privileged"
else
    fail "--no-privileged overrides config privileged"
fi

run_test
# A CLI -m overrides the config-file mount entirely.
output="$(TOOLBOXER_CONFIG="$CONFIG_TMP/cfg" "$TOOLBOXER" -m /tmp/toolboxer-test-xyz config 2>&1 || true)"
if grep -qE "mount +/tmp/toolboxer-test-xyz" <<<"$output"; then
    pass "-m overrides config mount"
else
    fail "-m overrides config mount"
fi

run_test
# A CLI --isolated wins over a config privileged (no mutual-exclusion error).
output="$(TOOLBOXER_CONFIG="$CONFIG_TMP/cfg" "$TOOLBOXER" --isolated config 2>&1 || true)"
if grep -qE "isolated +true" <<<"$output" && grep -qE "privileged +false" <<<"$output"; then
    pass "--isolated overrides config privileged"
else
    fail "--isolated overrides config privileged"
fi

cat > "$CONFIG_TMP/bad" <<EOF
privileged = true
isolated = true
EOF
run_test
output="$(TOOLBOXER_CONFIG="$CONFIG_TMP/bad" "$TOOLBOXER" config 2>&1 || true)"
if grep -q "mutually exclusive" <<<"$output"; then
    pass "config enabling both privileged and isolated errors"
else
    fail "config enabling both privileged and isolated errors"
fi

cat > "$CONFIG_TMP/unknown" <<EOF
nope = 1
EOF
run_test
output="$(TOOLBOXER_CONFIG="$CONFIG_TMP/unknown" "$TOOLBOXER" config 2>&1 || true)"
if grep -q "unknown config key" <<<"$output"; then
    pass "config warns on an unknown key"
else
    fail "config warns on an unknown key"
fi

# Boolean forms: yes/on/1 are truthy, 0 is falsey.
cat > "$CONFIG_TMP/bools" <<EOF
ai_agents  = yes
assumeyes  = on
privileged = 1
isolated   = 0
EOF
run_test
output="$(TOOLBOXER_CONFIG="$CONFIG_TMP/bools" "$TOOLBOXER" config 2>&1 || true)"
if grep -qE "ai_agents +true" <<<"$output" \
    && grep -qE "assumeyes +true" <<<"$output" \
    && grep -qE "privileged +true" <<<"$output" \
    && grep -qE "isolated +false" <<<"$output"; then
    pass "config accepts yes/on/1/0 boolean forms"
else
    fail "config accepts yes/on/1/0 boolean forms"
fi

# An unrecognised boolean warns and is treated as false.
cat > "$CONFIG_TMP/badbool" <<EOF
privileged = maybe
EOF
run_test
output="$(TOOLBOXER_CONFIG="$CONFIG_TMP/badbool" "$TOOLBOXER" config 2>&1 || true)"
if grep -q "invalid boolean" <<<"$output" && grep -qE "privileged +false" <<<"$output"; then
    pass "config warns on an invalid boolean and defaults it off"
else
    fail "config warns on an invalid boolean and defaults it off"
fi

# String keys (image, container_name) are read from the config file.
cat > "$CONFIG_TMP/strs" <<EOF
image          = example.com/img:7
container_name = mybox
EOF
run_test
output="$(TOOLBOXER_CONFIG="$CONFIG_TMP/strs" "$TOOLBOXER" config 2>&1 || true)"
if grep -qE "image +example.com/img:7" <<<"$output" \
    && grep -qE "container +mybox" <<<"$output"; then
    pass "config reads image and container_name"
else
    fail "config reads image and container_name"
fi

# distro/release from the config replace the host defaults.
cat > "$CONFIG_TMP/distro" <<EOF
distro  = debian
release = 12
EOF
run_test
output="$(TOOLBOXER_CONFIG="$CONFIG_TMP/distro" "$TOOLBOXER" config 2>&1 || true)"
if grep -qE "distro +debian" <<<"$output" && grep -qE "release +12" <<<"$output"; then
    pass "config reads distro and release"
else
    fail "config reads distro and release"
fi

# A rolling distro with 'latest' (or no release) is accepted — only a *pinned*
# version is rejected. 'config' runs finalize_names without pulling, so this
# exercises the positive path podman-free.
cat > "$CONFIG_TMP/rolling-ok" <<EOF
distro  = arch
release = latest
EOF
run_test
output="$(TOOLBOXER_CONFIG="$CONFIG_TMP/rolling-ok" "$TOOLBOXER" config 2>&1 || true)"
if grep -qE "distro +arch" <<<"$output" && ! grep -qi "rolling release" <<<"$output"; then
    pass "rolling distro accepts release=latest"
else
    fail "rolling distro accepts release=latest"
fi

# A leading ~ in a path value expands to $HOME.
cat > "$CONFIG_TMP/tilde" <<EOF
mount = ~/projects
EOF
run_test
output="$(TOOLBOXER_CONFIG="$CONFIG_TMP/tilde" "$TOOLBOXER" config 2>&1 || true)"
if grep -qF "$HOME/projects" <<<"$output"; then
    pass "config expands a leading ~ in a path"
else
    fail "config expands a leading ~ in a path"
fi

# Several mounts: a comma-separated list and a repeated key both accumulate.
# (Colon is reserved for src:dest, so it must NOT split the list.)
cat > "$CONFIG_TMP/mounts" <<EOF
mount = /tmp/a,/tmp/b
mount = /tmp/c
EOF
run_test
output="$(TOOLBOXER_CONFIG="$CONFIG_TMP/mounts" "$TOOLBOXER" config 2>&1 || true)"
if grep -qF "/tmp/a" <<<"$output" && grep -qF "/tmp/b" <<<"$output" \
    && grep -qF "/tmp/c" <<<"$output" && ! grep -qF "/tmp/a:/tmp/b" <<<"$output"; then
    pass "config accepts comma-separated and repeated mounts"
else
    fail "config accepts comma-separated and repeated mounts"
fi

# A src:dest spec sets a custom target; the source's leading ~ still expands.
cat > "$CONFIG_TMP/srcdest" <<EOF
mount = ~/proj:/work
EOF
run_test
output="$(TOOLBOXER_CONFIG="$CONFIG_TMP/srcdest" "$TOOLBOXER" config 2>&1 || true)"
if grep -qF "$HOME/proj:/work" <<<"$output"; then
    pass "config mount supports src:dest with a custom target"
else
    fail "config mount supports src:dest with a custom target"
fi

# A CLI -m accepts src:dest too.
run_test
output="$(TOOLBOXER_CONFIG="$CONFIG_TMP/none" "$TOOLBOXER" -m /tmp/s:/tmp/d config 2>&1 || true)"
if grep -qF "/tmp/s:/tmp/d" <<<"$output"; then
    pass "-m accepts src:dest"
else
    fail "-m accepts src:dest"
fi

# MOUNT_DIRS env is comma-separated (not colon, which now means src:dest).
run_test
output="$(TOOLBOXER_CONFIG="$CONFIG_TMP/none" MOUNT_DIRS="/tmp/e1,/tmp/e2:/mnt/e2" "$TOOLBOXER" config 2>&1 || true)"
if grep -qF "/tmp/e1" <<<"$output" && grep -qF "/tmp/e2:/mnt/e2" <<<"$output" \
    && ! grep -qF "/tmp/e1:/tmp/e2" <<<"$output"; then
    pass "MOUNT_DIRS env is comma-separated with src:dest support"
else
    fail "MOUNT_DIRS env is comma-separated with src:dest support"
fi

# An invalid explicit spec must fail instead of silently reducing the mount set.
cat > "$CONFIG_TMP/badmount" <<EOF
mount = :/dst
mount = /tmp/keep
EOF
run_test
output="$(TOOLBOXER_CONFIG="$CONFIG_TMP/badmount" "$TOOLBOXER" config 2>&1 || true)"
if grep -q "invalid mount" <<<"$output" && ! grep -q "Effective settings" <<<"$output"; then
    pass "config rejects an invalid explicit mount"
else
    fail "config rejects an invalid explicit mount"
fi

# The "key value" form (no '=') is accepted too.
cat > "$CONFIG_TMP/novalueeq" <<EOF
privileged true
EOF
run_test
output="$(TOOLBOXER_CONFIG="$CONFIG_TMP/novalueeq" "$TOOLBOXER" config 2>&1 || true)"
if grep -qE "privileged +true" <<<"$output"; then
    pass "config accepts the 'key value' form without '='"
else
    fail "config accepts the 'key value' form without '='"
fi

# A CLI --no-ai-agents switches off a config-enabled default.
run_test
output="$(TOOLBOXER_CONFIG="$CONFIG_TMP/cfg" "$TOOLBOXER" --no-ai-agents config 2>&1 || true)"
if grep -qE "ai_agents +false" <<<"$output"; then
    pass "--no-ai-agents overrides config ai_agents"
else
    fail "--no-ai-agents overrides config ai_agents"
fi

# Environment variables override the config file (the middle precedence tier).
run_test
output="$(TOOLBOXER_CONFIG="$CONFIG_TMP/strs" IMAGE="env.example/img:9" "$TOOLBOXER" config 2>&1 || true)"
if grep -qE "image +env.example/img:9" <<<"$output"; then
    pass "IMAGE env overrides config image"
else
    fail "IMAGE env overrides config image"
fi

run_test
output="$(TOOLBOXER_CONFIG="$CONFIG_TMP/cfg" MOUNT_DIRS="/tmp/env-mount" "$TOOLBOXER" config 2>&1 || true)"
if grep -qF "/tmp/env-mount" <<<"$output" && ! grep -qF "$CONFIG_TMP/code" <<<"$output"; then
    pass "MOUNT_DIRS env overrides config mount"
else
    fail "MOUNT_DIRS env overrides config mount"
fi

run_test
output="$(TOOLBOXER_CONFIG="$CONFIG_TMP/strs" CONTAINER_NAME="envbox" "$TOOLBOXER" config 2>&1 || true)"
if grep -qE "container +envbox" <<<"$output"; then
    pass "CONTAINER_NAME env overrides config container_name"
else
    fail "CONTAINER_NAME env overrides config container_name"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Image/name resolution (no podman needed) ==="

# Fast guard for "the right distro is pulled": source just the resolution
# helpers out of the script and check the distro→image mapping directly. The
# integration matrix below proves it against real registries but is opt-in and
# heavy; this runs on every push. A synthetic Fedora 44 host keeps the
# assertions independent of whoever runs the suite.
# Exported (not just assigned) so the sourced helpers see them — and so the
# linter doesn't read them as unused here.
export HOST_ID="fedora" HOST_VERSION_ID="44" HOST_ID_LIKE=""
RESOLVE_SRC="$(mktemp)"
sed -n '/^is_rolling_distro() {/,/^}/p; /^canonical_distro() {/,/^}/p; /^default_release() {/,/^}/p; /^resolve_image() {/,/^}/p; /^resolve_image_from_like() {/,/^}/p; /^resolve_name() {/,/^}/p' "$TOOLBOXER" > "$RESOLVE_SRC"
# shellcheck source=/dev/null
source "$RESOLVE_SRC"
rm -f "$RESOLVE_SRC"

assert_resolve() {  # description  expected  actual
    run_test
    if [[ "$2" == "$3" ]]; then
        pass "$1"
    else
        fail "$1" "expected '$2', got '$3'"
    fi
}

# The host distro uses the host's release; every other distro must NOT inherit
# it (no ubuntu:44 / leap:44) — the bug where 'create -d opensuse-leap' resolved
# to a nonexistent host-release tag (and a positional 'create opensuse-leap'
# quietly built the host distro instead).
assert_resolve "fedora (host) keeps the host release" \
    "registry.fedoraproject.org/fedora-toolbox:44" "$(resolve_image fedora "")"
assert_resolve "Rocky host defaults to its major, not an implicit point-release pin" \
    "docker.io/library/rockylinux:9" "$(HOST_ID=rocky HOST_VERSION_ID=9.5 resolve_image rocky "")"
assert_resolve "Debian host defaults to its major" \
    "docker.io/library/debian:12" "$(HOST_ID=debian HOST_VERSION_ID=12.8 resolve_image debian "")"
assert_resolve "ubuntu default tag is latest, not host 44" \
    "docker.io/library/ubuntu:latest" "$(resolve_image ubuntu "")"
assert_resolve "opensuse-leap default tag is latest, not host 44" \
    "registry.opensuse.org/opensuse/leap:latest" "$(resolve_image opensuse-leap "")"
assert_resolve "rhel default is ubiN:latest (no bare ubiN:N tag exists)" \
    "registry.access.redhat.com/ubi9/toolbox:latest" "$(resolve_image rhel "")"
assert_resolve "centos default is a current stream" \
    "quay.io/centos/centos:stream9" "$(resolve_image centos "")"
# Explicit -r is still honoured.
assert_resolve "explicit ubuntu release is honoured" \
    "docker.io/library/ubuntu:24.04" "$(resolve_image ubuntu 24.04)"
assert_resolve "explicit rhel minor keeps its exact tag" \
    "registry.access.redhat.com/ubi9/toolbox:9.4" "$(resolve_image rhel 9.4)"
# A point release is passed through verbatim (not rounded to the major), so the
# pull faithfully gets it — or fails — instead of silently substituting.
assert_resolve "rocky point release is not stripped to the major" \
    "docker.io/library/rockylinux:8.10" "$(resolve_image rocky 8.10)"
assert_resolve "debian point release is not stripped to the major" \
    "docker.io/library/debian:12.8" "$(resolve_image debian 12.8)"
# The container name tracks the same default, so it matches the pulled image.
assert_resolve "container name tracks the default-release image" \
    "ubuntu-toolbox-latest" "$(resolve_name ubuntu "")"

# Distro aliases canonicalise to the same image AND name as the full key, so
# 'opensuse'/'suse'/'tumbleweed' don't fall through to Fedora off a non-SUSE host.
assert_resolve "opensuse aliases to leap" \
    "registry.opensuse.org/opensuse/leap:latest" "$(resolve_image opensuse "")"
assert_resolve "suse aliases to leap" \
    "registry.opensuse.org/opensuse/leap:latest" "$(resolve_image suse "")"
assert_resolve "leap aliases to opensuse-leap" \
    "registry.opensuse.org/opensuse/leap:latest" "$(resolve_image leap "")"
assert_resolve "tumbleweed aliases to opensuse-tumbleweed" \
    "registry.opensuse.org/opensuse/tumbleweed:latest" "$(resolve_image tumbleweed "")"
assert_resolve "opensuse alias name matches the full key" \
    "opensuse-leap-toolbox-latest" "$(resolve_name opensuse "")"
assert_resolve "tumbleweed alias name matches the full key" \
    "opensuse-tumbleweed-toolbox-latest" "$(resolve_name tumbleweed "")"
assert_resolve "archlinux aliases to arch" \
    "docker.io/library/archlinux:latest" "$(resolve_image archlinux "")"
assert_resolve "archlinux alias name matches the full key" \
    "arch-toolbox-latest" "$(resolve_name archlinux "")"

# ---------------------------------------------------------------------------
echo ""
echo "=== Release matching (no podman needed) ==="

# The matrix's pinned-release check uses release_matches; verify its logic here
# without pulling, across exact, major-only, floating-minor, and codename forms.
assert_release() {  # description  cver  ccode  request  expect(yes|no)
    run_test
    if release_matches "$2" "$3" "$4"; then local got=yes; else local got=no; fi
    if [[ "$got" == "$5" ]]; then
        pass "$1"
    else
        fail "$1" "release_matches('$2','$3','$4') = $got, expected $5"
    fi
}
assert_release "exact numeric matches (ubuntu:22.04 -> 22.04)" 22.04 jammy 22.04 yes
assert_release "major request matches floating minor (rocky:9 -> 9.3)" 9.3 "" 9 yes
assert_release "point release must match exactly (rocky:8.10 rejects 8.9)" 8.9 "" 8.10 no
assert_release "Ubuntu releases in the same year are distinct" 24.10 oracular 24.04 no
assert_release "codename request matches VERSION_CODENAME (ubuntu:jammy)" 22.04 jammy jammy yes
assert_release "codename request matches debian (bookworm -> 12)" 12 bookworm bookworm yes
assert_release "wrong major is rejected (ubuntu:22.04 must not accept 24.04)" 24.04 noble 22.04 no
assert_release "wrong codename is rejected" 22.04 jammy noble no
assert_release "major mismatch rejected (rocky 8 vs 9)" 9.3 "" 8 no

# ---------------------------------------------------------------------------
echo ""
echo "=== Podman integration tests ==="

if [[ -n "${TOOLBOXER_SKIP_PODMAN:-}" ]]; then
    echo "  SKIP: TOOLBOXER_SKIP_PODMAN set, skipping integration tests"
elif ! type -P podman &>/dev/null; then
    echo "  SKIP: podman not found, skipping integration tests"
else
    unset -f podman
    export XDG_STATE_HOME="$CONFIG_TMP/state"
    export MOUNT_DIRS="$MOUNT_TMP/project:$HOME/code"
    reserve_test_name "$TEST_NAME"
    # NOTE: assert on captured output, never `cmd | grep -q`. Under pipefail a
    # left-hand command that exits non-zero (e.g. the duplicate 'create', or a
    # 'not found' lookup) — or a SIGPIPE from grep -q closing the pipe early —
    # makes the pipeline non-zero even when the pattern matched, so the test
    # would spuriously fail. Capturing with `|| true` sidesteps both.
    run_test
    # Include a nested home mount: Podman creates ~/.local and ~/.local/share
    # as root-owned parents unless toolboxer repairs them after startup.
    nested_home_source="$MOUNT_TMP/nested-home"
    if output="$("$TOOLBOXER" create \
        -m "$MOUNT_TMP/project:$HOME/code" \
        -m "$nested_home_source:$HOME/.local/share/toolboxer-test" \
        "$TEST_NAME" 2>&1)" && grep -q "created!" <<<"$output"; then
        pass "create container"
    else
        fail "create container"
        printf '%s\n' "$output" >&2
    fi

    run_test
    output="$("$TOOLBOXER" create "$TEST_NAME" 2>&1 || true)"
    if grep -q "already exists" <<<"$output"; then
        pass "create rejects duplicate"
    else
        fail "create rejects duplicate"
    fi

    run_test
    output="$("$TOOLBOXER" list --containers 2>&1 || true)"
    if grep -q "$TEST_NAME" <<<"$output"; then
        pass "list shows container"
    else
        fail "list shows container"
    fi

    # Reproduce an older container's root-owned cache before toolboxer performs
    # first-start setup. The repair must work even when the container was
    # already started outside toolboxer.
    podman start "$TEST_NAME" >/dev/null 2>&1 || true
    podman exec --user root "$TEST_NAME" \
        mkdir -p "$HOME/.cache/root-owned" >/dev/null 2>&1 || true
    podman exec --user root "$TEST_NAME" \
        touch "$HOME/.cache/root-owned/archive" >/dev/null 2>&1 || true

    run_test
    output="$("$TOOLBOXER" run --container "$TEST_NAME" echo hello 2>&1 || true)"
    if grep -q "hello" <<<"$output"; then
        pass "run executes command"
    else
        fail "run executes command"
    fi

    run_test
    output="$("$TOOLBOXER" run --container "$TEST_NAME" whoami 2>&1 || true)"
    if grep -q "$(whoami)" <<<"$output"; then
        pass "run preserves username"
    else
        fail "run preserves username"
    fi

    run_test
    output="$("$TOOLBOXER" run --container "$TEST_NAME" id -u 2>&1 || true)"
    if grep -q "$(id -u)" <<<"$output"; then
        pass "run preserves UID"
    else
        fail "run preserves UID"
    fi

    run_test
    # Regression: a pinned distro/release that doesn't exist must NOT fall back
    # to the only existing container ('enter -d ubuntu' used to enter the host
    # container). It should report the requested container missing instead. Use a
    # real distro (an unknown one is now rejected outright — tested separately)
    # with a PID-unique release, so the resolved name (debian-toolbox-0.<pid>)
    # can't collide with a container the user happens to have. 'run' reports the
    # missing container without pulling, so the bogus release never hits a registry.
    output="$("$TOOLBOXER" run -d debian -r "0.$$" echo nope 2>&1 || true)"
    if grep -q "not found" <<<"$output"; then
        pass "pinned distro does not substitute another container"
    else
        fail "pinned distro does not substitute another container"
    fi

    run_test
    if "$TOOLBOXER" run --container "$TEST_NAME" sudo true >/dev/null 2>&1; then
        pass "sudo works without password"
    else
        fail "sudo works without password"
    fi

    run_test
    # The container's own hostname must resolve via /etc/hosts (the 'files'
    # source), not fall through to DNS — otherwise sudo, which resolves the
    # local hostname on every call, stalls on the lookup. Guards against the
    # host /etc/hosts being bind-mounted over podman's generated one again.
    output="$("$TOOLBOXER" run --container "$TEST_NAME" getent -s files hosts toolboxer 2>&1 || true)"
    if grep -q "toolboxer" <<<"$output"; then
        pass "container hostname resolves via /etc/hosts (fast sudo)"
    else
        fail "container hostname resolves via /etc/hosts (fast sudo)"
    fi

    run_test
    # The user's home is usually the parent of the mounts, which podman creates
    # root-owned; setup hands it to the user so ~/.bashrc and provision scripts
    # can write to it.
    output="$("$TOOLBOXER" run --container "$TEST_NAME" sh -c "touch '$HOME/.toolboxer-write-test' && echo WRITABLE" 2>&1 || true)"
    if grep -q "WRITABLE" <<<"$output"; then
        pass "home directory is writable"
    else
        fail "home directory is writable"
    fi

    run_test
    # The AI-agent installers use ~/.local/bin and ~/.local/share. Both must be
    # writable even when an agent config is mounted below ~/.local/share.
    output="$("$TOOLBOXER" run --container "$TEST_NAME" sh -c \
        "mkdir -p '$HOME/.local/bin' && touch '$HOME/.local/share/.toolboxer-write-test' && echo WRITABLE" \
        2>&1 || true)"
    if grep -q "WRITABLE" <<<"$output"; then
        pass "nested mount parents in home are writable"
    else
        fail "nested mount parents in home are writable"
    fi

    run_test
    output="$("$TOOLBOXER" run --container "$TEST_NAME" sh -c \
        "touch '$HOME/.cache/root-owned/archive' '$HOME/.cache/claude-installer-test' && echo WRITABLE" \
        2>&1 || true)"
    if grep -q "WRITABLE" <<<"$output"; then
        pass "old root-owned cache content is repaired"
    else
        fail "old root-owned cache content is repaired"
    fi

    # Agent installers place their launchers in ~/.local/bin. Verify both the
    # direct `run` path and a login shell such as `enter` can resolve them.
    local_bin_probe="toolboxer-local-bin-test"
    "$TOOLBOXER" run --container "$TEST_NAME" sh -c \
        "printf '#!/bin/sh\necho LOCAL_BIN_OK\n' > '$HOME/.local/bin/$local_bin_probe' && chmod +x '$HOME/.local/bin/$local_bin_probe'" \
        >/dev/null 2>&1 || true

    run_test
    output="$("$TOOLBOXER" run --container "$TEST_NAME" "$local_bin_probe" 2>&1 || true)"
    if grep -q "LOCAL_BIN_OK" <<<"$output"; then
        pass "run resolves commands installed in user-local bin"
    else
        fail "run resolves commands installed in user-local bin" "$output"
    fi

    run_test
    output="$("$TOOLBOXER" run --container "$TEST_NAME" bash -lc "$local_bin_probe" 2>&1 || true)"
    if grep -q "LOCAL_BIN_OK" <<<"$output"; then
        pass "login shell resolves commands installed in user-local bin"
    else
        fail "login shell resolves commands installed in user-local bin" "$output"
    fi

    run_test
    "$TOOLBOXER" stop "$TEST_NAME" >/dev/null 2>&1 || true
    output="$("$TOOLBOXER" rm "$TEST_NAME" 2>&1 || true)"
    if grep -q "removed" <<<"$output"; then
        pass "rm removes container"
    else
        fail "rm removes container"
    fi

    run_test
    output="$("$TOOLBOXER" rm "$TEST_NAME" 2>&1 || true)"
    if grep -q "not found" <<<"$output"; then
        pass "rm reports not found"
    else
        fail "rm reports not found"
    fi

    # Provision script: runs on first start, and on demand via 'provision'.
    prov_script="$CONFIG_TMP/provision.sh"
    cat > "$prov_script" <<'PROV'
sudo install -d /opt/toolboxer-provisioned
PROV
    prov_name="toolboxer-prov-test-$TEST_SUFFIX"
    reserve_test_name "$prov_name"
    cleanup_prov() { "$TOOLBOXER" rm -f "$prov_name" >/dev/null 2>&1 || true; }
    trap 'cleanup; cleanup_config; cleanup_subid; cleanup_mounttmp; cleanup_agenttmp' EXIT

    run_test
    TOOLBOXER_PROVISION="$prov_script" "$TOOLBOXER" create "$prov_name" >/dev/null 2>&1 || true
    TOOLBOXER_PROVISION="$prov_script" "$TOOLBOXER" run -c "$prov_name" true >/dev/null 2>&1 || true
    output="$("$TOOLBOXER" run -c "$prov_name" ls -d /opt/toolboxer-provisioned 2>&1 || true)"
    if grep -q "toolboxer-provisioned" <<<"$output"; then
        pass "provision script runs on first start"
    else
        fail "provision script runs on first start"
    fi

    run_test
    # Remove the marker, then the explicit command must re-create it.
    "$TOOLBOXER" run -c "$prov_name" sudo rmdir /opt/toolboxer-provisioned >/dev/null 2>&1 || true
    TOOLBOXER_PROVISION="$prov_script" "$TOOLBOXER" provision "$prov_name" >/dev/null 2>&1 || true
    output="$("$TOOLBOXER" run -c "$prov_name" ls -d /opt/toolboxer-provisioned 2>&1 || true)"
    if grep -q "toolboxer-provisioned" <<<"$output"; then
        pass "provision command re-runs the script"
    else
        fail "provision command re-runs the script"
    fi
    cleanup_prov

    run_test
    # Use an intentionally invalid unique tag, not a point release a registry
    # might publish later. Never silently substitute another release.
    badrel_name="toolboxer-badrel-test-$TEST_SUFFIX"
    reserve_test_name "$badrel_name"
    status=0
    output="$("$TOOLBOXER" create -d rocky -r "toolboxer-nonexistent-$$" "$badrel_name" 2>&1)" || status=$?
    if [[ "$status" != 0 ]] && grep -qi "could not pull" <<< "$output" \
        && ! "$TOOLBOXER" run --container "$badrel_name" true >/dev/null 2>&1; then
        pass "unpullable pinned release fails with a clear error"
    else
        fail "unpullable pinned release fails with a clear error" "$output"
    fi
    "$TOOLBOXER" rm -f "$badrel_name" >/dev/null 2>&1 || true

    run_test
    # A minimal image without supported account/package tools must fail setup,
    # not mark it complete or run the user's command.
    nosudo_name="toolboxer-nosudo-test-$TEST_SUFFIX"
    reserve_test_name "$nosudo_name"
    if "$TOOLBOXER" create -i docker.io/bash "$nosudo_name" >/dev/null 2>&1; then
        status=0
        output="$("$TOOLBOXER" run --container "$nosudo_name" echo PAYLOAD_MUST_NOT_RUN 2>&1)" || status=$?
        if [[ "$status" != 0 ]] \
            && grep -Eqi "Required image command missing|could not install sudo" <<< "$output" \
            && ! grep -q PAYLOAD_MUST_NOT_RUN <<< "$output" \
            && ! podman exec --user root "$nosudo_name" test -f /etc/.toolboxer-setup-v1; then
            pass "unsupported minimal image fails before payload and setup marker"
        else
            fail "unsupported minimal image fails before payload and setup marker" "$output"
        fi
    else
        fail "unsupported minimal image fails before payload and setup marker" "create from docker.io/bash failed"
    fi
    "$TOOLBOXER" rm -f "$nosudo_name" >/dev/null 2>&1 || true

    # Per-distro image tests (opt-in — these pull images). Each distro exercises
    # its own sudo-install path (dnf/apt/pacman/zypper) and the user setup on a
    # stock base image. Configure with a space-separated list of distro[:release]
    # entries, e.g.:
    #   TOOLBOXER_TEST_DISTROS="ubuntu:24.04 debian:12 arch rocky:9" ./tests/...
    # TOOLBOXER_TEST_UBUNTU=1 is kept as a shorthand for "ubuntu:24.04".
    test_distros=()
    [[ -n "${TOOLBOXER_TEST_UBUNTU:-}" ]] && test_distros+=("ubuntu:24.04")
    if [[ -n "${TOOLBOXER_TEST_DISTROS:-}" ]]; then
        read -ra _extra_distros <<< "$TOOLBOXER_TEST_DISTROS"
        test_distros+=("${_extra_distros[@]}")
    fi

    if [[ ${#test_distros[@]} -gt 0 ]]; then
        echo ""
        echo "=== Per-distro image tests ==="
        dname=""
        cleanup_distro() {
            [[ -n "$dname" ]] || return 0
            "$TOOLBOXER" stop "$dname" >/dev/null 2>&1 || true
            "$TOOLBOXER" rm -f "$dname" >/dev/null 2>&1 || true
        }
        trap 'cleanup; cleanup_config; cleanup_subid; cleanup_mounttmp; cleanup_agenttmp' EXIT

        for dentry in "${test_distros[@]}"; do
            ddistro="${dentry%%:*}"
            drelease=""
            [[ "$dentry" == *:* ]] && drelease="${dentry#*:}"
            dname="toolboxer-${ddistro//[^a-zA-Z0-9]/_}-test-$TEST_SUFFIX"
            create_args=(-d "$ddistro")
            [[ -n "$drelease" ]] && create_args+=(-r "$drelease")

            echo "--- $dentry ---"
            reserve_test_name "$dname"

            run_test
            if output="$("$TOOLBOXER" create "${create_args[@]}" "$dname" 2>&1)" \
                && grep -q "created!" <<<"$output"; then
                pass "[$dentry] create"
            else
                fail "[$dentry] create"
                printf '%s\n' "$output" >&2
                cleanup_distro
                continue
            fi

            run_test
            # Confirm the container actually runs the requested distro by reading
            # its os-release ID exactly — the canonical key matches the ID for
            # every distro we support (opensuse-leap→opensuse-leap, rocky→rocky, …).
            # canonical_distro (sourced above) folds aliases first, so an entry of
            # 'opensuse'/'suse'/'leap' is checked against 'opensuse-leap'. A loose
            # substring match would let a wrong image (e.g. fedora pulled for
            # opensuse-leap, the host-release default-tag bug) slip through.
            expect_id="$(canonical_distro "$ddistro")"
            output="$("$TOOLBOXER" run --container "$dname" cat /etc/os-release 2>&1 || true)"
            # '|| true' on every extraction: a field can be absent (most distros
            # have no VERSION_CODENAME — only Debian/Ubuntu do), and under
            # 'set -euo pipefail' a no-match grep in a command substitution would
            # otherwise abort the whole suite instead of just yielding an empty value.
            osid="$(grep -E '^ID=' <<<"$output" | head -1 | cut -d= -f2- | tr -d '"'\''\r ' || true)"
            if [[ "$osid" == "$expect_id" ]]; then
                pass "[$dentry] runs $expect_id (ID=$osid)"
            else
                # Surface the run output so a setup failure is diagnosable in CI
                # instead of only showing an empty ID.
                fail "[$dentry] runs $expect_id (got ID=${osid:-?})" "run output: ${output:-<empty>}"
            fi

            # When a release was pinned, confirm the image really is that version
            # — '-d ubuntu -r 24.04' must pull 24.04, not just "an ubuntu". Matches
            # a codename (ubuntu:jammy) or the major for a numeric request (see
            # release_matches). Bare entries pull a rolling/latest tag with no
            # fixed version, so there's nothing to assert.
            if [[ -n "$drelease" ]]; then
                run_test
                cver="$(grep -E '^VERSION_ID=' <<<"$output" | head -1 | cut -d= -f2- | tr -d '"'\''\r ' || true)"
                ccode="$(grep -E '^VERSION_CODENAME=' <<<"$output" | head -1 | cut -d= -f2- | tr -d '"'\''\r ' || true)"
                if release_matches "$cver" "$ccode" "$drelease"; then
                    pass "[$dentry] is release $drelease (VERSION_ID=$cver${ccode:+, $ccode})"
                else
                    fail "[$dentry] is release $drelease (got VERSION_ID=${cver:-?}${ccode:+, $ccode})"
                fi
            fi

            run_test
            # In-container login must match the host user (a stock account at the
            # host UID is renamed, otherwise the user is created), so the
            # passwordless-sudo drop-in applies.
            output="$("$TOOLBOXER" run --container "$dname" id -un 2>&1 || true)"
            if grep -qx "$(id -un)" <<<"$output"; then
                pass "[$dentry] in-container username matches host"
            else
                fail "[$dentry] in-container username matches host"
            fi

            run_test
            if "$TOOLBOXER" run --container "$dname" sudo true >/dev/null 2>&1; then
                pass "[$dentry] passwordless sudo works"
            else
                fail "[$dentry] passwordless sudo works"
            fi

            cleanup_distro
        done
        dname=""
    fi
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed ==="
[[ "$TESTS_FAILED" -eq 0 ]] && exit 0 || exit 1
