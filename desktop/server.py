#!/usr/bin/env python3
"""Local server of the desktop port of LiveTranscriber.

Serves the page from `web/` and turns speech into text with a local Whisper model
(whisper.cpp), so everything works offline. Only the Python standard library is used.

Layout, next to this folder (override with LIVETRANSCRIBER_RUNTIME and LIVETRANSCRIBER_CACHE):
    runtime/whisper*/[Release/]whisper-server.exe   the recognizer; a graphics-card build is preferred
    runtime/models/ggml-small.bin                   the model
    cache/                                          logs and temporary files
"""

import argparse
import atexit
import ctypes
import json
import os
import re
import socket
import struct
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import webbrowser
from ctypes import wintypes
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

APP_DIR = Path(__file__).resolve().parent
WEB_DIR = APP_DIR / "web"
RUNTIME_DIR = Path(os.environ.get("LIVETRANSCRIBER_RUNTIME") or APP_DIR.parent / "runtime")
CACHE_DIR = Path(os.environ.get("LIVETRANSCRIBER_CACHE") or RUNTIME_DIR.parent / "cache")
MODEL_PATH = Path(os.environ.get("LIVETRANSCRIBER_MODEL") or RUNTIME_DIR / "models" / "ggml-small.bin")
THREADS = os.environ.get("LIVETRANSCRIBER_THREADS", "4")

SAMPLE_RATE = 16000
MAX_AUDIO_BYTES = 32 * 1024 * 1024
READY_TIMEOUT_SECONDS = 180
RECOGNIZE_TIMEOUT_SECONDS = 180
# Requests are answered only by the local program, never through a proxy or VPN.
HTTP = urllib.request.build_opener(urllib.request.ProxyHandler({}))


class RecognitionError(Exception):
    """The recognizer could not process the request."""


def free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def wav_bytes(pcm):
    """Wraps 16-bit mono PCM into a WAV file."""
    header = struct.pack(
        "<4sI4s4sIHHIIHH4sI", b"RIFF", 36 + len(pcm), b"WAVE", b"fmt ", 16, 1, 1,
        SAMPLE_RATE, SAMPLE_RATE * 2, 2, 16, b"data", len(pcm))
    return header + pcm


def multipart(wav):
    """The request body for the recognizer: settings and the WAV file."""
    boundary = "----LiveTranscriberBoundary"
    fields = {"temperature": "0.0", "temperature_inc": "0.2", "response_format": "json", "language": "ru"}
    parts = []
    for name, value in fields.items():
        parts.append(f"--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n{value}\r\n".encode())
    parts.append(
        f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"utterance.wav\"\r\n"
        "Content-Type: audio/wav\r\n\r\n".encode())
    parts.append(wav)
    parts.append(f"\r\n--{boundary}--\r\n".encode())
    return b"".join(parts), f"multipart/form-data; boundary={boundary}"


