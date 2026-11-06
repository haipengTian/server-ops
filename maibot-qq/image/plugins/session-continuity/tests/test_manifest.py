"""Check the shipped manifest with the same validator used by the pinned host."""

from pathlib import Path

import json
import os
import sys


def test_manifest_loads_on_pinned_host():
    host = Path(os.environ["MAIBOT_APP_ROOT"])
    sys.path.insert(0, str(host))
    from src.plugin_runtime.runner.manifest_validator import ManifestValidator

    manifest = json.loads((Path(__file__).parents[1] / "_manifest.json").read_text(encoding="utf-8"))
    validator = ManifestValidator(host_version="1.3.18", sdk_version="2.19.0", project_root=host,
                                  log_errors=False)
    assert validator.validate(manifest), validator.errors
