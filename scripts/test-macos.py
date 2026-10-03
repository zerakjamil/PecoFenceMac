#!/usr/bin/env python3
"""Exercise the packaged Rust engine against isolated files, never the real Desktop."""
import concurrent.futures
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
ENGINE = Path(os.environ.get("PECOFENCE_BUILD_DIR", str(Path.home() / "Library/Caches/PecoFence/build"))) / "PecoFence.app/Contents/MacOS/pecofence-mac-cli"


def main():
    with tempfile.TemporaryDirectory(prefix="pecofence-mac-test-") as temporary:
        folder = Path(temporary).resolve()
        config = folder / "config"
        desktop = folder / "Desktop"
        desktop.mkdir()
        report = desktop / "Report.pdf"
        report.write_text("report fixture")
        text = desktop / "Notes.txt"
        text.write_text("notes fixture")
        project = desktop / "Project"
        project.mkdir()
        original = {path.name: path.read_bytes() for path in desktop.iterdir() if path.is_file()}

        def request(op, fail=False, **fields):
            process = subprocess.run([str(ENGINE), "--config-dir", str(config)],
                input=json.dumps({"op": op, **fields}), text=True, capture_output=True, timeout=10)
            reply = json.loads(process.stdout)
            if fail:
                assert process.returncode != 0 and not reply["ok"], reply
                return reply
            assert process.returncode == 0 and reply["ok"], (reply, process.stderr)
            return reply["state"]

        state = request("sync", desktop=str(desktop))
        inbox = next(fence for fence in state["fences"] if fence["kind"] == "inbox")
        projects = next(fence for fence in state["fences"] if fence["title"] == "Projects")
        assert len(inbox["items"]) == 3
        assert all(entry["path"].startswith("/") for entry in inbox["items"])
        state = request("assign", fence=projects["id"], paths=[str(report)])
        assert len(next(f for f in state["fences"] if f["id"] == projects["id"])["items"]) == 1
        state = request("assign", fence=projects["id"], paths=[str(project)])
        assert any(entry["path"] == str(project) and entry["isFolder"] for fence in state["fences"] if fence["id"] == projects["id"] for entry in fence["items"])
        assert project.is_dir(), "Folder assignment moved original"
        state = request("create", title="Reading")
        reading = state["fences"][-1]
        request("rule-add", name="PDFs", extensions="pdf", fence=reading["id"])
        state = request("sync", desktop=str(desktop))
        assert next(f for f in state["fences"] if f["id"] == projects["id"])["items"], "Manual assignment lost"
        state = request("apply-rules")
        assert next(f for f in state["fences"] if f["id"] == reading["id"])["items"][0]["path"] == str(report)
        request("snapshot-save", name="Before changes")
        state = request("update", id=reading["id"], title="Renamed", rolledUp=True, locked=True, view="list")
        snapshot = state["snapshots"][0]
        state = request("snapshot-restore", id=snapshot["id"])
        assert next(f for f in state["fences"] if f["id"] == reading["id"])["title"] == "Reading"
        state = request("create", title="Folder", path=str(project))
        portal = state["fences"][-1]
        request("assign", fail=True, fence=portal["id"], paths=[str(text)])
        request("delete", fail=True, id=inbox["id"])
        request("remove", fail=True, item="00000000-0000-0000-0000-000000000000")
        before = (config / "config.json").read_bytes()
        invalid = dict(reading["geometry"], w=-1)
        request("update", fail=True, id=reading["id"], geometry=invalid)
        assert (config / "config.json").read_bytes() == before
        export = folder / "export.json"
        request("export", path=str(export))
        request("settings", theme="dark", keepUpdated=False)
        state = request("import", path=str(export))
        assert state["theme"] == "system"
        state = request("delete", id=reading["id"])
        assert not state["rules"]
        assert any(i["path"] == str(report) for f in state["fences"] if f["kind"] == "inbox" for i in f["items"])

        # Concurrent GUI/CLI writes must not overwrite one another.
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            list(pool.map(lambda number: request("create", title=f"Concurrent {number}"), range(8)))
        state = request("state")
        assert len([f for f in state["fences"] if f["title"].startswith("Concurrent")]) == 8
        request("sync", desktop=str(desktop))
        before = (config / "config.json").stat().st_mtime_ns
        request("sync", desktop=str(desktop))
        assert (config / "config.json").stat().st_mtime_ns == before, "Unchanged sync wrote config"
        assert {path.name: path.read_bytes() for path in desktop.iterdir() if path.is_file()} == original
        assert (config / "config.bak").exists()
        assert list((config / "backups").glob("*.json"))
        (config / "config.json").write_text("corrupt fixture")
        state = request("state")
        assert state.get("recoveryWarning")
        assert list(config.glob("config.unreadable-*.json"))
        assert state["fences"]
        print("PASS: sync, POSIX paths, assignments, rules, snapshots, portals, validation, import/export, concurrent writes, unchanged sync, backups/recovery, original files intact")

        config = folder / "stack-config"
        state = request("state")
        top, middle = state["fences"][:2]
        request("update", id=top["id"], rolledUp=True)
        request("update", id=middle["id"], geometry=dict(middle["geometry"], x=24, y=76, h=200, workH=1000))
        bottom = request("create", title="Bottom")["fences"][-1]
        request("update", id=bottom["id"], geometry=dict(bottom["geometry"], x=24, y=284, h=180, workH=1000))
        request("update", id=top["id"], geometry=dict(top["geometry"], workH=1000))
        state = request("update", id=top["id"], rolledUp=False)
        assert [f["geometry"]["y"] for f in state["fences"]] == [30, 348, 556]
        state = request("update", id=top["id"], rolledUp=True)
        assert [f["geometry"]["y"] for f in state["fences"]] == [30, 76, 284]
        request("update", id=bottom["id"], locked=True)
        before = (config / "config.json").read_bytes()
        request("update", fail=True, id=top["id"], rolledUp=False)
        assert (config / "config.json").read_bytes() == before, "Blocked cascade saved partial movements"
        request("update", id=bottom["id"], locked=False)
        request("update", id=top["id"], geometry=dict(top["geometry"], h=900, workH=1000))
        before = (config / "config.json").read_bytes()
        request("update", fail=True, id=top["id"], rolledUp=False)
        assert (config / "config.json").read_bytes() == before, "Off-screen cascade changed saved layout"
        print("PASS: expansion cascade, collapse restoration, atomic locked/screen-limit rejection")

        request("update", id=top["id"], geometry=dict(top["geometry"], h=310, workH=1000))
        state = request("reorder", id=bottom["id"], target=top["id"], after=False)
        assert [f["geometry"]["y"] for f in state["fences"]] == [218, 264, 30]
        request("update", id=middle["id"], locked=True)
        before = (config / "config.json").read_bytes()
        request("reorder", fail=True, id=bottom["id"], target=middle["id"], after=True)
        assert (config / "config.json").read_bytes() == before
        fingerprint = [{"devicePath":"stable-display-uuid","workDip":[1440,1000],"dpi":96}]
        state = request("snapshot-save", name="Monitor workspace", fingerprint=fingerprint)
        workspace = state["snapshots"][-1]
        assert workspace["displays"] == ["stable-display-uuid"]
        request("update", id=top["id"], title="Changed workspace")
        state = request("snapshot-restore", id=workspace["id"])
        assert state["fences"][0]["title"] == "Desktop"
        assert json.loads((config / "config.json").read_text())["layouts"][0]["fingerprint"] == fingerprint
        print("PASS: snap reorder, atomic reorder rejection, display-profile workspace save/restore")


if __name__ == "__main__":
    main()
