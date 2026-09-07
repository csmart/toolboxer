#!/usr/bin/env python3
"""Behavioral regression tests. Podman is always a disposable mock executable."""
import fcntl
import json
import os
from pathlib import Path
import re
import select
import shutil
import signal
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


class RegressionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="toolboxer-tests-")
        self.addCleanup(self.temp.cleanup)
        self.tmp = Path(self.temp.name)
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        (self.bin / "podman").symlink_to(ROOT / "tests" / "mock_podman.py")
        (self.bin / "id").symlink_to(ROOT / "tests" / "mock_id.py")
        self.config = self.tmp / "config"
        self.config.write_text("")
        self.log = self.tmp / "calls.jsonl"
        self.env = os.environ.copy()
        for name in ("IMAGE", "CONTAINER_NAME", "MOUNT_DIRS", "BASH_ENV", "CONTAINER_HOST", "CONTAINER_CONNECTION"):
            self.env.pop(name, None)
        self.env.update(PATH=f"{self.bin}:{os.environ['PATH']}",
                        TOOLBOXER_CONFIG=str(self.config),
                        TOOLBOXER_PROVISION=str(self.tmp / "no-provision"),
                        MOCK_LOG=str(self.log), MOCK_SCENARIO="{}",
                        XDG_RUNTIME_DIR=str(self.tmp / "runtime"), XDG_STATE_HOME=str(self.tmp / "state"))
        self.config.write_text(f"mount = {self.tmp}/project:/work\n")
        (self.tmp / "project").mkdir()

    def run_cli(self, *args, scenario=None, cwd=None):
        if scenario is not None:
            self.env["MOCK_SCENARIO"] = json.dumps(scenario)
        return subprocess.run([str(ROOT / "toolboxer"), *args], env=self.env,
                              cwd=cwd or self.tmp, text=True, capture_output=True)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def test_mount_errors_do_not_create(self):
        for spec in (":/work", "/tmp:relative", "/tmp:/work:ro"):
            result = self.run_cli("create", "-m", spec, "example")
            self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.calls(), [])

    def test_rootful_and_failed_runtime_queries_are_rejected(self):
        self.assertNotEqual(self.run_cli("create", "example", scenario=dict(info="false false crun")).returncode, 0)
        self.assertFalse(any(c[0] == "create" for c in self.calls()))
        self.assertNotEqual(self.run_cli("run", "-c", "example", "true", scenario=dict(fail=["info"])).returncode, 0)

    def test_user_setup_guards_dash_leading_names(self):
        # L5: a host username beginning with '-' must reach groupadd/useradd as
        # a name, not be parsed as an option. Extract the in-container setup
        # script and run it under recording stubs with a dash-leading user.
        source = (ROOT / "toolboxer").read_text()
        script = source.split("<<'SETUP'\n", 1)[1].split("\nSETUP\n", 1)[0]
        stub = self.tmp / "shadow-stub"
        stub.mkdir()
        log = self.tmp / "shadow.log"
        (stub / "getent").write_text("#!/bin/sh\nexit 2\n")           # nothing pre-exists
        (stub / "id").write_text("#!/bin/sh\necho 1000\n")            # created uid/gid match
        for cmd in ("groupadd", "useradd", "usermod"):
            (stub / cmd).write_text(
                f'#!/bin/sh\nprintf "%s\\n" "{cmd} $*" >> "$SHADOW_LOG"\n')
        for f in stub.iterdir():
            f.chmod(0o755)
        env = dict(os.environ, PATH=f"{stub}:{os.environ['PATH']}", SHADOW_LOG=str(log))
        result = subprocess.run(
            ["bash", "--noprofile", "--norc", "-s", "--", "1000", "1000", "-danger", "/home/x"],
            input=script, env=env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = log.read_text().splitlines()
        useradd = next(l for l in lines if l.startswith("useradd "))
        groupadd = next(l for l in lines if l.startswith("groupadd "))
        self.assertTrue(useradd.endswith("-- -danger"), useradd)
        self.assertTrue(groupadd.endswith("-- -danger"), groupadd)

    def test_arch_sudo_install_warns_before_full_upgrade(self):
        # M9: installing sudo on Arch runs a full system upgrade (pacman -Syu),
        # which is slow and updates more than sudo. Warn before it so the delay
        # and scope are not a surprise. Run the extracted sudo-install script
        # with only pacman on PATH so the Arch branch is taken.
        source = (ROOT / "toolboxer").read_text()
        script = re.search(r"bash --noprofile --norc -c '(.*?)' >&2", source, re.DOTALL).group(1)
        stub = self.tmp / "pm-stub"
        stub.mkdir()
        log = self.tmp / "pacman.log"
        # chmod must be reachable so the stub can make its installed sudo
        # executable, but dnf/apt-get/zypper/sudo must not be, or a different
        # branch is taken on this host. A tools dir with only chmod does both.
        tools = self.tmp / "pm-tools"
        tools.mkdir()
        (tools / "chmod").symlink_to(shutil.which("chmod"))
        # The stub records its args, marks its start on stderr (the warning's
        # own stream, so ordering is checkable), and installs a real sudo so the
        # script's final `command -v sudo` succeeds and the installer exits 0.
        (stub / "pacman").write_text('#!/bin/sh\n'
                                     'printf "%s\\n" "$*" >> "$PM_LOG"\n'
                                     'echo "PACMAN-START" >&2\n'
                                     'printf "#!/bin/sh\\n" > "$PM_STUB/sudo"\n'
                                     'chmod 755 "$PM_STUB/sudo"\n')
        (stub / "pacman").chmod(0o755)
        env = {"PATH": f"{stub}:{tools}", "PM_LOG": str(log), "PM_STUB": str(stub)}
        result = subprocess.run([shutil.which("bash"), "-c", script], env=env,
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("-Syu", log.read_text())
        # Presence is not enough: the warning must precede the upgrade. Both land
        # on stderr, so assert the warning appears before the stub's start marker.
        warn = re.search(r"full system upgrade|pacman -Syu", result.stderr)
        start = result.stderr.find("PACMAN-START")
        self.assertIsNotNone(warn, result.stderr)
        self.assertNotEqual(start, -1, result.stderr)
        self.assertLess(warn.start(), start, "warning did not precede the full upgrade")

    def test_create_neutralizes_inherited_toolbx_labels(self):
        # M7: Toolbx recognises com.github.containers.toolbox=true and
        # com.github.debarshiray.toolbox=true, which Podman inherits from the
        # fedora-toolbox base image. Toolboxer must override both so Toolbx does
        # not adopt its containers, while keeping its own toolboxer=true and
        # dropping the unused generic toolbox label.
        for key in ("com.github.containers.toolbox", "com.github.debarshiray.toolbox"):
            with self.subTest(key=key):
                if self.log.exists():
                    self.log.unlink()
                result = self.run_cli("create", "example",
                                      scenario=dict(image_labels={key: "true"}))
                self.assertEqual(result.returncode, 0, result.stderr)
                effective = subprocess.run(
                    [str(self.bin / "podman"), "inspect", "--format",
                     '{{index .Config.Labels "' + key + '"}}', "example"],
                    env=self.env, text=True, capture_output=True).stdout.strip()
                self.assertNotEqual(effective, "true",
                                    f"{key} still satisfies Toolbx recognition")
        create = next(c for c in self.calls() if c[0] == "create")
        self.assertIn("toolboxer=true", create)
        self.assertNotIn("toolbox=true", create)

    def test_create_proceeds_past_subid_warning(self):
        # T3: an unusable host subuid/subgid range warns but must not block
        # create; NSS-backed allocations may still work. The old shell test only
        # checked that the warning printed, never that create continued. Force
        # the warning with empty subid fixtures and assert create is dispatched.
        empty = self.tmp / "subid-empty"
        empty.write_text("")
        self.env["SUBUID_FILE"] = str(empty)
        self.env["SUBGID_FILE"] = str(empty)
        result = self.run_cli("create", "example")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("no usable subuid/subgid range", result.stderr)
        self.assertTrue(any(c[0] == "create" for c in self.calls()),
                        "create did not proceed past the subid warning")

    def test_create_stdout_is_only_the_container_id(self):
        # L8: create prints only the container ID on stdout so
        # id=$(toolboxer create ...) captures it cleanly; the progress and
        # result messages go to stderr.
        result = self.run_cli("create", "example")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "c" * 64)
        self.assertIn("created!", result.stderr)
        self.assertNotIn("Creating", result.stdout)

    def test_create_stdout_is_only_the_container_id_when_pulling(self):
        # L8: a create that pulls must still print only the container ID.
        # Podman prints the pulled image ID to stdout, so create must send the
        # pull's stdout to stderr; otherwise capturing stdout returns the image
        # result before the ID.
        result = self.run_cli("create", "--pull", "always", "example")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(any(c[0] == "pull" for c in self.calls()), "pull did not run")
        self.assertEqual(result.stdout.strip(), "c" * 64)
        self.assertNotIn("a" * 64, result.stdout)

    def test_podman_info_fields_are_case_sensitive(self):
        for field, expected_status in (("SELinuxEnabled", 0), ("SelinuxEnabled", 125)):
            result = subprocess.run([str(self.bin / "podman"), "info", "--format",
                                     "{{.Host.Security." + field + "}}"],
                                    env=self.env, text=True, capture_output=True)
            self.assertEqual(result.returncode, expected_status, result.stderr)
            if expected_status == 0:
                self.assertEqual(result.stdout, "false\n")

    def test_mock_podman_rejects_unhandled_verbs(self):
        # The mock must not lend false confidence: a verb it does not model
        # exits 125 like a real CLI error, while the lifecycle verbs the wrapper
        # actually drives are modelled explicitly and succeed. Without this, a
        # regression that shelled out to an unmodelled verb would pass silently.
        podman = str(self.bin / "podman")
        unknown = subprocess.run([podman, "totally-bogus-verb"],
                                 env=self.env, text=True, capture_output=True)
        self.assertEqual(unknown.returncode, 125, unknown.stdout)
        for verb in ("pull", "start", "stop", "rm", "rmi"):
            modelled = subprocess.run([podman, verb, "x"],
                                      env=self.env, text=True, capture_output=True)
            self.assertEqual(modelled.returncode, 0, f"{verb}: {modelled.stderr}")

    def test_force_removal_passes_the_typed_info_preflight(self):
        result = self.run_cli("rm", "coding", "--force", scenario=dict(exists=True, info="true true crun"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([c for c in self.calls() if c[0] == "rm"],
                         [["rm", "--volumes", "-f", "coding"]])

    def test_rm_removes_container_even_when_its_image_is_gone(self):
        # H1: image bookkeeping is best-effort. A container whose image was
        # already deleted (forced rmi, storage GC) must still be removable; a
        # failed `podman image inspect` during tracking must not skip the
        # `podman rm` the user asked for.
        result = self.run_cli("rm", "gone-img",
                              scenario=dict(exists=True, fail_inspect=["a" * 64]))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(any(c[0] == "rm" and "gone-img" in c for c in self.calls()),
                        "podman rm was not called after a tracking failure")
        self.assertIn("removing it anyway", result.stderr)

    def test_unmanaged_containers_and_implicit_isolated_mounts_are_rejected(self):
        result = self.run_cli("run", "-c", "example", "true", scenario=dict(exists=True, managed="false"))
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(c[0] == "exec" for c in self.calls()))
        result = self.run_cli("create", "--isolated", "example", scenario=dict(mounts="/unsafe:/host"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unexpected bind mounts", result.stderr)

    def test_existing_container_mount_flags_are_validated(self):
        result = self.run_cli("-m", f"{self.tmp}:/different", "run", "-c", "example", "true", scenario=dict(exists=True))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("recreate it to change mounts", result.stderr)

    def test_config_mode_matching_is_asymmetric_for_existing_containers(self):
        # Documented asymmetry: a configured isolated=true is enforced against
        # an existing container, but a configured privileged=true is not; only
        # an explicit CLI --privileged is. Pin all three so it stays deliberate.
        base = f"mount = {self.tmp}/project:/work\n"
        self.config.write_text(base + "isolated = true\n")
        result = self.run_cli("run", "-c", "example", "true", scenario=dict(exists=True))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not satisfy --isolated", result.stderr)
        self.config.write_text(base + "privileged = true\n")
        result = self.run_cli("run", "-c", "example", "true", scenario=dict(exists=True))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.config.write_text(base)
        result = self.run_cli("--privileged", "run", "-c", "example", "true", scenario=dict(exists=True))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("do not match", result.stderr)

    def test_enter_creates_missing_container_with_the_requested_mode(self):
        # enter on a missing container re-invokes create with the resolved mode
        # passed explicitly. The mode is taken from the CLI here while the
        # config names none, so only explicit flags can carry it: a re-invoked
        # create that re-read the config alone would fall back to integrated.
        self.config.write_text(f"mount = {self.tmp}/project:/work\n")
        for cli_mode, expected_mode in (([], "integrated"),
                                        (["--privileged"], "privileged"),
                                        (["--isolated"], "isolated")):
            self.log.unlink(missing_ok=True)
            result = self.run_cli(*cli_mode, "-y", "enter", "example", scenario=dict(exists=False))
            self.assertEqual(result.returncode, 0, (expected_mode, result.stderr))
            create = next((c for c in self.calls() if c[0] == "create"), None)
            self.assertIsNotNone(create, (expected_mode, "no create call was logged"))
            self.assertIn(f"toolboxer.mode={expected_mode}", create, (expected_mode, create))

    def test_list_continues_when_an_image_inspect_fails(self):
        good, vanished, genuine = "a" * 64, "c" * 64, "b" * 64
        container_row = "dead1234beef\tcontainer1\ttoday\tExited\tsomeimage"
        # An image removed mid-listing is skipped silently: list still succeeds
        # and prints the surviving image plus the container table.
        result = self.run_cli("list", scenario=dict(
            image_ids=f"{good}\n{vanished}", fail_inspect=[vanished],
            vanish_images=[vanished], containers=container_row))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(good, result.stdout)
        self.assertNotIn(vanished, result.stdout)
        self.assertIn("container1", result.stdout)
        # The benign race must be fully quiet: neither our warning nor Podman's
        # own inspect error may reach stderr.
        self.assertEqual(result.stderr, "", result.stderr)
        # A genuine inspect failure keeps listing but is not reported as
        # success, and the container section still prints.
        result = self.run_cli("list", scenario=dict(
            image_ids=f"{good}\n{genuine}", fail_inspect=[genuine],
            containers=container_row))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(good, result.stdout)
        self.assertNotIn(genuine, result.stdout)
        self.assertIn("container1", result.stdout)
        self.assertIn("could not inspect", result.stderr)

    def test_list_both_selectors_show_both_sections(self):
        result = self.run_cli("list", "--images", "--containers")
        self.assertEqual(result.returncode, 0)
        self.assertIn("IMAGE NAME", result.stdout)
        self.assertIn("CONTAINER NAME", result.stdout)

    def test_stop_and_all_removal_cannot_expand_the_target(self):
        result = self.run_cli("stop", "unrelated", scenario=dict(exists=True, managed="false"))
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(c[0] == "stop" for c in self.calls()))
        self.log.unlink()
        result = self.run_cli("rm", "--all", "-d", "ubuntu")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_cli_validation_and_help(self):
        for args in (("create", "--mount"), ("enter", "one", "two"),
                     ("run", "--preserve-fds", "bad", "true")):
            result = self.run_cli(*args)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("unbound variable", result.stderr)
        self.assertIn("Usage: toolboxer enter", self.run_cli("help", "enter").stdout)

    def test_diagnostics_go_to_stderr_and_help_to_stdout(self):
        # 'run' promises callers real output on stdout, so every diagnostic
        # path must leave stdout empty. The usage default of exit 1 is pinned
        # because this fix changes streams, not status codes.
        self.config.write_text(f"mount = {self.tmp}/project:/work\nprivileged = true\nisolated = true\n")
        result = self.run_cli("config", scenario={})
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertIn("mutually exclusive", result.stderr)
        self.config.write_text(f"mount = {self.tmp}/project:/work\n")
        cases = (
            (("--frobnicate", "config"), {}, ("Unknown option", "Usage:")),
            (("bogus",), {}, ("Unknown command", "Usage:")),
            (("list", "--bogus"), {}, ("Unknown list option", "Usage:")),
            (("--privileged", "--isolated", "config"), {}, ("mutually exclusive",)),
            (("create", "-i", "custom:1", "-d", "ubuntu", "example"), {}, ("incompatible",)),
            (("create", "example"), dict(exists=True), ("already exists", "Remove it first")),
            (("run",), {}, ("requires a command", "Usage: toolboxer run")),
            (("run", "-c", "example", "true"), {}, ("not found", "Create one first")),
            (("stop", "example"), {}, ("does not exist",)),
            (("provision", "example"), {}, ("not found", "Create one first")),
        )
        for args, scenario, messages in cases:
            result = self.run_cli(*args, scenario=scenario)
            self.assertEqual(result.returncode, 1, (args, result.stderr))
            self.assertEqual(result.stdout, "", args)
            for message in messages:
                self.assertIn(message, result.stderr, args)
        for args in (("-h",), ("help", "run"), ("create", "--help")):
            result = self.run_cli(*args, scenario={})
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("Usage:", result.stdout, args)
            self.assertNotIn("Usage:", result.stderr, args)

    def test_empty_config_mounts_and_boolean_equals_cannot_change_targets(self):
        self.config.write_text("mount = ,\n")
        self.assertNotEqual(self.run_cli("config").returncode, 0)
        self.assertEqual(self.run_cli("-m", str(self.tmp), "config").returncode, 0)
        self.config.write_text("")
        self.assertNotEqual(self.run_cli("create", "--isolated=false").returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_agent_selection_is_a_canonical_set(self):
        result = self.run_cli("--agent", "codex", "--agent", "claude", "--agent", "codex", "config")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertRegex(result.stdout, r"agents\s+claude codex\n")
        result = self.run_cli("--agent", "claude", "--agent", "codex", "config")
        self.assertRegex(result.stdout, r"agents\s+claude codex\n")

    def test_create_flags_override_config_before_validation(self):
        with self.config.open("a") as f:
            f.write("privileged = true\nisolated = true\ndistro = fedora\nrelease = 44\n")
        result = self.run_cli("create", "--no-privileged", "--distro=ubuntu", "example")
        self.assertEqual(result.returncode, 0, result.stderr)
        call = next(c for c in self.calls() if c[0] == "create")
        self.assertIn("docker.io/library/ubuntu:latest", call)

    def test_run_payload_is_not_parsed_as_wrapper_options(self):
        result = self.run_cli("run", "-c", "example", "echo", "--distro=garbage", "-af",
                              scenario=dict(exists=True))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls()[-1][-3:], ["echo", "--distro=garbage", "-af"])

    def test_run_inner_exec_forwards_payload_across_sh_variants(self):
        # The `run` inner `sh -c` fragment must forward the payload correctly
        # under whichever /bin/sh the target image ships. bash honours
        # `exec --`, but dash's exec passes argv straight to execve, so an
        # unconditional `exec --` makes dash treat `--` as the command and fail
        # every run with exit 127. bash's plain `exec "$@"`, meanwhile, parses a
        # leading-dash payload as exec options and blanks the environment.
        # Guarding on BASH_VERSION keeps both correct. This bug is invisible in
        # the mock argv, so execute the real fragment under each shell present.
        source = (ROOT / "toolboxer").read_text()
        # Anchor on version-stable markers (the PATH export and the `sh "$@"`
        # argv0+payload suffix) so the behavioural assertions below, not the
        # extraction, decide pass/fail even for a buggy fragment.
        candidates = [l for l in source.splitlines()
                      if 'export PATH="$HOME/.local/bin:$PATH"' in l
                      and l.rstrip().endswith('sh "$@"')]
        self.assertEqual(len(candidates), 1, "expected exactly one run inner exec fragment")
        match = re.search(r"sh -c '([^']*)' sh", candidates[0])
        self.assertIsNotNone(match, "could not locate the run inner exec fragment")
        fragment = match.group(1)

        shells = {}
        for name in ("/bin/sh", "bash", "dash"):
            path = name if name.startswith("/") else shutil.which(name)
            if path and os.path.exists(path):
                shells[os.path.realpath(path)] = path
        self.assertTrue(shells, "no shell available to exercise the fragment")

        for shell in shells.values():
            env = dict(os.environ, MARKER="sentinel")
            ctx = f"shell={shell}"

            # Ordinary command: args (including a space) preserved, exit 0.
            ordinary = subprocess.run(
                [shell, "-c", fragment, "sh", "printf", "%s\n", "hello world"],
                env=env, text=True, capture_output=True)
            self.assertEqual(ordinary.returncode, 0, f"{ctx}: {ordinary.stderr}")
            self.assertEqual(ordinary.stdout, "hello world\n", ctx)

            # A non-zero payload status must survive unchanged.
            status = subprocess.run(
                [shell, "-c", fragment, "sh", "sh", "-c", "exit 7"],
                env=env, text=True, capture_output=True)
            self.assertEqual(status.returncode, 7, f"{ctx}: {status.stderr}")

            # Leading-dash payload: `-c` is a (missing) command name, never an
            # exec option. Correct result is command-not-found (127), and the
            # environment must not be cleared (would signal bash's `exec -c`).
            dashed = subprocess.run(
                [shell, "-c", fragment, "sh", "-c", "printenv", "MARKER"],
                env=env, text=True, capture_output=True)
            self.assertEqual(dashed.returncode, 127,
                             f"{ctx}: rc={dashed.returncode} out={dashed.stdout!r}")
            self.assertNotIn("sentinel", dashed.stdout,
                             f"{ctx}: leading-dash payload ran with a modified environment")

    def test_config_effective_release_matches_image(self):
        with self.config.open("a") as f:
            f.write("distro = ubuntu\n")
        result = self.run_cli("config")
        self.assertRegex(result.stdout, r"release\s+latest")

    def test_quoted_config_value_keeps_literal_hash(self):
        # M2: a quoted value is literal, so a '#' inside a mount source path
        # survives instead of being cut at the first '#'.
        hashed = self.tmp / "foo#bar"
        hashed.mkdir()
        with self.config.open("a") as f:
            f.write(f'mount = "{hashed}:/hashed"\n')
        result = self.run_cli("create", "example")
        self.assertEqual(result.returncode, 0, result.stderr)
        call = next(c for c in self.calls() if c[0] == "create")
        self.assertIn(f"{hashed}:/hashed", call)

    def test_unquoted_compact_comment_keeps_boolean_meaning(self):
        # Compatibility guard: '#' without a quote still begins a comment
        # anywhere in an unquoted value, so an existing "isolated = true#note"
        # stays true and creates an isolated container rather than parsing as a
        # non-boolean and silently downgrading to integrated mode.
        with self.config.open("a") as f:
            f.write("isolated = true#always on\n")
        result = self.run_cli("create", "example")
        self.assertEqual(result.returncode, 0, result.stderr)
        call = next(c for c in self.calls() if c[0] == "create")
        self.assertIn("toolboxer.mode=isolated", call)

    def test_empty_agents_selection_shares_none_not_all(self):
        # M3: an empty agents selection must share none and clear any earlier
        # sharing state, never fall through to "all". This covers a lone empty
        # value, one that only tokenises to nothing (a comma or whitespace), and
        # an empty value that follows an earlier opt-in. Isolated HOME/XDG/agent
        # fixtures keep the wrapper away from the operator's real credentials.
        home = self.tmp / "home"
        (home / ".claude").mkdir(parents=True)
        (home / ".codex").mkdir()
        (home / ".claude.json").write_text('{"fixture": true}')
        self.env.update(HOME=str(home),
                        XDG_CONFIG_HOME=str(home / ".config"),
                        XDG_DATA_HOME=str(home / ".local/share"),
                        CLAUDE_CONFIG_DIR=str(home / ".claude"),
                        CODEX_HOME=str(home / ".codex"))
        # A non-home mount stays valid so agent directories are the only paths
        # that would ever be rooted under the isolated home.
        base_mount = f"mount = {self.tmp}/project:/work\n"
        empties = ["agents =", "agents = ,", 'agents = " "',
                   "ai_agents = true\nagents =", "agents = codex\nagents ="]
        for body in empties:
            with self.subTest(body=body):
                self.config.write_text(base_mount + body + "\n")
                if self.log.exists():
                    self.log.unlink()
                result = self.run_cli("create", "example")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("empty 'agents'", result.stderr)
                create = next(c for c in self.calls() if c[0] == "create")
                self.assertIn("toolboxer.agents=false", create)
                self.assertFalse(any(a.startswith(str(home)) for a in create),
                                 f"{body!r} bound a path under the isolated home")
                self.assertFalse(any(c[0] == "cp" for c in self.calls()),
                                 f"{body!r} copied a credential file")

    def test_agent_source_env_paths_are_validated(self):
        # H3: agent source dirs come from env vars (CLAUDE_CONFIG_DIR,
        # CODEX_HOME, XDG_*), so they are validated like a user mount, against a
        # CANONICAL home and without losing filename bytes. '/', the home
        # (however spelled), an ancestor, a separator-bearing path, or a symlink
        # resolving to a newline-named dir must never be bound as ~/.claude; a
        # specific directory elsewhere is fine.
        real = self.tmp / "real-home"
        real.mkdir()
        link = self.tmp / "home-link"
        link.symlink_to(real)                      # HOME reached via a symlink
        self.env["HOME"] = str(link)
        nl_dir = real / "\n"                        # a directory named newline
        nl_dir.mkdir()
        nl_link = self.tmp / "nl-link"             # normal-named symlink to it
        nl_link.symlink_to(nl_dir)
        bad = {
            "root": "/",
            "home-symlinked": str(link),               # == $HOME, spelled as a symlink
            "home-physical": str(real),                # the physical home
            "home-dotdot": str(link / ".." / link.name),
            "ancestor": str(self.tmp),                 # parent of the home
            "newline-symlink": str(nl_link),           # resolves to a newline dir
            "colon": f"{self.tmp}/a:b",
            "env-trailing-newline": f"{self.tmp}/plain\n",  # stripped by $() -> wrong dir
            "env-middle-newline": f"{self.tmp}/a\nb",
        }
        for label, path in bad.items():
            with self.subTest(bad=label):
                self.env["CLAUDE_CONFIG_DIR"] = path
                if self.log.exists():
                    self.log.unlink()
                result = self.run_cli("create", "--agent", "claude", "example")
                self.assertNotEqual(result.returncode, 0, f"{label} should be refused")
                self.assertFalse(any(c[0] == "create" for c in self.calls()),
                                 f"{label} still created a container")
        good = self.tmp / "custom-claude"
        good.mkdir()
        self.env["CLAUDE_CONFIG_DIR"] = str(good)
        if self.log.exists():
            self.log.unlink()
        result = self.run_cli("create", "--agent", "claude", "example")
        self.assertEqual(result.returncode, 0, result.stderr)
        create = next(c for c in self.calls() if c[0] == "create")
        # Assert the exact bind: the configured (canonical) custom source mapped
        # to the standard in-container dest. Checking only the dest, or only a
        # matching source basename, would miss a bug binding the wrong directory
        # (e.g. the default ~/.claude, or a same-named dir under a different
        # parent) to ~/.claude. The wrapper resolves the source with realpath, so
        # compare against good.resolve().
        self.assertIn(f"{good.resolve()}:{link}/.claude", self._volumes(create),
                      f"agent bind was not <custom source>:~/.claude; got {self._volumes(create)}")

    def test_isolated_selinux_warns_before_relabeling_shared_dirs(self):
        # H4: isolated mode on an SELinux host relabels every shared directory,
        # live --agent credential dirs included, with :z on the host. Warn so
        # the relabel of credentials is not silent, while keeping the (tested)
        # live sharing. There is no :z and no warning without SELinux.
        home = self.tmp / "home"
        (home / ".claude").mkdir(parents=True)
        self.env.update(HOME=str(home), CLAUDE_CONFIG_DIR=str(home / ".claude"))
        result = self.run_cli("create", "--isolated", "--agent", "claude", "example",
                              scenario=dict(info="true true crun"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertRegex(result.stderr, r"relabel")
        self.assertRegex(result.stderr, r"agent")
        create = next(c for c in self.calls() if c[0] == "create")
        self.assertTrue(any(a.endswith("/.claude:z") for a in create),
                        "agent dir should still be shared live, with :z")
        self.log.unlink()
        result = self.run_cli("create", "--isolated", "--agent", "claude", "example",
                              scenario=dict(info="true false crun"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotRegex(result.stderr, r"relabel")

    def test_key_value_form_ignores_equals_in_comment(self):
        # An '=' inside a comment must not act as the assignment delimiter for
        # the space-separated "key value" form. "isolated true # note=x" must
        # stay isolated, not parse as an unknown key and drop to integrated.
        with self.config.open("a") as f:
            f.write("isolated true # note=x\n")
        result = self.run_cli("create", "example")
        self.assertEqual(result.returncode, 0, result.stderr)
        call = next(c for c in self.calls() if c[0] == "create")
        self.assertIn("toolboxer.mode=isolated", call)

    def test_invalid_quoted_mount_fails_before_any_create(self):
        # A malformed quoted mount must abort the command before any Podman
        # call, not be dropped. Dropping a sole bad mount falls back to the
        # broader DEFAULT_MOUNT_DIRS; dropping one beside a valid mount silently
        # shrinks the requested set. Both widen or distort host exposure, so the
        # existing invalid-mount contract requires a hard failure. Covers both
        # quote styles, partial and unterminated quotes, alone and with a valid
        # mount already present.
        src = self.tmp / "src"
        (src / "private").mkdir(parents=True)
        keep = self.tmp / "keep"
        keep.mkdir()
        bad_lines = (
            f'mount = "{src}"/private:/sel',   # partial double quote
            f"mount = '{src}'/private:/sel",   # partial single quote
            f'mount = "{src}/private:/sel',    # unterminated double quote
            f"mount = '{src}/private:/sel",    # unterminated single quote
        )
        for bad in bad_lines:
            for extra in ("", f"\nmount = {keep}:/keep"):   # sole, then beside a valid mount
                with self.subTest(bad=bad, extra=bool(extra)):
                    self.config.write_text(bad + extra + "\n")
                    if self.log.exists():
                        self.log.unlink()
                    result = self.run_cli("create", "example")
                    self.assertNotEqual(result.returncode, 0,
                                        f"{bad!r} should fail, not create")
                    self.assertIn("invalid quoted value", result.stderr)
                    self.assertEqual(self.calls(), [],
                                     f"{bad!r} still dispatched a Podman call")

    def test_equivalent_distro_alias_preserves_configured_release(self):
        with self.config.open("a") as config:
            config.write("distro = opensuse-leap\nrelease = 15.6\n")
        result = self.run_cli("create", "--distro", "suse", "example")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("registry.opensuse.org/opensuse/leap:15.6", next(c for c in self.calls() if c[0] == "create"))

    def test_relative_and_file_mount_workdirs(self):
        result = self.run_cli("create", "--isolated", "-m", ".", "example")
        self.assertEqual(result.returncode, 0, result.stderr)
        call = next(c for c in self.calls() if c[0] == "create")
        self.assertEqual(call[call.index("--workdir") + 1], str(self.tmp))
        self.log.unlink()
        result = self.run_cli("create", "--isolated", "-m", f"{self.config}:/config", "file-only")
        self.assertEqual(result.returncode, 0, result.stderr)
        call = next(c for c in self.calls() if c[0] == "create")
        self.assertEqual(call[call.index("--workdir") + 1], "/tmp")

    def test_mount_list_trailing_whitespace(self):
        self.env["MOUNT_DIRS"] = f"{self.tmp}, "
        self.assertEqual(self.run_cli("config").returncode, 0)

    def test_diagnostics_refuse_overwrite_and_default_to_read_checks(self):
        output = self.tmp / "diagnostics.log"
        self.env["MOCK_SCENARIO"] = json.dumps(dict(exists=True))
        result = subprocess.run([str(ROOT / "diagnose.sh"), "-o", str(output), "example"],
                                env=self.env, text=True, capture_output=True)
        self.assertTrue(output.exists(), result.stderr)
        self.assertEqual(output.stat().st_mode & 0o777, 0o600)
        for call in self.calls():
            self.assertFalse(any("mktemp" in a or "--version" == a or a == "-lc" for a in call), call)
            self.assertNotIn(["command", "-v"], [call[i:i + 2] for i in range(len(call))])
        original = output.read_bytes()
        result = subprocess.run([str(ROOT / "diagnose.sh"), "-o", str(output)], env=self.env,
                                text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(output.read_bytes(), original)

    def test_agent_selection_honors_xdg_without_creating_other_agents(self):
        self.env["XDG_CONFIG_HOME"] = str(self.tmp / "agent-config")
        self.env["XDG_DATA_HOME"] = str(self.tmp / "agent-data")
        result = self.run_cli("create", "--agent", "goose", "example")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.tmp / "agent-config/goose").is_dir())
        self.assertFalse((self.tmp / "agent-config/opencode").exists())
        call = next(c for c in self.calls() if c[0] == "create")
        self.assertTrue(any(str(self.tmp / "agent-config/goose") in a for a in call))

    def test_diagnostics_bound_every_podman_call_including_optional_checks(self):
        (self.bin / "timeout").symlink_to(ROOT / "tests" / "mock_timeout.py")
        timeout_log = self.tmp / "timeouts.jsonl"
        self.env["MOCK_TIMEOUT_LOG"] = str(timeout_log)
        self.env["MOCK_SCENARIO"] = json.dumps(dict(exists=True, output="present"))
        subprocess.run([str(ROOT / "diagnose.sh"), "--agent-versions", "--write-probes",
                        "-o", str(self.tmp / "optional.log"), "example"],
                       env=self.env, text=True, capture_output=True, timeout=15)
        timed_calls = [json.loads(line) for line in timeout_log.read_text().splitlines()]
        self.assertEqual([c[4:] for c in timed_calls], self.calls())
        self.assertTrue(any(any('--version' in a for a in c) for c in self.calls()))
        self.assertTrue(any(any('mktemp' in a for a in c) for c in self.calls()))
        self.assertTrue(all(c[:3] == ["-k", "2s", "10s"] for c in timed_calls))

    def test_diagnostics_include_sudo_executable_and_target_metadata(self):
        self.env["MOCK_SCENARIO"] = json.dumps(dict(exists=True))
        result = subprocess.run([str(ROOT / "diagnose.sh"), "-o", str(self.tmp / "sudo-diagnostics.log"), "example"],
                                env=self.env, text=True, capture_output=True)
        self.assertIn("sudo executable metadata", result.stdout)
        calls = [c for c in self.calls() if c[0] == "exec" and any('sudo_bin=' in a for a in c)]
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][1:3], ["--user", "0"])
        self.assertIn('stat -Lc "%F %u:%g %a %n"', calls[0][-1])

    def test_failed_home_inspection_stops_before_repair_or_markers(self):
        result = self.run_cli("run", "-c", "example", "payload", scenario=dict(
            exists=True, setup_pending=True, fail_mount_inspect=True))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("refusing to repair", result.stderr)
        self.assertFalse(any("touch" in c for c in self.calls()))

    def test_agent_files_are_copied_and_temporary_credentials_cleaned_on_failure(self):
        test_home = self.tmp / "home"
        test_home.mkdir()
        (test_home / ".claude.json").write_text('{"fixture": true}')
        self.env["HOME"] = str(test_home)
        for failure in ([], ["cp"]):
            self.log.unlink(missing_ok=True)
            result = self.run_cli("create", "--agent", "claude", "example", scenario=dict(fail=failure))
            self.assertEqual(result.returncode == 0, not failure, result.stderr)
            create = next(c for c in self.calls() if c[0] == "create")
            self.assertFalse(any(".claude.json:" in a for a in create))
            copy = next(c for c in self.calls() if c[0] == "cp")
            self.assertFalse(Path(copy[1]).exists())
            self.assertEqual((test_home / ".claude.json").read_text(), '{"fixture": true}')

    def test_create_rolls_back_only_its_own_container_on_later_failure(self):
        test_home = self.tmp / "home"
        test_home.mkdir()
        (test_home / ".claude.json").write_text('{"fixture": true}')
        self.env["HOME"] = str(test_home)
        created = "c" * 64
        rollback = ["rm", "--volumes", created]
        # Each post-create step fails in turn; the container is removed by the
        # ID podman create printed, never by name, and without --force.
        for scenario, extra in ((dict(fail=["inspect"]), ()), (dict(fail=["cp"]), ("--agent", "claude"))):
            self.log.unlink(missing_ok=True)
            result = self.run_cli("create", *extra, "example", scenario=scenario)
            self.assertEqual(result.returncode, 125, result.stderr)
            self.assertEqual([c for c in self.calls() if c[0] == "rm"], [rollback], scenario)
            # Progress lines and the ID podman create prints stay on stdout
            # exactly as before; only the rollback's own output is hidden.
            self.assertEqual(result.stdout.count(created), 1, scenario)
        # remember_image fails with status 1 when the state root is a file, so
        # a failed cleanup (125) is proven not to replace the original status.
        self.log.unlink(missing_ok=True)
        blocker = self.tmp / "state-file"
        blocker.write_text("")
        self.env["XDG_STATE_HOME"] = str(blocker)
        result = self.run_cli("create", "example", scenario=dict(fail=["rm"]))
        self.env["XDG_STATE_HOME"] = str(self.tmp / "state")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual([c for c in self.calls() if c[0] == "rm"], [rollback])
        self.assertIn(f"could not remove partially created container {created}", result.stderr)
        # No rollback on success, on a failed create, or when the name exists.
        for scenario, status in (({}, 0), (dict(fail=["create"]), 125), (dict(exists=True), 1)):
            self.log.unlink(missing_ok=True)
            result = self.run_cli("create", "example", scenario=scenario)
            self.assertEqual(result.returncode, status, result.stderr)
            self.assertFalse(any(c[0] == "rm" for c in self.calls()), scenario)

    def test_create_interrupted_during_setup_removes_its_container(self):
        test_home = self.tmp / "home"
        test_home.mkdir()
        (test_home / ".claude.json").write_text('{"fixture": true}')
        self.env["HOME"] = str(test_home)
        self.env["MOCK_SCENARIO"] = json.dumps(dict(cp_delay=3))
        # A signal aimed at the wrapper PID alone must still cancel the setup
        # child that owns the cleanup; group delivery covers Ctrl-C and kill.
        for target, signum, status in (("pid", signal.SIGTERM, 143),
                                       ("group", signal.SIGTERM, 143),
                                       ("group", signal.SIGINT, 130)):
            self.log.unlink(missing_ok=True)
            process = subprocess.Popen([str(ROOT / "toolboxer"), "create", "--agent", "claude", "example"],
                                       env=self.env, cwd=self.tmp, text=True, start_new_session=True,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline and not any(c[0] == "cp" for c in self.calls()):
                    time.sleep(0.05)
                self.assertTrue(any(c[0] == "cp" for c in self.calls()), "copy never started")
                if target == "pid":
                    os.kill(process.pid, signum)
                else:
                    os.killpg(process.pid, signum)
                stdout, stderr = process.communicate(timeout=20)
            finally:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.communicate()
            self.assertEqual(process.returncode, status, (target, signum, stderr))
            self.assertEqual([c for c in self.calls() if c[0] == "rm"], [["rm", "--volumes", "c" * 64]], (target, signum))
            self.assertNotIn("created!", stderr, (target, signum))

    def test_agent_credential_snapshot_is_removed_on_interrupt(self):
        # copy_agent_files stages agent credentials in a mode-600 mktemp dir
        # before podman cp. An interrupt mid-copy must delete that snapshot
        # rather than leave real credentials on disk.
        test_home = self.tmp / "home"
        test_home.mkdir()
        (test_home / ".claude.json").write_text('{"fixture": true}')
        self.env["HOME"] = str(test_home)
        self.env["MOCK_SCENARIO"] = json.dumps(dict(cp_delay=3))
        process = subprocess.Popen([str(ROOT / "toolboxer"), "create", "--agent", "claude", "example"],
                                   env=self.env, cwd=self.tmp, text=True, start_new_session=True,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline and not any(c[0] == "cp" for c in self.calls()):
                time.sleep(0.05)
            cp = next(c for c in self.calls() if c[0] == "cp")
            os.killpg(process.pid, signal.SIGINT)
            process.communicate(timeout=20)
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
                process.communicate()
        stage = cp[1][:-2] if cp[1].endswith("/.") else os.path.dirname(cp[1])
        self.assertEqual(process.returncode, 130)
        self.assertFalse(os.path.exists(stage), f"credential staging dir {stage} leaked")

    def test_create_removes_container_when_id_output_pipe_closes(self):
        # Publishing the created ID must not orphan the container when the
        # stdout reader has already gone away; that write raises SIGPIPE after
        # the container exists. create_delay holds podman create open so the
        # reader closes before the ID is written.
        test_home = self.tmp / "home"
        test_home.mkdir()
        self.env["HOME"] = str(test_home)
        self.env["MOCK_SCENARIO"] = json.dumps(dict(create_delay=3))
        process = subprocess.Popen([str(ROOT / "toolboxer"), "create", "example"],
                                   env=self.env, cwd=self.tmp, text=True,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            # The reader goes away before the ID is written (create_delay holds
            # podman create open, and progress now goes to stderr), so the ID
            # write to stdout raises SIGPIPE.
            process.stdout.close()
            process.wait(timeout=20)
            stderr = process.stderr.read()
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            process.stderr.close()
        self.assertEqual(process.returncode, 141, stderr)
        self.assertEqual([c for c in self.calls() if c[0] == "rm"], [["rm", "--volumes", "c" * 64]])

    def test_runtime_dir_is_canonicalised_consistently(self):
        # A non-canonical XDG_RUNTIME_DIR must be canonicalised identically for
        # the tmpfs mount, the saved label, and the exported env value; a
        # divergent env path can fail to resolve in the container even when the
        # tmpfs exists at the resolved path.
        self.env["XDG_RUNTIME_DIR"] = f"{self.tmp}/rt/../rt"
        result = self.run_cli("create", "example", scenario={})
        self.assertEqual(result.returncode, 0, result.stderr)
        create = next(c for c in self.calls() if c[0] == "create")

        def paired(flag, prefix=""):
            for i, arg in enumerate(create):
                if arg == flag and create[i + 1].startswith(prefix):
                    return create[i + 1]
            self.fail(f"{flag} {prefix!r} absent from create args")

        env_val = paired("--env", "XDG_RUNTIME_DIR=").split("=", 1)[1]
        tmpfs_target = paired("--tmpfs").split(":", 1)[0]
        label_val = paired("--label", "toolboxer.runtime-dir=").split("=", 1)[1]
        self.assertEqual(env_val, tmpfs_target)
        self.assertEqual(env_val, label_val)
        self.assertNotIn("/../", env_val)
        self.assertFalse(env_val.endswith("/.."))

    def test_pull_policy_controls_image_refresh(self):
        # --pull always refreshes from the registry even when the image is
        # present locally (the fix for stale/relocated image storage).
        result = self.run_cli("create", "--pull", "always", "example", scenario={})
        self.assertEqual(result.returncode, 0, result.stderr)
        pull = next((c for c in self.calls() if c[0] == "pull"), None)
        self.assertIsNotNone(pull, "expected a podman pull call for --pull always")
        self.assertIn("--policy", pull)
        self.assertIn("always", pull)
        # The default policy (missing) does not pull when the image exists.
        self.log.unlink(missing_ok=True)
        result = self.run_cli("create", "example2", scenario={})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(c[0] == "pull" for c in self.calls()),
                         "default --pull missing must not pull an existing image")
        # An invalid policy is rejected.
        result = self.run_cli("create", "--pull", "banana", "example3", scenario={})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid --pull", result.stderr)
        # never is enforced on the create itself (not just the pre-check), so a
        # race between the existence check and creation cannot trigger a pull.
        self.log.unlink(missing_ok=True)
        result = self.run_cli("create", "--pull", "never", "example4", scenario={})
        self.assertEqual(result.returncode, 0, result.stderr)
        create = next(c for c in self.calls() if c[0] == "create")
        self.assertIn("--pull=never", create)
        self.assertFalse(any(c[0] == "pull" for c in self.calls()), "never must not pull")

    def test_removal_failures_and_volume_cleanup(self):
        result = self.run_cli("rm", "example", scenario=dict(exists=True, fail=["rm"]))
        self.assertNotEqual(result.returncode, 0)
        call = next(c for c in self.calls() if c[0] == "rm")
        self.assertIn("--volumes", call)
        self.assertNotEqual(self.run_cli("list", scenario=dict(fail=["container"])).returncode, 0)

    def test_container_image_inspection_failure_does_not_skip_other_targets(self):
        result = self.run_cli("rm", "bad", "good", scenario=dict(exists=True, fail_image_for="bad"))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual([c[-1] for c in self.calls() if c[0] == "rm"], ["good"])

    def test_image_tracking_includes_base_images_after_container_removal(self):
        self.assertEqual(self.run_cli("create", "example").returncode, 0)
        result = self.run_cli("list", "--images")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("ubuntu:latest", result.stdout)

    def test_force_image_removal_never_deletes_unmanaged_dependents(self):
        result = self.run_cli("rmi", "--force", "ubuntu", scenario=dict(dependencies="unrelated\tfalse"))
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(c[0] in ("rm", "rmi") for c in self.calls()))
        self.log.unlink()
        result = self.run_cli("rmi", "--force", "ubuntu", scenario=dict(dependencies="ours\ttrue"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--volumes", next(c for c in self.calls() if c[0] == "rm"))
        call = next(c for c in self.calls() if c[0] == "rmi")
        self.assertNotIn("--force", call)
        self.assertNotIn("-f", call)
        self.assertNotEqual(self.run_cli("rmi", "ubuntu", scenario=dict(fail=["rmi"])).returncode, 0)

    def test_automatic_selection_does_not_corrupt_stdout(self):
        result = self.run_cli("run", "printf", "{}", scenario=dict(containers="only", output="{}"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "{}")
        self.assertIn("Using container", result.stderr)

    def test_failed_setup_never_marks_success_or_runs_payload(self):
        for failure in ("fail_setup", "fail_sudo", "fail_sudo_metadata"):
            self.log.unlink(missing_ok=True)
            result = self.run_cli("run", "-c", "example", "payload", scenario={
                "exists": True, "setup_pending": True, failure: True})
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(any("touch" in c and "/etc/.toolboxer-setup-v1" in c for c in self.calls()))
            self.assertFalse(any("payload" in c for c in self.calls()))

    def run_sudo_metadata_repair(self, *binds, fail_chown=False, lose_chown=False):
        source = (ROOT / "toolboxer").read_text()
        start = source.index("repair_sudo_metadata() {")
        function = source[start:source.index("\n}\n", start) + 3]
        # Real files, chmod and symlink resolution; emulate ownership only so
        # these safe tests need neither root nor working user namespaces.
        script = '''
set -euo pipefail
declare -A repaired=()
stat() {
    local path="${@: -1}"
    if [[ "$2" == '%u:%g' ]]; then
        if [[ "${repaired[$path]:-}" == yes ]]; then echo 0:0; else echo 1980:1980; fi
    else
        command stat "$@"
    fi
}
chown() {
    [[ "$1" == -- && "$2" == 0:0 ]]
    [[ "$FAIL_CHOWN" != true ]] || return 77
    command chmod u-s -- "${@: -1}"
    if [[ "$LOSE_CHOWN" != true ]]; then repaired["${@: -1}"]=yes; fi
}
'''
        env = dict(self.env, FAIL_CHOWN=str(fail_chown).lower(), LOSE_CHOWN=str(lose_chown).lower())
        return subprocess.run(["bash", "-c", script + function + '\nrepair_sudo_metadata "$@"', "bash",
                               str(self.tmp / "sudo"), str(self.tmp / "sudo.conf"),
                               str(self.tmp / "sudoers"), str(self.tmp / "sudoers.d"), *map(str, binds)],
                              env=env, text=True, capture_output=True)

    def prepare_sudo_metadata_fixture(self):
        (self.tmp / "sudo").write_bytes(b"unchanged executable fixture")
        (self.tmp / "sudo").chmod(0o111)
        (self.tmp / "sudo.conf").write_text("# preserve configuration\n")
        (self.tmp / "sudoers").write_text("# preserve main policy\n")
        (self.tmp / "sudoers.d").mkdir(mode=0o750)
        (self.tmp / "sudoers.d" / "existing").write_text("# preserve existing drop-in\n")
        return {p: p.stat().st_ino for p in self.tmp.glob("sudo*")}

    def test_sudo_metadata_repairs_reported_mode_without_replacing_files(self):
        inodes = self.prepare_sudo_metadata_fixture()
        for _ in range(2):
            result = self.run_sudo_metadata_repair()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((self.tmp / "sudo").stat().st_mode & 0o7777, 0o4111)
            self.assertEqual({p: p.stat().st_ino for p in inodes}, inodes)
        (self.tmp / "sudo").chmod(0o755)  # read the fixture after testing execute-only permissions
        self.assertEqual((self.tmp / "sudo").read_bytes(), b"unchanged executable fixture")
        self.assertEqual((self.tmp / "sudoers.d" / "existing").read_text(), "# preserve existing drop-in\n")

    def test_sudo_metadata_rejects_host_bind_targets_before_any_changes(self):
        self.prepare_sudo_metadata_fixture()
        alias = self.tmp / "sudoers-link"
        alias.symlink_to(self.tmp / "sudoers.d", target_is_directory=True)
        for bind in (Path("/"), self.tmp, self.tmp / "sudo", self.tmp / "sudoers.d" / "existing", alias):
            result = self.run_sudo_metadata_repair(bind)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("host bind mount", result.stderr)
            self.assertEqual((self.tmp / "sudo").stat().st_mode & 0o7777, 0o111)

    def test_sudo_metadata_follows_local_binary_symlinks_and_handles_missing_optional_paths(self):
        self.prepare_sudo_metadata_fixture()
        (self.tmp / "sudo").rename(self.tmp / "sudo-real")
        (self.tmp / "sudo").symlink_to("sudo-real")
        (self.tmp / "sudo.conf").unlink()
        # openSUSE Leap ships no /etc/sudoers, only /etc/sudoers.d; repair must
        # not treat the absent main file as an error.
        (self.tmp / "sudoers").unlink()
        (self.tmp / "sudoers.d" / "existing").unlink()
        (self.tmp / "sudoers.d").rmdir()
        result = self.run_sudo_metadata_repair()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.tmp / "sudo").is_symlink())
        self.assertEqual((self.tmp / "sudo-real").stat().st_mode & 0o7777, 0o4111)
        self.assertTrue((self.tmp / "sudoers.d").is_dir())
        self.assertFalse((self.tmp / "sudoers").exists())

    def test_sudo_metadata_rejects_symlink_to_host_mount(self):
        self.prepare_sudo_metadata_fixture()
        host = self.tmp / "host"
        host.mkdir()
        (self.tmp / "sudo").rename(host / "sudo")
        (self.tmp / "sudo").symlink_to(host / "sudo")
        result = self.run_sudo_metadata_repair(host)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("host bind mount", result.stderr)
        self.assertEqual((host / "sudo").stat().st_mode & 0o7777, 0o111)

    def test_sudo_metadata_reports_failed_or_ineffective_chown(self):
        self.prepare_sudo_metadata_fixture()
        for options in (dict(fail_chown=True), dict(lose_chown=True)):
            result = self.run_sudo_metadata_repair(**options)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(str(self.tmp / "sudo"), result.stderr)
            self.assertIn("1980:1980", result.stderr)

    def test_isolated_checks_existing_containers(self):
        result = self.run_cli("--isolated", "run", "-c", "existing", "true", scenario=dict(exists=True))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not satisfy --isolated", result.stderr)
        self.assertFalse(any(c[0] == "exec" for c in self.calls()))

    def test_isolated_creation_has_explicit_namespaces_and_entrypoint(self):
        result = self.run_cli("create", "--isolated", "example")
        self.assertEqual(result.returncode, 0, result.stderr)
        call = next(c for c in self.calls() if c[0] == "create")
        for option in ("--network", "--pid", "--ipc", "--uts"):
            self.assertEqual(call[call.index(option) + 1], "private")
        self.assertIn("--init", call)
        self.assertIn("--privileged=false", call)
        self.assertEqual(call[call.index("--entrypoint") + 1], "sleep")
        self.assertNotIn("SELinux confinement requested", result.stdout)

    def test_isolated_labels_and_uts_are_checked_and_privileged_still_works(self):
        for mode in ("false|private|private|private|system_u:system_r:container_t:s0|isolated|false|all|host",
                     "false|private|private|private|unconfined_u:unconfined_r:unconfined_t:s0|isolated|false|all|private"):
            result = self.run_cli("create", "--isolated", "example", scenario=dict(info="true true crun", mode=mode))
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("does not satisfy --isolated", result.stderr)
        result = self.run_cli("create", "--isolated", "example", scenario=dict(info="true true crun"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("SELinux confinement requested", result.stderr)
        result = self.run_cli("create", "--privileged", "example", scenario={})
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_runtime_mount_does_not_expose_host_directory(self):
        runtime = self.tmp / "runtime"
        runtime.mkdir()
        self.env["XDG_RUNTIME_DIR"] = str(runtime)
        result = self.run_cli("create", "example")
        self.assertEqual(result.returncode, 0, result.stderr)
        call = next(c for c in self.calls() if c[0] == "create")
        self.assertNotIn(f"{runtime}:{runtime}", call)
        self.assertFalse(any("podman.sock" in arg for arg in call))
        self.assertIn("--tmpfs", call)
        self.assertEqual(call[call.index("--tmpfs") + 1], f"{runtime}:rw,mode=0700,notmpcopyup")

    def test_unsafe_socket_paths_are_not_forwarded(self):
        # L6: a host-integration socket whose path contains ':' cannot be a
        # valid --volume src:dest, so it is skipped rather than mounted with a
        # corrupted spec; a normal path is still mounted. A newline is worse: it
        # would also split the --env forwarding (collect_args uses mapfile -t)
        # into stray create arguments, so the env value is dropped too.
        import socket as socketlib
        good = self.tmp / "ssh.sock"
        colon = self.tmp / "a:b.sock"
        for path in (good, colon):
            s = socketlib.socket(socketlib.AF_UNIX)
            s.bind(str(path))
            self.addCleanup(s.close)
        self.env["SSH_AUTH_SOCK"] = str(colon)
        result = self.run_cli("create", "example")
        self.assertEqual(result.returncode, 0, result.stderr)
        volumes = self._volumes(next(c for c in self.calls() if c[0] == "create"))
        self.assertFalse(any("a:b.sock" in v for v in volumes),
                         "a colon-bearing socket path was mounted")
        # An unsafe socket that is present but unmountable is skipped with a
        # warning, not silently, so a missing agent inside is explained.
        self.assertIn("not forwarding the SSH agent", result.stderr,
                      "no warning when an unsafe SSH_AUTH_SOCK was skipped")
        self.log.unlink()
        self.env["SSH_AUTH_SOCK"] = str(good)
        result = self.run_cli("create", "example")
        self.assertEqual(result.returncode, 0, result.stderr)
        volumes = self._volumes(next(c for c in self.calls() if c[0] == "create"))
        self.assertIn(f"{good}:{good}", volumes, "a normal socket path was not mounted")
        self.assertNotIn("not forwarding the SSH agent", result.stderr,
                         "warned about a socket that was forwarded fine")
        # A newline value must not split into a stray argument through --env.
        self.log.unlink()
        self.env["SSH_AUTH_SOCK"] = f"{self.tmp}/agent\nbad.sock"
        result = self.run_cli("create", "example")
        self.assertEqual(result.returncode, 0, result.stderr)
        create = next(c for c in self.calls() if c[0] == "create")
        self.assertFalse(any("bad.sock" in a for a in create),
                         "a newline socket value split into a stray create argument")

    def test_isolated_create_omits_host_service_binds(self):
        # Isolated mode promises no automatic host-service mounts, so create must
        # leave out the host SSH agent, D-Bus, X11, and host config files that an
        # integrated create forwards. The live suite proves private namespaces at
        # runtime but not that these binds were omitted from the create spec.
        import socket as socketlib
        ssh = self.tmp / "ssh.sock"
        dbus = self.tmp / "dbus.sock"
        for path in (ssh, dbus):
            s = socketlib.socket(socketlib.AF_UNIX)
            s.bind(str(path))
            self.addCleanup(s.close)
        self.env.update(SSH_AUTH_SOCK=str(ssh),
                        DBUS_SESSION_BUS_ADDRESS=f"unix:path={dbus}")
        host_paths = (str(ssh), str(dbus), "/tmp/.X11-unix",
                      "/etc/resolv.conf", "/etc/machine-id")

        result = self.run_cli("create", "--isolated", "example")
        self.assertEqual(result.returncode, 0, result.stderr)
        iso_vols = self._volumes(next(c for c in self.calls() if c[0] == "create"))
        for p in host_paths:
            self.assertFalse(any(p in v for v in iso_vols),
                             f"isolated create bound a host service/config path: {p}\n{iso_vols}")

        # Sanity: an integrated create with the same host services forwards them,
        # so the assertion above would notice if isolation stopped omitting them.
        self.log.unlink()
        result = self.run_cli("create", "example")
        self.assertEqual(result.returncode, 0, result.stderr)
        int_vols = self._volumes(next(c for c in self.calls() if c[0] == "create"))
        self.assertIn(f"{ssh}:{ssh}", int_vols,
                      "integrated create did not forward the host SSH socket; test is not meaningful")

    @staticmethod
    def _volumes(create_call):
        return [create_call[i + 1] for i, a in enumerate(create_call) if a == "--volume"]

    def test_runtime_ownership_uses_saved_tmpfs_on_each_start(self):
        # A start (created/exited -> running) reowns the fresh, root-owned tmpfs
        # using the saved runtime dir, non-recursively. A container already
        # running skips this redundant reown; see the warm-path test below.
        for state in ("created", "exited"):
            self.log.unlink(missing_ok=True)
            result = self.run_cli("run", "-c", "example", "payload", scenario=dict(
                exists=True, state=state, runtime_dir="/saved/runtime", tmpfs_dirs="/saved/runtime"))
            self.assertEqual(result.returncode, 0, result.stderr)
            repair = next(c for c in self.calls() if any("chmod 0700" in a for a in c))
            self.assertEqual(repair[-2:], ["1000:1000", "/saved/runtime"])
            self.assertFalse(any("-R" in a for a in repair))

    def test_warm_running_container_skips_redundant_runtime_reown(self):
        # M5: an already-running container's runtime tmpfs was reowned on its
        # start and is writable, so the warm path skips the redundant chown/chmod
        # while a start we perform still reowns the fresh tmpfs.
        result = self.run_cli("run", "-c", "example", "payload", scenario=dict(
            exists=True, state="running", runtime_dir="/saved/runtime", tmpfs_dirs="/saved/runtime"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(any("chmod 0700" in a for a in c) for c in self.calls()),
                         "reowned an already-writable running runtime dir")
        for state in ("created", "exited"):
            self.log.unlink(missing_ok=True)
            result = self.run_cli("run", "-c", "example", "payload", scenario=dict(
                exists=True, state=state, runtime_dir="/saved/runtime", tmpfs_dirs="/saved/runtime"))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(any(any("chmod 0700" in a for a in c) for c in self.calls()), state)

    def test_external_start_reowns_runtime_when_not_writable(self):
        # M5: a start performed outside toolboxer leaves a fresh root-owned
        # runtime tmpfs. On the warm path (state running) toolboxer must not skip
        # the reown for a root-owned dir; it reowns it, confirms it, and proceeds.
        result = self.run_cli("run", "-c", "example", "payload", scenario=dict(
            exists=True, state="running", runtime_dir="/saved/runtime",
            tmpfs_dirs="/saved/runtime", runtime_root_owned=True))
        self.assertEqual(result.returncode, 0, result.stderr)
        repair = next(c for c in self.calls() if any("chmod 0700" in a for a in c))
        self.assertEqual(repair[-2:], ["1000:1000", "/saved/runtime"])
        self.assertTrue(any("payload" in c for c in self.calls()))

    def test_warm_running_repairs_runtime_dir_not_meeting_contract(self):
        # M5/db:139: writability alone is not enough to skip the reown. A running
        # container whose runtime dir does not already meet the private-runtime
        # contract must still be repaired to uid:gid mode 0700, not skipped:
        # 0600/0200 are writable by the owner but lack the search bit (unusable),
        # 0777 is too permissive for the XDG contract, and a wrong group also
        # fails it. Each must reown; none may reach the payload without repair.
        for meta in ("1000:1000:600", "1000:1000:200", "1000:1000:777", "1000:2450:700"):
            self.log.unlink(missing_ok=True)
            result = self.run_cli("run", "-c", "example", "payload", scenario=dict(
                exists=True, state="running", runtime_dir="/saved/runtime",
                tmpfs_dirs="/saved/runtime", runtime_meta=meta))
            self.assertEqual(result.returncode, 0, (meta, result.stderr))
            repair = next((c for c in self.calls() if any("chmod 0700" in a for a in c)), None)
            self.assertIsNotNone(repair, f"did not repair runtime dir with metadata {meta}")
            self.assertEqual(repair[-2:], ["1000:1000", "/saved/runtime"], meta)

    def test_payload_with_stat_text_is_not_intercepted(self):
        # The warm-path runtime check is one specific internal exec. A user
        # payload must run normally with its output and status intact even when
        # an argument contains the same stat text, or is byte-identical to the
        # whole internal check script; only the exact internal exec shape is the
        # check. Otherwise the mock could mask payload failures in any test.
        exact = '[ "$(stat -c "%u:%g:%a" "$1")" = "$2:700" ] && [ -w "$1" ]'
        for payload in ("stat -c %a /tmp", exact):
            self.log.unlink(missing_ok=True)
            result = self.run_cli("run", "-c", "example", "payload", payload,
                                  scenario=dict(exists=True, state="running",
                                                runtime_dir="/saved/runtime", tmpfs_dirs="/saved/runtime",
                                                output="PAYLOAD-OUT", payload_status=37))
            self.assertEqual(result.returncode, 37, (payload, result.stderr))
            self.assertIn("PAYLOAD-OUT", result.stdout, payload)

    def test_warm_runtime_check_runs_as_the_user(self):
        # The warm-path postcondition check must run as the user, so it reflects
        # the user's own access (an ancestor they cannot traverse), not root's.
        # Assert the recorded check exec uses --user <uid:gid>.
        result = self.run_cli("run", "-c", "example", "payload", scenario=dict(
            exists=True, state="running", runtime_dir="/saved/runtime", tmpfs_dirs="/saved/runtime"))
        self.assertEqual(result.returncode, 0, result.stderr)
        check = next(c for c in self.calls()
                     if c[0] == "exec" and any('stat -c "%u:%g:%a"' in a for a in c))
        self.assertEqual(check[check.index("--user") + 1], "1000:1000")

    def test_warm_start_combines_state_and_tmpfs_inspects(self):
        # M5: the warm path reads run state and the tmpfs list in one podman
        # inspect rather than two. The runtime-dir label is deliberately kept in
        # its own query (it is untrusted multi-line metadata), so it must not be
        # folded into the state/tmpfs query.
        result = self.run_cli("run", "-c", "example", "payload", scenario=dict(
            exists=True, state="running", runtime_dir="/saved/runtime", tmpfs_dirs="/saved/runtime"))
        self.assertEqual(result.returncode, 0, result.stderr)
        templates = [c[c.index("--format") + 1] for c in self.calls()
                     if c[0] == "inspect" and "--format" in c]
        stateq = [t for t in templates if "State.Status" in t]
        self.assertEqual(len(stateq), 1, templates)
        self.assertIn("HostConfig.Tmpfs", stateq[0])
        # The state/tmpfs query must not carry the untrusted label, and no
        # separate tmpfs-only query may remain.
        self.assertNotIn("toolboxer.runtime-dir", stateq[0])
        for t in templates:
            if "State.Status" in t:
                continue
            self.assertNotIn("HostConfig.Tmpfs", t, t)

    def test_malformed_runtime_label_refuses_before_any_ownership_change(self):
        # M5: a saved runtime-dir label may hold an embedded newline (create
        # rejects such paths, but the enter/run consumer must still fail closed).
        # It must never be split so one of its lines matches the tmpfs list and
        # authorises a chown/chmod. An embedded LF, and a leading LF, must both
        # refuse execution without any ownership command, while a genuinely
        # missing label keeps its legacy skip (no repair, payload runs).
        refuse = ("/host/runtime\n/host/runtime", "\n/host/runtime")
        for label in refuse:
            self.log.unlink(missing_ok=True)
            result = self.run_cli("run", "-c", "example", "payload", scenario=dict(
                exists=True, state="running", runtime_dir=label, tmpfs_dirs="/other"))
            self.assertNotEqual(result.returncode, 0, label)
            self.assertFalse(any(any("chmod 0700" in a for a in c) for c in self.calls()), label)
            self.assertFalse(any(any("chown" in a for a in c) for c in self.calls()), label)
            self.assertFalse(any("payload" in c for c in self.calls()), label)
        # A missing label is the legacy shape: skip repair, do not refuse.
        self.log.unlink(missing_ok=True)
        result = self.run_cli("run", "-c", "example", "payload", scenario=dict(
            exists=True, state="running", runtime_dir="", tmpfs_dirs="/other"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(any("chmod 0700" in a for a in c) for c in self.calls()))
        self.assertTrue(any("payload" in c for c in self.calls()))

    def test_keep_id_and_runtime_use_nondefault_host_ids(self):
        scenario = dict(host_uid=1980, host_gid=2450)
        result = self.run_cli("create", "example", scenario=scenario)
        self.assertEqual(result.returncode, 0, result.stderr)
        create = next(c for c in self.calls() if c[0] == "create")
        self.assertEqual([a for a in create if a.startswith("--userns=")], ["--userns=keep-id"])
        self.assertEqual(create[create.index("--user") + 1], "root")
        # state=exited forces a start, so the fresh tmpfs is reowned and the
        # chown target (the nondefault host IDs) can be asserted.
        result = self.run_cli("run", "-c", "example", "payload", scenario=dict(exists=True, state="exited", **scenario))
        self.assertEqual(result.returncode, 0, result.stderr)
        repair = next(c for c in self.calls() if any("chmod 0700" in a for a in c))
        self.assertEqual(repair[-2], "1980:2450")
        payload = next(c for c in self.calls() if "payload" in c)
        self.assertEqual(payload[payload.index("--user") + 1], "1980:2450")

    def test_runtime_ownership_failure_blocks_the_payload(self):
        # The empty-tmpfs guard blocks before any reown. fail_runtime_ownership
        # uses state=exited so the reown runs and its chmod fails. Crucially,
        # fail_runtime_writable stays on the warm path (state defaults to
        # running): even a container that looks correctly owned must have its
        # user-access re-verified, so a dir the user cannot write blocks there too
        # rather than being skipped.
        for scenario in (dict(runtime_dir="/saved/runtime", tmpfs_dirs=""),
                         dict(runtime_dir="/saved/runtime", tmpfs_dirs="/saved/runtime", state="exited", fail_runtime_ownership=True),
                         dict(runtime_dir="/saved/runtime", tmpfs_dirs="/saved/runtime", fail_runtime_writable=True)):
            self.log.unlink(missing_ok=True)
            result = self.run_cli("run", "-c", "example", "payload", scenario=dict(exists=True, **scenario))
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(any("payload" in c for c in self.calls()))
            if not scenario["tmpfs_dirs"]:
                self.assertFalse(any(any("chmod 0700" in a for a in c) for c in self.calls()))

    def test_integrated_first_setup_repairs_runtime_before_setup_and_payload(self):
        result = self.run_cli("create", "example")
        self.assertEqual(result.returncode, 0, result.stderr)
        result = self.run_cli("run", "-c", "example", "payload", scenario=dict(
            exists=True, state="configured", setup_pending=True))
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls()
        repair = next(i for i, c in enumerate(calls) if any("chmod 0700" in a for a in c))
        setup = next(i for i, c in enumerate(calls) if c[0] == "exec" and "-s" in c)
        payload = next(i for i, c in enumerate(calls) if "payload" in c)
        self.assertLess(repair, setup)
        self.assertLess(setup, payload)

    def test_invalid_runtime_paths_do_not_create(self):
        for runtime in ("relative", "/", "/run/..", "/run/with:colon", "/run/with\nnewline", "/run/with\ttab"):
            self.env["XDG_RUNTIME_DIR"] = runtime
            result = self.run_cli("create", "example")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("XDG_RUNTIME_DIR", result.stderr)
        self.assertFalse(any(c[0] == "create" for c in self.calls()))

    def test_runtime_mount_and_label_use_the_same_normalized_path(self):
        runtime = self.tmp / "runtime"
        self.env["XDG_RUNTIME_DIR"] = f"{runtime}//./"
        result = self.run_cli("create", "example")
        self.assertEqual(result.returncode, 0, result.stderr)
        create = next(c for c in self.calls() if c[0] == "create")
        self.assertIn(f"toolboxer.runtime-dir={runtime}", create)
        self.assertEqual(create[create.index("--tmpfs") + 1], f"{runtime}:rw,mode=0700,notmpcopyup")
        result = self.run_cli("run", "-c", "example", "payload", scenario=dict(exists=True))
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_legacy_runtime_bind_is_not_reowned(self):
        # A legacy container either records no private runtime tmpfs (older
        # layout) or records a runtime dir that is a host bind rather than the
        # tmpfs. Neither may be chmod'd/chowned. The old test drove neither
        # case: with no recorded runtime dir the repair returns immediately, so
        # a regression that reowned a host bind would still have passed. Cover
        # both shapes across stopped and running states.
        # A metadata write is any chown/chmod that names the runtime path,
        # whether the tokens are separate argv (chmod 0700 -- path) or inside
        # the sh -c repair string with the path as a later argument. Checking a
        # single "chmod 0700" element missed the direct-argv form and chown
        # entirely, so a write before the guard's refusal went undetected.
        def touches_runtime(path):
            for call in self.calls():
                if any(("chown" in a or "chmod" in a) for a in call) \
                        and any(path in a for a in call):
                    return True
            return False

        for state in ("created", "exited", "running"):
            # No recorded runtime dir: repair is skipped and the run proceeds.
            self.log.unlink(missing_ok=True)
            result = self.run_cli("run", "-c", "example", "payload",
                                  scenario=dict(exists=True, state=state, runtime_dir=""))
            self.assertEqual(result.returncode, 0, result.stderr)
            # With no saved label the legacy runtime path the wrapper could
            # reach is $XDG_RUNTIME_DIR, not the id-derived default, so check the
            # actual fixture value.
            self.assertFalse(touches_runtime(self.env["XDG_RUNTIME_DIR"]), state)
            self.assertTrue(any("payload" in c for c in self.calls()))
            # A recorded runtime dir that is not the private tmpfs (a host bind)
            # is refused, never reowned, and the payload does not run.
            self.log.unlink(missing_ok=True)
            result = self.run_cli("run", "-c", "example", "payload", scenario=dict(
                exists=True, state=state, runtime_dir="/run/user/1000", tmpfs_dirs="/other/tmpfs"))
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("refusing ownership changes", result.stderr)
            self.assertFalse(touches_runtime("/run/user/1000"), state)
            self.assertFalse(any("payload" in c for c in self.calls()))

    def test_explicit_first_provision_runs_once_and_keeps_stdout_clean(self):
        script = self.tmp / "provision.sh"
        script.write_text("echo provision-output\n")
        self.env["TOOLBOXER_PROVISION"] = str(script)
        result = self.run_cli("provision", "example", scenario=dict(exists=True, setup_pending=True))
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = [c for c in self.calls() if any("exec bash -s" in a for a in c)]
        self.assertEqual(len(calls), 1)
        self.assertEqual(result.stdout, "")

    def test_explicit_provision_fails_when_distro_undetectable(self):
        # M6: explicit provision must fail if the container's distro cannot be
        # read, rather than run the script blind with an empty TOOLBOXER_DISTRO.
        script = self.tmp / "provision.sh"
        script.write_text("echo hi\n")
        self.env["TOOLBOXER_PROVISION"] = str(script)
        result = self.run_cli("provision", "example",
                              scenario=dict(exists=True, setup_pending=True, os_release=""))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("could not read the container's distro", result.stderr)
        self.assertFalse(any("exec bash -s" in a for c in self.calls() for a in c),
                         "provision script ran despite an undetectable distro")

    def test_automatic_provision_warns_but_proceeds_when_distro_undetectable(self):
        # M6: automatic first-use provision warns but still runs when the distro
        # cannot be read; NSS or the base image may still make it work.
        script = self.tmp / "provision.sh"
        script.write_text("echo hi\n")
        self.env["TOOLBOXER_PROVISION"] = str(script)
        result = self.run_cli("run", "-c", "example", "payload",
                              scenario=dict(exists=True, setup_pending=True, os_release=""))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("could not read the container's distro", result.stderr)
        self.assertTrue(any("exec bash -s" in a for c in self.calls() for a in c),
                        "automatic provision did not run")

    def test_detected_distro_is_passed_to_provision(self):
        # M6: a detected distro/release is exported to the provision script.
        script = self.tmp / "provision.sh"
        script.write_text("echo hi\n")
        self.env["TOOLBOXER_PROVISION"] = str(script)
        result = self.run_cli("provision", "example",
                              scenario=dict(exists=True, setup_pending=True, os_release="fedora 44"))
        self.assertEqual(result.returncode, 0, result.stderr)
        prov = next(c for c in self.calls() if any("exec bash -s" in a for a in c))
        self.assertIn("TOOLBOXER_DISTRO=fedora", prov)
        self.assertIn("TOOLBOXER_RELEASE=44", prov)

    def test_os_release_probe_requires_a_distro_id(self):
        # M6: the detection probe must yield nothing when ID is absent, even if
        # VERSION_ID is set, so the version cannot be read as the distro. A
        # rolling release (ID, no VERSION_ID) still detects. Runs the actual
        # probe's formatting logic against controlled ID/VERSION_ID values.
        source = (ROOT / "toolboxer").read_text()
        probe = re.search(r"sh -c '(\. /etc/os-release[^']*)'", source).group(1)
        # The formatting after sourcing os-release, whichever separator is used.
        fmt = re.sub(r"^\. /etc/os-release 2>/dev/null\s*[;&]+\s*", "", probe)

        def emit(**vars):
            env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), **vars}
            return subprocess.run(["sh", "-c", fmt], env=env,
                                  text=True, capture_output=True).stdout

        self.assertEqual(emit(ID="fedora", VERSION_ID="44"), "fedora 44")
        self.assertEqual(emit(ID="arch").strip(), "arch")   # rolling: no version
        self.assertEqual(emit(VERSION_ID="44"), "")         # ID missing -> nothing
        self.assertEqual(emit(), "")

    def test_os_release_payload_is_not_intercepted_by_mock(self):
        # M6: the mock's os-release handler must match only the provisioning
        # probe (sh -c '. /etc/os-release ...'), not a user payload that merely
        # names the path or greps its version field, or it would mask the
        # payload's real output and exit status.
        for payload in (["payload", "/etc/os-release"],
                        ["payload", "grep VERSION_ID /etc/os-release"],
                        ["payload", "sh", "-c", '. /etc/os-release; printf "%s" "$VERSION_ID"'],
                        ["payload", "-c", ". /etc/os-release-copy"]):
            with self.subTest(payload=payload):
                self.log.unlink(missing_ok=True)
                result = self.run_cli("run", "-c", "example", *payload,
                                      scenario=dict(exists=True, payload_status=37,
                                                    output="payload-output"))
                self.assertEqual(result.returncode, 37)
                self.assertEqual(result.stdout, "payload-output")

    def test_concurrent_initialization_runs_setup_and_provision_once(self):
        script = self.tmp / "provision.sh"
        script.write_text("true\n")
        self.env["TOOLBOXER_PROVISION"] = str(script)
        self.env["MOCK_SCENARIO"] = json.dumps(dict(exists=True, setup_pending=True, setup_delay=0.2))
        processes = [subprocess.Popen([str(ROOT / "toolboxer"), "run", "-c", "example", "payload"],
                                      env=self.env, cwd=self.tmp, stdin=subprocess.DEVNULL,
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                     for _ in range(2)]
        try:
            for process in processes:
                output, error = process.communicate(timeout=15)
                self.assertEqual(process.returncode, 0, error)
                self.assertEqual(output, "")
        finally:
            for process in processes:
                if process.poll() is None:
                    process.kill()
                process.wait()
        self.assertEqual(sum("-s" in c and "testuser" in c for c in self.calls()), 1)
        self.assertEqual(sum(any("exec bash -s" in a for a in c) for c in self.calls()), 1)

    def initialization_script(self, initializer, invocation="ensure_started"):
        source = (ROOT / "toolboxer").read_text()
        start = source.index("ensure_started() {")
        function = source[start:source.index("\n}\n", start) + 3]
        return "set -euo pipefail\nCONTAINER_NAME=example\n" + function + initializer + "\n" + invocation

    def assert_initialization_lock_available(self):
        path = Path(self.env["XDG_RUNTIME_DIR"]) / "toolboxer" / "example.lock"
        with path.open() as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def test_initialization_descendants_do_not_inherit_the_lock_descriptor(self):
        # Use a real external Bash and real descriptors, not a Podman mock.
        # conmon can otherwise inherit this descriptor and retain the lock for
        # the container's entire lifetime after initialization has returned.
        script = self.initialization_script('''
initialize_container() {
    bash -c '
        for fd in /proc/self/fd/*; do
            if [[ "$fd" -ef "$1" ]]; then
                echo "setup child inherited lock descriptor $fd" >&2
                exit 42
            fi
        done
    ' bash "$XDG_RUNTIME_DIR/toolboxer/$CONTAINER_NAME.lock"
}
''')
        result = subprocess.run(["bash", "-c", script], env=self.env, text=True,
                                capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_initialization_lock_available()

    def test_initialization_lock_is_held_until_setup_finishes(self):
        script = self.initialization_script('''
initialize_container() {
    echo initializing >&2
    IFS= read -r reply
}
''')
        with subprocess.Popen(["bash", "-c", script], env=self.env, text=True,
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE) as process:
            try:
                self.assertTrue(select.select([process.stderr], [], [], 5)[0], "setup did not start")
                self.assertEqual(process.stderr.readline(), "initializing\n")
                with self.assertRaises(BlockingIOError):
                    self.assert_initialization_lock_available()
            finally:
                output, error = process.communicate(input="continue\n", timeout=5)
        self.assertEqual(process.returncode, 0, error)
        self.assertEqual(output, "")
        self.assert_initialization_lock_available()

    def test_contended_initialization_reports_wait_before_running_setup(self):
        path = Path(self.env["XDG_RUNTIME_DIR"]) / "toolboxer" / "example.lock"
        path.parent.mkdir(parents=True)
        script = self.initialization_script('''
initialize_container() { echo initialized; }
''')
        with path.open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            with subprocess.Popen(["bash", "-c", script], env=self.env, text=True,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE) as process:
                try:
                    self.assertTrue(select.select([process.stderr], [], [], 5)[0], "silent lock wait")
                    self.assertIn("Waiting for initialization lock on 'example'", process.stderr.readline())
                    self.assertIsNone(process.poll())
                finally:
                    fcntl.flock(lock, fcntl.LOCK_UN)
                    output, error = process.communicate(timeout=5)
        self.assertEqual(process.returncode, 0, error)
        self.assertEqual(output, "")
        self.assertEqual(error, "initialized\n")
        self.assert_initialization_lock_available()

    def test_initialization_failure_releases_lock_and_preserves_errexit(self):
        script = self.initialization_script('''
initialize_container() {
    bash -c 'exit 42'
    echo incorrectly-continued
}
''', invocation="ensure_started; echo incorrectly-ran-payload")
        result = subprocess.run(["bash", "-c", script], env=self.env, text=True,
                                capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertEqual(result.stderr, "")
        self.assert_initialization_lock_available()

    def test_lock_utility_errors_do_not_run_setup_or_report_contention(self):
        script = self.initialization_script('''
flock() { return 73; }
initialize_container() { echo incorrectly-initialized; }
''')
        result = subprocess.run(["bash", "-c", script], env=self.env, text=True,
                                capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 73, result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertNotIn("Waiting", result.stderr)
        self.assertNotIn("incorrectly-initialized", result.stderr)
        self.assert_initialization_lock_available()

    def test_legacy_setup_is_verified_without_automatic_reprovision(self):
        script = self.tmp / "provision.sh"
        script.write_text("true\n")
        self.env["TOOLBOXER_PROVISION"] = str(script)
        result = self.run_cli("run", "-c", "example", "payload", scenario=dict(
            exists=True, setup_pending=True, legacy=True))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(any("-s" in c for c in self.calls()))
        self.assertFalse(any(any("exec bash -s" in a for a in c) for c in self.calls()))

    def test_provision_failure_is_retryable_and_explicit_failure_is_nonzero(self):
        script = self.tmp / "provision.sh"
        script.write_text("exit 42\n")
        self.env["TOOLBOXER_PROVISION"] = str(script)
        scenario = dict(exists=True, setup_pending=True, fail_provision=True)
        result = self.run_cli("provision", "example", scenario=scenario)
        self.assertNotEqual(result.returncode, 0)
        result = self.run_cli("run", "-c", "example", "payload", scenario=scenario)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sum(any("exec bash -s" in a for a in c) for c in self.calls()), 2)
        self.assertFalse(any("touch" in c and "/etc/.toolboxer-provisioned-v1" in c for c in self.calls()))

    def test_run_preserves_payload_exit_status(self):
        result = self.run_cli("run", "-c", "example", "payload", scenario=dict(exists=True, payload_status=37))
        self.assertEqual(result.returncode, 37)

    def test_failed_source_preparation_does_not_create(self):
        result = self.run_cli("create", "-m", f"{self.config}/impossible:/work", "example")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(c[0] == "create" for c in self.calls()))

    def test_run_uses_saved_workdir_and_maps_subdirectories(self):
        project = self.tmp / "project"
        (project / "child").mkdir()
        scenario = dict(exists=True, workdir="/original", mounts=f"{project}\t/work")
        result = self.run_cli("run", "-c", "example", "pwd", scenario=scenario)
        self.assertEqual(result.returncode, 0, result.stderr)
        call = self.calls()[-1]
        self.assertEqual(call[call.index("--workdir") + 1], "/original")
        result = self.run_cli("run", "-c", "example", "pwd", scenario=scenario, cwd=project / "child")
        self.assertEqual(result.returncode, 0, result.stderr)
        call = self.calls()[-1]
        self.assertEqual(call[call.index("--workdir") + 1], "/work/child")


if __name__ == "__main__":
    unittest.main()
