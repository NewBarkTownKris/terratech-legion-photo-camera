# TerraTech Legion Photo Mode

**Pre-release for the Steam edition of TerraTech Legion, build 24221609.** The camera mod lets you compose a shot around your Tech while the action is frozen. It includes a detached camera, a viewfinder, photographic exposure controls, and separate PNG and HDR shutters. The implementation plan records which paths have been exercised in the game and which still have only offline coverage. [Live test results and remaining work](IMPLEMENTATION_PLAN.md)

**Tested only on Linux with Proton Experimental.** The native Windows package is untested. The dev.2 fix for 4K captures at 4× scale passed full-resolution offline tests on Linux. In-game verification of that fix is still pending. [Download the Windows or Linux/Proton package](https://github.com/NewBarkTownKris/terratech-legion-photo-camera/releases/tag/v0.1.0-dev.2)

Install the mod and its UE4SS loader, then start a run and press **F8** during gameplay. The camera starts at the gameplay view. Move with **WASD**, aim with the **mouse**, and press **F9** for a PNG. Press **F8** again to resume. **F1** shows the controls in the finder. [Windows and Linux/Proton installation](INSTALL.md)

## Framing a shot

| Control | Action |
| --- | --- |
| WASD · E / Q | Move at 8 m/s. Rise with E and descend with Q. Hold Ctrl for fine movement at 1.6 m/s or Shift for fast travel at 32 m/s. |
| Mouse or arrow keys | Aim the camera. |
| Z / X · **P** | Roll the camera. **P** levels the horizon. Leave F10 to the game. |
| [ / ] · F7 | Narrow or widen the field of view. F7 cycles 16, 24, 35, 50, 85, 135, 200 and 600 mm equivalent lenses. |
| F5 · F6 | Cycle viewport, 3:2, 4:3, 1:1, 16:9, 5:4, 21:9 and 65:24 framing. F6 rotates the crop. |
| H · G · R | Toggle the finder, toggle the thirds grid or cycle the reticle. |
| F4 | Open Studio. Up/down selects a row and left/right adjusts it. Close Studio to aim again. |

With a controller, the left stick moves, the right stick aims, and RB/LB raises or lowers the camera. Click the left stick for Studio and use the D-pad to adjust its rows. A/Cross fires PNG, Y/Triangle fires PNG + EXR, and a right-stick click focuses. Press and release View/Back by itself to resume. For controller entry, bind a Steam Input shortcut to F8.

## Focus, exposure and film

Point the reticle at a surface and press **N** to focus there. With the finder visible and Studio closed, middle-click also focuses and left-click fires PNG. A missed trace keeps the last focus distance.

| Control | Action |
| --- | --- |
| T | Toggle continuous center autofocus or lock the current focus plane. |
| J / K or mouse wheel | Move the focus plane nearer or farther. L switches between 20% and 1% steps. |
| B · U / I · Y | Toggle photographic depth of field, adjust aperture, or cycle 1×, 2×, 4× and 8× DOF strength. |
| Shift or Ctrl + wheel | Adjust aperture when the exposure mode allows it. |
| Alt + wheel · Ctrl+Alt + wheel | Adjust shutter speed or manual ISO. |
| C | Switch chromatic aberration between the game setting and Off. |

**Game** is the default exposure mode. To meter the framed scene, open Studio and choose Manual, Aperture Priority or Shutter Priority. The dials span f/1–f/16, 8 seconds–1/32000 second, and ISO 100–6400. Studio also offers exposure compensation, Auto ISO limits, eleven film looks and optional ISO grain. With Game exposure and grain enabled, the Grain ISO dial controls grain while the game sets brightness.

## Saving and developing photos

- **F9** saves the display-rendered PNG at the finder crop. **F3** saves the PNG and requests a separate scene-linear EXR at the same framing. The EXR is the grading master. Its separate render can differ in particles, bloom and other screen-space effects.
- For a **long exposure**, choose a photographic mode with a shutter of 1/15 second or slower and fire either shutter. Pan or move during the countdown to leave a trail across a frozen scene. F8 cancels the timed shot and resumes gameplay.
- In Studio, **Capture scale** selects 1× through 4× in each dimension. A 3840 × 2160 viewport produced a 7670 × 2832 panorama at 2×. A 1280 × 720 viewport produced a 5120 × 2880 image at 4×.
- **Multi-pass** appears for large instant prints, including 3× and 4× from a 4K viewport. The camera renders a sequence of smaller images, writes temporary files beside the shot, and assembles the PNG. At 4K/4×, allow about 1.5 GB of free space for a Game-mode PNG/EXR pair or 2.5 GB for a photographic pair. The finder shows progress. **F8** cancels and resumes driving. Once the PNG is saved, canceling during HDR development keeps it.
- **F2** opens the destination picker when the camera launcher is listening. The default is `%LOCALAPPDATA%\TerraTech_Legion\Saved\Screenshots\Windows` on Windows and the same directory inside Proton's prefix for app 3596700. Files use the prefix `TerraTechLegion_`. Run `python3 tools/photo_directory.py --show` to print the active folder.

To develop EXRs into 16-bit ARRI Wide Gamut 3/LogC3 EI 800 TIFF, 16-bit Fujifilm F-Gamut/F-Log TIFF or floating-point linear DNG, install the Python imaging dependencies into a virtual environment in the extracted package. On Linux, run the following commands.

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
./Develop-Photos.sh
```

On Windows, use `py -3 -m venv .venv`, then `.venv\Scripts\python -m pip install -r requirements.txt` and open **Develop-Photos.cmd**. Choose a folder and output formats in the developer. The command-line equivalent accepts a single EXR or a directory.

```sh
.venv/bin/python tools/export_photo.py "/path/to/photos" --format all
```

Developed files appear beside their EXRs. Running the command again fills in missing companions and keeps existing ones. The TIFF exporter records the whole-stop offset it uses to fit highlights. `--ev` sets the offset explicitly and `--integer-dng` produces 16-bit DNG for readers that require it.

## Development

The gameplay code is in `mod/Scripts/`. The Lua checks exercise the camera, exposure, input and shutter against fixtures. The Python suite covers installers, folder handling, packaging and EXR development. Run the checks and create a package from a source checkout with Lua 5.4 and the Python requirements installed.

```sh
for test in tests/*.lua; do lua5.4 "$test" || exit 1; done
python3 -m unittest discover -s tests
python3 tools/package_release.py --version 0.1.0-dev.2 --output dist/0.1.0-dev.2
```

Set `UE4SS_TEST_ZIP` to the local official v4.0.0 ZIP for the fresh-loader fixture tests. Packaging produces Windows and Linux/Proton ZIPs and a SHA-256 checksum manifest.

Adapted from the MIT-licensed Denshattack! Photo Camera by NewBarkTownKris. [License](LICENSE) · [Upstream notice](THIRD_PARTY_LICENSES/Denshattack-Photo-Camera.txt)
