"""Stage or install TerraTechLegionPhoto on Linux/Proton. Defaults to status."""

import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import io
import os
from pathlib import Path
import shlex
import sys
import tempfile
from urllib.request import urlopen
import uuid
import zipfile


from legion_target import (APP_ID, ARCHIVE_URL as RELEASE_ASSET, BIN as GAME_BIN, GAME_EXE, HELPERS,
                        LOADER_FILES, LOADER_MARKER, MOD, MOD_MARKER as MARKER, PENDING_PROXY,
                        PROXY_SHA256, RELEASE, SAVED, ZIP_SHA256, check_loader_components,
                        finish_loader_activation, installed_in, original_file, plain_file)

SHIPPING_EXE = GAME_BIN / GAME_EXE
SOURCE = Path(__file__).resolve().parents[1] / "mod" / "Scripts"


def default_game():
    from photo_directory import steam_libraries

    for library in steam_libraries():
        game = installed_in(library)
        if game:
            return game
    raise ValueError("TerraTech Legion was not found in your Steam libraries. Pass --game '/path/to/TerraTech Legion'.")


def loader_mods(game, explicit_root):
    bin_dir = game / GAME_BIN
    if not (game / SHIPPING_EXE).is_file():
        raise ValueError(f"TerraTech Legion shipping executable missing from {bin_dir}. Check --game.")
    if explicit_root:
        roots = [explicit_root]
    elif (bin_dir / "override.txt").is_file():
        raise ValueError("A custom UE4SS override.txt is present. Pass --ue4ss-root for that loader.")
    else:
        roots = [bin_dir / "ue4ss", bin_dir]
    for root in roots:
        if (root / "UE4SS.dll").is_file() and (root / "Mods").is_dir():
            return root / "Mods"
    if explicit_root is not None:
        raise ValueError(f"No UE4SS.dll and Mods directory in {explicit_root}")
    return None


@contextmanager
def locked(directory):
    # All installer instances coordinate on the parent of the mod folder.
    fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        os.close(fd)


def existing_install(target):
    if target.is_symlink():
        raise ValueError(f"Move the existing symlink before managing {target}.")
    if not target.exists():
        return False
    marker = target / MARKER
    if not marker.is_file() or marker.is_symlink() or marker.read_bytes() != MOD.encode():
        raise ValueError(f"An existing unmanaged copy occupies {target}. Move it aside first.")
    return True


def package_files():
    scripts = {Path("Scripts") / p.name: p.read_bytes() for p in sorted(SOURCE.glob("*.lua"))}
    if not scripts.get(Path("Scripts/main.lua")):
        raise ValueError(f"No camera entry point found at {SOURCE / 'main.lua'}.")
    # UE4SS v4 starts mods containing enabled.txt, preserving the user's mods.txt.
    launcher = SOURCE.parent / "launch_camera.py"
    tools_dir = Path(__file__).resolve().parent
    exporters = {Path(name): (tools_dir / name).read_bytes()
                 for name in HELPERS}
    return {**scripts, Path("LICENSE"): (SOURCE.parents[1] / "LICENSE").read_bytes(),
            Path("enabled.txt"): b"", Path(MARKER): MOD.encode(),
            Path(launcher.name): launcher.read_bytes(), **exporters}


def write_package(directory, files):
    (directory / "Scripts").mkdir(parents=True)
    for relative, data in files.items():
        (directory / relative).write_bytes(data)


def backup(target, backup_parent):
    backups = backup_parent / f"{MOD}-backups"
    backups.mkdir(exist_ok=True)
    path = backups / uuid.uuid4().hex
    target.rename(path)
    return path


def publish(parent, backup_parent):
    files = package_files()
    parent.mkdir(parents=True, exist_ok=True)
    target = parent / MOD
    with locked(parent):
        exists = existing_install(target)
        if exists:
            old_scripts = {p.relative_to(target) for p in (target / "Scripts").glob("*.lua")}
            expected = {p for p in files if p.suffix == ".lua"}
            if old_scripts == expected and all((target / p).is_file() and (target / p).read_bytes() == data
                                               for p, data in files.items()):
                print(f"Already installed: {target}")
                return
        with tempfile.TemporaryDirectory(prefix=".photo-camera-", dir=parent) as tmp:
            staged = Path(tmp) / MOD
            write_package(staged, files)
            previous = backup(target, backup_parent) if exists else None
            try:
                staged.rename(target)
            except OSError:
                if previous:
                    previous.rename(target)
                raise
            if previous:
                print(f"Previous copy preserved at {previous}")
    print(f"Published {target}")


