"""Install the two image routes and a private reference photo on this instance."""

from copy import deepcopy
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time


DATA = Path("/opt/maibot-qq")
BUNDLED = "/opt/bundled-plugins/nuonuo-photo"
FILES = ("plugin.py", "intent.py", "images.py", "config.py", "_manifest.json", "webui.json", "README.md")


def reference_state(state, filename):
    if state.get("job", {}).get("status") == "running":
        raise ValueError("A photo is generating; wait until it finishes before upgrading")
    updated = deepcopy(state)
    if filename:
        updated.update(reference=filename, candidate=filename)
    return updated


def restore_reference(current, previous, installed):
    restored = deepcopy(current)
    if not installed:
        return restored
    for name in ("reference", "candidate"):
        if restored.get(name) == installed:
            restored[name] = previous.get(name, "")
    return restored


def image_override(text, image):
    value = json.loads(text)
    value["services"]["maibot"]["image"] = image
    return json.dumps(value, ensure_ascii=False, indent=2) + "\n"


def run(args, capture=False):
    return subprocess.run(args, check=True, stdout=subprocess.PIPE if capture else None).stdout


def compose(ops, *args):
    return run(["docker", "compose", "--env-file", str(ops / ".env"), "-f", str(ops / "compose.yaml"),
                "-f", str(ops / "compose.qq-face.yaml"), *args], capture=args[:1] == ("ps",))


def write_json(path, value):
    temp = path.with_suffix(".tmp")
    temp.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temp.replace(path)


def wait_healthy(cid):
    for _ in range(90):
        status = run(["docker", "inspect", "--format", "{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}", cid], True).decode().strip()
        if status == "running healthy":
            return
        if status.startswith(("exited", "dead")):
            break
        time.sleep(2)
    raise RuntimeError("MaiBot did not become healthy; restore the saved version")


def rollback(backup):
    record = json.loads((backup / "restore.json").read_text(encoding="utf-8"))
    ops, cid = Path(record["ops"]), record["container"]
    # Stop by Docker identity, independently of any partially written Compose.
    run(["docker", "stop", cid])
    runtime = DATA / "runtime/plugins/nuonuo-photo"
    for filename in FILES:
        saved = backup / "runtime" / filename
        if saved.is_file():
            shutil.copy2(saved, runtime / filename)
        elif (runtime / filename).is_file():
            (runtime / filename).unlink()
    # Restore bundled code in the current container as well as the image used
    # by future Compose recreations. Preserve all QQ face mounts.
    run(["docker", "create", "--name", "maibot-photo-restore-" + record["stamp"], record["old_image"]], True)
    recovery = "maibot-photo-restore-" + record["stamp"]
    try:
        with tempfile.TemporaryDirectory(prefix="photo-restore-") as tmp:
            run(["docker", "cp", recovery + ":" + BUNDLED, str(Path(tmp) / "plugin")])
            run(["docker", "cp", str(Path(tmp) / "plugin") + "/.", cid + ":" + BUNDLED])
    finally:
        run(["docker", "rm", recovery], True)
    state_path = DATA / "runtime/data/plugins/haipengtian.nuonuo-photo/state.json"
    current = json.loads(state_path.read_text(encoding="utf-8"))
    previous = json.loads((backup / "state.json").read_text(encoding="utf-8"))
    write_json(state_path, restore_reference(current, previous, record["reference"]))
    overlay = ops / "compose.qq-face.yaml"
    overlay.write_text(image_override(overlay.read_text(encoding="utf-8"), record["old_image"]), encoding="utf-8")
    run(["docker", "start", cid], True)
    wait_healthy(cid)
    print("Photo plugin and previous reference restored. Newer image requests/results remain saved.")


