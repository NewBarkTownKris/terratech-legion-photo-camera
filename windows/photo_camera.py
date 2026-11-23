"""Install TerraTech Legion Photo Mode and run its native Windows folder picker."""

import argparse
from contextlib import contextmanager
import ctypes
from ctypes import wintypes
import hashlib
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
from urllib.request import urlopen
import uuid
import zipfile


HERE = Path(__file__).resolve().parent


# Imports work both in a source checkout and in the installed UE4SS mod.
_tools = HERE.parent / "tools"
sys.path.insert(0, str(_tools if (_tools / "photo_directory.py").is_file() else HERE.parent))
try:
    import photo_directory as folders
    from legion_target import (APP_ID, ARCHIVE_URL, BIN, GAME_EXE, HELPERS as EXPORTERS, LOADER_FILES,
                            LOADER_MARKER, MOD, MOD_MARKER, PENDING_PROXY, PROXY_SHA256, ZIP_SHA256 as SHA256,
                            check_loader_components, finish_loader_activation,
                            installed_in, original_file)
finally:
    sys.path.pop(0)


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def reparse(path):
    try:
        return bool(getattr(path.lstat(), "st_file_attributes", 0) & stat.FILE_ATTRIBUTE_REPARSE_POINT)
    except FileNotFoundError:
        return False


def choose_folder(title, start=None):
    from tkinter import Tk, filedialog
    root = Tk()
    root.withdraw()
    root.attributes("-topmost", True)
    try:
        value = filedialog.askdirectory(title=title, initialdir=str(start or Path.home()), parent=root,
                                        mustexist=True)
        return Path(value) if value else None
    finally:
        root.destroy()


def choose(args):
    if args.reset:
        folders.settings_file().unlink(missing_ok=True)
    elif args.set is not None:
        folders.set_directory(args.set)
    elif not args.show:
        try:
            start = folders.selected_directory()
        except (OSError, ValueError):
            start = None
        value = choose_folder("Choose a TerraTech Legion screenshot folder", start if start and start.is_dir()
                              else Path.home() / "Pictures")
        if value is None:
            return
        folders.set_directory(value)
    print(f"Screenshot folder: {folders.selected_directory()}")


def find_game():
    import winreg
    steam = []
    for hive, subkey, field in ((winreg.HKEY_CURRENT_USER, r"SOFTWARE\Valve\Steam", "SteamPath"),
                               (winreg.HKEY_LOCAL_MACHINE, r"SOFTWARE\WOW6432Node\Valve\Steam", "InstallPath")):
        try:
            with winreg.OpenKey(hive, subkey) as key:
                steam.append(Path(winreg.QueryValueEx(key, field)[0]))
        except OSError:
            pass
    libraries = list(steam)
    for root in steam:
        vdf = root / "steamapps/libraryfolders.vdf"
        if vdf.is_file():
            for item in re.findall(r'"path"\s+"((?:\\.|[^"\\])*)"', vdf.read_text(encoding="utf-8-sig")):
                libraries.append(Path(item.replace("\\\\", "\\")))
    for root in libraries:
        game = installed_in(root / "steamapps")
        if game:
            return game
    return choose_folder("Select the TerraTech Legion folder in your Steam library")


@contextmanager
def mutex(name):
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.CreateMutexW.argtypes = (wintypes.LPVOID, wintypes.BOOL, wintypes.LPCWSTR)
    kernel.CreateMutexW.restype = wintypes.HANDLE
    kernel.CloseHandle.argtypes = (wintypes.HANDLE,)
    ctypes.set_last_error(0)
    handle = kernel.CreateMutexW(None, False, "Local\\TerraTechLegionPhoto-" + name)
    if not handle:
        raise ctypes.WinError(ctypes.get_last_error())
    exists = ctypes.get_last_error() == 183
    try:
        if exists:
            raise ValueError("Another photo camera operation is already running")
        yield
    finally:
        kernel.CloseHandle(handle)


