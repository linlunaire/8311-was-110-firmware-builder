"""Offline regressions: all firmware devices and commands are test fixtures."""
import base64
import hashlib
import io
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tarfile
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
TMP_ROOT = ROOT / ".test-tmp"


def shell_path(path):
    path = str(Path(path).resolve()).replace("\\", "/")
    if os.name == "nt":
        return "/" + path[0].lower() + path[2:]
    return path


def shell_command():
    override = os.environ.get("TEST_SHELL")
    if override:
        return [override] + shlex.split(os.environ.get("TEST_SHELL_ARGS", ""))
    if os.name == "nt":
        return [str(Path(os.environ["ProgramFiles"]) / "Git/bin/bash.exe")]
    return ["/bin/sh"]


class ShellFixture(unittest.TestCase):
    def setUp(self):
        TMP_ROOT.mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix="regression-", dir=TMP_ROOT)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        (self.root / "tmp").mkdir()
        self.ops = self.root / "operations"
        self.env = os.environ.copy()
        self.env.update(TEST_BIN=shell_path(self.bin), OPS=shell_path(self.ops),
                        FIXTURE=shell_path(self.root))

    def tearDown(self):
        assert self.root.resolve().is_relative_to(TMP_ROOT.resolve())
        self.temp.cleanup()

    def command(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/sh\n" + body + "\n", encoding="utf-8", newline="\n")
        path.chmod(0o755)

    def script(self, source, relocate=False):
        data = (ROOT / source).read_text(encoding="utf-8")
        if relocate:
            data = data.replace("/dev/null", "__TEST_DEV_NULL__")
            for prefix in ("/tmp/", "/dev/", "/proc/", "/sys/", "/ptconf/", "/lib/", "/usr/sbin/"):
                data = data.replace(prefix, shell_path(self.root) + prefix)
            data = data.replace("__TEST_DEV_NULL__", "/dev/null")
        path = self.root / Path(source).name
        data = data.replace("\n", '\nexport PATH="$TEST_BIN:$PATH"\n', 1)
        path.write_text(data, encoding="utf-8", newline="\n")
        path.chmod(0o755)
        return path

    def run_script(self, path, *args, stdin="", cwd=None):
        shell = shell_command()
        if path.name == "build.sh" and os.name != "nt":
            shell = [shutil.which("bash")]
        return subprocess.run(shell + [shell_path(path), *map(str, args)],
                              env=self.env, cwd=cwd or ROOT, input=stdin,
                              text=True, capture_output=True, timeout=45)

    def operations(self):
        return self.ops.read_text().splitlines() if self.ops.exists() else []


class UpgradeTests(ShellFixture):
    def setUp(self):
        super().setUp()
        self.upgrade = self.script("files/common/usr/sbin/8311-firmware-upgrade.sh", True)
        (self.root / "dev").mkdir()
        (self.root / "proc").mkdir()
        (self.root / "proc/cmdline").write_text("console=ttyS0 rootfsname=rootfsA\n")
        self.command("flock", '[ "${LOCK_FAIL:-0}" = 0 ]')
        self.command("ubinfo", '''
case "$3" in
    kernelA) id=0 ;; bootcoreA) id=1 ;; rootfsA) id=2 ;;
    kernelB) id=3 ;; bootcoreB) id=4 ;; rootfsB) id=5 ;;
    *) exit 1 ;;
esac
if [ "${REMAPPED_A:-0}" = 1 ]; then
    case "$3" in bootcoreA) id=2 ;; rootfsA) id=1 ;; esac
fi
printf 'Volume ID: %s\nSize: 1 LEBs (4096 bytes, 4 KiB)\n' "$id"
''')
        self.command("ubiupdatevol", '''
echo "write:$3" >> "$OPS"
[ "${FLASH_FAIL:-0}" = 0 ] || exit 7
cat > "$3"
[ "${BAD_READBACK:-0}" = 0 ] || printf 'corrupt' > "$3"
''')
        self.command("fw_setenv", '''
echo "env:$1:$2" >> "$OPS"
[ "${ENV_FAIL:-0}" = 0 ] || exit 8
''')
        self.command("reboot", 'echo reboot >> "$OPS"')
        self.command("sleep", ":")
        # A test must fail loudly if a new destructive command escapes its mocks.
        for name in ("ubimkvol", "ubirsvol", "mtd"):
            self.command(name, 'echo unexpected-write >> "$OPS"; exit 99')

    def archive(self, overrides=None, omit=None, corrupt=None):
        images = {"kernel.bin": b"kernel fixture\x00\xff", "bootcore.bin": b"bootcore fixture",
                  "rootfs.img": b"rootfs fixture" * 5}
        control = {"FW_VERSION": "test", "FW_REVISION": "fixture", "FW_VARIANT": "basic"}
        for name, data in images.items():
            key = name.split(".")[0].upper()
            control["SIZE_" + key] = str(len(data))
            control["SHA256_" + key] = hashlib.sha256(data).hexdigest()
        control.update(overrides or {})
        if corrupt:
            images[corrupt] += b"corrupt"
        members = {"control": "".join(f"{key}={value}\n" for key, value in control.items()).encode(), **images}
        path = self.root / "upgrade.tar"
        with tarfile.open(path, "w", format=tarfile.USTAR_FORMAT) as archive:
            for name, data in members.items():
                if name == omit:
                    continue
                info = tarfile.TarInfo(name)
                info.size = len(data)
                archive.addfile(info, io.BytesIO(data))
        return shell_path(path)

    def assert_clean_stage(self):
        self.assertEqual(list((self.root / "tmp").glob("8311-upgrade.*")), [])

    def test_install_validates_and_writes_only_inactive_bank(self):
        result = self.run_script(self.upgrade, "--install", "--yes", self.archive())
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual([line.rsplit("_", 1)[-1] for line in self.operations()[:3]], ["3", "4", "5"])
        self.assertEqual(self.operations()[3:], ["env:commit_bank:B"] * 2)
        self.assert_clean_stage()
        self.assertTrue((self.root / "tmp/8311-firmware-upgrade.lock").exists())

    def test_install_from_bank_b_targets_bank_a(self):
        (self.root / "proc/cmdline").write_text("rootfsname=rootfsB\n")
        result = self.run_script(self.upgrade, "--install", "--yes", self.archive())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([line.rsplit("_", 1)[-1] for line in self.operations()[:3]], ["0", "1", "2"])

    def test_declining_commit_keeps_boot_bank_and_uses_volume_names(self):
        (self.root / "proc/cmdline").write_text("rootfsname=rootfsB\n")
        self.env["REMAPPED_A"] = "1"
        result = self.run_script(self.upgrade, "--install", self.archive(), stdin="y\nn\n")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual([line.rsplit("_", 1)[-1] for line in self.operations()], ["0", "2", "1"])
        self.assert_clean_stage()

    def test_explicit_install_rejects_bad_last_image_before_any_write(self):
        result = self.run_script(self.upgrade, "--install", "--yes", self.archive(corrupt="rootfs.img"))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.operations(), [])
        self.assert_clean_stage()

    def test_missing_image_is_rejected(self):
        result = self.run_script(self.upgrade, "--install", "--yes", self.archive(omit="bootcore.bin"))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.operations(), [])

    def test_bad_metadata_is_rejected_before_any_write(self):
        for key, value in (("SIZE_ROOTFS", "0"), ("SIZE_ROOTFS", "-1"),
                           ("SIZE_ROOTFS", "123garbage"), ("SIZE_ROOTFS", "999"),
                           ("SHA256_ROOTFS", "0" * 64), ("SHA256_ROOTFS", "not-a-hash")):
            with self.subTest(key=key, value=value):
                result = self.run_script(self.upgrade, "--install", "--yes", self.archive({key: value}))
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.operations(), [])
                self.assert_clean_stage()

    def test_flash_and_readback_and_commit_failures_propagate(self):
        for failure in ("FLASH_FAIL", "BAD_READBACK", "ENV_FAIL"):
            with self.subTest(failure=failure):
                self.env[failure] = "1"
                result = self.run_script(self.upgrade, "--install", "--yes", "--reboot", self.archive())
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("reboot", self.operations())
                if failure != "ENV_FAIL":
                    self.assertFalse(any(line.startswith("env:") for line in self.operations()))
                self.assert_clean_stage()
                self.ops.unlink()
                del self.env[failure]

    def test_lock_contention_and_unknown_bank_fail_before_writes(self):
        self.env["LOCK_FAIL"] = "1"
        result = self.run_script(self.upgrade, "--install", "--yes", self.archive())
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.operations(), [])
        del self.env["LOCK_FAIL"]
        (self.root / "proc/cmdline").write_text("rootfsname=unknown\n")
        result = self.run_script(self.upgrade, "--install", "--yes", self.archive())
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.operations(), [])

    def test_validation_only_does_not_require_a_device(self):
        (self.root / "proc/cmdline").unlink()
        result = self.run_script(self.upgrade, "--validate", self.archive())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.operations(), [])
        self.assert_clean_stage()

    def test_cancel_returns_distinct_status_without_writes(self):
        result = self.run_script(self.upgrade, "--install", self.archive(), stdin="n\n")
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertEqual(self.operations(), [])


