"""Choose or locate the photo folder used by the TerraTech Legion camera and exporter."""

import argparse
import hashlib
import os
from pathlib import Path, PureWindowsPath
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time

from legion_target import APP_ID, SAVED, installed_in


def steam_libraries():
    """Return Steam's steamapps directories, including external Linux libraries."""
    home = Path.home()
    data_home = Path(os.environ.get("XDG_DATA_HOME") or home / ".local/share")
    roots = [p for p in Path(__file__).resolve().parents if p.name == "steamapps"]
    steam_root = os.environ.get("STEAM_COMPAT_CLIENT_INSTALL_PATH")
    if steam_root:
        roots.append(Path(steam_root) / "steamapps")
    roots.extend(Path(path) / "steamapps" for path in
                 os.environ.get("STEAM_COMPAT_LIBRARY_PATHS", "").split(os.pathsep) if path)
    roots.extend(p / "steamapps" for p in (
        data_home / "Steam", home / ".steam/steam",
        home / ".var/app/com.valvesoftware.Steam/data/Steam",
    ))
    paths = []
    for steamapps in roots:
        if steamapps in paths:
            continue
        paths.append(steamapps)
        try:
            vdf = (steamapps / "libraryfolders.vdf").read_text(encoding="utf-8-sig")
        except (OSError, UnicodeError):
            continue
        for match in re.finditer(r'^\s*"path"\s*"((?:\\.|[^"\\])*)"', vdf, re.MULTILINE):
            library = Path(re.sub(r'\\([\\"])', r'\1', match.group(1)))
            if library.is_absolute():
                paths.append(library / "steamapps")
    return list(dict.fromkeys(path.resolve() for path in paths))


def _saved_folder():
    if sys.platform == "win32":
        local = Path(os.environ.get("LOCALAPPDATA") or Path.home() / "AppData/Local")
        return local / SAVED
    compat = os.environ.get("STEAM_COMPAT_DATA_PATH")
    if compat and (Path(compat).name == APP_ID or os.environ.get("SteamAppId") == APP_ID):
        prefix = Path(compat) / "pfx"
    else:
        libraries = steam_libraries()
        # A moved game may leave an older prefix in its previous Steam library.
        libraries.sort(key=lambda p: installed_in(p) is None)
        prefixes = [p / "compatdata" / APP_ID / "pfx" for p in libraries]
        prefix = next((p for p in prefixes if p.is_dir()), prefixes[0])
    return prefix / "drive_c/users/steamuser/AppData/Local" / SAVED


DEFAULT_SHOTS = _saved_folder() / "Screenshots/Windows"


def prepare_default_directory(directory=None):
    """Prepare the shared destination before a Lua shutter writes its staging file."""
    directory = DEFAULT_SHOTS if directory is None else directory
    directory.mkdir(parents=True, exist_ok=True)
    return directory


def settings_file():
    return DEFAULT_SHOTS.parent.parent / "TerraTechLegionPhotoDirectory.txt"


def _validate(path):
    value = str(path)
    if not path.is_absolute():
        raise ValueError("The saved photo folder must be an absolute path")
    if any(ch in value for ch in "\r\n\0"):
        raise ValueError("The folder path cannot contain a newline or NUL")
    try:
        value.encode("utf-8")
    except UnicodeEncodeError as exc:
        raise ValueError("The folder path must be valid UTF-8") from exc
    return path


def _key(path):
    return hashlib.sha256(str(path).encode("utf-8")).hexdigest()


def _atomic_write(path, data, *, sync=False):
    temp = tempfile.NamedTemporaryFile(dir=path.parent, prefix=".terratech-legion-camera-dir-", delete=False)
    staged = Path(temp.name)
    try:
        with temp:
            temp.write(data)
            temp.flush()
            if sync:
                os.fsync(temp.fileno())
        for attempt in range(5):
            try:
                os.replace(staged, path)
                break
            except PermissionError as exc:
                # The game can briefly hold the previous setting open without
                # delete sharing while checking where to save the next shot.
                if getattr(exc, "winerror", None) not in (5, 32, 33) or attempt == 4:
                    raise
                time.sleep(0.02 * (attempt + 1))
    finally:
        staged.unlink(missing_ok=True)


def _alias_matches(alias, target):
    if sys.platform == "win32":
        # os.readlink supports junctions, including on an offline target drive.
        try:
            if alias.lstat().st_reparse_tag != stat.IO_REPARSE_TAG_MOUNT_POINT:
                return False
            linked = os.readlink(alias).removeprefix("\\\\?\\")
            return PureWindowsPath(linked) == PureWindowsPath(target)
        except OSError:
            return False
    return alias.is_symlink() and alias.readlink() == target


