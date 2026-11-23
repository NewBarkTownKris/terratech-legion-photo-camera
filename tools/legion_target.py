"""Steam build layout and pinned UE4SS loader for the TerraTech Legion camera packages."""

import hashlib
import os
from pathlib import Path
import re
import stat
import sys


APP_ID = "3596700"
MOD = "TerraTechLegionPhoto"
BIN = Path("TerraTech_Legion/Binaries/Win64")
GAME_EXE = "TerraTech_LegionEOS-Win64-Shipping.exe"
SAVED = Path("TerraTech_Legion/Saved")
MOD_MARKER = ".terratech-legion-photo-camera-install"
LOADER_MARKER = ".terratech-legion-photo-camera-loader"
RELEASE = "https://github.com/UE4SS-RE/RE-UE4SS/releases/tag/v4.0.0"
ARCHIVE_URL = "https://github.com/UE4SS-RE/RE-UE4SS/releases/download/v4.0.0/UE4SS_v4.0.0.zip"
ZIP_SHA256 = "251ad0d1381a241750e036f5918cbf2b5d7ec58ebc608cb2dd09d459d0c81e45"
PROXY_SHA256 = "21fafb3e49958e2b16721d57d5c1af3efcaaae6d91a430bb6124a67e80f5fb42"
PENDING_PROXY = ".terratech-legion-photo-camera-proxy.pending"
LOADER_COMPONENTS = {
    "UE4SS.dll": "3843d81a8280096b0de3c750eebf15507e374c250dc551cbf07e7be7acc1e2ba",
    "UE4SS-settings.ini": "c96a3b1ac2f29f4aca3c72198eb557075ee30fc1d1186c332a025a8d2e66bd48",
}
LOADER_FILES = ("dwmapi.dll", "ue4ss/UE4SS.dll", "ue4ss/UE4SS-settings.ini", "ue4ss/LICENSE",
                "ue4ss/UE4SS_SDK_Backends/UE4SS.json", "ue4ss/Mods/shared/UEHelpers/UEHelpers.lua")
HELPERS = ("legion_target.py", "develop_photos.py", "export_photo.py", "grade.py", "linear_dng.py", "photo_directory.py")


def installed_in(steamapps):
    """Read the retail app's declared installation directory in this library."""
    manifest = steamapps / f"appmanifest_{APP_ID}.acf"
    try:
        contents = manifest.read_text(encoding="utf-8-sig")
    except (OSError, UnicodeError):
        return None
    match = re.search(r'^\s*"installdir"\s*"([^"/\\]+)"', contents, re.MULTILINE)
    if match and match[1] not in (".", ".."):
        game = steamapps / "common" / match[1]
        if (game / BIN / GAME_EXE).is_file():
            return game
    return None


def plain_file(path):
    if not path.is_file() or path.is_symlink():
        return False
    return not (getattr(path.lstat(), "st_file_attributes", 0) & stat.FILE_ATTRIBUTE_REPARSE_POINT)


def original_file(path, expected):
    return plain_file(path) and hashlib.sha256(path.read_bytes()).hexdigest() == expected


def finish_loader_activation(tree, archive_hash, proxy_hash):
    """Complete or retry the second rename of a fresh loader installation."""
    pending = tree / PENDING_PROXY
    marker = tree / LOADER_MARKER
    proxy = tree.parent / "dwmapi.dll"
    if not os.path.lexists(pending):
        if not os.path.lexists(proxy) and plain_file(marker) and marker.read_bytes() == archive_hash.encode("ascii"):
            raise ValueError("The camera loader's dwmapi.dll is missing. Roll back with remove --remove-loader and reinstall.")
        return
    if not original_file(pending, proxy_hash) or not plain_file(marker) or marker.read_bytes() != archive_hash.encode("ascii"):
        raise ValueError(f"Cannot verify this unfinished loader installation in {tree}")
    if not os.path.lexists(proxy):
        if os.name == "nt":
            pending.rename(proxy)  # Exclusive on Windows.
            return
        os.link(pending, proxy)  # Atomic, exclusive publication on Linux.
    elif not original_file(proxy, proxy_hash):
        raise ValueError(f"Another proxy occupies {proxy}. The camera installer preserved it.")
    # Activation has committed. A leftover pending hard link can be retired
    # next time without taking a working installation back out of service.
    try:
        pending.unlink()
    except OSError as error:
        print(f"Loader is active. Pending proxy cleanup will retry on install: {error}", file=sys.stderr)


def check_loader_components(tree):
    for name, expected in LOADER_COMPONENTS.items():
        if not original_file(tree / name, expected):
            raise ValueError(f"The installed {name} has changed. Remove just the camera to preserve this loader.")