class FwenvTests(ShellFixture):
    def test_base64_is_single_line_and_preserves_literal_values(self):
        script = self.script("files/common/usr/sbin/fwenv_set")
        self.command("fw_setenv", 'printf "%s|%s|%s\\n" "$1" "$2" "$3" >> "$OPS"')
        for value in ("x" * 100, r"literal\n\t\\", "-n", "猫棒配置"):
            with self.subTest(value=value):
                if self.ops.exists():
                    self.ops.unlink()
                result = self.run_script(script, "--8311", "--base64", "--", "fw_match", value)
                self.assertEqual(result.returncode, 0, result.stderr)
                encoded = base64.b64encode(value.encode()).decode()
                self.assertEqual(self.operations(), ["--|8311_fw_match_b64|" + encoded] * 2)

    def test_base64_failure_prevents_environment_writes(self):
        script = self.script("files/common/usr/sbin/fwenv_set")
        self.command("base64", "exit 13")
        self.command("fw_setenv", 'echo write >> "$OPS"')
        result = self.run_script(script, "--base64", "fw_match", "fixture")
        self.assertEqual(result.returncode, 13, result.stderr)
        self.assertEqual(self.operations(), [])

    def test_password_persistence_does_not_print_hash(self):
        script = self.script("files/common/usr/sbin/8311-persist-root-password.sh")
        self.env["TEST_HASH"] = "$6$fixture$examplehash"
        self.command("awk", 'printf "%s\\n" "$TEST_HASH"')
        self.command("fwenv_set", 'printf "%s\\n" "$3" >> "$OPS"')
        result = self.run_script(script)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.operations(), [self.env["TEST_HASH"]])
        self.assertNotIn(self.env["TEST_HASH"], result.stdout + result.stderr)

    def test_first_write_failure_cannot_be_masked_by_second_write(self):
        script = self.script("files/common/usr/sbin/fwenv_set")
        self.command("fw_setenv", '''
if [ -f "$OPS" ]; then echo second >> "$OPS"; exit 0; fi
echo first > "$OPS"
exit 42
''')
        result = self.run_script(script, "--8311", "fix_vlans", "1")
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertEqual(self.operations(), ["first"])

    def test_double_write_and_option_terminator_are_preserved(self):
        script = self.script("files/common/usr/sbin/fwenv_set")
        self.command("fw_setenv", 'printf "%s|%s|%s\\n" "$1" "$2" "$3" >> "$OPS"')
        result = self.run_script(script, "--8311", "--", "loid", "-test-value")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.operations(), ["--|8311_loid|-test-value"] * 2)


