#!/usr/bin/env bash
set -euo pipefail
image=${1:?image required}
docker run --rm --network none --entrypoint /opt/maibot/.venv/bin/python "$image" \
  -c 'from importlib.metadata import version; import PIL, tomlkit, maibot_sdk; assert version("maibot-plugin-sdk") == "2.19.0"; assert version("maibot-dashboard") == "1.9.12"'
docker run --rm --network none --entrypoint /opt/maibot/.venv/bin/python "$image" -m src.cli.tool --version
docker run --rm --network none --entrypoint /opt/maibot/.venv/bin/python "$image" -m src.cli.tool init --directory /tmp/test-instance

# Exercise the patched adapter and inspect real bundled frames without networking.
docker run --rm --network none --entrypoint /opt/maibot/.venv/bin/python \
  -e ADAPTER_ROOT=/opt/bundled-plugins/snowluma-adapter \
  -v "$PWD/maibot-qq/image/regressions:/regressions:ro" "$image" /regressions/test_qq_face_visual.py -v
docker run --rm --network none --entrypoint /opt/maibot/.venv/bin/python "$image" -c '
from pathlib import Path
from PIL import Image
p = Path("/opt/bundled-plugins/snowluma-adapter/assets/qq_faces")
assert len(list(p.glob("*.png"))) == 327
assert Image.open(p / "334.png").n_frames == 1
assert Image.open(p / "0.png").n_frames > 1
'

# Pinned market plugin contract: preserve APNG colors, inject animation text, reuse cache.
gif_source=$(mktemp -d)
trap 'rm -rf -- "$gif_source"' EXIT
git -C "$gif_source" init --quiet
git -C "$gif_source" remote add origin https://github.com/fabiocsa/maibot-read-gif.git
git -C "$gif_source" fetch --depth 1 origin b69ed723156fd7a05d2af212c9881cf76602ab42
git -C "$gif_source" checkout --detach FETCH_HEAD
git -C "$gif_source" apply "$PWD/maibot-qq/image/read-gif-palette.patch"
docker run --rm --network none --entrypoint /opt/maibot/.venv/bin/python \
  -e ADAPTER_ROOT=/opt/bundled-plugins/snowluma-adapter -e READ_GIF_ROOT=/read-gif \
  -v "$PWD/maibot-qq/image/regressions:/regressions:ro" -v "$gif_source:/read-gif:ro" \
  "$image" /regressions/test_qq_face_read_gif.py -v
# A missing migration must fail before business runtime or network connections start.
if docker run --rm --network none "$image"; then
  printf 'Image unexpectedly started without an imported instance.\n' >&2
  exit 1
fi