def _ensure_alias(alias, target):
    if sys.platform == "win32":
        import _winapi
        if not os.path.lexists(alias):
            # Create a complete junction before publishing it. A failed
            # FSCTL_SET_REPARSE_POINT can leave an ordinary directory behind.
            with tempfile.TemporaryDirectory(dir=alias.parent, prefix=".junction-") as tmp:
                junction = Path(tmp) / "folder"
                _winapi.CreateJunction(str(target), str(junction))
                try:
                    junction.rename(alias)  # Exclusive on Windows.
                except FileExistsError:
                    pass
    else:
        try:
            alias.symlink_to(target, target_is_directory=True)
        except FileExistsError:
            pass
    if not _alias_matches(alias, target):
        raise ValueError(f"The photo folder alias already belongs to another location: {alias}")


def selected_directory():
    """Return the configured path, including when a selected drive is offline."""
    try:
        value = settings_file().read_bytes().decode("utf-8")
    except FileNotFoundError:
        return DEFAULT_SHOTS
    lines = value.split("\n")
    if len(lines) != 3 or lines[2]:
        raise ValueError(f"Invalid photo directory setting in {settings_file()}. Use --set PATH or --reset")
    path = _validate(Path(lines[1]))
    if _key(path) != lines[0]:
        raise ValueError("The photo directory setting is incomplete. Use --set PATH or --reset")
    alias = settings_file().parent / "TerraTechLegionPhotoFolders" / lines[0]
    if not _alias_matches(alias, path):
        raise ValueError("The photo directory alias does not match the setting. Use --set PATH or --reset")
    return path


def set_directory(directory, *, create=False):
    target = _validate(Path(directory).expanduser().resolve())
    if sys.platform == "win32" and not re.fullmatch("[a-zA-Z]:", target.drive):
        raise ValueError("Choose a photo folder on a local drive for the Windows camera")
    if create:
        target.mkdir(parents=True, exist_ok=True)
    if not target.is_dir():
        raise ValueError(f"The selected folder is unavailable: {target}")
    # Actually creating a file catches read-only mounts and ACL limitations.
    with tempfile.NamedTemporaryFile(dir=target, prefix=".terratech-legion-camera-write-"):
        pass
    config = settings_file()
    # An ASCII alias avoids quoting and Win32 code-page issues. Keep previous
    # aliases stable while a PNG or EXR write may still be in flight.
    key = _key(target)
    alias = config.parent / "TerraTechLegionPhotoFolders" / key
    alias.parent.mkdir(parents=True, exist_ok=True)
    _ensure_alias(alias, target)
    _atomic_write(config, f"{key}\n{target}\n".encode("utf-8"), sync=True)
    return target


def _dialog_command(start):
    if not (os.environ.get("WAYLAND_DISPLAY") or os.environ.get("DISPLAY")):
        raise ValueError("Open the folder picker in a desktop session, or use --set PATH")
    kde = "KDE" in os.environ.get("XDG_CURRENT_DESKTOP", "").upper()
    dialogs = ("kdialog", "zenity") if kde else ("zenity", "kdialog")
    for name in dialogs:
        executable = shutil.which(name)
        if executable:
            break
    else:
        raise ValueError("The folder picker needs kdialog or zenity. You can also use --set PATH")
    title = "Choose a TerraTech Legion screenshot folder"
    if name == "kdialog":
        return [executable, "--title", title, "--getexistingdirectory", str(start)]
    return [executable, "--file-selection", "--directory", "--title", title,
            "--filename", str(start) + "/"]


def choose_directory(start):
    argv = _dialog_command(start)
    result = subprocess.run(argv, capture_output=True)
    if result.returncode == 1:
        return None
    if result.returncode != 0:
        raise OSError(result.stderr.decode(errors="replace").strip() or f"{argv[0]} could not open the picker")
    value = os.fsdecode(result.stdout).removesuffix("\n")
    return Path(value) if value else None


def _process_start(pid):
    # Linux /proc stat fields 3 and 22 are state and start time. Start time
    # survives exec, and distinguishes the original game command from a reused PID.
    try:
        stat = Path(f"/proc/{pid}/stat").read_bytes().rsplit(b") ", 1)[1].split()
    except (FileNotFoundError, ProcessLookupError):
        return None
    return None if stat[0] in (b"Z", b"X") else stat[19]


def _close_picker(picker):
    if picker is None or picker.poll() is not None:
        return
    # Close the Python picker and its kdialog/zenity child together on game exit.
    try:
        os.killpg(picker.pid, signal.SIGTERM)
        picker.wait(timeout=2)
    except ProcessLookupError:
        pass
    except subprocess.TimeoutExpired:
        os.killpg(picker.pid, signal.SIGKILL)
        picker.wait()