def game_processes():
    # Tool Help lists executable names without launching external commands or inspecting game memory.
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    class ProcessEntry(ctypes.Structure):
        _fields_ = [("dwSize", wintypes.DWORD), ("cntUsage", wintypes.DWORD),
                    ("th32ProcessID", wintypes.DWORD), ("th32DefaultHeapID", ctypes.c_size_t),
                    ("th32ModuleID", wintypes.DWORD), ("cntThreads", wintypes.DWORD),
                    ("th32ParentProcessID", wintypes.DWORD), ("pcPriClassBase", wintypes.LONG),
                    ("dwFlags", wintypes.DWORD), ("szExeFile", wintypes.WCHAR * 260)]
    kernel.CreateToolhelp32Snapshot.argtypes = (wintypes.DWORD, wintypes.DWORD)
    kernel.CreateToolhelp32Snapshot.restype = wintypes.HANDLE
    kernel.CloseHandle.argtypes = (wintypes.HANDLE,)
    for func in (kernel.Process32FirstW, kernel.Process32NextW):
        func.argtypes = (wintypes.HANDLE, ctypes.POINTER(ProcessEntry))
        func.restype = wintypes.BOOL
    snapshot = kernel.CreateToolhelp32Snapshot(2, 0)
    if snapshot == ctypes.c_void_p(-1).value:
        raise ctypes.WinError(ctypes.get_last_error())
    result = []
    entry = ProcessEntry()
    entry.dwSize = ctypes.sizeof(entry)
    try:
        ok = kernel.Process32FirstW(snapshot, ctypes.byref(entry))
        while ok:
            if entry.szExeFile.casefold() == GAME_EXE.casefold():
                result.append(entry.th32ProcessID)
            ok = kernel.Process32NextW(snapshot, ctypes.byref(entry))
    finally:
        kernel.CloseHandle(snapshot)
    return result


def launch():
    folders.prepare_default_directory()
    saved = folders.settings_file().parent
    ready = saved / "TerraTechLegionPhotoDirectoryPicker.ready"
    request = saved / "TerraTechLegionPhotoDirectoryPicker.request"
    with mutex("folder-picker"):
        processes = game_processes()
        if not processes:
            os.startfile(f"steam://rungameid/{APP_ID}")
            print("Waiting for TerraTech Legion to start through Steam...", flush=True)
            deadline = time.monotonic() + 180
            while not processes and time.monotonic() < deadline:
                time.sleep(.5)
                processes = game_processes()
        if not processes:
            raise ValueError("TerraTech Legion did not start. Open it in Steam and run Launch-Camera.cmd again.")
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel.OpenProcess.argtypes = (wintypes.DWORD, wintypes.BOOL, wintypes.DWORD)
        kernel.OpenProcess.restype = wintypes.HANDLE
        kernel.WaitForSingleObject.argtypes = (wintypes.HANDLE, wintypes.DWORD)
        kernel.WaitForSingleObject.restype = wintypes.DWORD
        kernel.CloseHandle.argtypes = (wintypes.HANDLE,)
        game = kernel.OpenProcess(0x00100000, False, processes[0])  # SYNCHRONIZE
        if not game:
            raise ctypes.WinError(ctypes.get_last_error())
        picker = None
        try:
            request.unlink(missing_ok=True)
            next_heartbeat = 0
            print("F2 folder picker ready. This window closes when the game exits.", flush=True)
            while kernel.WaitForSingleObject(game, 250) == 258:  # WAIT_TIMEOUT
                if time.monotonic() >= next_heartbeat:
                    folders._atomic_write(ready, f"{int(time.time())}\n".encode("ascii"))
                    next_heartbeat = time.monotonic() + 2
                try:
                    request.unlink()
                except FileNotFoundError:
                    continue
                if picker is None or picker.poll() is not None:
                    picker = subprocess.Popen([sys.executable, str(HERE / "photo_camera.py"), "choose"])
        finally:
            kernel.CloseHandle(game)
            ready.unlink(missing_ok=True)
            if picker is not None and picker.poll() is None:
                picker.terminate()
                picker.wait()


