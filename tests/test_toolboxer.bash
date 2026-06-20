#!/usr/bin/env bash
# Basic smoke tests for toolboxer
# Requires podman to be installed and working (rootless)
set -euo pipefail

TOOLBOXER="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/toolboxer"
TEST_NAME="toolboxer-test-$$"
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
}

run_test() {
    ((TESTS_RUN++)) || true
}

cleanup() {
    podman rm -f "$TEST_NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
echo "=== CLI tests (no podman needed) ==="

run_test
if "$TOOLBOXER" --help 2>&1 | grep -q "Commands:"; then
    pass "--help shows usage"
else
    fail "--help shows usage"
fi

run_test
if "$TOOLBOXER" help 2>&1 | grep -q "Commands:"; then
    pass "help command shows usage"
else
    fail "help command shows usage"
fi

run_test
if "$TOOLBOXER" create --help 2>&1 | grep -q -- "--distro"; then
    pass "create --help shows --distro"
else
    fail "create --help shows --distro"
fi

run_test
if "$TOOLBOXER" enter --help 2>&1 | grep -q -- "--release"; then
    pass "enter --help shows --release"
else
    fail "enter --help shows --release"
fi

run_test
if "$TOOLBOXER" run --help 2>&1 | grep -q -- "--container"; then
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
if "$TOOLBOXER" --help 2>&1 | grep -q "config"; then
    pass "--help lists the config command"
else
    fail "--help lists the config command"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Config file tests (no podman needed) ==="

CONFIG_TMP="$(mktemp -d)"
cleanup_config() { rm -rf "$CONFIG_TMP"; }
# Chain config cleanup onto the existing container-cleanup EXIT trap.
trap 'cleanup; cleanup_config' EXIT

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

# An invalid spec (empty source) warns and is skipped, not mounted.
cat > "$CONFIG_TMP/badmount" <<EOF
mount = :/dst
mount = /tmp/keep
EOF
run_test
output="$(TOOLBOXER_CONFIG="$CONFIG_TMP/badmount" "$TOOLBOXER" config 2>&1 || true)"
if grep -q "invalid mount" <<<"$output" && grep -qF "/tmp/keep" <<<"$output"; then
    pass "config warns on an invalid mount spec and skips it"
else
    fail "config warns on an invalid mount spec and skips it"
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
echo "=== Podman integration tests ==="

if [[ -n "${TOOLBOXER_SKIP_PODMAN:-}" ]]; then
    echo "  SKIP: TOOLBOXER_SKIP_PODMAN set, skipping integration tests"
elif ! command -v podman &>/dev/null; then
    echo "  SKIP: podman not found, skipping integration tests"
else
    run_test
    if "$TOOLBOXER" create "$TEST_NAME" 2>&1 | grep -q "created"; then
        pass "create container"
    else
        fail "create container"
    fi

    run_test
    if "$TOOLBOXER" create "$TEST_NAME" 2>&1 | grep -q "already exists"; then
        pass "create rejects duplicate"
    else
        fail "create rejects duplicate"
    fi

    run_test
    if "$TOOLBOXER" list --containers 2>&1 | grep -q "$TEST_NAME"; then
        pass "list shows container"
    else
        fail "list shows container"
    fi

    run_test
    if "$TOOLBOXER" run --container "$TEST_NAME" echo hello 2>&1 | grep -q "hello"; then
        pass "run executes command"
    else
        fail "run executes command"
    fi

    run_test
    if "$TOOLBOXER" run --container "$TEST_NAME" whoami 2>&1 | grep -q "$(whoami)"; then
        pass "run preserves username"
    else
        fail "run preserves username"
    fi

    run_test
    if "$TOOLBOXER" run --container "$TEST_NAME" id -u 2>&1 | grep -q "$(id -u)"; then
        pass "run preserves UID"
    else
        fail "run preserves UID"
    fi

    run_test
    if "$TOOLBOXER" run --container "$TEST_NAME" sudo true 2>&1; then
        pass "sudo works without password"
    else
        fail "sudo works without password"
    fi

    run_test
    "$TOOLBOXER" stop "$TEST_NAME" >/dev/null 2>&1 || true
    if "$TOOLBOXER" rm "$TEST_NAME" 2>&1 | grep -q "removed"; then
        pass "rm removes container"
    else
        fail "rm removes container"
    fi

    run_test
    if "$TOOLBOXER" rm "$TEST_NAME" 2>&1 | grep -q "not found"; then
        pass "rm reports not found"
    else
        fail "rm reports not found"
    fi
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed ==="
[[ "$TESTS_FAILED" -eq 0 ]] && exit 0 || exit 1
