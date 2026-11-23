"""Build the Windows and Linux/Proton release downloads from this checkout."""

import argparse
import hashlib
import os
from pathlib import Path
import re
import tempfile
import zipfile

from legion_target import HELPERS as EXPORT_TOOLS, MOD as NAME

ROOT = Path(__file__).resolve().parents[1]
PLATFORMS = ("windows", "linux-proton")


def release_files(root, platform):
    files = [root / "README.md", root / "INSTALL.md", root / "IMPLEMENTATION_PLAN.md", root / "LICENSE", root / "requirements.txt",
             root / "THIRD_PARTY_LICENSES/Denshattack-Photo-Camera.txt", root / "mod/Scripts/main.lua"]
    files.extend((root / "mod/Scripts").glob("*.lua"))
    files.extend(root / "tools" / name for name in EXPORT_TOOLS)
    if platform == "windows":
        files.extend([root / "Install-Windows.cmd", root / "Develop-Photos.cmd"])
        files.extend(root / "windows" / name for name in ("photo_camera.py", "Run-Python.cmd", "Launch-Camera.cmd"))
    else:
        files.extend([root / "Install-Linux.sh", root / "Develop-Photos.sh", root / "tools/install.py", root / "mod/launch_camera.py"])
    for path in sorted(set(files), key=lambda p: p.relative_to(root).as_posix()):
        if not path.is_file() or path.is_symlink():
            raise ValueError(f"Missing or invalid release input: {path}")
        yield path


def build_archive(root, output, version, platform):
    folder = f"{NAME}-{version}"
    archive = output / f"{folder}-{platform}.zip"
    # Stable timestamps, modes, ordering and line endings for checkout-independent builds.
    with zipfile.ZipFile(archive, "w") as bundle:
        for path in release_files(root, platform):
            member = f"{folder}/{path.relative_to(root).as_posix()}"
            entry = zipfile.ZipInfo(member, date_time=(1980, 1, 1, 0, 0, 0))
            entry.create_system = 3
            entry.external_attr = (0o100755 if path.suffix == ".sh" else 0o100644) << 16
            data = path.read_bytes().replace(b"\r\n", b"\n")
            if path.suffix.lower() == ".cmd":
                data = data.replace(b"\n", b"\r\n")
            bundle.writestr(entry, data, compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)
    return archive


def build_release(root, output, version):
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9]+(?:[.-][A-Za-z0-9]+)*)?", version):
        raise ValueError("Use a version such as 0.1.0 or 0.1.0-beta.1.")
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=output, prefix=".release-") as temp:
        staged = Path(temp)
        archives = [build_archive(root, staged, version, platform) for platform in PLATFORMS]
        sums = staged / "SHA256SUMS.txt"
        lines = [f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n" for path in archives]
        sums.write_bytes("".join(lines).encode("ascii"))
        products = [*archives, sums]
        for path in products:
            os.replace(path, output / path.name)
        return [output / path.name for path in products]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True, help="Release version without a v prefix")
    parser.add_argument("--output", type=Path, default=ROOT / "dist", help="Output directory (default: dist)")
    args = parser.parse_args()
    try:
        for product in build_release(ROOT, args.output, args.version):
            print(product)
    except (ValueError, OSError) as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()
