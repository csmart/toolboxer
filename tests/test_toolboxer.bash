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
