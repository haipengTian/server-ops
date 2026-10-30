"""Narrow, reversible adapter overlay for an existing Docker deployment (Linux)."""

import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone


OLD_HELPER = 'compose() { docker compose --env-file "$OPS_DIR/.env" -f "$OPS_DIR/compose.yaml" "$@"; }'
NEW_HELPER = '''compose() {
  local extra=()
  [[ ! -f "$OPS_DIR/compose.qq-face.yaml" ]] || extra=(-f "$OPS_DIR/compose.qq-face.yaml")
  docker compose --env-file "$OPS_DIR/.env" -f "$OPS_DIR/compose.yaml" "${extra[@]}" "$@"
}'''
BUNDLED = "/opt/bundled-plugins/snowluma-adapter"
FILES = ("config.py", "codecs/inbound/message_codec.py")
DATA = Path("/opt/maibot-qq")


def visual_config(text):
    section = re.search(r"(?m)^\[plugin\][ \t]*(?:#.*)?\r?\n", text)
    if section is None:
        raise ValueError("Adapter config has no [plugin] section; no changes made")
    end_match = re.search(r"(?m)^\[", text[section.end():])
    end = section.end() + end_match.start() if end_match else len(text)
    body = text[section.end():end]
    pattern = r'''(?m)^(qq_face_parse_mode\s*=\s*)["'][^"'\r\n]*["']'''
    if re.search(pattern, body):
        body = re.sub(pattern, r'\1"visual"', body, count=1)
    else:
        body = 'qq_face_parse_mode = "visual"\n' + body
    return text[:section.end()] + body + text[end:]


def deployment_helper(text):
    if NEW_HELPER in text:
        return text
    if text.count(OLD_HELPER) != 1:
        raise ValueError("Unexpected deploy.sh compose helper; review it before installing")
    return text.replace(OLD_HELPER, NEW_HELPER)


def run(args, *, data=None, capture=False, cwd=None):
    result = subprocess.run(args, input=data, stdout=subprocess.PIPE if capture else None,
                            check=True, cwd=cwd)
    return result.stdout if capture else None


def compose(ops, *args):
    cmd = ["docker", "compose", "--env-file", str(ops / ".env"), "-f", str(ops / "compose.yaml")]
    overlay = ops / "compose.qq-face.yaml"
    if overlay.is_file():
        cmd += ["-f", str(overlay)]
    return run(cmd + list(args), capture=args[:1] == ("ps",))


def restore(backup):
    state = json.loads((backup / "restore.json").read_text())
    ops = Path(state["ops"])
    # Never depend on a possibly invalid candidate Compose file to recover.
    running = run(["docker", "ps", "--format", "{{.Names}}"], capture=True).decode().splitlines()
    if state["container_name"] in running:
        run(["docker", "stop", state["container_name"]])
    for filename, existed in state["files"].items():
        path = Path(filename)
        if existed:
            shutil.copy2(backup / ("saved-" + str(list(state["files"]).index(filename))), path)
        elif path.exists():
            path.unlink()
    # Restore the *running code*, including its original writable-layer fixes.
    # Keep a local image-only override after rollback; never publish this image.
    helper = ops / "deploy.sh"
    helper.write_text(deployment_helper(helper.read_text()))
    (ops / "compose.qq-face.yaml").write_text(json.dumps(
        {"services": {"maibot": {"image": state["snapshot_image"]}}}, indent=2) + "\n")
    compose(ops, "up", "-d", "--no-deps", "--wait", "--wait-timeout", "300", "maibot")
    print("Previous adapter and configuration restored; verify QQ receive/reply in Dashboard.")


