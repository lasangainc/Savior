#!/usr/bin/env python3
"""Exercise real yt-dlp and FFmpeg using a generated clip on a temporary local server."""
import functools
import http.server
from pathlib import Path
import subprocess
import tempfile
import threading

repo = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix="savior-integration-") as directory:
    clip = Path(directory) / "sample.mp4"
    subprocess.run([
        "/opt/homebrew/bin/ffmpeg", "-hide_banner", "-loglevel", "error",
        "-f", "lavfi", "-i", "color=c=blue:s=320x180:r=24",
        "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100",
        "-t", "1", "-c:v", "libx264", "-c:a", "aac", "-shortest", str(clip)
    ], check=True)
    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=directory)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        subprocess.run([str(repo / "Tests/run-smoke-tests.sh"),
                        f"http://127.0.0.1:{server.server_port}/sample.mp4"], check=True)
    finally:
        server.shutdown()
        server.server_close()
        thread.join()
