"""Build failure and deterministic packaging checks with synthetic components."""
import hashlib
import os
import shutil
import tarfile

from test_regressions import ROOT, ShellFixture, shell_path


class CreateTests(ShellFixture):
    def setUp(self):
        super().setUp()
        self.create = self.script("create.sh")
        self.source = self.root / "source [1] # &"
        self.source.mkdir()
        self.images = {"bootcore.bin": b"boot\x00", "kernel.bin": b"kernel\xff", "rootfs.img": b"rootfs\x00"}
        for name, data in self.images.items():
            path = self.source / name
            path.write_bytes(data)
            os.utime(path, (12345, 12345))
        self.version = self.source / "version"
        self.version.write_text("FW_VERSION=fixture\nFW_REVISION=test\nFW_VARIANT=basic\n")
        self.output = self.root / "upgrade.tar"
        self.output.write_bytes(b"previous build")

    def arguments(self):
        return ["--basic", "-i", shell_path(self.output), "-F", shell_path(self.version),
                "-b", shell_path(self.source / "bootcore.bin"), "-k", shell_path(self.source / "kernel.bin"),
                "-r", shell_path(self.source / "rootfs.img"), "-D", "@100000"]

    def test_archive_names_bytes_hashes_and_times_are_stable_without_touching_inputs(self):
        result = self.run_script(self.create, *self.arguments())
        self.assertEqual(result.returncode, 0, result.stderr)
        with tarfile.open(self.output) as archive:
            self.assertEqual(set(archive.getnames()), {"upgrade.sh", "control", *self.images})
            control = archive.extractfile("control").read().decode()
            for name, data in self.images.items():
                self.assertEqual(archive.extractfile(name).read(), data)
                self.assertIn("SHA256_" + name.split(".")[0].upper() + "=" + hashlib.sha256(data).hexdigest(), control)
            self.assertTrue(all(member.mtime == 100000 for member in archive.getmembers()))
        self.assertTrue(all((self.source / name).stat().st_mtime == 12345 for name in self.images))
        self.assertEqual(list(self.root.glob("*.build.*")), [])

    def test_bad_date_and_tar_failure_preserve_previous_output(self):
        result = self.run_script(self.create, *self.arguments()[:-1], "invalid date")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.output.read_bytes(), b"previous build")
        self.command("tar", "exit 7")
        result = self.run_script(self.create, *self.arguments())
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.output.read_bytes(), b"previous build")
        self.assertEqual(list(self.root.glob("*.build.*")), [])

    def test_missing_option_and_output_alias_are_rejected(self):
        self.assertNotEqual(self.run_script(self.create, "--image").returncode, 0)
        self.output = self.source / "kernel.bin"
        self.assertNotEqual(self.run_script(self.create, *self.arguments()).returncode, 0)
        self.assertEqual(self.output.read_bytes(), self.images["kernel.bin"])


class WholeImageTests(ShellFixture):
    def setUp(self):
        super().setUp()
        self.whole = self.script("wholeImage.sh")
        for name in ("whole_image", "out", "tools"):
            (self.root / name).mkdir()
        (self.root / "whole_image/uboot-azores-1.0.24.bin").write_bytes(b"boot")
        (self.root / "whole_image/ubootenv-azores.img").write_bytes(b"env!")
        for name in ("kernel.bin", "bootcore.bin", "rootfs.img"):
            (self.root / "out" / name).write_bytes(b"synthetic")
        for name in ("whole-image.img", "whole-image-endian.img"):
            (self.root / "out" / name).write_bytes(b"previous build")
        (self.root / "system_sw.ini").write_text("fixture\n")
        swap = self.root / "tools/endianess_swap.sh"
        swap.write_text((ROOT / "tools/endianess_swap.sh").read_text(), newline="\n")
        swap.chmod(0o755)
        self.command("ubinize", '''
printf 'ubi!' > "$2"
[ "${UBINIZE_FAIL:-0}" = 0 ] || exit 1
''')

    def test_checked_flash_layout_padding_and_endianness(self):
        result = self.run_script(self.whole, "100000", cwd=self.root)
        self.assertEqual(result.returncode, 0, result.stderr)
        data = (self.root / "out/whole-image.img").read_bytes()
        expected = b"boot" + b"\xff" * (0x100000 - 4)
        expected += (b"env!" + b"\xff" * (0x40000 - 4)) * 2
        expected += b"\xff" * (0x40000 + 0x100000 + 0x1000000) + b"ubi!"
        self.assertEqual(data, expected)
        reverse = (self.root / "out/whole-image-endian.img").read_bytes()
        self.assertEqual(reverse[:8], b"toob\xff\xff\xff\xff")
        self.assertEqual(reverse[-4:], b"!ibu")
        self.assertEqual(len(reverse), len(data))

    def test_failed_ubinize_and_oversized_input_keep_previous_flash_images(self):
        self.env["UBINIZE_FAIL"] = "1"
        self.assertNotEqual(self.run_script(self.whole, cwd=self.root).returncode, 0)
        del self.env["UBINIZE_FAIL"]
        (self.root / "whole_image/ubootenv-azores.img").write_bytes(b"x" * (0x40000 + 1))
        self.assertNotEqual(self.run_script(self.whole, cwd=self.root).returncode, 0)
        for name in ("whole-image.img", "whole-image-endian.img"):
            self.assertEqual((self.root / "out" / name).read_bytes(), b"previous build")
        self.assertEqual(list((self.root / "out").glob("*.build.*")), [])


class RawBuildBoundaryTests(ShellFixture):
    def test_inputs_in_generated_trees_are_rejected_before_replacement(self):
        build = self.script("build.sh")
        (self.root / "out").mkdir()
        source = self.root / "out/stock.img"
        source.write_bytes(b"keep this input")
        result = self.run_script(build, "-i", shell_path(source), "-I", shell_path(self.root))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("generated build directory", result.stderr)
        self.assertEqual(source.read_bytes(), b"keep this input")