def remove(parent):
    target = parent / MOD
    with locked(parent):
        if existing_install(target):
            print(f"Removed from UE4SS. Previous files preserved at {backup(target, parent.parent)}")
        else:
            print(f"Already absent: {target}")


def install_with_loader(game, archive):
    bin_dir = game / GAME_BIN
    mods = loader_mods(game, None)
    if mods:
        print("Using the existing UE4SS installation.")
        publish(mods, mods.parent)
        return
    occupied = {p.name.lower() for p in bin_dir.iterdir()}
    conflicts = occupied.intersection({"ue4ss", "ue4ss.dll", "dwmapi.dll", "mods", "ue4ss-settings.ini"})
    if conflicts:
        raise ValueError(f"Existing loader files require review before installation: {sorted(conflicts)}")
    payload = archive.read_bytes()
    if hashlib.sha256(payload).hexdigest() != ZIP_SHA256:
        raise ValueError(f"UE4SS archive SHA-256 differs from the pinned v4.0.0 release: {ZIP_SHA256}")
    with tempfile.TemporaryDirectory(prefix=".photo-camera-", dir=bin_dir) as tmp:
        staged = Path(tmp)
        with zipfile.ZipFile(io.BytesIO(payload)) as bundle:
            for member in LOADER_FILES:
                path = staged / member
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(bundle.read(member))
        tree = staged / "ue4ss"
        (tree / "Mods/mods.txt").write_bytes(b"")
        (tree / LOADER_MARKER).write_text(ZIP_SHA256, encoding="ascii")
        write_package(tree / "Mods" / MOD, package_files())
        (staged / "dwmapi.dll").rename(tree / PENDING_PROXY)
        tree.rename(bin_dir / "ue4ss")
        try:
            finish_loader_activation(bin_dir / "ue4ss", ZIP_SHA256, PROXY_SHA256)
        except (OSError, ValueError):
            (bin_dir / "ue4ss").rename(tree)
            raise
    print(f"Installed UE4SS v4.0.0 and {MOD} in {bin_dir}")


def remove_with_loader(game):
    bin_dir = game / GAME_BIN
    tree = bin_dir / "ue4ss"
    proxy = bin_dir / "dwmapi.dll"
    marker = tree / LOADER_MARKER
    if not os.path.lexists(tree) and not os.path.lexists(proxy):
        print("Camera and loader already absent.")
        return
    if tree.is_symlink() or not plain_file(marker) or marker.read_bytes() != ZIP_SHA256.encode("ascii"):
        raise ValueError("Only a UE4SS installation created by --loader-zip can be rolled back.")
    proxy_present = os.path.lexists(proxy)
    if proxy_present and not original_file(proxy, PROXY_SHA256):
        raise ValueError("The original dwmapi.dll has changed. Use remove to remove just the camera.")
    check_loader_components(tree)
    mods = tree / "Mods"
    with locked(mods):
        existing_install(mods / MOD)
        if set(p.name for p in mods.iterdir()) - {MOD, "shared", "mods.txt"}:
            raise ValueError("Other mods exist in this loader. Use remove to remove just the camera.")
        folder = bin_dir / f"{MOD}-backups" / uuid.uuid4().hex
        folder.mkdir(parents=True)
        if proxy_present:
            proxy.rename(folder / proxy.name)
        try:
            tree.rename(folder / tree.name)
        except OSError:
            if proxy_present:
                (folder / proxy.name).rename(proxy)
            raise
    print(f"Removed the camera and its loader. Full backup: {folder}")


def launch_info(game, mods=None):
    mods = mods or (game / GAME_BIN / "ue4ss/Mods")
    launcher = shlex.quote(str(mods / MOD / "launch_camera.py"))
    print("Steam launch options for the Linux folder picker with the game's current renderer:")
    print(f'  WINEDLLOVERRIDES="dwmapi=n,b" python3 {launcher} %command%')
    print("With custom options, add dwmapi=n,b to existing DLL overrides and keep the other arguments.")
    print(f"Official loader: UE4SS v4.0.0 ({RELEASE})")
    print(f"Standard loader archive extraction location: {game / GAME_BIN}")


