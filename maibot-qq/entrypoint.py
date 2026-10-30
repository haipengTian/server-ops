"""Use image-pinned plugin code, preserving each instance's config and data."""
from pathlib import Path
import os
import shutil
import sys
from fix_read_gif_palette import apply as fix_gif_palette
from instance_fixes import apply as fix_instance

instance = Path('/instance')
for name in ('config/bot_config.toml', 'config/model_config.toml', 'eula.confirmed', 'privacy.confirmed'):
    if not (instance / name).is_file():
        sys.exit('Import the existing instance before starting MaiBot; missing ' + name)
for source in Path('/opt/bundled-plugins').iterdir():
    shutil.copytree(source, instance / 'plugins' / source.name, dirs_exist_ok=True)
fix_gif_palette(instance, Path('/opt/deploy/read-gif-palette.patch'))
fix_instance(instance, Path('/opt/deploy/qzone-bridge'), Path('/opt/maibot/src/plugin_runtime/component_query.py'))
os.execv(sys.executable, [sys.executable, '-m', 'src.cli.tool', 'run', '--directory', str(instance)])
