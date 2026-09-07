# Contributing to toolboxer

## Reporting issues

Open an issue with expected/actual behavior, reproduction steps, host distro,
Podman/runtime versions, and the relevant error output. The repository's
`diagnose.sh` can collect a log; review it for personal paths and command output
before sharing. Do not include credentials or authentication files.

## Submitting changes

1. Create a focused branch from `main`.
2. Add a behavioral regression for each bug. Mocks test wrapper decisions;
   actual namespace, filesystem, account, and SELinux behavior needs live tests.
3. Run `make test` (safe: no real Podman) and `make lint` (ShellCheck required).
4. Run `./tests/test_toolboxer.sh` and `./tests/test_isolation.sh` on a
   working local rootless Podman host when changing container behavior.
5. Submit a PR describing the checks run and any unavailable environments.

The test suite uses Python 3.9+ for behavioral regressions. Set
`TOOLBOXER_TEST_DISTROS="ubuntu:24.04 debian:12 arch rocky:9"` for additional
live image coverage. The CI workflow runs the supported distro matrix once:
fix a failure instead of masking it with whole-suite retries. Live tests create
temporary containers and fixtures, clean their own containers, and retain pulled
images. Use a disposable development host when testing broad changes.

Isolated-mode changes also need an enforcing SELinux host (for example Fedora).
Record disabled/permissive/enforcing status; a label check on an Ubuntu runner
does not demonstrate SELinux enforcement. If rootless Podman cannot start in the
test environment, report that limitation rather than treating mocked tests as
equivalent coverage.

## Code style and scope

Keep the implementation a single Bash script with focused functions and explicit
failure handling. Prefer toolbox-style CLI conventions, but document intentional
differences rather than claiming full compatibility.

Use four-space indentation, snake_case functions, uppercase globals, lowercase
locals, and `[[ ]]` conditions. Keep comments focused on intent or non-obvious
constraints. Protect host bind sources and unrelated containers/images in both
production code and test cleanup. New diagnostic checks must avoid credential
disclosure; checks that run user programs or write files should be opt-in.