class HookTests(ShellFixture):
    def setUp(self):
        super().setUp()
        self.hook = self.script("examples/vlan_fixes_hook.sh", True)
        for directory in ("lib", "sys/class/net/eth0_0", "sys/class/net/eth0_0_2"):
            (self.root / directory).mkdir(parents=True)
        (self.root / "lib/8311-vlans-lib.sh").write_text('''
tc_flower_clear() { echo unexpected-clear >> "$OPS"; return 99; }
tc_flower_replace() {
    count=$(cat "$FIXTURE/rules" 2>/dev/null || echo 0)
    count=$((count + 1)); echo "$count" > "$FIXTURE/rules"
    printf '%s\\n' "$*" >> "$OPS"
    [ "$count" != "${RULE_FAIL_AT:-0}" ] || return 17
}
''', newline="\n")
        self.env.update(INTERNET_VLAN="41", IPTV_VLAN="43", IPTV_ENABLED="0", INTERNET_CONVERT="0")

    def test_internet_is_untagged_and_iptv_is_opt_in(self):
        (self.root / "sys/class/net/eth0_0_2").rmdir()
        result = self.run_script(self.hook)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.operations()), 4)
        self.assertIn("vlan_id 41 action vlan pop pass", self.operations()[0])
        self.assertIn("action vlan push id 41 protocol 802.1Q pass", self.operations()[3])
        self.assertTrue(all("eth0_0_2" not in line for line in self.operations()))

    def test_iptv_retains_a_tag_for_a_router_vlan_interface(self):
        self.env["IPTV_ENABLED"] = "1"
        result = self.run_script(self.hook)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.operations()), 7)
        self.assertIn("action vlan modify id 43 protocol 802.1Q pass", self.operations()[4])
        self.assertIn("action vlan push id 43 protocol 802.1Q pass", self.operations()[6])

    def test_every_rule_failure_stops_later_rules(self):
        self.env["IPTV_ENABLED"] = "1"
        for index in range(1, 8):
            with self.subTest(index=index):
                if self.ops.exists(): self.ops.unlink()
                if (self.root / "rules").exists(): (self.root / "rules").unlink()
                self.env["RULE_FAIL_AT"] = str(index)
                result = self.run_script(self.hook)
                self.assertEqual(result.returncode, 17, result.stderr)
                self.assertEqual(len(self.operations()), index)

    def test_invalid_values_and_missing_interfaces_make_no_rule_changes(self):
        for values in ({"INTERNET_VLAN": "0"}, {"INTERNET_VLAN": "4095"},
                       {"INTERNET_VLAN": "41;echo"}, {"INTERNET_CONVERT": "1"}, {"INTERNET_CONVERT": "4095"},
                       {"IPTV_ENABLED": "yes"}, {"IPTV_ENABLED": "1", "IPTV_VLAN": "0"}):
            with self.subTest(values=values):
                saved = self.env.copy()
                self.env.update(values)
                self.assertNotEqual(self.run_script(self.hook).returncode, 0)
                self.assertEqual(self.operations(), [])
                self.env = saved
        self.env["IPTV_ENABLED"] = "1"
        (self.root / "sys/class/net/eth0_0_2").rmdir()
        self.assertNotEqual(self.run_script(self.hook).returncode, 0)
        self.assertEqual(self.operations(), [])