def watch_requests(parent_pid=None):
    # Keep the folder discovery API importable on other platforms for offline exports.
    if not sys.platform.startswith("linux"):
        raise ValueError("The in-game folder picker listener runs on the Linux desktop")
    import fcntl

    started = _process_start(parent_pid) if parent_pid is not None else None
    if parent_pid is not None and started is None:
        return
    saved = settings_file().parent
    # On a fresh Proton launch, wait for Wine to create the user profile.
    # Precreating drive_c through mkdir could interfere with prefix setup.
    local_appdata = saved.parent.parent
    while not local_appdata.is_dir():
        if parent_pid is None:
            raise ValueError("Start TerraTech Legion through its Steam launch option to initialize the Proton profile")
        if _process_start(parent_pid) != started:
            return
        time.sleep(.25)
    prepare_default_directory()
    directory_fd = os.open(saved, os.O_DIRECTORY | os.O_RDONLY)
    try:
        try:
            fcntl.flock(directory_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print("TerraTech Legion photo folder picker is already listening", file=sys.stderr)
            return
        request = saved / "TerraTechLegionPhotoDirectoryPicker.request"
        ready = saved / "TerraTechLegionPhotoDirectoryPicker.ready"
        request.unlink(missing_ok=True)
        ready.unlink(missing_ok=True)
        picker = None
        next_heartbeat = 0.0
        try:
            try:
                _dialog_command(Path.home())
                can_open = True
            except ValueError as exc:
                print(exc, file=sys.stderr, flush=True)
                can_open = False
            while parent_pid is None or _process_start(parent_pid) == started:
                now = time.monotonic()
                if can_open and now >= next_heartbeat:
                    _atomic_write(ready, f"{int(time.time())}\n".encode("ascii"))
                    next_heartbeat = now + 2
                try:
                    request.unlink()
                except FileNotFoundError:
                    pass
                else:
                    if picker is None or picker.poll() is not None:
                        # No text supplied by the game participates in the command.
                        # Repeated presses while this picker is open are coalesced.
                        picker = subprocess.Popen([sys.executable, str(Path(__file__).resolve())],
                                                  stdin=subprocess.DEVNULL, start_new_session=True)
                if picker is not None and picker.poll() is not None:
                    picker = None
                time.sleep(0.25)
        finally:
            ready.unlink(missing_ok=True)
            _close_picker(picker)
    finally:
        os.close(directory_fd)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    options = parser.add_mutually_exclusive_group()
    options.add_argument("--set", metavar="PATH", type=Path,
                         help="Select a photo folder, creating it if needed")
    options.add_argument("--show", action="store_true", help="Print the active screenshot folder")
    options.add_argument("--reset", action="store_true", help="Use the game's standard screenshot folder")
    options.add_argument("--watch", action="store_true", help="Listen for in-game folder picker requests")
    parser.add_argument("--parent-pid", type=int, metavar="PID",
                        help="With --watch, stop when this Linux process exits")
    args = parser.parse_args()
    if args.parent_pid is not None and (not args.watch or args.parent_pid < 1):
        parser.error("--parent-pid needs --watch and a positive Linux PID")
    try:
        if args.watch:
            def stop_watching(signum, frame):
                raise KeyboardInterrupt
            signal.signal(signal.SIGTERM, stop_watching)
            try:
                watch_requests(args.parent_pid)
            except KeyboardInterrupt:
                pass
        elif args.show:
            print(selected_directory())
        elif args.reset:
            settings_file().unlink(missing_ok=True)
            print(f"Using game screenshot folder: {DEFAULT_SHOTS}")
        elif args.set is not None:
            print(f"Screenshot folder: {set_directory(args.set, create=True)}")
        elif sys.platform == "win32":
            here = Path(__file__).resolve().parent
            # Windows installs and the source tree use different helper layouts.
            helper = here / "windows/photo_camera.py"
            if not helper.is_file():
                helper = here.parent / "windows/photo_camera.py"
            if not helper.is_file():
                raise FileNotFoundError("Missing Windows photo folder picker. Reinstall the camera package.")
            sys.exit(subprocess.call([sys.executable, str(helper), "choose"]))
        else:
            try:
                start = selected_directory()
            except ValueError:
                # The picker can repair a malformed setting or a missing alias.
                start = DEFAULT_SHOTS
            if start == DEFAULT_SHOTS or not start.is_dir():
                pictures = Path.home() / "Pictures"
                start = pictures if pictures.is_dir() else Path.home()
            selection = choose_directory(start)
            if selection is not None:
                print(f"Screenshot folder: {set_directory(selection)}")
    except (OSError, ValueError, RuntimeError) as exc:
        parser.exit(1, f"{exc}\n")


if __name__ == "__main__":
    main()