def install(ops):
    package = Path(__file__).resolve().parent
    helper = ops / "deploy.sh"
    original_helper = helper.read_text()
    new_helper = deployment_helper(original_helper)
    overlay = ops / "compose.qq-face.yaml"
    if overlay.exists():
        raise ValueError("QQ face overlay already exists; keep it or use its saved rollback first")
    runtime = DATA / "runtime/plugins/snowluma-adapter"
    config = runtime / "config.toml"
    new_config = visual_config(config.read_text())
    gif_files = list((DATA / "runtime/plugins").glob("*/read_animation/frames.py"))
    if len(gif_files) != 1:
        raise ValueError("Install/enable Read GIF v0.1.2 in the plugin market first")
    gif_frame_file = gif_files[0]
    cid = compose(ops, "ps", "-q", "maibot").decode().strip()
    if not cid or "\n" in cid:
        raise ValueError("Expected one running MaiBot container")
    mounts = json.loads(run(["docker", "inspect", "--format", "{{json .Mounts}}", cid], capture=True))
    container_name = run(["docker", "inspect", "--format", "{{.Name}}", cid], capture=True).decode().strip().lstrip("/")
    if not any(m["Destination"] == "/instance" and Path(m["Source"]).resolve() == (DATA / "runtime").resolve()
               for m in mounts):
        raise ValueError("Container /instance is not /opt/maibot-qq/runtime; no changes made")
    # Parse without logging or returning private configuration.
    run(["docker", "exec", "-i", cid, "python", "-c",
         "import sys,tomllib; tomllib.loads(sys.stdin.read())"], data=new_config.encode())
    assets = package / "qq_faces"
    if not (assets / "334.png").is_file() or not (assets / "catalog.json").is_file():
        raise ValueError("Missing bundled original QQ face assets")
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    backup = DATA / "backups" / ("qq-face-" + stamp)
    backup.mkdir(parents=True, mode=0o700)
    target = DATA / "qq-face-visual" / stamp
    with tempfile.TemporaryDirectory(prefix="qq-face-") as staging:
        stage = Path(staging)
        adapter = stage / "adapter"
        run(["docker", "cp", cid + ":" + BUNDLED, str(adapter)])
        run(["git", "apply", "--check", str(package / "qq-face-visual.patch")], cwd=adapter)
        run(["git", "apply", str(package / "qq-face-visual.patch")], cwd=adapter)
        for filename in FILES:
            compile((adapter / filename).read_text(), filename, "exec")
        gif_stage = stage / "read-gif"
        (gif_stage / "read_animation").mkdir(parents=True)
        shutil.copy2(gif_frame_file, gif_stage / "read_animation/frames.py")
        run(["git", "apply", "--check", str(package / "read-gif-palette.patch")], cwd=gif_stage)
        run(["git", "apply", str(package / "read-gif-palette.patch")], cwd=gif_stage)
        new_gif_frames = (gif_stage / "read_animation/frames.py").read_text()
        compile(new_gif_frames, "read_animation/frames.py", "exec")
        target.mkdir(parents=True, mode=0o755)
        for filename in FILES:
            destination = target / filename
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(adapter / filename, destination)
        shutil.copytree(assets, target / "assets/qq_faces")
    volumes = [{"type": "bind", "source": str(target / relative), "target": BUNDLED + "/" + relative,
                "read_only": True, "bind": {"create_host_path": False, "selinux": "Z"}}
               for relative in (*FILES, "assets/qq_faces")]
    snapshot_image = "maibot-qq-local:pre-qq-face-" + stamp.lower()
    overlay_text = json.dumps({"services": {"maibot": {"image": snapshot_image, "volumes": volumes}}}, indent=2) + "\n"
    paths = [helper, overlay, config, gif_frame_file] + [runtime / name for name in FILES]
    state = {"ops": str(ops), "files": {str(p): p.is_file() for p in paths},
             "snapshot_image": snapshot_image, "container_name": container_name}
    for i, path in enumerate(paths):
        if path.is_file():
            shutil.copy2(path, backup / ("saved-" + str(i)))
    (backup / "restore.json").write_text(json.dumps(state))
    shutil.copy2(__file__, backup / "install_qq_face_visual.py")
    candidate = backup / "candidate-compose.yaml"
    candidate.write_text(overlay_text)
    run(["docker", "compose", "--env-file", str(ops / ".env"), "-f", str(ops / "compose.yaml"),
         "-f", str(candidate), "config", "--quiet"])
    # Mounts are excluded. This local recovery image retains manual core fixes
    # in the current container's writable layer before it is ever recreated.
    run(["docker", "commit", "--pause=true", cid, snapshot_image])
    print("Rollback: python3 " + str(backup / "install_qq_face_visual.py") + " --rollback " + str(backup), flush=True)
    # Only MaiBot is recreated. SnowLuma/QQ and all other services stay running.
    try:
        compose(ops, "stop", "maibot")
        helper.write_text(new_helper)
        overlay.write_text(overlay_text)
        config.write_text(new_config)
        gif_frame_file.write_text(new_gif_frames)
        compose(ops, "config", "--quiet")
        compose(ops, "up", "-d", "--no-deps", "--wait", "--wait-timeout", "300", "maibot")
    except Exception:
        print("Install failed; restoring previous configuration.", flush=True)
        restore(backup)
        raise
    print("QQ face visual overlay enabled. Send a NEW native QQ face to verify actual VLM recognition.")


if __name__ == "__main__":
    os.umask(0o077)
    if len(sys.argv) == 3 and sys.argv[1] == "--rollback":
        restore(Path(sys.argv[2]).resolve())
    elif len(sys.argv) == 2:
        install(Path(sys.argv[1]).resolve())
    else:
        sys.exit("Usage: python3 install_qq_face_visual.py /opt/maibot-qq-deploy/maibot-qq")