def write_package(target):
    release = HERE.parent
    scripts = release / "mod/Scripts"
    if not (scripts / "main.lua").is_file():
        raise ValueError("Run Install-Windows.cmd from the extracted release folder")
    shutil.copytree(scripts, target / "Scripts")
    shutil.copy2(release / "LICENSE", target / "LICENSE")
    (target / "enabled.txt").touch()
    (target / MOD_MARKER).write_bytes(MOD.encode("ascii"))
    helpers = target / "windows"
    helpers.mkdir()
    for name in ("photo_camera.py", "Run-Python.cmd", "Launch-Camera.cmd"):
        shutil.copy2(HERE / name, helpers / name)
    for name in EXPORTERS:
        shutil.copy2(release / "tools" / name, target / name)


def backup(target, parent):
    backups = parent / (MOD + "-backups")
    backups.mkdir(exist_ok=True)
    dest = backups / uuid.uuid4().hex
    target.rename(dest)
    return dest


def managed(target):
    if reparse(target) or target.is_symlink():
        raise ValueError(f"Existing reparse point at {target}. Move it aside before installation.")
    if not target.exists():
        return False
    marker = target / MOD_MARKER
    if reparse(marker) or not marker.is_file() or marker.read_bytes() != MOD.encode("ascii"):
        raise ValueError(f"An unmanaged camera already exists at {target}. Move it aside first.")
    return True


def publish(mods):
    target = mods / MOD
    had_previous = managed(target)
    with tempfile.TemporaryDirectory(dir=mods.parent, prefix=".photo-camera-") as temp:
        stage = Path(temp) / MOD
        write_package(stage)
        if had_previous:
            files = [p.relative_to(stage) for p in stage.rglob("*") if p.is_file()]
            current_scripts = {p.name for p in (target / "Scripts").glob("*.lua")}
            packaged_scripts = {p.name for p in (stage / "Scripts").glob("*.lua")}
            if (current_scripts == packaged_scripts
                    and all((target / p).is_file() and digest(target / p) == digest(stage / p) for p in files)):
                return target
        old = backup(target, mods.parent) if had_previous else None
        try:
            stage.rename(target)
        except OSError:
            if old is not None:
                old.rename(target)
            raise
    return target


def install_new_loader(bin_dir, local_zip):
    for name in ("ue4ss", "UE4SS.dll", "dwmapi.dll", "Mods", "UE4SS-settings.ini", "override.txt"):
        path = bin_dir / name
        if path.exists() or reparse(path):
            raise ValueError(f"Existing loader file at {path}. Specify a working --ue4ss-root or review this installation.")
    with tempfile.TemporaryDirectory(dir=bin_dir, prefix=".photo-camera-") as temp:
        stage = Path(temp)
        if local_zip is None:
            local_zip = stage / "UE4SS.zip"
            print(f"Downloading pinned UE4SS v4.0.0 from {ARCHIVE_URL}", flush=True)
            with urlopen(ARCHIVE_URL, timeout=90) as response, local_zip.open("xb") as output:
                shutil.copyfileobj(response, output)
        if digest(local_zip) != SHA256:
            raise ValueError(f"UE4SS ZIP checksum mismatch. The expected SHA-256 is {SHA256}")
        with zipfile.ZipFile(local_zip) as archive:
            for name in LOADER_FILES:
                dest = stage / name
                dest.parent.mkdir(parents=True, exist_ok=True)
                with archive.open(name) as source, dest.open("xb") as out:
                    shutil.copyfileobj(source, out)
        tree = stage / "ue4ss"
        (tree / "Mods/mods.txt").write_bytes(b"")
        (tree / LOADER_MARKER).write_bytes(SHA256.encode("ascii"))
        write_package(tree / "Mods" / MOD)
        (stage / "dwmapi.dll").rename(tree / PENDING_PROXY)
        tree.rename(bin_dir / "ue4ss")
        try:
            finish_loader_activation(bin_dir / "ue4ss", SHA256, PROXY_SHA256)
        except (OSError, ValueError):
            (bin_dir / "ue4ss").rename(tree)
            raise
    return bin_dir / "ue4ss/Mods" / MOD


def loader_root(bin_dir, explicit):
    if explicit is not None:
        roots = [explicit.expanduser().resolve()]
    elif (bin_dir / "override.txt").exists():
        raise ValueError("Pass --ue4ss-root for the custom loader specified by override.txt")
    else:
        roots = [bin_dir / "ue4ss", bin_dir]
    for root in roots:
        if (root / "UE4SS.dll").is_file() and (root / "Mods").is_dir():
            return root
    if explicit is not None:
        raise ValueError(f"No UE4SS.dll and Mods directory in {roots[0]}")
    return None


