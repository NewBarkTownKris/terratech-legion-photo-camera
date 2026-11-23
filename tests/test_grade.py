import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import numpy as np
import OpenEXR
import OpenImageIO as oiio

TOOLS = Path(__file__).resolve().parents[1] / "tools"
sys.path.insert(0, str(TOOLS))
import grade


def read_tiff(path):
    reader = oiio.ImageInput.open(str(path))
    try:
        spec = reader.spec()
        assert spec.format == oiio.UINT16 and spec.nchannels == 3
        assert spec.get_int_attribute("tiff:PhotometricInterpretation") == 2
        return reader.read_image(oiio.UINT16), spec.get_string_attribute("ImageDescription")
    finally:
        reader.close()


class GradeTests(unittest.TestCase):
    def test_primary_matrices(self):
        # The ARRI data sheet's published XYZ -> AWG matrix, multiplied by
        # standard D65 Rec.709 -> XYZ. Column 0 is a scene-linear red primary.
        np.testing.assert_allclose(grade.MATRICES["logc3"][:, 0], [.631321, .036820, .017370], atol=1e-6)
        np.testing.assert_allclose(grade.MATRICES["flog"][:, 0], [.627404, .069097, .016391], atol=1e-6)
        for m in grade.MATRICES.values():
            np.testing.assert_allclose(m @ np.ones(3), np.ones(3), atol=1e-12)

    def test_published_chart_codes_in_actual_tiff_files(self):
        gray = np.array([0, 0.18, .9, 1, 2, 4], dtype=np.float32)
        rgb = np.repeat(gray[:, None], 3, axis=1)[None, ...]
        with tempfile.TemporaryDirectory() as d:
            for profile, reference in (("logc3", [95, 400]), ("flog", [95, 470, 705])):
                with self.subTest(profile=profile):
                    path = Path(d) / f"{profile}.tif"
                    self.assertEqual(grade.write_log_tiff(path, rgb, profile), (0, 0))
                    image, description = read_tiff(path)
                    self.assertIn(grade.PROFILES[profile], description)
                    np.testing.assert_array_equal(image[:, :, 0], image[:, :, 2])
                    codes10 = np.rint(image[0, :, 0].astype(float) * 1023 / 65535)
                    np.testing.assert_array_equal(codes10[:len(reference)], reference)
                    self.assertTrue(np.all(np.diff(image[0, :, 0].astype(int)) > 0))

    def test_exr_origin_and_metadata_checks(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "input.exr"
            rgb = np.full((3, 4, 3), .18, dtype=np.float16)
            rgb[0, 0] = [-.1, 1.5, 8]
            def write(header, samples=rgb):
                OpenEXR.File(header, {"RGB": samples}).write(str(path))
            for tag in ({"chromaticities": grade.REC709}, {"colorInteropID": "lin_rec709_scene"}):
                write(tag)
                np.testing.assert_array_equal(grade.read_linear_exr(path), rgb)
            write({})
            with self.assertRaisesRegex(ValueError, "untagged"):
                grade.read_linear_exr(path)
            np.testing.assert_array_equal(grade.read_linear_exr(path, assume_rec709=True), rgb)
            for tag in ({"chromaticities": grade.F_GAMUT}, {"chromaticities": grade.REC709,
                         "colorInteropID": "srgb_rec709_scene"}):
                write(tag)
                with self.assertRaisesRegex(ValueError, "Rec.709"):
                    grade.read_linear_exr(path, assume_rec709=True)
            write({"chromaticities": grade.REC709}, np.zeros_like(rgb, dtype=np.uint32))
            with self.assertRaisesRegex(ValueError, "precision"):
                grade.read_linear_exr(path)

    def test_highlight_recovery_and_atomic_output(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            rgb = np.full((65, 4, 3), 64.0, dtype=np.float32)
            # A failing final strip must leave no partially usable photo.
            rgb[-1, 0, 0] = np.nan
            path = root / "photo.tiff"
            with self.assertRaisesRegex(ValueError, "Invalid linear sample"):
                grade.write_log_tiff(path, rgb, "flog")
            self.assertEqual(list(root.iterdir()), [])
            rgb[-1, 0] = -1
            low, high = grade.write_log_tiff(path, rgb, "flog")
            self.assertEqual(low, 3)
            self.assertEqual(high, rgb.size - 3)
            original = path.read_bytes()
            with self.assertRaises(FileExistsError):
                grade.write_log_tiff(path, rgb, "flog", exposure=-4)
            self.assertEqual(path.read_bytes(), original)
            path2 = root / "darker.tif"
            self.assertEqual(grade.write_log_tiff(path2, rgb, "flog", exposure=-4), (3, 0))
            converted, _ = read_tiff(path2)
            self.assertLess(converted[0, 0, 0], 65535)

    def test_auto_exposure_at_upper_curve_endpoints(self):
        # Independent inverses of the published curves evaluated at code 1.
        for profile, limit in (("logc3", 55.079576698813185), ("flog", 7.281324880488497)):
            frame = np.zeros((65, 4, 3))
            self.assertEqual(grade.highlight_exposure(frame, profile), 0)
            for factor, ev in ((1 - 1e-8, 0), (1, 0), (1 + 1e-8, -1),
                               (2 - 1e-8, -1), (2 + 1e-8, -2), (4, -2)):
                with self.subTest(profile=profile, brightness=factor):
                    frame[-1, -1] = limit * factor
                    self.assertEqual(grade.highlight_exposure(frame, profile), ev)
            frame[-1, -1] = [1.2 * limit, 0, 0]
            self.assertEqual(grade.highlight_exposure(frame, profile), 0,
                             "A saturated Rec.709 red fits after widening the gamut")

    def test_camera_exif_in_bigtiff(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "big.tif"
            rgb = np.arange(12, dtype=np.uint16).reshape(2, 2, 3)
            spec = oiio.ImageSpec(2, 2, 3, oiio.UINT16)
            spec.attribute("tiff:bigtiff", 1)
            spec.attribute("Exif:ExifVersion", "0232")
            writer = oiio.ImageOutput.create(str(path))
            self.assertTrue(writer.open(str(path), spec))
            self.assertTrue(writer.write_image(rgb))
            self.assertTrue(writer.close())
            grade.write_tiff_exif(path, grade.capture_exif({"expTime": 1/32000, "isoSpeed": 320,
                                                           "aperture": 5.6}))
            reader = oiio.ImageInput.open(str(path))
            try:
                self.assertAlmostEqual(reader.spec().get_float_attribute("ExposureTime"), 1/32000)
                self.assertAlmostEqual(reader.spec().get_float_attribute("FNumber"), 5.6, places=5)
                np.testing.assert_array_equal(reader.spec().getattribute("Exif:ISOSpeedRatings"), [320])
                np.testing.assert_array_equal(reader.read_image(oiio.UINT16), rgb)
            finally:
                reader.close()

    def test_cli_from_another_directory(self):
        with tempfile.TemporaryDirectory() as d:
            source = Path(d) / "train.exr"
            values = np.full((2, 4, 3), .18, dtype=np.float32)
            values[0, 0] = 12
            OpenEXR.File({"chromaticities": grade.REC709}, {"RGB": values}).write(str(source))
            result = subprocess.run([sys.executable, TOOLS / "grade.py", source, "--profile", "flog"],
                                    cwd=d, check=True, capture_output=True, text=True)
            self.assertIn("0 above white", result.stdout)
            self.assertIn("-1 EV", result.stdout)
            self.assertTrue(source.with_name("train_flog.tiff").is_file())


if __name__ == "__main__":
    unittest.main()
