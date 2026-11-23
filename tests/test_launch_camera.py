"""Verify the optional Steam wrapper without launching a game or a desktop picker."""

from pathlib import Path
import sys
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "mod"))
import launch_camera


class ProtonLauncherTests(unittest.TestCase):
    def test_target_keeps_every_argument_and_starts_one_picker(self):
        for game in ("/Games/TerraTech_Legion/TerraTech_LegionEOS.exe", r"Z:\games\TerraTech_LegionEOS-Win64-Shipping.exe"):
            with self.subTest(game=game), mock.patch.object(launch_camera.os, "execvp") as execute, \
                    mock.patch.object(launch_camera.subprocess, "Popen") as popen:
                command = ["steam-wrapper", "--other", "proton", "run", game, "-dx12", "-sm6", "with spaces"]
                launch_camera.main(command)
                execute.assert_called_once_with(command[0], command)
                args = popen.call_args.args[0]
                self.assertTrue(args[1].endswith("photo_directory.py"))
                self.assertEqual(args[2:], ["--watch", "--parent-pid", str(launch_camera.os.getpid())])

    def test_unrelated_command_passes_through_without_picker(self):
        with mock.patch.object(launch_camera.os, "execvp") as execute, \
                mock.patch.object(launch_camera.subprocess, "Popen") as popen:
            command = ["proton", "run", "TerraTech_Legion_DEMO.exe", "-sm6"]
            launch_camera.main(command)
            execute.assert_called_once_with(command[0], command)
            popen.assert_not_called()