class SupportTests(ShellFixture):
    def setUp(self):
        super().setUp()
        self.support = self.script("files/common/usr/sbin/8311-support.sh", True)
        self.command("flock", ":")
        self.command("fw_printenv", '''
[ "${ENV_FAIL:-0}" = 0 ] || exit 5
printf '%s\n' '8311_reg_id_hex=736563726574' '8311_lpwd=secret-password' '8311_gpon_sn=TEST12345678' '8311_future_secret=unknown-secret' '8311_internet_vlan=100' '8311_fix_vlans=1'
''')
        self.command("8311-extvlan-decode.sh", '[ "${VLAN_FAIL:-0}" = 0 ] || exit 6; echo "VLAN table fixture"')
        self.command("pontop", 'echo private-pontop > "$FIXTURE/tmp/pontop.txt"')
        self.command("omci_pipe.sh", 'echo private-omci')
        self.command("8311-tc-filter-dump.sh", 'echo private-tc')
        self.command("logread", 'echo secret-password')

    def contents(self):
        with tarfile.open(self.root / "tmp/support.tar.gz") as archive:
            return {member.name: archive.extractfile(member).read().decode()
                    for member in archive.getmembers() if member.isfile()}

    def test_default_diagnostics_redact_unknown_fields_and_omit_raw_sources(self):
        result = self.run_script(self.support)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        files = self.contents()
        content = "\n".join(files.values())
        for sensitive in ("736563726574", "secret-password", "TEST12345678", "unknown-secret", "private-"):
            self.assertNotIn(sensitive, content)
        self.assertIn("8311_internet_vlan=100", content)
        self.assertIn("8311_future_secret=[REDACTED]", content)
        self.assertEqual(set(files), {"support/README.txt", "support/fwenvs.txt", "support/extvlan-tables.txt"})

    def test_raw_diagnostics_require_explicit_option(self):
        result = self.run_script(self.support, "--raw")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        files = self.contents()
        self.assertIn("secret-password", files["support/fwenvs.txt"])
        self.assertIn("private-omci", files["support/omci_pipe_mda.txt"])
        self.assertIn("secret-password", files["support/system_log.txt"])

    def test_failed_generation_does_not_offer_an_old_raw_archive(self):
        for failure in ("ENV_FAIL", "VLAN_FAIL"):
            with self.subTest(failure=failure):
                self.env[failure] = "1"
                old = self.root / "tmp/support.tar.gz"
                old.write_bytes(b"old raw archive")
                result = self.run_script(self.support)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(old.exists())
                self.assertEqual([p for p in (self.root / "tmp").glob("8311-support.*") if p.is_dir()], [])
                del self.env[failure]