def upgrade(ops):
    package = Path(__file__).resolve().parent
    overlay = ops / "compose.qq-face.yaml"
    old_override = overlay.read_text(encoding="utf-8")
    json.loads(old_override)["services"]["maibot"]["image"]
    compose(ops, "config", "--quiet")
    cid = compose(ops, "ps", "-q", "maibot").decode().strip()
    if not cid or "\n" in cid:
        raise ValueError("Expected one running MaiBot container")
    container_name = run(["docker", "inspect", "--format", "{{.Name}}", cid], True).decode().strip().lstrip("/")
    mounts = json.loads(run(["docker", "inspect", "--format", "{{json .Mounts}}", cid], True))
    if not any(m["Destination"] == "/instance" and Path(m["Source"]).resolve() == (DATA / "runtime").resolve() for m in mounts):
        raise ValueError("Unexpected /instance mount; no changes made")
    runtime = DATA / "runtime/plugins/nuonuo-photo"
    state_path = DATA / "runtime/data/plugins/haipengtian.nuonuo-photo/state.json"
    state = json.loads(state_path.read_text(encoding="utf-8"))
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ").lower()
    reference = "reference-" + stamp + ".jpg" if (package / "reference.jpg").is_file() else ""
    reference_state(state, reference)
    for filename in FILES:
        source = package / "nuonuo-photo" / filename
        if filename.endswith(".py"):
            compile(source.read_text(encoding="utf-8"), filename, "exec")
    if reference and not (package / "reference.jpg").read_bytes().startswith(b"\xff\xd8"):
        raise ValueError("Missing prepared reference JPEG")
    # Detect existing edits instead of silently overwriting this plugin.
    with tempfile.TemporaryDirectory(prefix="photo-check-") as tmp:
        bundled = Path(tmp) / "bundled"
        run(["docker", "cp", cid + ":" + BUNDLED, str(bundled)])
        for original in (package / "baseline").iterdir():
            expected = original.read_text(encoding="utf-8")
            for current in (bundled / original.name, runtime / original.name):
                if current.read_text(encoding="utf-8") != expected:
                    raise ValueError("Photo plugin differs from the packaged baseline: " + original.name + "; review before upgrading")
    backup = DATA / "backups" / ("photo-" + stamp)
    backup.mkdir(parents=True, mode=0o700)
    (backup / "runtime").mkdir()
    shutil.copy2(__file__, backup / "upgrade_photo.py")
    old_image = "maibot-qq-local:pre-photo-" + stamp
    new_image = "maibot-qq-local:photo-" + stamp
    print("Rollback: python3 " + str(backup / "upgrade_photo.py") + " --rollback " + str(backup), flush=True)
    run(["docker", "stop", cid])
    # Re-read after graceful shutdown so completed jobs and request dedup are kept.
    try:
        state = json.loads(state_path.read_text(encoding="utf-8"))
        new_state = reference_state(state, reference)
        run(["docker", "commit", cid, old_image], True)
        shutil.copy2(state_path, backup / "state.json")
        (backup / "compose.qq-face.yaml").write_text(old_override, encoding="utf-8")
        for filename in FILES:
            if (runtime / filename).is_file():
                shutil.copy2(runtime / filename, backup / "runtime" / filename)
        write_json(backup / "restore.json", {"ops": str(ops), "container": container_name, "old_image": old_image,
                   "reference": reference, "stamp": stamp})
    except Exception:
        run(["docker", "start", cid], True)
        raise
    try:
        for filename in FILES:
            source = package / "nuonuo-photo" / filename
            run(["docker", "cp", str(source), cid + ":" + BUNDLED + "/" + filename])
            shutil.copy2(source, runtime / filename)
        if reference:
            shutil.copy2(package / "reference.jpg", state_path.parent / reference)
        write_json(state_path, new_state)
        run(["docker", "commit", cid, new_image], True)
        overlay.write_text(image_override(old_override, new_image), encoding="utf-8")
        compose(ops, "config", "--quiet")
        run(["docker", "start", cid], True)
        wait_healthy(cid)
    except Exception:
        print("Upgrade failed; restoring the previous photo plugin and reference.", flush=True)
        rollback(backup)
        raise
    version = json.loads((package / "nuonuo-photo/_manifest.json").read_text(encoding="utf-8"))["version"]
    print("Photo plugin v" + version + " healthy: image status + failure feedback + explicit regeneration enabled.")


if __name__ == "__main__":
    os.umask(0o077)
    if len(sys.argv) == 3 and sys.argv[1] == "--rollback":
        rollback(Path(sys.argv[2]).resolve())
    elif len(sys.argv) == 2:
        upgrade(Path(sys.argv[1]).resolve())
    else:
        sys.exit("Usage: python3 upgrade_photo.py /opt/maibot-qq-deploy/maibot-qq")
