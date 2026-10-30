"""Apply repository-managed fixes to the supported installed market plugins."""

import importlib.util
import json
from pathlib import Path


def apply(instance, bridge, host_source):
    plugins = Path(instance) / 'plugins'
    installed = {json.loads(p.read_text(encoding='utf-8-sig')).get('id'): p.parent
                 for p in plugins.glob('*/_manifest.json')}
    # Standalone diary/space installations keep their original contract.
    if not {'internetsb.maizone', 'bockegai.diary-plugin'} <= installed.keys():
        return
    spec = importlib.util.spec_from_file_location('instance_qzone_bridge', Path(bridge) / 'apply.py')
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    changes = module.build_changes(plugins, Path(host_source))
    module.apply_changes(plugins, changes)

