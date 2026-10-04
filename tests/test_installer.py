"""Checks for the standalone Ubuntu installation path."""

from pathlib import Path
import subprocess
import tempfile
import unittest


INSTALLER = Path(__file__).resolve().parents[1] / "outputs" / "install-openrct2-manager.sh"


class InstallerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = INSTALLER.read_text()

    def test_installer_is_valid_bash(self):
        result = subprocess.run(["bash", "-n", str(INSTALLER)], text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_missing_openrct2_uses_official_release_ppa_by_default(self):
        self.assertIn("AUTO_INSTALL_OPENRCT2=${AUTO_INSTALL_OPENRCT2:-true}", self.source)
        self.assertIn("OPENRCT2_INSTALL_CHANNEL=${OPENRCT2_INSTALL_CHANNEL:-release}", self.source)
        self.assertIn('ppa_channel=master', self.source)
        self.assertIn('add-apt-repository -y "ppa:openrct2/${ppa_channel}"', self.source)
        self.assertIn('apt-get install -y --no-install-recommends openrct2', self.source)

    def test_detector_accepts_explicit_executable_outside_path(self):
        start = self.source.index("find_openrct2() {")
        end = self.source.index("\nopenrct2_was_installed=false", start)
        function = self.source[start:end]
        with tempfile.TemporaryDirectory() as folder:
            binary = Path(folder) / "custom-openrct2"
            binary.write_text("#!/bin/sh\nexit 0\n")
            binary.chmod(0o755)
            command = function + '\nOPENRCT2_BIN="$1"\nfind_openrct2\n'
            result = subprocess.run(["bash", "-c", command, "test", str(binary)],
                                    text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(Path(result.stdout.strip()), binary.resolve())

    def test_detector_covers_ubuntu_games_paths_and_install_can_be_disabled(self):
        self.assertIn("/usr/games/openrct2", self.source)
        self.assertIn("automatic installation is disabled", self.source)
        self.assertLess(self.source.index('apt-get install -y --no-install-recommends openrct2'),
                        self.source.index('version_line=$("$OPENRCT2_BIN" --version'))

    def test_old_ppa_package_falls_back_to_verified_official_release(self):
        self.assertIn("https://api.github.com/repos/OpenRCT2/OpenRCT2/releases/latest", self.source)
        self.assertIn("sha256sum -c -", self.source)
        self.assertIn("The Ubuntu package is too old", self.source)
        self.assertIn("tar -tzf", self.source)
        self.assertIn("The OpenRCT2 archive contains an unsafe path", self.source)


if __name__ == "__main__":
    unittest.main()
