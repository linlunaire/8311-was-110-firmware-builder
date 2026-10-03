"""Release builds must reject substituted inputs without destroying prior output."""
import importlib.util
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("release_builder", ROOT / "tools/build_from_release.py")
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


class ReleaseInputTests(unittest.TestCase):
    def test_substituted_base_cannot_touch_previous_output(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            base = root / "base.tar"
            base.write_bytes(b"not the public upstream firmware")
            output = root / "release"
            output.mkdir()
            previous = output / "local-upgrade.tar"
            previous.write_bytes(b"keep prior artifact")
            with self.assertRaisesRegex(ValueError, "pinned upstream"):
                builder.build(base, output, "v2.8.3-opt1")
            self.assertEqual(previous.read_bytes(), b"keep prior artifact")
            self.assertEqual(sorted(path.name for path in root.iterdir()), ["base.tar", "release"])


if __name__ == "__main__":
    unittest.main()
