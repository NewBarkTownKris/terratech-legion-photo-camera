import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import zipfile


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from package_release import build_release
from legion_target import APP_ID, BIN, GAME_EXE, MOD, ZIP_SHA256, installed_in


class ReleaseTests(unittest.TestCase):
    def test_discovery_requires_the_retail_manifest_and_shipping_executable(self):
        with tempfile.TemporaryDirectory() as directory:
            library = Path(directory) / "steamapps"
            game = library / "common/Custom TerraTech Legion Folder"
            binary = game / BIN / GAME_EXE
            binary.parent.mkdir(parents=True)
            binary.touch()
            (library / "appmanifest_1.acf").write_text('"installdir" "Custom TerraTech Legion Folder"\n')
            self.assertIsNone(installed_in(library))
            manifest = library / f"appmanifest_{APP_ID}.acf"
            manifest.write_text('"installdir" "Custom TerraTech Legion Folder"\n')
            self.assertEqual(installed_in(library), game)
            binary.unlink()
            self.assertIsNone(installed_in(library))

    def test_rebuilds_match_and_platforms_contain_their_installers(self):
        with tempfile.TemporaryDirectory() as directory:
            batches = [build_release(ROOT, Path(directory) / run, "0.1.0") for run in ("a", "b")]
            self.assertEqual([p.read_bytes() for p in batches[0]], [p.read_bytes() for p in batches[1]])
            windows, linux, checksum = batches[0]
            self.assertEqual(checksum.read_text().splitlines(), [
                f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}" for path in (windows, linux)
            ])
            for path, entry in ((windows, "Install-Windows.cmd"), (linux, "Install-Linux.sh")):
                with zipfile.ZipFile(path) as bundle:
                    self.assertIsNone(bundle.testzip())
                    names = [x.removeprefix("TerraTechLegionPhoto-0.1.0/") for x in bundle.namelist()]
                    self.assertIn(entry, names)
                    self.assertIn("mod/Scripts/main.lua", names)
                    self.assertIn("requirements.txt", names)
                    self.assertIn("INSTALL.md", names)
                    self.assertIn("IMPLEMENTATION_PLAN.md", names)
                    self.assertIn("THIRD_PARTY_LICENSES/Denshattack-Photo-Camera.txt", names)
                    self.assertIn("Develop-Photos.sh" if path == linux else "Develop-Photos.cmd", names)
                    self.assertIn("tools/develop_photos.py", names)
                    self.assertEqual(len(names), len(set(names)))
                    self.assertFalse(any(name.endswith((".dll", ".exe", ".exr", ".png", ".zip"))
                                         or "__pycache__" in name for name in names))
                    if path == linux:
                        self.assertFalse(any(name.startswith("windows/") for name in names))
                        mode = bundle.getinfo(f"TerraTechLegionPhoto-0.1.0/{entry}").external_attr >> 16
                        self.assertTrue(mode & 0o111)
                    else:
                        self.assertIn("windows/photo_camera.py", names)
                        self.assertNotIn("tools/install.py", names)

    @unittest.skipUnless(sys.platform.startswith("linux"), "Linux/Proton installer requires Linux")
    def test_packaged_linux_install_repeat_and_remove(self):
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory)
            _, archive, _ = build_release(ROOT, temp / "release", "0.1.0")
            with zipfile.ZipFile(archive) as bundle:
                bundle.extractall(temp / "extracted")
            checkout = temp / "extracted/TerraTechLegionPhoto-0.1.0"
            steamapps = temp / "Steam Library/steamapps"
            game = steamapps / "common/TerraTech_Legion"
            binaries = game / "TerraTech_Legion/Binaries/Win64"
            binaries.mkdir(parents=True)
            (binaries / "TerraTech_LegionEOS-Win64-Shipping.exe").touch()
            def run(action, *args, expect=0):
                env = dict(os.environ)
                env.pop("STEAM_COMPAT_DATA_PATH", None)
                result = subprocess.run(["sh", str(checkout / "Install-Linux.sh"), action,
                                         "--game", str(game), *args], cwd=temp, env=env,
                                        capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, expect, result.stdout + result.stderr)
                return result.stdout + result.stderr

            bad = temp / "incorrect-loader.zip"
            bad.write_bytes(b"wrong loader")
            self.assertIn("SHA-256", run("install", "--loader-zip", str(bad), expect=1))
            self.assertFalse((binaries / "ue4ss").exists())
            mods = binaries / "ue4ss/Mods"
            mods.mkdir(parents=True)
            (mods.parent / "UE4SS.dll").touch()
            neighbor = mods / "mods.txt"
            neighbor.write_text("OtherMod : 1\n")
            self.assertIn("Published", run("install", "--download-loader"))
            camera = mods / "TerraTechLegionPhoto"
            self.assertTrue((camera / "Scripts/main.lua").is_file())
            self.assertTrue((camera / "enabled.txt").is_file())
            self.assertTrue((camera / "launch_camera.py").is_file())
            compat = steamapps / "compatdata" / APP_ID
            self.assertFalse(compat.exists())  # Only Proton creates and initializes a prefix.
            local = compat / "pfx/drive_c/users/steamuser/AppData/Local"
            local.mkdir(parents=True)
            self.assertIn("Already installed", run("install"))
            self.assertTrue((local / "TerraTech_Legion/Saved/Screenshots/Windows").is_dir())
            self.assertIn("Camera present: True", run("status"))
            run("remove")
            self.assertFalse(camera.exists())
            self.assertEqual(neighbor.read_text(), "OtherMod : 1\n")
            self.assertTrue((mods.parent / "UE4SS.dll").is_file())

    @unittest.skipUnless(sys.platform.startswith("linux") and os.environ.get("UE4SS_TEST_ZIP"),
                         "requires a local copy of the official UE4SS fixture")
    def test_clean_proton_install_and_loader_rollback(self):
        loader = Path(os.environ["UE4SS_TEST_ZIP"])
        self.assertEqual(hashlib.sha256(loader.read_bytes()).hexdigest(), ZIP_SHA256)
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory)
            game = temp / "TerraTech_Legion"
            binaries = game / BIN
            binaries.mkdir(parents=True)
            (binaries / GAME_EXE).touch()
            installer = [sys.executable, str(ROOT / "tools/install.py")]
            def run(action, *extra):
                env = dict(os.environ, STEAM_COMPAT_DATA_PATH=str(temp / "compatdata" / APP_ID))
                return subprocess.run([*installer, action, "--game", str(game), *extra],
                                      cwd=temp, env=env, check=True, capture_output=True, text=True)
            run("install", "--loader-zip", str(loader))
            installed = binaries / "ue4ss/Mods" / MOD
            self.assertTrue((installed / "enabled.txt").is_file())
            with zipfile.ZipFile(loader) as bundle:
                self.assertEqual((binaries / "ue4ss/UE4SS-settings.ini").read_bytes(),
                                 bundle.read("ue4ss/UE4SS-settings.ini"))
            self.assertIn("Already installed", run("install").stdout)
            # The installed helper imports the shared target module out of the installed mod.
            compat = temp / "compatdata" / APP_ID
            result = subprocess.run([sys.executable, str(installed / "photo_directory.py"), "--show"],
                                    env={**os.environ, "STEAM_COMPAT_DATA_PATH": str(compat)},
                                    cwd=temp, check=True, capture_output=True, text=True)
            self.assertTrue(Path(result.stdout.strip()).is_relative_to(compat))
            for path in (binaries / "ue4ss/UE4SS.dll", installed / ".terratech-legion-photo-camera-install"):
                original = path.read_bytes()
                path.write_bytes(b"foreign replacement")
                with self.subTest(path=path.name), self.assertRaises(subprocess.CalledProcessError):
                    run("remove", "--remove-loader")
                self.assertEqual(path.read_bytes(), b"foreign replacement")
                self.assertTrue((binaries / "dwmapi.dll").exists())
                path.write_bytes(original)
            run("remove", "--remove-loader")
            self.assertFalse((binaries / "dwmapi.dll").exists())
            self.assertFalse((binaries / "ue4ss").exists())
            self.assertTrue((binaries / GAME_EXE).exists())

    @unittest.skipUnless(sys.platform.startswith("linux") and os.environ.get("UE4SS_TEST_ZIP"),
                         "requires a local copy of the official UE4SS fixture")
    def test_proton_retries_interrupted_install_from_two_processes(self):
        import install
        from legion_target import PENDING_PROXY
        with tempfile.TemporaryDirectory() as directory:
            game = Path(directory) / "TerraTech_Legion"
            binary = game / BIN / GAME_EXE
            binary.parent.mkdir(parents=True)
            binary.touch()
            tree = binary.parent / "ue4ss"
            archive = Path(os.environ["UE4SS_TEST_ZIP"])
            with mock.patch.object(install, "finish_loader_activation", side_effect=KeyboardInterrupt), \
                    self.assertRaises(KeyboardInterrupt):
                install.install_with_loader(game, archive)
            self.assertTrue((tree / PENDING_PROXY).is_file())
            cmd = [sys.executable, str(ROOT / "tools/install.py"), "install", "--game", str(game)]
            env = dict(os.environ, STEAM_COMPAT_DATA_PATH=str(Path(directory) / "compatdata" / APP_ID))
            with subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env) as first, \
                    subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env) as second:
                for process in (first, second):
                    output, _ = process.communicate(timeout=10)
                    self.assertEqual(process.returncode, 0, output)
            self.assertTrue((binary.parent / "dwmapi.dll").is_file())
            self.assertFalse((tree / PENDING_PROXY).exists())
            self.assertTrue((tree / "Mods" / MOD / "enabled.txt").is_file())
            self.assertFalse((tree / f"{MOD}-backups").exists())


if __name__ == "__main__":
    unittest.main()