class ExtractTests(ShellFixture):
    def setUp(self):
        super().setUp()
        self.extract = self.script("extract.sh")
        self.images = {"bootcore.bin": b"boot\x00\xff123", "kernel.bin": b"kernel1234",
                       "rootfs.img": b"rootfs\x00\xfe456"}
        self.outputs = ["header.bin", *self.images]

    def stock_image(self, length=None, truncate=0):
        header = bytearray(0xD00)
        header[:16] = b"~@$^*)+ATOS!#%&("
        for index, (name, content) in enumerate(self.images.items()):
            offset = 0x100 + index * 48
            header[offset:offset + 32] = name.encode().ljust(32, b"\0")
            field = length if index == 2 and length is not None else "00" + str(len(content))
            header[offset + 32:offset + 48] = field.encode().ljust(16, b"\0")
        data = bytes(header) + b"".join(self.images.values())
        if truncate:
            data = data[:-truncate]
        source = self.root / "stock.img"
        source.write_bytes(data)
        return source, bytes(header)

    def assert_rejected_without_overwriting(self, source):
        for name in self.outputs:
            (self.root / name).write_bytes(b"previous output")
        result = self.run_script(self.extract, "-i", shell_path(source), cwd=self.root)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        for name in self.outputs:
            self.assertEqual((self.root / name).read_bytes(), b"previous output")

    def test_valid_components_are_extracted_byte_for_byte(self):
        source, header = self.stock_image()
        result = self.run_script(self.extract, "-i", shell_path(source), cwd=self.root)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for name, data in {"header.bin": header, **self.images}.items():
            self.assertEqual((self.root / name).read_bytes(), data)

    def test_truncated_tail_cannot_be_satisfied_with_bytes_from_an_earlier_component(self):
        source, _ = self.stock_image(truncate=5)
        self.assert_rejected_without_overwriting(source)

    def test_invalid_zero_or_overflowing_lengths_are_rejected(self):
        for length in ("", "-1", "1+1", "abc", "0000000000000000", "9999999999999999"):
            with self.subTest(length=length):
                source, _ = self.stock_image(length=length)
                self.assert_rejected_without_overwriting(source)

    def test_truncated_header_is_rejected(self):
        source, _ = self.stock_image()
        source.write_bytes(source.read_bytes()[:100])
        self.assert_rejected_without_overwriting(source)


class BuildTests(ShellFixture):
    def setUp(self):
        super().setUp()
        self.build = self.script("build.sh")

    def test_documented_tar_option_is_accepted(self):
        for option in ("-O", "--tar-out"):
            result = self.run_script(self.build, option, "custom.tar")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Must specify --bfw-image-file", result.stderr)
            self.assertNotIn("Usage:", result.stdout)

    def test_all_value_options_reject_missing_values(self):
        for option in ("-i", "--image", "--bfw-image-file", "-I", "--image-dir", "--basic-image-dir",
                       "-o", "--image-out", "-O", "--tar-out", "-V", "--image-version", "-r", "--image-revision"):
            with self.subTest(option=option):
                result = self.run_script(self.build, option)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("requires a value", result.stderr)

    def test_aliases_and_external_working_directory_preserve_previous_output(self):
        stock = self.root / "stock"
        stock.mkdir()
        (stock / "bfw.img").write_bytes(b"test")
        (self.root / "out").mkdir()
        sentinel = self.root / "out/previous-build"
        sentinel.write_text("keep")
        result = self.run_script(self.build, "--image", "bfw.img", "--image-dir", ".", cwd=stock)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("bootcore.bin", result.stderr)
        self.assertEqual(sentinel.read_text(), "keep")


