#!/usr/bin/env python3
"""A deliberately small Podman protocol fake; it never executes containers."""
import json
import os
import re
import sys
import time

args = sys.argv[1:]
with open(os.environ["MOCK_LOG"], "a") as log:
    log.write(json.dumps(args) + "\n")
scenario = json.loads(os.environ.get("MOCK_SCENARIO", "{}"))
# The wrapper's warm-path runtime postcondition check, matched verbatim so a
# user payload that merely mentions stat is not intercepted. Must stay identical
# to the sh -c script in toolboxer's ensure_runtime_directory.
RUNTIME_CHECK = '[ "$(stat -c "%u:%g:%a" "$1")" = "$2:700" ] && [ -w "$1" ]'
key = " ".join(args[:2])
if args[0] in scenario.get("fail", []):
    print("injected Podman failure", file=sys.stderr)
    sys.exit(125)
if key == "container exists":
    sys.exit(0 if scenario.get("exists", False) else 1)
if key == "image exists":
    idv = args[2]
    if idv in scenario.get("vanish_images", []):
        # Present on the first check (enumeration), gone on the second
        # (the post-inspect re-check), modelling a mid-listing removal.
        with open(os.environ["MOCK_LOG"]) as log:
            seen = sum(1 for line in log if json.loads(line)[:3] == ["image", "exists", idv])
        sys.exit(0 if seen <= 1 else 1)
    sys.exit(1 if idv in scenario.get("gone_images", []) else 0)
if key == "image inspect":
    target = args[-1]
    if target in scenario.get("fail_inspect", []):
        print(f"image inspect failed for {target}", file=sys.stderr)
        sys.exit(125)
    if args[args.index("--format") + 1] == "{{.Id}}":
        print(target if len(target) == 64 else "a" * 64)
    else:
        print(f"{target}\tdocker.io/library/ubuntu:latest\ttoday")
elif args[0] == "info":
    rootless, selinux, runtime = scenario.get("info", "true false crun").split()
    # Case-sensitive Go struct fields, not the lower-camel-case JSON keys.
    # Schema: containers/podman v4.9.3 libpod/define/info.go (also checked on main).
    fields = {
        ".Host.Security.Rootless": rootless,
        ".Host.Security.SELinuxEnabled": selinux,
        ".Host.OCIRuntime.Name": runtime,
        ".Host.CgroupsVersion": "v2",
        ".Host.CgroupManager": "systemd",
        ".Host.NetworkBackend": "netavark",
        ".Store.GraphDriverName": "overlay",
        ".Store.GraphRoot": "/mock/storage",
        ".Store.RunRoot": "/mock/runtime",
    }

    def render_field(match):
        field = match.group(1)
        if field not in fields:
            print(f"unsupported Podman info template field: {field}", file=sys.stderr)
            sys.exit(125)
        return fields[field]

    template = args[args.index("--format") + 1]
    rendered = re.sub(r"\{\{(\.[A-Za-z0-9_.]+)\}\}", render_field, template)
    if "{{" in rendered:
        print(f"unsupported Podman info template: {template}", file=sys.stderr)
        sys.exit(125)
    print(rendered)
elif args[0] == "create":
    for index, arg in enumerate(args):
        if arg == "--tmpfs":
            for option in args[index + 1].partition(":")[2].split(","):
                if option.partition("=")[0] in ("uid", "gid"):
                    print(f'unknown mount option "{option}": invalid mount option', file=sys.stderr)
                    sys.exit(125)
    # Real Podman prints the new container's ID; the wrapper's rollback keys on it.
    # A delay lets a test close the ID reader before the wrapper publishes it.
    time.sleep(scenario.get("create_delay", 0))
    print("c" * 64)
elif args[0] == "cp":
    # Lets a test interrupt the wrapper while a copy is still in flight.
    time.sleep(scenario.get("cp_delay", 0))