class Engine:
    """A running whisper-server.exe: the model is loaded once and kept in memory."""

    def __init__(self):
        self.process = None
        self.port = None
        self.lock = threading.Lock()
        self.kind = None
        self.device = None
        self.error = None
        self.log_path = None

    @property
    def is_ready(self):
        return self.process is not None and self.process.poll() is None

    def start(self):
        if not MODEL_PATH.is_file():
            self.error = f"модель не найдена: {MODEL_PATH}"
            report(f"Модель распознавания не найдена: {MODEL_PATH}")
            return

        for kind, executable in self.candidates():
            if not executable.is_file():
                continue
            report(f"Запускаю распознавание ({'видеокарта' if kind == 'cuda' else 'процессор'}): {executable}")
            if self.launch(kind, executable):
                return
        if self.error is None:
            self.error = "whisper-server.exe не найден в папке runtime"
            report("Программа распознавания не найдена в папке runtime")

    def candidates(self):
        """Available recognizers, a graphics-card build first."""
        if not RUNTIME_DIR.is_dir():
            return []
        found = []
        for directory in sorted(RUNTIME_DIR.iterdir()):
            if not directory.is_dir() or not directory.name.startswith("whisper"):
                continue
            for executable in (directory / "Release" / "whisper-server.exe", directory / "whisper-server.exe"):
                if executable.is_file():
                    kind = "cuda" if "cuda" in directory.name or "cublas" in directory.name else "cpu"
                    found.append((kind, executable))
                    break
        found.sort(key=lambda candidate: candidate[0] != "cuda")
        return found

    def launch(self, kind, executable):
        self.port = free_port()
        CACHE_DIR.mkdir(parents=True, exist_ok=True)
        log_path = CACHE_DIR / f"whisper-{kind}-{time.strftime('%Y%m%d-%H%M%S')}.log"
        self.log_path = log_path
        # Freshly extracted programs may be checked by Windows for a minute after
        # installation: allow for that on the first start.
        arguments = [str(executable), "--host", "127.0.0.1", "--port", str(self.port),
                     "-m", str(MODEL_PATH), "-l", "ru", "-t", THREADS]
        if kind == "cuda":
            arguments += ["-bs", "5", "-bo", "5"]

        try:
            with open(log_path, "wb") as log:
                # No new console: the program shares this one, so closing the window stops it too.
                self.process = subprocess.Popen(arguments, cwd=str(executable.parent),
                                                stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT)
                keep_with_parent(self.process)
                if not self.wait_ready(READY_TIMEOUT_SECONDS):
                    code = self.process.poll()
                    self.process.kill()
                    self.process.wait()
                    self.process = None
                    self.error = (f"программа распознавания закрылась с кодом {code}" if code is not None
                                  else "программа распознавания не ответила за три минуты")
                    report(f"Этот вариант не запустился ({self.error}). {tail_of(log_path)}")
                    return False
        except OSError as error:
            self.process = None
            self.error = str(error)
            report(f"Не удалось запустить {executable.name}: {error}")
            return False

        self.device = find_device(log_path)
        if kind == "cuda" and self.device is None:
            # The build started but did not find the graphics card (Windows may have blocked
            # its library): it would compute on the processor, slower than the plain build.
            self.stop()
            self.error = "видеокарта не обнаружена"
            report(f"Этот вариант не увидел видеокарту. {tail_of(log_path)}")
            return False

        self.kind = kind
        self.error = None
        where = f"видеокарта, {self.device}" if self.device else (
            "видеокарта" if kind == "cuda" else "процессор")
        report(f"Готово: {MODEL_PATH.name}, считает {where}")
        return True

    def wait_ready(self, timeout):
        """Waits until the recognizer accepts connections, or exits."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                return False
            try:
                with HTTP.open(f"http://127.0.0.1:{self.port}/", timeout=2) as response:
                    response.read()
                return True
            except (urllib.error.URLError, OSError, ValueError):
                time.sleep(0.2)
        return False

    def recognize(self, pcm):
        """Transcribes 16-bit mono PCM at 16 kHz. Returns (text, elapsed ms)."""
        if not self.is_ready:
            raise RecognitionError(self.error or "распознаватель не запущен")
        body, content_type = multipart(wav_bytes(pcm))
        request = urllib.request.Request(f"http://127.0.0.1:{self.port}/inference", data=body,
                                         headers={"Content-Type": content_type}, method="POST")
        started = time.perf_counter()
        try:
            # One request at a time, in the order they came.
            with self.lock:
                with HTTP.open(request, timeout=RECOGNIZE_TIMEOUT_SECONDS) as response:
                    payload = json.loads(response.read().decode("utf-8"))
        except (urllib.error.URLError, TimeoutError, OSError, ValueError) as error:
            raise RecognitionError(f"распознаватель не ответил: {error}") from error
        return (payload.get("text") or "").strip(), round((time.perf_counter() - started) * 1000)

    def stop(self):
        process, self.process = self.process, None
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()


def find_device(log_path):
    """The graphics card the recognizer reports in its log, if any."""
    try:
        text = log_path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None
    match = re.search(r"Device \d+:\s*(.+?),\s*compute", text)
    return match.group(1).strip() if match else None


_job_handle = None


def keep_with_parent(process):
    """Windows only: makes the recognizer close when this program ends, however it ends,
    so that it never stays behind in memory without the page."""
    global _job_handle
    if os.name != "nt" or not hasattr(process, "_handle"):
        return

    class BasicLimits(ctypes.Structure):
        _fields_ = [
            ("per_process_time", ctypes.c_int64), ("per_job_time", ctypes.c_int64),
            ("limit_flags", wintypes.DWORD), ("minimum_working_set", ctypes.c_size_t),
            ("maximum_working_set", ctypes.c_size_t), ("active_process_limit", wintypes.DWORD),
            ("affinity", ctypes.c_size_t), ("priority_class", wintypes.DWORD),
            ("scheduling_class", wintypes.DWORD),
        ]

    class IoCounters(ctypes.Structure):
        _fields_ = [(name, ctypes.c_uint64) for name in
                    ("reads", "writes", "other", "read_bytes", "write_bytes", "other_bytes")]

    class ExtendedLimits(ctypes.Structure):
        _fields_ = [
            ("basic", BasicLimits), ("io", IoCounters), ("process_memory", ctypes.c_size_t),
            ("job_memory", ctypes.c_size_t), ("peak_process_memory", ctypes.c_size_t),
            ("peak_job_memory", ctypes.c_size_t),
        ]

    kernel32 = ctypes.windll.kernel32
    kernel32.CreateJobObjectW.restype = wintypes.HANDLE
    kernel32.CreateJobObjectW.argtypes = [wintypes.LPVOID, wintypes.LPCWSTR]
    kill_on_job_close = 0x2000
    extended_limit_information = 9

    job = kernel32.CreateJobObjectW(None, None)
    if not job:
        return
    limits = ExtendedLimits()
    limits.basic.limit_flags = kill_on_job_close
    configured = kernel32.SetInformationJobObject(
        job, extended_limit_information, ctypes.byref(limits), ctypes.sizeof(limits))
    assigned = configured and kernel32.AssignProcessToJobObject(
        job, wintypes.HANDLE(int(process._handle)))
    if assigned:
        # The recognizer lives exactly as long as this handle does.
        _job_handle = job
    else:
        kernel32.CloseHandle(job)


def tail_of(log_path):
    try:
        lines = [line for line in log_path.read_text(encoding="utf-8", errors="replace").splitlines() if line.strip()]
    except OSError:
        return ""
    return "Последние строки журнала: " + " | ".join(lines[-4:])


def status(engine):
    return {
        "ready": engine.is_ready,
        "engine": engine.kind if engine.is_ready else None,
        "device": engine.device,
        # "small" for ggml-small.bin
        "model": MODEL_PATH.stem.removeprefix("ggml-"),
        "modelPath": str(MODEL_PATH),
        "error": engine.error,
        # Drafts while a person is still speaking only make sense when recognition is fast.
        "draftCapable": engine.is_ready and engine.kind == "cuda",
    }


def report(message):
    print(f"[{time.strftime('%H:%M:%S')}] {message}", flush=True)


class Handler(SimpleHTTPRequestHandler):
    engine = None

    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(WEB_DIR), **kwargs)

    def end_headers(self):
        # The page is being edited often: always give the fresh files.
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def do_GET(self):
        if self.path.split("?", 1)[0] == "/api/status":
            return self.send_json(status(self.engine))
        return super().do_GET()

    def translate_path(self, path):
        # /demo/<name> serves recordings from cache/demo, handy for trying the page without a microphone.
        prefix = "/demo/"
        if path.startswith(prefix):
            target = (CACHE_DIR / "demo" / urllib.parse.unquote(path[len(prefix):])).resolve()
            if target == (CACHE_DIR / "demo").resolve() or (CACHE_DIR / "demo").resolve() not in target.parents:
                return str(WEB_DIR / "not-found")
            return str(target)
        return super().translate_path(path)

    def do_POST(self):
        path, _, query = self.path.partition("?")
        if path != "/api/recognize":
            return self.send_json({"error": "not found"}, 404)

        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0 or length % 2 != 0 or length > MAX_AUDIO_BYTES:
            return self.send_json({"error": "unexpected audio length"}, 400)
        pcm = self.rfile.read(length)
        if len(pcm) != length:
            return self.send_json({"error": "truncated audio"}, 400)

        try:
            text, elapsed = self.engine.recognize(pcm)
        except RecognitionError as error:
            return self.send_json({"error": str(error)}, 503)
        seconds = len(pcm) / (SAMPLE_RATE * 2)
        if "draft=1" not in query:
            report(f"{seconds:5.1f} с звука -> {elapsed:5d} мс  {text[:80]!r}")
        return self.send_json({"text": text, "ms": elapsed, "seconds": seconds})

    def send_json(self, payload, code=200):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        # The page's own requests are reported above; keep the console quiet.
        if not str(args[0] if args else "").startswith(("GET /web/", "GET / ")):
            super().log_message(format, *args)


def main():
    parser = argparse.ArgumentParser(description="LiveTranscriber for the computer")
    parser.add_argument("--no-browser", action="store_true", help="do not open the page yourself")
    parser.add_argument("--port", type=int, default=8765, help="port for the page (default 8765)")
    arguments = parser.parse_args()

    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, ValueError):
        pass

    try:
        server = ThreadingHTTPServer(("127.0.0.1", arguments.port), Handler)
    except OSError:
        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True

    engine = Engine()
    Handler.engine = engine
    atexit.register(engine.stop)
    threading.Thread(target=engine.start, daemon=True).start()

    url = f"http://127.0.0.1:{server.server_address[1]}/"
    report(f"Страница приложения: {url}")
    report(f"Распознаватель и модель: {RUNTIME_DIR}   (чтобы закрыть приложение, закрой это окно)")
    if not arguments.no_browser:
        threading.Timer(0.8, webbrowser.open, args=(url,)).start()

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        engine.stop()
        server.server_close()


if __name__ == "__main__":
    main()
