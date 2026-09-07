#!/usr/bin/env python3
"""Stable host identity for protocol tests, including tests run as root in CI."""
import json
import os
import sys

scenario = json.loads(os.environ.get("MOCK_SCENARIO", "{}"))
uid, gid = str(scenario.get("host_uid", 1000)), str(scenario.get("host_gid", 1000))
values = {"-u": uid, "-g": gid, "-un": "testuser", "-G": f"{gid} 1001"}
print(values.get(sys.argv[1] if len(sys.argv) > 1 else "", f"uid={uid}(testuser) gid={gid}(testuser)"))