elif args[0] == "inspect":
    template = args[args.index("--format") + 1]
    if "State.Status" in template and "HostConfig.Tmpfs" in template:
        # The warm-path combined inspect: run state, then each tmpfs path on its
        # own line (via println). The runtime-dir label is queried separately so
        # its value cannot bleed into the tmpfs list, so it is not emitted here.
        print(scenario.get("state", "running"))
        with open(os.environ["MOCK_LOG"]) as log:
            tpaths = [call[i + 1].partition(":")[0] for line in log
                      for call in [json.loads(line)] for i, a in enumerate(call) if a == "--tmpfs"]
        tmpfs = scenario.get("tmpfs_dirs", "\n".join(tpaths))
        if tmpfs:
            print(tmpfs)
    elif "State.Status" in template:
        print(scenario.get("state", "running"))
    elif "toolboxer.runtime-dir" in template:
        with open(os.environ["MOCK_LOG"]) as log:
            paths = [a.split("=", 1)[1] for line in log for a in json.loads(line) if a.startswith("toolboxer.runtime-dir=")]
        print(scenario.get("runtime_dir", paths[-1] if paths else ""))
    elif "HostConfig.Tmpfs" in template:
        with open(os.environ["MOCK_LOG"]) as log:
            paths = [call[i + 1].partition(":")[0] for line in log
                     for call in [json.loads(line)] for i, a in enumerate(call) if a == "--tmpfs"]
        print(scenario.get("tmpfs_dirs", "\n".join(paths)))
    elif "WorkingDir" in template:
        print(scenario.get("workdir", "/work"))
    elif "Mounts" in template:
        if scenario.get("fail_mount_inspect"):
            sys.exit(125)
        binds = []
        with open(os.environ["MOCK_LOG"]) as log:
            for line in log:
                call = json.loads(line)
                if call[0] == "create":
                    binds = [call[i + 1].removesuffix(":z") for i, arg in enumerate(call) if arg == "--volume"]
        default = "\n".join(binds)
        if "{{println .Destination}}" in template:
            default = "\n".join(bind.split(":", 1)[1] for bind in binds)
        print(scenario.get("mounts", default))
    elif "HostConfig.Privileged" in template:
        mode = "integrated"
        agents = "false"
        names = "all"
        with open(os.environ["MOCK_LOG"]) as log:
            for line in log:
                for arg in json.loads(line):
                    if arg.startswith("toolboxer.mode="):
                        mode = arg.split("=", 1)[1]
                    if arg.startswith("toolboxer.agents="):
                        agents = arg.split("=", 1)[1]
                    if arg.startswith("toolboxer.agent-names="):
                        names = arg.split("=", 1)[1]
        if mode == "isolated":
            label = "system_u:system_r:container_t:s0" if scenario.get("info", "true false crun").split()[1] == "true" else ""
            default = f"false|private|private|private|{label}|isolated|{agents}|{names}|private"
        else:
            privileged = "true" if mode == "privileged" else "false"
            default = f"{privileged}|host|host|host||{mode}|{agents}|{names}|private"
        print(scenario.get("mode", default))
    elif 'index .Config.Labels "toolboxer"' in template:
        print(scenario.get("managed", "true"))
    elif 'index .Config.Labels "toolboxer.binds"' in template:
        with open(os.environ["MOCK_LOG"]) as log:
            labels = [a.split("=", 1)[1] for line in log for a in json.loads(line) if a.startswith("toolboxer.binds=")]
        print(labels[-1] if labels else "")
    elif template == "{{.Image}}":
        if args[-1] == scenario.get("fail_image_for"):
            sys.exit(125)
        print("a" * 64)
    elif (label_query := re.search(r'index \.Config\.Labels "([^"]+)"', template)):
        # Effective container label: Podman inherits image labels, but a create
        # --label of the same key overrides them. Model that so a test can check
        # the resolved label, not just raw create argv.
        key = label_query.group(1)
        value = scenario.get("image_labels", {}).get(key, "")
        with open(os.environ["MOCK_LOG"]) as log:
            for line in log:
                call = json.loads(line)
                if call[:1] == ["create"]:
                    for i, arg in enumerate(call):
                        if arg == "--label" and call[i + 1].startswith(key + "="):
                            value = call[i + 1].split("=", 1)[1]
        print(value)
    else:
        print(scenario.get("inspect", ""))
