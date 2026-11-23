import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import numpy as np
import OpenEXR
from PIL.TiffImagePlugin import ImageFileDirectory_v2

TOOLS = Path(__file__).resolve().parents[1] / "tools"
sys.path.insert(0, str(TOOLS))
from linear_dng import write_dng


def read_raw(path):
    with path.open("rb") as stream:
        head = stream.read(8)
        ifd = ImageFileDirectory_v2(head)
        ifd.load(stream)
        strips = []
        for offset, count in zip(ifd[273], ifd[279]):
            stream.seek(offset)
            dtype = "<f4" if ifd[339][0] == 3 else "<u2"
            strips.append(np.frombuffer(stream.read(count), dtype))
        rgb = np.concatenate(strips).reshape(ifd[257], ifd[256], ifd[277])
    return ifd, rgb


class LinearDngTest(unittest.TestCase):
    def test_headroom_metadata_and_rgb_strips(self):
        # Uneven strip height, per-channel patches, and bright samples that
        # would collapse to white in a display-referred file.
        ramp = np.linspace(0, 7.5, num=75 * 19 * 3, dtype=np.float32).reshape(75, 19, 3)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "photo.dng"
            self.assertEqual(write_dng(ramp, path, integer=True), (3, 0))
            ifd, samples = read_raw(path)
            self.assertEqual(ifd[262], 34892)
            self.assertEqual(ifd[258], (16, 16, 16))
            self.assertEqual(ifd[50714], (0, 0, 0))
            self.assertEqual(ifd[50717], (65535,) * 3)
            self.assertEqual(ifd[50778], 21)
            self.assertEqual(tuple(map(float, ifd[50728])), (1, 1, 1))
            self.assertEqual(ifd[50708], "TerraTech Legion Virtual Camera")
            self.assertEqual(ifd[279], (32 * 19 * 6, 32 * 19 * 6, 11 * 19 * 6))
            gain = 2 ** float(ifd[50730])
            np.testing.assert_allclose(samples * (gain / 65535), ramp, rtol=0, atol=gain / 65535 / 2)
            color = np.array(ifd[50721], dtype=float).reshape(3, 3)
            forward = np.array(ifd[50964], dtype=float).reshape(3, 3)
            np.testing.assert_allclose(color @ [.95045593, 1, 1.08905775], [1, 1, 1], atol=2e-6)
            np.testing.assert_allclose(forward @ [1, 1, 1], [.9642, 1, .8249], atol=2e-6)
            # Reference D50 PCS red for the Bradford-adapted sRGB primary.
            np.testing.assert_allclose(forward[:, 0], [.43604, .22249, .01392], atol=7e-6)

    def test_negative_values_nonfinite_and_existing_output(self):
        chart = np.array([[[-.1, .18, .8]]], dtype=np.float32)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "negative.dng"
            with self.assertRaisesRegex(ValueError, "negative"):
                write_dng(chart, path, integer=True)
            self.assertFalse(path.exists())
            self.assertEqual(write_dng(chart, path, clip_negative=True, integer=True), (1, 1))
            _, raw = read_raw(path)
            self.assertEqual(raw[0, 0, 0], 0)
            original = path.read_bytes()
            with self.assertRaises(FileExistsError):
                write_dng(np.zeros_like(chart), path)
            self.assertEqual(path.read_bytes(), original)
            with self.assertRaisesRegex(ValueError, "NaN"):
                write_dng(np.full_like(chart, np.nan), path.with_name("invalid.dng"))

    def test_cli_from_tagged_half_exr(self):
        with tempfile.TemporaryDirectory() as directory:
            exr = Path(directory) / "capture.exr"
            dng = exr.with_suffix(".dng")
            patch = np.full((33, 12), 5.5, dtype=np.float16)
            OpenEXR.File({"colorInteropID": "lin_rec709_scene"}, {
                "R": patch.copy(), "G": patch / 2, "B": patch / 4,
            }).write(str(exr))
            subprocess.run([sys.executable, str(TOOLS / "linear_dng.py"), str(exr), str(dng)],
                           check=True, capture_output=True)
            ifd, raw = read_raw(dng)
            self.assertEqual(ifd[258], (32,) * 3)
            self.assertEqual(ifd[50706], bytes((1, 4, 0, 0)))
            self.assertEqual(ifd[50717], (1,) * 3)
            self.assertEqual(ifd[50730], 9)
            np.testing.assert_array_equal(raw[32, 0] * 512, [5.5, 2.75, 1.375])

    def test_float_recovers_signed_shadows_next_to_bright_emitters(self):
        rgb = np.array([[[-.002, .00001, .003], [309.25, .18, 2.005]]], dtype=np.float32)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "float.dng"
            self.assertEqual(write_dng(rgb, path), (9, 0))
            ifd, samples = read_raw(path)
            np.testing.assert_array_equal(np.ldexp(samples, int(ifd[50730])), rgb)
            bright = rgb * 4
            self.assertEqual(write_dng(bright, path.with_name("bright.dng")), (11, 0))


if __name__ == "__main__":
    unittest.main()
