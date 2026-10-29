#!/usr/bin/env bash
set -euo pipefail
image=${1:?image required}
docker run --rm --network none --entrypoint /opt/maibot/.venv/bin/python "$image" \
  -c 'from importlib.metadata import version; import PIL, tomlkit, maibot_sdk; assert version("maibot-plugin-sdk") == "2.19.0"; assert version("maibot-dashboard") == "1.9.12"'
docker run --rm --network none --entrypoint /opt/maibot/.venv/bin/python "$image" -m src.cli.tool --version
docker run --rm --network none --entrypoint /opt/maibot/.venv/bin/python "$image" -m src.cli.tool init --directory /tmp/test-instance
# A missing migration must fail before business runtime or network connections start.
if docker run --rm --network none "$image"; then
  printf 'Image unexpectedly started without an imported instance.\n' >&2
  exit 1
fi
