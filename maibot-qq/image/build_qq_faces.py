"""Bundle original QQ PNG/APNG assets; no network requests occur during chat."""

from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path, PurePosixPath
import re
import sys
from urllib.parse import quote
from urllib.request import urlopen


QFACE_REVISION = "c96fa14ff894147ac0442dda0fce6a4523e5fcbd"
SOURCE = f"https://raw.githubusercontent.com/koishijs/QFace/{QFACE_REVISION}/public/"
MAX_BYTES = 4 * 1024 * 1024


def fetch(path):
    with urlopen(SOURCE + quote(path, safe="/"), timeout=45) as response:
        data = response.read(MAX_BYTES + 1)
    if len(data) > MAX_BYTES:
        raise ValueError(f"QQ resource exceeds 4 MiB: {path}")
    return data


def select_assets(index):
    result = {}
    for face_id, entry in index["emojis"].items():
        if not re.fullmatch(r"[0-9]{1,8}", face_id):
            continue
        assets = entry.get("assets", [])
        # Preserve animation bytes. A PNG fallback is explicitly a static asset.
        asset = next((a for kind in ("apng", "png") for a in assets if a["type"] == kind), None)
        if asset is None:
            continue
        path = PurePosixPath(asset["path"])
        expected = PurePosixPath("assets/qq_emoji") / face_id / asset["type"]
        if path.parent != expected or path.suffix != ".png":
            raise ValueError(f"Unexpected QFace asset path: {path}")
        result[face_id] = {"name": entry["describe"].lstrip("/"),
                           "source_path": str(path), "source_type": asset["type"]}
    if "334" not in result:
        raise ValueError("QFace snapshot is missing 虎虎生威 (334)")
    return result


def build(output):
    output = Path(output)
    output.mkdir(parents=True, exist_ok=True)
    selected = select_assets(json.loads(fetch("assets/qq_emoji/_index.v2.json")))

    def download(item):
        face_id, asset = item
        data = fetch(asset["source_path"])
        if not data.startswith(b"\x89PNG\r\n\x1a\n"):
            raise ValueError(f"Invalid PNG/APNG for QQ face {face_id}")
        (output / f"{face_id}.png").write_bytes(data)
        return len(data)

    with ThreadPoolExecutor(max_workers=6) as pool:
        total = sum(pool.map(download, selected.items()))
    (output / "catalog.json").write_text(json.dumps(
        {"source": "https://github.com/koishijs/QFace", "revision": QFACE_REVISION,
         "assets": selected}, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    (output / "NOTICE.txt").write_text(
        "QQ face resources originate from Tencent; copyright belongs to Tencent.\n"
        "QFace: https://github.com/koishijs/QFace (code: MIT).\n"
        "Resources are for personal study/communication, not commercial use.\n"
        "PNG/APNG bytes are preserved; Lottie-only animations are not rendered.\n",
        encoding="utf-8")
    print(f"Bundled {len(selected)} QQ face assets, {total} bytes, source {QFACE_REVISION}")


if __name__ == "__main__":
    build(sys.argv[1])