def prepare_installed_destination(game):
    from photo_directory import prepare_default_directory

    compat = os.environ.get("STEAM_COMPAT_DATA_PATH")
    if compat and (Path(compat).name == APP_ID or os.environ.get("SteamAppId") == APP_ID):
        prefix = Path(compat) / "pfx"
    elif game.parent.name == "common" and game.parent.parent.name == "steamapps":
        prefix = game.parent.parent / "compatdata" / APP_ID / "pfx"
    else:
        return
    local = prefix / "drive_c/users/steamuser/AppData/Local"
    if local.is_dir():
        prepare_default_directory(local / SAVED / "Screenshots/Windows")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("status", "stage", "install", "remove"),
                        nargs="?", default="status")
    parser.add_argument("--game", type=Path, help="TerraTech Legion game directory (default: discover from Steam)")
    parser.add_argument("--ue4ss-root", type=Path, help="Custom UE4SS directory containing UE4SS.dll and Mods")
    loaders = parser.add_mutually_exclusive_group()
    loaders.add_argument("--loader-zip", type=Path, help="Install a missing loader from the official v4.0.0 archive")
    loaders.add_argument("--download-loader", action="store_true", help="Download and verify the pinned v4.0.0 loader if missing")
    parser.add_argument("--remove-loader", action="store_true", help="Also roll back a loader installed by this tool")
    parser.add_argument("--output", type=Path, help="Parent directory for the staged mod (stage only)")
    args = parser.parse_args()
    if (args.loader_zip or args.download_loader) and (args.action != "install" or args.ue4ss_root):
        parser.error("Loader installation options require install and the standard game layout")
    if args.remove_loader and (args.action != "remove" or args.ue4ss_root):
        parser.error("--remove-loader is used with remove and the standard game layout")
    if args.action == "stage":
        if not args.output:
            parser.error("stage requires --output DIRECTORY")
        output = args.output.expanduser().resolve()
        publish(output, output)
        return 0
    if args.output:
        parser.error("--output is used with stage")
    game = args.game.expanduser().resolve() if args.game else default_game()
    root = args.ue4ss_root.expanduser().resolve() if args.ue4ss_root else None
    if not (game / SHIPPING_EXE).is_file():
        raise ValueError(f"Cannot find {SHIPPING_EXE} in {game}")
    # Lock before discovering the loader. A concurrent rollback may move the
    # entire ue4ss directory, invalidating a Mods path discovered before locking.
    with locked(game / GAME_BIN):
        result = manage_game(args, game, root)
        if result == 0 and args.action == "install":
            try:
                prepare_installed_destination(game)
            except OSError as error:
                print(f"Camera installed. Could not create its default screenshot folder: {error}", file=sys.stderr)
        return result


def manage_game(args, game, root):
    mods = loader_mods(game, root)
    if args.action == "install" and mods == game / GAME_BIN / "ue4ss/Mods":
        finish_loader_activation(mods.parent, ZIP_SHA256, PROXY_SHA256)
    if args.download_loader and not mods:
        with tempfile.TemporaryDirectory() as tmp:
            archive = Path(tmp) / "UE4SS_v4.0.0.zip"
            print(f"Downloading {RELEASE_ASSET}", flush=True)
            with urlopen(RELEASE_ASSET, timeout=45) as download:
                # The pinned archive is 8.4 MiB. Bound unexpected server responses.
                payload = download.read(16 * 1024 * 1024 + 1)
            if len(payload) > 16 * 1024 * 1024:
                raise ValueError("Download exceeded the size limit for the pinned UE4SS release.")
            archive.write_bytes(payload)
            install_with_loader(game, archive)
        launch_info(game)
        return 0
    if args.loader_zip:
        install_with_loader(game, args.loader_zip.expanduser())
        launch_info(game)
        return 0
    if args.remove_loader:
        remove_with_loader(game)
        return 0
    if not mods:
        print("UE4SS.dll and its Mods directory were not found together.")
        print("Install it with: python3 tools/install.py install --download-loader (or --loader-zip PATH)")
        launch_info(game)
        return 0 if args.action == "status" else 1
    if args.action == "status":
        target = mods / MOD
        print(f"UE4SS mods directory: {mods}")
        print(f"Camera present: {target.exists()}")
        launch_info(game, mods)
    elif args.action == "install":
        publish(mods, mods.parent)
        launch_info(game, mods)
    else:
        remove(mods)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError) as error:
        sys.exit(str(error))
