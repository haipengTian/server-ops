"""Use image-pinned plugin code, preserving each instance's config and data."""
from pathlib import Path
import os
import shutil
import sys

instance = Path('/instance')
for name in ('config/bot_config.toml', 'config/model_config.toml', 'eula.confirmed', 'privacy.confirmed'):
    if not (instance / name).is_file():
        sys.exit('Import the existing instance before starting MaiBot; missing ' + name)
for source in Path('/opt/bundled-plugins').iterdir():
    shutil.copytree(source, instance / 'plugins' / source.name, dirs_exist_ok=True)
os.execv(sys.executable, [sys.executable, '-m', 'src.cli.tool', 'run', '--directory', str(instance)])
