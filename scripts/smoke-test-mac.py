#!/usr/bin/env python3
"""Launch the actual archived executable, including dyld and menu-bar setup.
Checks are disabled for this process; microphone capture and sync never start.
"""
import pathlib
import subprocess
import sys

app = pathlib.Path(sys.argv[1]).resolve()
result = subprocess.run(
    [str(app / "Contents/MacOS/Murmur"), "--smoke-test", "-SUEnableAutomaticChecks", "NO"],
    capture_output=True, text=True, timeout=25,
)
if result.returncode != 0 or "MURMUR_READY menu_bar=present" not in result.stdout:
    print(result.stderr[-4000:], file=sys.stderr)
    raise SystemExit(f"Archived app failed launch/menu-bar smoke test (exit {result.returncode}).")
print("Archived app launched successfully and created its menu bar icon.")
