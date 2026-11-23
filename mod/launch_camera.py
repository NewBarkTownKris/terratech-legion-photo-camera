"""Enable TerraTech Legion's host folder picker when wrapping a Proton Steam command."""

import os
from pathlib import Path, PureWindowsPath
import subprocess
import sys


GAME_EXECUTABLES = {"terratech_legioneos.exe", "terratech_legioneos-win64-shipping.exe"}


def main(command):
    if not command:
        sys.exit("Usage in Steam launch options: python3 launch_camera.py %command%")
    if any(PureWindowsPath(arg.strip('"')).name.lower() in GAME_EXECUTABLES for arg in command):
        picker = Path(__file__).resolve().with_name("photo_directory.py")
        if not picker.is_file():
            picker = picker.parent.parent / "tools/photo_directory.py"
        if picker.is_file():
            try:
                subprocess.Popen([sys.executable, str(picker), "--watch", "--parent-pid", str(os.getpid())],
                                 stdin=subprocess.DEVNULL, start_new_session=True)
            except OSError as exc:
                print(f"Could not start the TerraTech Legion photo folder picker: {exc}", file=sys.stderr)
        else:
            print("Missing photo_directory.py. Reinstall the camera to use the F2 picker.", file=sys.stderr)
    # Keep the original Steam/Proton arguments, renderer, PID and exit status.
    os.execvp(command[0], command)


if __name__ == "__main__":
    main(sys.argv[1:])
