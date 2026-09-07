#!/usr/bin/env python3
"""Record timeout arguments and execute the already-mocked Podman command."""
import json
import os
import sys

args = sys.argv[1:]
with open(os.environ["MOCK_TIMEOUT_LOG"], "a") as log:
    log.write(json.dumps(args) + "\n")
if args[:3] != ["-k", "2s", "10s"]:
    sys.exit(125)
os.execv(args[3], args[3:])
