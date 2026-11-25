#!/usr/bin/env python3
"""Runs a freshly unpacked whisper.cpp build on a test recording and reports how it went.

Example:
    python tools/check_build.py D:/LiveTranscriber/runtime/whisper-cuda-b5454 \
        --model D:/LiveTranscriber/runtime/models/ggml-small.bin \
        --wav D:/LiveTranscriber/cache/test-irina.wav
"""

import argparse
import ctypes
import re
import subprocess
import sys
import time
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description="check a Whisper build")
    parser.add_argument("build_dir", help="folder that holds whisper-cli.exe (or a Release subfolder)")
    parser.add_argument("--model", required=True, help="model file")
    parser.add_argument("--wav", required=True, help="test recording")
    arguments = parser.parse_args()

    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, ValueError):
        pass
    # Keep Windows from showing a dialog if a library fails to load.
    ctypes.windll.kernel32.SetErrorMode(0x8003)

    build = Path(arguments.build_dir)
    program = next((path for path in (build / "Release" / "whisper-cli.exe", build / "whisper-cli.exe")
                    if path.is_file()), None)
    if program is None:
        sys.exit(f"whisper-cli.exe not found under {build}")

    for attempt in (1, 2):
        started = time.perf_counter()
        process = subprocess.run([str(program), "-m", arguments.model, "-f", arguments.wav,
                                  "-l", "ru", "-t", "4"], capture_output=True)
        wall = time.perf_counter() - started
        output = (process.stdout + process.stderr).decode("utf-8", errors="replace")

        device = re.search(r"whisper_backend_init_gpu: device 0: (.+?) \(type", output)
        total = re.search(r"total time =\s+(\d+) ms", output)
        print(f"attempt {attempt}: exit code {process.returncode}, wall {wall:.1f} s, "
              f"device {device.group(1) if device else '?'}, model time {total.group(1) + ' ms' if total else '?'}")
        for line in output.splitlines():
            if line.startswith("["):
                print("   ", line.strip()[:200])
        if process.returncode != 0:
            print(output[-1200:])


if __name__ == "__main__":
    main()
