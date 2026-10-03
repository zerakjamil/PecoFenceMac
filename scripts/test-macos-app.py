#!/usr/bin/env python3
"""Run desktop/Quick Look checks in an isolated app session. Quit PecoFence first."""
import json
import stat
import subprocess
import tempfile
import time
from pathlib import Path

app = Path.home() / "Library/Caches/PecoFence/build/PecoFence.app"
with tempfile.TemporaryDirectory(prefix="pecofence-app-test-") as directory:
    root = Path(directory)
    desktop, config = root / "Desktop", root / "config"
    desktop.mkdir()
    config.mkdir()
    file = desktop / "preview.txt"
    file.write_text("Native Quick Look fixture")
    (config / "mac-preferences.json").write_text(json.dumps({"hideFencedDesktop": True}))
    process = subprocess.Popen([
        "open", "-n", "-W", "--env", f"PECOFENCE_CONFIG_DIR={config}",
        "--env", f"PECOFENCE_DESKTOP_DIR={desktop}", "--stdout", str(root / "stdout"),
        "--stderr", str(root / "stderr"), str(app), "--args", "--smoke-test",
    ])
    hidden = False
    deadline = time.monotonic() + 20
    while process.poll() is None and time.monotonic() < deadline:
        hidden |= bool(file.stat().st_flags & stat.UF_HIDDEN)
        time.sleep(0.05)
    process.wait(timeout=5)
    stdout, stderr = (root / "stdout").read_text(), (root / "stderr").read_text()
    assert "SMOKE OK" in stdout, stdout + stderr
    assert hidden, "Fenced Desktop item was not hidden while the app ran"
    assert not file.stat().st_flags & stat.UF_HIDDEN, "Original flag not restored on quit"
    print(stdout.strip())
    print("PASS: Desktop hiding active in native app; originals restored on quit")
