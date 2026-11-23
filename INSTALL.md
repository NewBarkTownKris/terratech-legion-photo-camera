# Install TerraTech Legion Photo Mode

**Tested only on Linux with Proton Experimental.** The Windows package is available for native Windows users and awaits testing on that platform.

The target is the Windows Steam edition of TerraTech Legion, app 3596700. Close the game and extract the package for your platform. The installer uses the Steam library manifest to locate the game. New installations use the SHA-256-verified UE4SS v4.0.0 loader. Existing UE4SS installations can host the camera in their Mods folder.

## Linux and Steam Deck with Proton

1. In the extracted directory, run `sh Install-Linux.sh`. For an offline installation, run `sh Install-Linux.sh install --loader-zip "/path/to/UE4SS_v4.0.0.zip"`. You can get the archive from the [official UE4SS release](https://github.com/UE4SS-RE/RE-UE4SS/releases/tag/v4.0.0).
2. For the standard loader, open the game's **Properties → General → Launch Options**. To enable the camera and its F2 folder picker, use the full launch option printed by the installer. This needs Python 3 and either Zenity or KDialog for the folder dialog. If you only want the camera, the launch option for an empty field is `WINEDLLOVERRIDES="dwmapi=n,b" %command%`.
3. If you already have launch options, keep your existing wrapper and arguments. Add `dwmapi=n,b` to any existing `WINEDLLOVERRIDES` list, separating entries with a semicolon. For F2 support, insert the installer's `python3 '…/launch_camera.py'` immediately before the existing `%command%`. If you use a custom loader or proxy, keep its working DLL override.
4. Start TerraTech Legion through Steam and load into gameplay. Press **F8** for photo mode, **F9** to save a PNG, and **F8** to resume.

Use `python3 tools/photo_directory.py --show` to print the active output folder. Use `--set "/path/to/folder"` to select a destination from the terminal or `--reset` to restore the default. The default maps to `%LOCALAPPDATA%/TerraTech_Legion/Saved/Screenshots/Windows` in the game's Proton prefix.

## Windows

1. Install Python 3.11 or newer with Tcl/Tk. Double-click **Install-Windows.cmd**. To use a downloaded loader archive, run `Install-Windows.cmd --loader-zip "C:\Downloads\UE4SS_v4.0.0.zip"` in Command Prompt.
2. Start the game through Steam, or use **windows\Launch-Camera.cmd** in the extracted package for the in-game F2 folder picker. Enter and leave photo mode with **F8** and take a PNG with **F9**.
3. Photos default to `%LOCALAPPDATA%\TerraTech_Legion\Saved\Screenshots\Windows`. From the extracted package, run `windows\Run-Python.cmd choose --show` to print the active destination, `choose --set "D:\Photos"` to select an existing local folder or `choose --reset` to restore the default.

## Advanced layout and removal

Pass `--game "path to TerraTech Legion"` for explicit discovery. The game directory contains `TerraTech_LegionEOS.exe`. If your UE4SS installation uses a custom directory, add `--ue4ss-root "path to loader"` pointing to the folder containing its `UE4SS.dll` and `Mods`. Run the installer again to update the managed mod.

On Linux, `python3 tools/install.py status` reports the detected loader and camera. Remove the camera with `sh Install-Linux.sh remove`. On Windows, run `windows\Run-Python.cmd remove` from the extracted package. Add `--remove-loader` to roll back a fresh loader this installer created. Removal moves the managed files into a backup and preserves your photos. Remove the camera's Python wrapper from Steam launch options when uninstalling, and remove its DLL override if you also remove the loader.