class LuaTests(unittest.TestCase):
    def test_lua_regressions(self):
        try:
            from lupa.lua51 import LuaRuntime
        except ImportError:
            lua = shutil.which("lua5.1") or shutil.which("lua")
            self.assertIsNotNone(lua, "Install Lua 5.1 or Python lupa to run the Lua regressions")
            result = subprocess.run([lua, "tests/test_lua.lua"], cwd=ROOT, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            lua = LuaRuntime(unpack_returned_tuples=True)
            lua.globals().REPO_ROOT = ROOT.as_posix()
            def host_call(command):
                # Git for Windows includes PCRE grep; the firmware uses pcre2grep.
                command = command.replace("/usr/bin/pcre2grep", "grep -P")
                return subprocess.run(shell_command() + ["-c", command], cwd=ROOT, capture_output=True).returncode
            lua.globals().HOST_CALL = host_call
            lua.execute((ROOT / "tests/test_lua.lua").read_text(encoding="utf-8"))


class VlanDaemonTests(ShellFixture):
    def setUp(self):
        super().setUp()
        self.daemon = self.script("files/common/usr/sbin/8311-vlansd.sh", True)
        # Some BusyBox ash builds implement sleep internally and bypass PATH.
        # Explicitly call the fixture so tests never wait on real retry delays.
        source = self.daemon.read_text()
        self.daemon.write_text(source.replace("\n", '\nsleep() { "$TEST_BIN/sleep" "$@"; }\n', 1),
                               encoding="utf-8", newline="\n")
        for directory in ("lib", "usr/sbin", "ptconf/8311", "sys/devices/virtual/net/gem-omci"):
            (self.root / directory).mkdir(parents=True)
        (self.root / "mode").write_text("1\n")
        (self.root / "lib/8311.sh").write_text('''
fwenv_get_8311() { cat "$FIXTURE/mode"; }
to_console() { cat >> "$FIXTURE/log"; }
''', newline="\n")
        (self.root / "lib/8311-vlans-lib.sh").write_text(":\n")
        self.env["MAX_CYCLES"] = "4"
        self.command("flock", '''
[ "$#" -gt 2 ] || exit 0
[ "${FIX_LOCK_BUSY:-0}" = 0 ] || exit 1
shift
shift
[ "$1" = -c ] || exit 99
sh -c "$2"
''')
        self.command("sleep", '''
echo "sleep:$1" >> "$OPS"
cycle=$(cat "$FIXTURE/cycle" 2>/dev/null || echo 0)
cycle=$((cycle + 1))
echo "$cycle" > "$FIXTURE/cycle"
if [ "$cycle" = 1 ]; then
    case "$SCENARIO" in
        enable) echo 1 > "$FIXTURE/mode"; touch "$FIXTURE/tmp/8311-vlans.reload" ;;
        reload) touch "$FIXTURE/tmp/8311-vlans.reload" ;;
        hook) echo '# changed hook' >> "$FIXTURE/ptconf/8311/vlan_fixes_hook.sh" ;;
    esac
fi
if [ "$cycle" -ge "$MAX_CYCLES" ]; then kill -TERM "$PPID"; fi
''')
        self.command("8311-detect-config.sh", '''
echo detect >> "$OPS"
count=$(cat "$FIXTURE/detects" 2>/dev/null || echo 0)
count=$((count + 1)); echo "$count" > "$FIXTURE/detects"
case ",${DETECT_FAIL_CYCLES:-}," in *,"$count",*) exit 3 ;; esac
[ "${DETECT_FAIL:-0}" = 0 ] || exit 3
if [ "${BAD_HASH:-0}" = 1 ]; then echo invalid; else printf '%064d\n' 1; fi
''')
        self.command("8311-fix-vlans.sh", '''
echo fix >> "$OPS"
count=$(cat "$FIXTURE/fixes" 2>/dev/null || echo 0)
count=$((count + 1))
echo "$count" > "$FIXTURE/fixes"
if [ "${FAIL_UNTIL:-0}" -ge "$count" ]; then exit 5; fi
if [ -f "$FIXTURE/tmp/8311-config.sh" ]; then echo cached >> "$OPS"; else echo fresh >> "$OPS"; fi
echo cache > "$FIXTURE/tmp/8311-config.sh"
''')
        for name in ("8311-detect-config.sh", "8311-fix-vlans.sh"):
            shutil.copy2(self.bin / name, self.root / "usr/sbin" / name)

    def run_daemon(self):
        result = self.run_script(self.daemon)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return self.operations()

    def test_unchanged_topology_applies_once(self):
        ops = self.run_daemon()
        self.assertEqual(ops.count("fix"), 1)
        self.assertEqual(ops.count("detect"), 4)
        self.assertEqual([x for x in ops if x.startswith("sleep:")], ["sleep:5"] * 4)
        fields = (self.root / "tmp/8311-vlans.status").read_text().strip().split("\t")
        self.assertEqual(fields[4:], ["applied", "none", "0"])
        self.assertGreater(int(fields[2]), 0)

    def test_failures_back_off_and_success_resets_delay(self):
        self.env.update(FAIL_UNTIL="3", MAX_CYCLES="6")
        ops = self.run_daemon()
        self.assertEqual(ops.count("fix"), 4)
        self.assertEqual([x for x in ops if x.startswith("sleep:")],
                         ["sleep:5", "sleep:10", "sleep:20", "sleep:5", "sleep:5", "sleep:5"])

    def test_retry_delay_is_capped(self):
        self.env.update(FAIL_UNTIL="99", MAX_CYCLES="7")
        ops = self.run_daemon()
        self.assertEqual([x for x in ops if x.startswith("sleep:")],
                         ["sleep:5", "sleep:10", "sleep:20", "sleep:40", "sleep:60", "sleep:60", "sleep:60"])
        fields = (self.root / "tmp/8311-vlans.status").read_text().strip().split("\t")
        self.assertEqual(fields[4:], ["error", "apply", "60"])
        self.assertEqual(fields[2], "0")

    def test_failed_or_invalid_detection_never_applies_rules(self):
        for failure in ("DETECT_FAIL", "BAD_HASH"):
            with self.subTest(failure=failure):
                self.env[failure] = "1"
                ops = self.run_daemon()
                self.assertNotIn("fix", ops)
                self.ops.unlink()
                (self.root / "cycle").unlink()
                del self.env[failure]

    def test_enabling_while_idle_does_not_need_another_daemon(self):
        (self.root / "mode").write_text("0\n")
        self.env["SCENARIO"] = "enable"
        ops = self.run_daemon()
        self.assertEqual(ops.count("fix"), 1)
        self.assertEqual(ops.count("detect"), 3)

    def test_reload_invalidates_cached_local_vlan_settings(self):
        self.env["SCENARIO"] = "reload"
        ops = self.run_daemon()
        self.assertEqual(ops.count("fix"), 2)
        self.assertEqual(ops.count("fresh"), 2)
        self.assertNotIn("cached", ops)

    def test_changed_hook_is_detected_without_a_topology_change(self):
        (self.root / "ptconf/8311/vlan_fixes_hook.sh").write_text("# original hook\n")
        self.env["SCENARIO"] = "hook"
        ops = self.run_daemon()
        self.assertEqual(ops.count("fix"), 2)

    def test_busy_lock_does_not_remove_another_workers_cache(self):
        self.env["FIX_LOCK_BUSY"] = "1"
        cache = self.root / "tmp/8311-config.sh"
        cache.write_text("in use")
        (self.root / "tmp/8311-vlans.reload").touch()
        self.assertNotIn("fix", self.run_daemon())
        self.assertEqual(cache.read_text(), "in use")

    def test_hook_only_without_a_hook_reports_waiting(self):
        (self.root / "mode").write_text("2\n")
        self.assertNotIn("detect", self.run_daemon())
        fields = (self.root / "tmp/8311-vlans.status").read_text().strip().split("\t")
        self.assertEqual(fields[4:], ["waiting", "hook", "0"])

    def test_detection_recovery_resets_backoff_without_reapplying(self):
        self.env["DETECT_FAIL_CYCLES"] = "2,4"
        ops = self.run_daemon()
        self.assertEqual(ops.count("fix"), 1)
        self.assertEqual([x for x in ops if x.startswith("sleep:")], ["sleep:5"] * 4)

    def test_invalid_mode_reports_a_configuration_error(self):
        (self.root / "mode").write_text("3\n")
        self.assertNotIn("detect", self.run_daemon())
        fields = (self.root / "tmp/8311-vlans.status").read_text().strip().split("\t")
        self.assertEqual(fields[3:], ["unknown", "error", "configuration", "0"])

    def test_missing_pon_and_disabled_mode_do_not_report_success(self):
        (self.root / "sys/devices/virtual/net/gem-omci").rmdir()
        self.assertNotIn("detect", self.run_daemon())
        fields = (self.root / "tmp/8311-vlans.status").read_text().strip().split("\t")
        self.assertEqual(fields[4:], ["waiting", "pon", "0"])
        (self.root / "mode").write_text("0\n")
        self.run_daemon()
        fields = (self.root / "tmp/8311-vlans.status").read_text().strip().split("\t")
        self.assertEqual(fields[4:], ["disabled", "none", "0"])


if __name__ == "__main__":
    unittest.main()
