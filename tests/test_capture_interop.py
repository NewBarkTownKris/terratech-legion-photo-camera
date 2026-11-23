import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import numpy as np
import OpenEXR
from PIL import ExifTags
from PIL.TiffImagePlugin import ImageFileDirectory_v2

from test_grade import read_tiff
from test_linear_dng import read_raw
from grade import MATRICES
from photo_directory import prepare_default_directory


ROOT = Path(__file__).resolve().parents[1]


def lua54():
    for name in ("lua5.4", "lua54", "lua"):
        executable = shutil.which(name)
        if executable:
            version = subprocess.run([executable, "-e", "io.write(_VERSION)"],
                                     capture_output=True, text=True, timeout=5)
            if version.returncode == 0 and version.stdout == "Lua 5.4":
                return executable
    return None


LUA = lua54()


class CaptureInteropTests(unittest.TestCase):
    @unittest.skipUnless(LUA, "Lua 5.4 is required to generate the EXR fixture")
    def test_banded_camera_master_develops_into_matching_tiffs_and_dng(self):
        # The two source bands have distinct colours and one HDR highlight.
        # The writer averages a two-sample accumulator and applies gain 4.
        expected = np.array([[[1, .5, .25], [2, 1, .5]],
                             [[.5, 1, 4], [.25, .5, 1]]], dtype=np.float32)
        with tempfile.TemporaryDirectory() as directory:
            # On Windows the exporter resolves LOCALAPPDATA directly. On
            # Proton the host sees the same folder through the Steam prefix.
            compat = Path(directory) / "3596700"
            profile = compat / "pfx/drive_c/users/steamuser/AppData/Local"
            profile.mkdir(parents=True)
            shots = profile / "TerraTech_Legion/Saved/Screenshots/Windows"
            self.assertFalse(shots.exists())
            prepare_default_directory(shots)
            env = {**os.environ, "STEAM_COMPAT_DATA_PATH": str(compat), "LOCALAPPDATA": str(profile)}
            master = shots / "shot.exr"
            subprocess.run([LUA, "tests/fixtures/banded_master.lua"], env=env, cwd=ROOT, check=True)
            with OpenEXR.File(str(master)) as image:
                self.assertEqual(image.header()["terraTechLegionExposureMode"], "Manual")
                self.assertEqual(image.header()["terraTechLegionShutterSamples"], 2)
                self.assertEqual(image.header()["isoSpeed"], 400)
                np.testing.assert_array_equal(image.channels()["RGB"].pixels, expected)

            result = subprocess.run([sys.executable, str(ROOT / "tools/export_photo.py")],
                                    cwd=directory, env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            # All patch values are above the log curves' linear toes. Decode
            # the quantized log codes and convert back to scene-linear Rec.709.
            curves = {"logc3": (5.555556, .052272, .247190, .385537),
                      "flog": (.555556, .009468, .344676, .790453)}
            for profile, (a, b, c, d) in curves.items():
                with self.subTest(profile=profile):
                    path = master.with_name(f"shot_{profile}.tiff")
                    self.check_camera_exif(path)
                    samples, description = read_tiff(path)
                    self.assertIn("Exposure offset 0 stops", description)
                    encoded = samples.astype(np.float64) / 65535
                    wide_rgb = (10 ** ((encoded - d) / c) - b) / a
                    scene_rgb = wide_rgb @ np.linalg.inv(MATRICES[profile]).T
                    np.testing.assert_allclose(scene_rgb, expected, rtol=.0003, atol=.00015)

            dng = master.with_suffix(".dng")
            self.check_camera_exif(dng)
            tags, samples = read_raw(dng)
            self.assertEqual(tags[50730], 9)
            np.testing.assert_array_equal(np.ldexp(samples, 9), expected)

    def check_camera_exif(self, path):
        with path.open("rb") as stream:
            head = stream.read(8)
            parent = ImageFileDirectory_v2(head)
            stream.seek(parent.next)
            parent.load(stream)
            stream.seek(parent[ExifTags.IFD.Exif])
            exif = ImageFileDirectory_v2(head, group=ExifTags.IFD.Exif)
            exif.load(stream)
            self.assertEqual(exif[ExifTags.Base.ISOSpeedRatings], 400)
            self.assertEqual(exif[ExifTags.Base.FNumber], 4)
            self.assertEqual(exif[ExifTags.Base.ExposureTime], 1/8)
            self.assertEqual(exif[ExifTags.Base.ExposureProgram], 1)