elif key == "container list":
    if any("ancestor=" in a for a in args):
        print(scenario.get("dependencies", ""))
    elif "{{.ImageID}}" in args:
        print(scenario.get("image_ids", ""))
    else:
        print(scenario.get("containers", ""))
elif args[0] == "exec":
    stdin = ""
    if "-i" in args:
        stdin = sys.stdin.read()
    if "repair_sudo_metadata" in stdin and scenario.get("fail_sudo_metadata"):
        sys.exit(42)
    if any('chmod 0700' in a for a in args) and scenario.get("fail_runtime_ownership"):
        sys.exit(42)
    if "test" in args and "-w" in args and scenario.get("fail_runtime_writable"):
        sys.exit(1)
    if (len(args) == 11 and args[1] == "--user" and args[2] == args[10]
            and args[4:9] == ["sh", "-eu", "-c", RUNTIME_CHECK, "sh"]):
        # The warm-path postcondition check, matched by its exact internal exec
        # shape -- `exec --user <uid:gid> <name> sh -eu -c <RUNTIME_CHECK> sh
        # <dir> <uid:gid>` -- not by script text appearing anywhere in argv, so a
        # user payload (even one byte-identical to the script) is left to normal
        # dispatch. The --user value (args[2]) must equal the uid:gid passed as
        # $2 (args[10]): a check run as root does not match here and so cannot
        # stay falsely green. It exits 0 only if the dir already equals
        # uid:gid:700 and is writable by the user, i.e. the reown is redundant.
        # Metadata defaults to healthy (skip); runtime_root_owned models a start
        # outside toolboxer (root-owned), runtime_meta forces an
        # owner:group:octal-mode, fail_runtime_writable a dir the user cannot
        # access.
        uid_gid = args[10]
        actual = "0:0:700" if scenario.get("runtime_root_owned") else scenario.get("runtime_meta", uid_gid + ":700")
        ok = actual == uid_gid + ":700" and not scenario.get("fail_runtime_writable")
        sys.exit(0 if ok else 1)
    if "test" in args and "-f" in args and scenario.get("setup_pending"):
        if scenario.get("legacy") and args[-1] in ("/etc/sudoers.d/testuser", "/etc/.toolboxer-home-repaired-v2"):
            sys.exit(0)
        with open(os.environ["MOCK_LOG"]) as log:
            touched = any("touch" in (call := json.loads(line)) and args[-1] in call for line in log)
        sys.exit(0 if touched else 1)
    if "-s" in args and scenario.get("fail_setup"):
        sys.exit(42)
    if "-s" in args:
        time.sleep(scenario.get("setup_delay", 0))
    if any("exec bash -s" in arg for arg in args) and scenario.get("fail_provision"):
        sys.exit(42)
    if any("command -v sudo" in arg for arg in args) and scenario.get("fail_sudo"):
        sys.exit(42)
    if (len(args) == 5 and args[2:4] == ["sh", "-c"]
            and args[4].startswith(". /etc/os-release")):
        # The provisioning distro probe has the exact top-level shape
        # `exec <container> sh -c '. /etc/os-release ...'`. The run wrapper
        # always adds flags and trailing payload arguments, so a user payload,
        # even one whose own nested -c sources os-release, is not this shape and
        # is not intercepted. Default to a real value; os_release="" forces
        # failure.
        print(scenario.get("os_release", "ubuntu 24.04"), end="")
        sys.exit(0)
    if "test" not in args:
        print(scenario.get("output", ""), end="")
    if "payload" in args:
        sys.exit(scenario.get("payload_status", 0))
elif args[0] == "pull":
    # Real Podman prints the pulled image's ID to stdout (fmt.Println); model
    # that so a test can prove create keeps its own stdout to the container ID.
    print("a" * 64)
elif args[0] in ("start", "stop", "rm", "rmi"):
    # Lifecycle verbs the wrapper drives. Modelled as success by default and
    # recorded in MOCK_LOG like any other call; inject failure through the
    # "fail" scenario (exit 125) rather than leaving them to succeed by
    # accident. An unmodelled verb must not look like it worked.
    pass
else:
    print(f"mock_podman: unhandled command {args!r}", file=sys.stderr)
    sys.exit(125)
