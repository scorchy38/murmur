#!/usr/bin/env python3
"""Render development fixtures in real macOS windows; never opens the microphone.

Usage: python3 scripts/render-voice-previews.py /path/to/Debug/Murmur.app [output-dir]
The invoking terminal needs Screen Recording permission for window screenshots.
"""
import pathlib
import re
import selectors
import subprocess
import sys
import time

app = pathlib.Path(sys.argv[1]).resolve()
output = pathlib.Path(sys.argv[2] if len(sys.argv) > 2 else "build/voice-previews").resolve()
output.mkdir(parents=True, exist_ok=True)
for scenario in ["listening", "processing", "result", "long", "warmup", "error", "library", "settings", "menu"]:
    process = subprocess.Popen([str(app / "Contents/MacOS/Murmur"), "--preview", scenario], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    try:
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)
        deadline = time.monotonic() + 12
        window = None
        while time.monotonic() < deadline:
            if not selector.select(timeout=1):
                continue
            line = process.stdout.readline()
            match = re.search(r"MURMUR_PREVIEW_WINDOW=(\d+)", line)
            if match:
                window = match.group(1)
                break
            if process.poll() is not None:
                break
        if window is None:
            raise RuntimeError(f"{scenario}: preview window did not open; use a Debug build")
        time.sleep(0.8)
        subprocess.run(["/usr/sbin/screencapture", "-x", "-o", "-l", window, str(output / f"{scenario}.png")], check=True)
        print(f"Rendered {scenario}", flush=True)
    finally:
        process.terminate()
        process.wait(timeout=5)
        selector.close()
