"""Apply the bounded Read GIF v0.1.2 fix at startup; preserve newer versions."""

from pathlib import Path
import subprocess


def apply(instance, patch):
    for frames in (Path(instance) / "plugins").glob("*/read_animation/frames.py"):
        root = frames.parents[1]
        command = ["git", "apply", "--check", str(patch)]
        checked = subprocess.run(command, cwd=root, capture_output=True)
        if checked.returncode == 0:
            subprocess.run(["git", "apply", str(patch)], cwd=root, check=True)
            print("Read GIF: applied palette APNG rewind fix.", flush=True)
        else:
            fixed = subprocess.run(["git", "apply", "--reverse", "--check", str(patch)], cwd=root, capture_output=True)
            if fixed.returncode:
                print("Read GIF: code differs from v0.1.2; palette fix skipped, verify APNG colors after upgrade.", flush=True)


if __name__ == "__main__":
    apply("/instance", Path(__file__).with_name("read-gif-palette.patch"))