def remove_loader(bin_dir, root):
    proxy = bin_dir / "dwmapi.dll"
    marker = root / LOADER_MARKER
    proxy_present = os.path.lexists(proxy)
    if (root != bin_dir / "ue4ss" or reparse(root) or reparse(marker) or not marker.is_file()
            or marker.read_bytes() != SHA256.encode("ascii") or (proxy_present and not original_file(proxy, PROXY_SHA256))):
        raise ValueError("This loader cannot be matched to the camera installer. Remove just the camera instead.")
    check_loader_components(root)
    managed(root / "Mods" / MOD)
    other = {p.name for p in (root / "Mods").iterdir()} - {MOD, "shared", "mods.txt"}
    if other:
        raise ValueError("Other mods use this loader. Remove the camera without --remove-loader.")
    dest = bin_dir / (MOD + "-backups") / uuid.uuid4().hex
    dest.mkdir(parents=True)
    if proxy_present:
        proxy.rename(dest / proxy.name)
    try:
        root.rename(dest / root.name)
    except OSError:
        if proxy_present:
            (dest / proxy.name).rename(proxy)
        raise
    print(f"Camera and loader moved to {dest}")


def manage(args):
    game = args.game or find_game()
    if game is None:
        return
    bin_dir = game.expanduser().resolve() / BIN
    if not (bin_dir / GAME_EXE).is_file():
        raise ValueError(f"Cannot find {GAME_EXE} in {bin_dir}")
    if game_processes():
        raise ValueError("Close TerraTech Legion before installing or removing the camera")
    lock_name = hashlib.sha256(str(bin_dir).casefold().encode("utf-8")).hexdigest()
    with mutex(lock_name):
        root = loader_root(bin_dir, args.ue4ss_root)
        if args.command == "install":
            if root == bin_dir / "ue4ss":
                finish_loader_activation(root, SHA256, PROXY_SHA256)
            dest = publish(root / "Mods") if root else install_new_loader(bin_dir, args.loader_zip)
            try:
                folders.prepare_default_directory()
            except OSError as error:
                print(f"Camera installed. Could not create its default screenshot folder: {error}", file=sys.stderr)
            print(f"Installed {MOD} in {dest}")
            print(f"For the in-game F2 folder picker, launch using {dest / 'windows' / 'Launch-Camera.cmd'}")
        elif root and args.remove_loader:
            remove_loader(bin_dir, root)
        elif root and managed(root / "Mods" / MOD):
            print(f"Removed camera. Previous files: {backup(root / 'Mods' / MOD, root)}")
        else:
            print("Camera already absent.")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("install", "remove"):
        action = sub.add_parser(name)
        action.add_argument("--game", type=Path, help="Steam TerraTech Legion installation directory")
        action.add_argument("--ue4ss-root", type=Path, help="Existing custom loader directory containing UE4SS.dll")
        if name == "install":
            action.add_argument("--loader-zip", type=Path, help="Use a local official UE4SS v4.0.0 ZIP for a clean install")
        else:
            action.add_argument("--remove-loader", action="store_true", help="Also remove this installer's unchanged loader")
    sub.add_parser("launch", help="Open the game through Steam and listen for the F2 folder picker")
    choose_cmd = sub.add_parser("choose", help="Select the screenshot destination in Windows Explorer")
    options = choose_cmd.add_mutually_exclusive_group()
    options.add_argument("--set", type=Path, help="Choose an existing local directory")
    options.add_argument("--show", action="store_true")
    options.add_argument("--reset", action="store_true")
    args = parser.parse_args(argv)
    if sys.platform != "win32":
        parser.exit(1, "This launcher requires Windows. On Linux use tools/install.py.\n")
    if sys.version_info < (3, 11):
        parser.exit(1, "Install Python 3.11 or newer for Windows, with Tcl/Tk.\n")
    try:
        if args.command == "choose":
            choose(args)
        elif args.command == "launch":
            launch()
        else:
            manage(args)
    except (OSError, ValueError, ImportError, zipfile.BadZipFile, KeyError) as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()
