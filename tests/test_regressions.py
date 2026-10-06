"""Offline regressions: all firmware devices and commands are test fixtures."""
import base64
import hashlib
import io
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import struct
import sys
import tarfile
import tempfile
import time
import unittest
import zlib


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


def uimage_fixture(payload):
    header = bytearray(struct.pack(">7I4B32s", 0x27051956, 0, 0, len(payload), 0, 0,
                                   zlib.crc32(payload), 5, 5, 2, 0, b"fixture"))
    struct.pack_into(">I", header, 4, zlib.crc32(header))
    return header + payload


def squashfs_fixture():
    data = bytearray(128)
    data[:4] = b"hsqs"
    struct.pack_into("<I", data, 12, 262144)
    struct.pack_into("<HH", data, 28, 4, 0)
    struct.pack_into("<Q", data, 40, len(data))
    return data


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
        if os.name == "nt":
            self.command("python3", "exec " + shlex.quote(sys.executable.replace("\\", "/")) + ' "$@"')

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
        if path.read_text(encoding="utf-8").startswith("#!/bin/bash") and os.name != "nt":
            shell = [shutil.which("bash")]
        return subprocess.run(shell + [shell_path(path), *map(str, args)],
                              env=self.env, cwd=cwd or ROOT, input=stdin,
                              text=True, encoding="utf-8", capture_output=True, timeout=45)

    def operations(self):
        return self.ops.read_text().splitlines() if self.ops.exists() else []

    def limits(self):
        (self.root / "lib").mkdir(exist_ok=True)
        shutil.copyfile(ROOT / "files/common/lib/8311-limits.sh", self.root / "lib/8311-limits.sh")
        if os.name == "nt":
            # MSYS has no RLIMIT_FSIZE. Keep status/size checks; Linux CI exercises
            # the real kernel limit, including rapid output and pontop's side file.
            path = self.root / "lib/8311-limits.sh"
            path.write_text(path.read_text().replace('ulimit -f "$(( (bytes + unit - 1) / unit ))" || exit 126', ':'),
                            encoding="utf-8", newline="\n")
        self.command("8311-temp-space.sh", '[ "${SPACE_FAIL:-0}" = 0 ]')
        with (self.root / "lib/8311-limits.sh").open("a") as file:
            file.write('\nrequire_tmp_space() { [ "${SPACE_FAIL:-0}" = 0 ]; }\n')
            if os.name == "nt":
                # Native Windows Python cannot inherit an MSYS FIFO. Linux CI
                # runs the real shared helper, including the byte counter.
                file.write('''
stream_digest() {
    local directory="$1" algorithm="$2" expected="$3" result code=0
    shift 3
    "$@" > "$directory/stream" || { rm -f "$directory/stream"; return 1; }
    [ "$(wc -c < "$directory/stream")" -eq "$expected" ] || code=1
    result=$("$algorithm" < "$directory/stream") || code=1
    rm -f "$directory/stream"
    [ "$code" -eq 0 ] || return 1
    printf '%s\\n' "$result"
}
''')

    def binary_tools(self):
        helper = self.root / "binary_tools.py"
        helper.write_text('''import pathlib,sys,zlib
kind,*args=sys.argv[1:]
if kind == 'crc32':
    data=pathlib.Path(args[0]).read_bytes() if args else sys.stdin.buffer.read()
    # Match BusyBox: named inputs include the filename, stdin includes only CRC.
    print('%08x%s' % (zlib.crc32(data), ' '+args[0] if args else ''))
else:
    start=int(args[args.index('-s')+1]); length=int(args[args.index('-n')+1])
    print(pathlib.Path(args[-1]).read_bytes()[start:start+length].hex(),end='')
''', encoding="utf-8")
        for name in ("crc32", "hexdump"):
            self.command(name, "exec " + shlex.quote(sys.executable.replace("\\", "/")) + " " +
                         shlex.quote(shell_path(helper)) + " " + name + ' "$@"')

    def start_script(self, script, *args):
        return subprocess.Popen(shell_command() + [shell_path(script), *map(str, args)],
                                env=self.env, cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def wait_entered(self, process):
        deadline = time.monotonic() + 10
        while not (self.root / "entered").exists():
            if process.poll() is not None:
                self.fail("Worker exited before holding the lock: " + "".join(process.communicate()))
            if time.monotonic() >= deadline:
                self.fail("Worker did not enter its critical section")
            time.sleep(0.01)


class UpgradeTests(ShellFixture):
    def setUp(self):
        super().setUp()
        self.upgrade = self.script("files/common/usr/sbin/8311-firmware-upgrade.sh", True)
        self.limits()
        self.binary_tools()
        (self.root / "dev").mkdir()
        (self.root / "proc").mkdir()
        (self.root / "proc/cmdline").write_text("console=ttyS0 rootfsname=rootfsA\n")
        (self.root / "env").mkdir()
        (self.root / "env/commit_bank").write_text("A")
        self.command("flock", '[ "${LOCK_FAIL:-0}" = 0 ]')
        self.command("ubinfo", '''
[ "${MISSING_VOLUME:-}" != "$3" ] || exit 1
case "$3" in
    kernelA) id=0 ;; bootcoreA) id=1 ;; rootfsA) id=2 ;;
    kernelB) id=3 ;; bootcoreB) id=4 ;; rootfsB) id=5 ;;
    *) exit 1 ;;
esac
if [ "${REMAPPED_A:-0}" = 1 ]; then
    case "$3" in bootcoreA) id=2 ;; rootfsA) id=1 ;; esac
fi
capacity=4096
[ "$3" != rootfsB ] || capacity=${ROOTFS_CAPACITY:-4096}
printf 'Volume ID: %s\nSize: 1 LEBs (%s bytes, 4 KiB)\n' "$id" "$capacity"
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
[ "${ENV_FAIL_KEY:-}" != "$1" ] || exit 8
printf '%s' "$2" > "$FIXTURE/env/$1"
''')
        self.command("fw_printenv", 'cat "$FIXTURE/env/$2" 2>/dev/null')
        self.command("reboot", 'echo reboot >> "$OPS"')
        self.command("sleep", ":")
        # A test must fail loudly if a new destructive command escapes its mocks.
        for name in ("ubimkvol", "ubirsvol", "mtd"):
            self.command(name, 'echo unexpected-write >> "$OPS"; exit 99')

    def archive(self, overrides=None, omit=None, corrupt=None, extra="", images_override=None):
        images = {"kernel.bin": uimage_fixture(b"kernel fixture\x00\xff"),
                  "bootcore.bin": uimage_fixture(b"bootcore fixture"), "rootfs.img": squashfs_fixture()}
        images.update(images_override or {})
        control = {"FW_VERSION": "test", "FW_REVISION": "fixture", "FW_VARIANT": "basic"}
        for name, data in images.items():
            key = name.split(".")[0].upper()
            control["SIZE_" + key] = str(len(data))
            control["SHA256_" + key] = hashlib.sha256(data).hexdigest()
        control.update(overrides or {})
        if corrupt:
            images[corrupt] += b"corrupt"
        members = {"control": ("".join(f"{key}={value}\n" for key, value in control.items()) + extra).encode(), **images}
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
        self.assertEqual(self.operations()[:2], ["env:img_validB:false"] * 2)
        self.assertEqual([line.rsplit("_", 1)[-1] for line in self.operations()[2:5]], ["3", "4", "5"])
        self.assertEqual(self.operations()[5:], ["env:img_validB:true"] * 2 + ["env:commit_bank:B"] * 2)
        self.assert_clean_stage()
        self.assertTrue((self.root / "tmp/8311-firmware-upgrade.lock").exists())

    def test_failed_boot_environment_reads_stop_before_component_writes(self):
        self.command("fw_printenv", 'cat "$FIXTURE/env/$2" 2>/dev/null; [ "$2" != "$READ_FAIL_KEY" ] || exit 7')
        for key in ("commit_bank", "img_validB"):
            with self.subTest(key=key):
                self.env["READ_FAIL_KEY"] = key
                self.ops.unlink(missing_ok=True)
                result = self.run_script(self.upgrade, "--install", "--yes", "--no-commit", self.archive())
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(any(item.startswith("write:") for item in self.operations()))
                self.assert_clean_stage()

    def test_install_from_bank_b_targets_bank_a(self):
        (self.root / "proc/cmdline").write_text("rootfsname=rootfsB\n")
        (self.root / "env/commit_bank").write_text("B")
        result = self.run_script(self.upgrade, "--install", "--yes", self.archive())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([line.rsplit("_", 1)[-1] for line in self.operations() if line.startswith("write:")], ["0", "1", "2"])

    def test_declining_commit_keeps_boot_bank_and_uses_volume_names(self):
        (self.root / "proc/cmdline").write_text("rootfsname=rootfsB\n")
        (self.root / "env/commit_bank").write_text("B")
        self.env["REMAPPED_A"] = "1"
        result = self.run_script(self.upgrade, "--install", self.archive(), stdin="y\nn\n")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual([line.rsplit("_", 1)[-1] for line in self.operations() if line.startswith("write:")], ["0", "2", "1"])
        self.assertNotIn("env:commit_bank:A", self.operations())
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

    def test_metadata_limits_target_and_formats_fail_before_any_write(self):
        bad_crc = uimage_fixture(b"payload")
        bad_crc[-1] ^= 1
        for kwargs in ({"overrides": {"FW_VARIANT": "other"}},
                       {"overrides": {"FW_TARGET": "OTHER-ONT"}},
                       {"extra": "FW_VERSION=duplicate\n"},
                       {"extra": "UNKNOWN=" + "x" * 5000 + "\n"},
                       {"overrides": {"SIZE_ROOTFS": "33554433"}},
                       {"overrides": {"SIZE_KERNEL": "0080"}},
                       {"images_override": {"rootfs.img": b"x" * 128}},
                       {"images_override": {"kernel.bin": b"x" * 128}},
                       {"images_override": {"kernel.bin": bad_crc}}):
            with self.subTest(kwargs=list(kwargs)):
                result = self.run_script(self.upgrade, "--install", "--yes", self.archive(**kwargs))
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertEqual(self.operations(), [])
                self.assert_clean_stage()

    def test_insufficient_space_rejects_before_any_write(self):
        self.env["SPACE_FAIL"] = "1"
        result = self.run_script(self.upgrade, "--install", "--yes", self.archive())
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.operations(), [])

    def test_missing_or_undersized_last_volume_is_rejected_before_any_write(self):
        for key, value in (("MISSING_VOLUME", "rootfsB"), ("ROOTFS_CAPACITY", "96")):
            self.env[key] = value
            result = self.run_script(self.upgrade, "--install", "--yes", self.archive())
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(self.operations(), [])
            del self.env[key]

    def test_readback_reader_failure_cannot_mark_a_bank_valid_even_with_correct_bytes(self):
        self.command("head", '''
PATH=${PATH#*:} head "$@" || exit $?
case "$3" in "$FIXTURE"/dev/*) exit 7 ;; esac
''')
        result = self.run_script(self.upgrade, "--install", "--yes", self.archive())
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.root / "env/img_validB").read_text(), "false")
        self.assertNotIn("env:img_validB:true", self.operations())

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
                    self.assertEqual([line for line in self.operations() if line.startswith("env:")], ["env:img_validB:false"] * 2)
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

    def test_validation_no_longer_spawns_metadata_grep_and_cut_commands(self):
        for name in ("grep", "cut"):
            self.command(name, f'echo {name} >> "$OPS"; PATH=${{PATH#*:}} {name} "$@"')
        result = self.run_script(self.upgrade, "--validate", self.archive())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.operations(), [])

    def test_cancel_returns_distinct_status_without_writes(self):
        result = self.run_script(self.upgrade, "--install", self.archive(), stdin="n\n")
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertEqual(self.operations(), [])

    def test_web_install_preserves_default_and_trial_only_changes_one_boot_selection(self):
        for trial in (False, True):
            with self.subTest(trial=trial):
                args = ["--install", "--yes", "--no-commit"] + (["--trial"] if trial else [])
                result = self.run_script(self.upgrade, *args, self.archive())
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual((self.root / "env/commit_bank").read_text(), "A")
                self.assertEqual((self.root / "env/img_activate").exists(), trial)
                if trial:
                    self.assertEqual((self.root / "env/img_activate").read_text(), "B")

    def test_trial_session_cannot_overwrite_its_default_bank(self):
        (self.root / "env/commit_bank").write_text("B")
        result = self.run_script(self.upgrade, "--install", "--yes", "--no-commit", self.archive())
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.operations(), [])

    def test_reboot_without_commit_requires_an_explicit_trial_before_any_writes(self):
        result = self.run_script(self.upgrade, "--install", "--yes", "--no-commit", "--reboot", self.archive())
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.operations(), [])

    def test_failed_final_commit_keeps_old_default_and_never_reboots(self):
        self.env["ENV_FAIL_KEY"] = "commit_bank"
        result = self.run_script(self.upgrade, "--install", "--yes", "--reboot", self.archive())
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.root / "env/commit_bank").read_text(), "A")
        self.assertEqual((self.root / "env/img_validB").read_text(), "true")
        self.assertNotIn("reboot", self.operations())

    @unittest.skipUnless(sys.platform == "linux", "Requires real Linux flock")
    def test_real_upgrade_processes_cannot_overlap(self):
        (self.bin / "flock").unlink()
        self.command("ubiupdatevol", '''
echo "write:$3" >> "$OPS"
touch "$FIXTURE/entered"
while [ ! -f "$FIXTURE/release" ]; do /bin/sleep 0.02; done
cat > "$3"
''')
        archive = self.archive()
        first = self.start_script(self.upgrade, "--install", "--yes", archive)
        try:
            self.wait_entered(first)
            before = self.operations()
            second = self.run_script(self.upgrade, "--install", "--yes", archive)
            self.assertNotEqual(second.returncode, 0)
            self.assertIn("already in progress", second.stderr)
            self.assertEqual(self.operations(), before)
        finally:
            (self.root / "release").touch()
            stdout, stderr = first.communicate(timeout=10)
        self.assertEqual(first.returncode, 0, stdout + stderr)
        self.assertEqual(len([op for op in self.operations() if op.startswith("write:")]), 3)


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


class RuleFingerprintTests(ShellFixture):
    def setUp(self):
        super().setUp()
        self.fingerprint = self.script("files/common/usr/sbin/8311-vlan-rules-hash.sh", True)
        (self.root / "sys/class/net/eth0_0").mkdir(parents=True)
        self.command("tc", "printf '%s\\n' 'filter vlan_id 41' '  index 3 ref 1 bind 1'")

    def test_normalization_produces_one_structural_fingerprint(self):
        result = self.run_script(self.fingerprint)
        expected = hashlib.sha256(b"eth0_0 ingress\nfilter vlan_id 41\neth0_0 egress\nfilter vlan_id 41\n").hexdigest()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, expected + "\n")
        self.assertEqual(list((self.root / "tmp").iterdir()), [])

    def test_normalization_failure_never_fingerprints_empty_input(self):
        self.command("sed", "exit 7")
        result = self.run_script(self.fingerprint)
        self.assertNotEqual(result.returncode, 0, "normalization failure became a successful empty hash")
        self.assertEqual(result.stdout, "")

    def test_hash_failure_and_mixed_diagnostics_are_rejected(self):
        for output, code in (("0" * 64 + "  file", 7),
                             ("diagnostic\\n" + "0" * 64 + "  file", 0)):
            with self.subTest(output=output, code=code):
                self.command("sha256sum", f"printf '%b\\n' '{output}'; exit {code}")
                result = self.run_script(self.fingerprint)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")

    def test_normalization_file_creation_or_write_failure_propagates(self):
        (self.root / "unwritable").mkdir()
        for action in ("exit 7", 'echo "$FIXTURE/unwritable"'):
            self.command("mktemp", f'''
case "$1" in *normalized*) {action} ;;
*) PATH=${{PATH#*:}} mktemp "$@" ;; esac
''')
            result = self.run_script(self.fingerprint)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, "")


class SupportTests(ShellFixture):
    def setUp(self):
        super().setUp()
        self.support = self.script("files/common/usr/sbin/8311-support.sh", True)
        self.limits()
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

    def test_real_tc_dump_failure_never_publishes_partial_raw_support(self):
        dump = self.script("files/common/usr/sbin/8311-tc-filter-dump.sh")
        shutil.copyfile(dump, self.bin / "8311-tc-filter-dump.sh")
        self.command("ip", 'echo "1: eth0_0: <UP>"; [ "${QUERY_FAIL:-}" != ip ] || exit 7')
        self.command("tc", 'echo "filter fixture"; [ "${QUERY_FAIL:-}" != tc ] || exit 7')
        for command in ("ip", "tc"):
            with self.subTest(command=command):
                self.env["QUERY_FAIL"] = command
                result = self.run_script(self.support, "--raw")
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((self.root / "tmp/support.tar.gz").exists())
        del self.env["QUERY_FAIL"]
        result = self.run_script(self.support, "--raw")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("filter fixture", self.contents()["support/tc_filters.txt"])
        self.command("ip", "exit 0")
        self.assertEqual(self.run_script(self.support, "--raw").returncode, 0)
        self.assertEqual(self.contents()["support/tc_filters.txt"], "")

    def test_deletion_uses_the_same_generation_lock(self):
        archive = self.root / "tmp/support.tar.gz"
        archive.write_bytes(b"fixture")
        self.command("flock", "exit 1")
        self.assertNotEqual(self.run_script(self.support, "--delete").returncode, 0)
        self.assertTrue(archive.exists())
        self.command("flock", ":")
        result = self.run_script(self.support, "--delete")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(archive.exists())

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

    def test_fast_output_growth_and_space_failure_never_publish_an_archive(self):
        for source in ("fw_printenv", "omci_pipe.sh", "pontop", "logread"):
            with self.subTest(source=source):
                self.command(source, 'head -c 2097152 /dev/zero' +
                             (' > "$FIXTURE/tmp/pontop.txt"' if source == "pontop" else ""))
                result = self.run_script(self.support, "--raw")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Output limit exceeded", result.stderr)
                self.assertFalse((self.root / "tmp/support.tar.gz").exists())
                self.command(source, 'echo fixture' +
                             (' > "$FIXTURE/tmp/pontop.txt"' if source == "pontop" else ""))
        self.env["SPACE_FAIL"] = "1"
        self.assertNotEqual(self.run_script(self.support).returncode, 0)
        self.assertFalse((self.root / "tmp/support.tar.gz").exists())

    def test_timeout_and_partial_failed_query_are_distinct(self):
        for code, message in ((124, "Query timed out"), (7, "Query failed")):
            self.command("8311-extvlan-decode.sh", f"echo partial; exit {code}")
            result = self.run_script(self.support)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(message, result.stderr)
            self.assertFalse((self.root / "tmp/support.tar.gz").exists())

    @unittest.skipUnless(sys.platform == "linux", "Requires real Linux flock")
    def test_real_generation_excludes_deletion_and_another_generator(self):
        (self.bin / "flock").unlink()
        self.command("fw_printenv", '''
touch "$FIXTURE/entered"
while [ ! -f "$FIXTURE/release" ]; do /bin/sleep 0.02; done
echo 8311_fix_vlans=1
''')
        first = self.start_script(self.support)
        try:
            self.wait_entered(first)
            for args in ((), ("--delete",)):
                second = self.run_script(self.support, *args)
                self.assertNotEqual(second.returncode, 0)
                self.assertIn("already in progress", second.stderr)
        finally:
            (self.root / "release").touch()
            stdout, stderr = first.communicate(timeout=10)
        self.assertEqual(first.returncode, 0, stdout + stderr)
        self.assertEqual(self.run_script(self.support, "--delete").returncode, 0)

    @unittest.skipUnless(sys.platform == "linux", "Requires Linux locks and real timeout")
    def test_timeout_descendants_never_allow_overlapping_support_work(self):
        import fcntl
        (self.bin / "flock").unlink()
        timeout = [shutil.which("busybox"), "timeout"] if os.environ.get("TEST_SHELL") == "busybox" else [shutil.which("timeout")]
        self.command("timeout", 'shift 2; shift; exec ' + " ".join(map(shlex.quote, timeout)) + ' -k 1 1 "$@"')
        self.command("fw_printenv", '/bin/sleep 3 & wait')
        result = self.run_script(self.support)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Query timed out", result.stderr)
        with (self.root / "tmp/8311-support.lock").open("a") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                # Some BusyBox versions signal only the immediate command. Its
                # surviving child must retain the lock until it finishes.
                second = self.run_script(self.support, "--delete")
                self.assertNotEqual(second.returncode, 0)
                deadline = time.monotonic() + 4
                while True:
                    try:
                        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                        break
                    except BlockingIOError:
                        self.assertLess(time.monotonic(), deadline)
                        time.sleep(0.02)


@unittest.skipUnless(sys.platform == "linux", "Requires real POSIX record locks")
class ConfigurationConcurrencyTests(ShellFixture):
    def test_save_and_restore_share_a_real_lock_in_both_orders(self):
        for first_action, second_action in (("save", "restore"), ("restore", "save")):
            with self.subTest(first=first_action):
                for name in ("entered", "release", "writers"):
                    (self.root / name).unlink(missing_ok=True)
                command = [sys.executable, str(ROOT / "tests/config_lock_worker.py"), str(self.root)]
                first = subprocess.Popen(command + [first_action], cwd=ROOT, env=self.env,
                                         text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                try:
                    self.wait_entered(first)
                    second = subprocess.run(command + [second_action], cwd=ROOT, env=self.env,
                                            text=True, capture_output=True, timeout=4)
                    self.assertEqual(second.returncode, 0, second.stderr)
                    self.assertEqual(json.loads(second.stdout)["status"], 409)
                    self.assertEqual((self.root / "writers").read_text().splitlines(), [first_action])
                finally:
                    (self.root / "release").touch()
                    stdout, stderr = first.communicate(timeout=10)
                self.assertEqual(first.returncode, 0, stderr)
                self.assertEqual(json.loads(stdout), {"status": 200, "success": True})


class TempSpaceTests(ShellFixture):
    def setUp(self):
        super().setUp()
        self.space = self.script("files/common/usr/sbin/8311-temp-space.sh", True)
        library = self.script("files/common/lib/8311-limits.sh", True)
        (self.root / "lib").mkdir()
        shutil.copyfile(library, self.root / "lib/8311-limits.sh")
        (self.root / "proc").mkdir()
        self.command("df", "printf 'Filesystem Blocks Used Available Capacity Mounted\\nfixture %s %s %s 0%% /tmp\\n' \"${TOTAL_KB:-0}\" \"${USED_KB:-0}\" \"${DISK_KB:-0}\"")

    def check_space_report(self, total, used, available, succeeds):
        (self.root / "proc/meminfo").write_text("MemAvailable: 262144 kB\n")
        self.env.update(TOTAL_KB=str(total), USED_KB=str(used), DISK_KB=str(available))
        result = self.run_script(self.space, "16777216")
        self.assertEqual(result.returncode == 0, succeeds, result.stdout + result.stderr)

    def test_zero_total_capacity_uses_memory_budget(self):
        self.check_space_report(0, 0, 0, True)

    def test_full_finite_filesystem_is_rejected(self):
        self.check_space_report(32768, 32768, 0, False)

    def test_insufficient_finite_filesystem_is_rejected(self):
        self.check_space_report(32768, 31744, 1024, False)

    def test_sufficient_finite_filesystem_is_accepted(self):
        self.check_space_report(65536, 32768, 32768, True)

    def test_inconsistent_or_malformed_capacity_reports_fail_closed(self):
        for total, available in ((0, 1), (1024, 2048), ("bad", 0), (32768, ""), (32768, "bad")):
            with self.subTest(total=total, available=available):
                self.check_space_report(total, 0, available, False)

    def test_memory_budget_handles_zero_block_tmp_and_finite_filesystem(self):
        (self.root / "proc/meminfo").write_text("MemAvailable: 65536 kB\n")
        self.assertEqual(self.run_script(self.space, "1048576").returncode, 0)
        self.env["TOTAL_KB"] = "131072"
        self.env["DISK_KB"] = "8192"
        self.assertNotEqual(self.run_script(self.space, "1048576").returncode, 0)
        self.env["DISK_KB"] = "100000"
        self.assertNotEqual(self.run_script(self.space, "60000000").returncode, 0)

    def test_old_kernel_memory_fallback_and_unreadable_stats_fail_closed(self):
        (self.root / "proc/meminfo").write_text("MemFree: 16000 kB\nBuffers: 2000 kB\nCached: 10000 kB\nShmem: 8000 kB\n")
        self.assertEqual(self.run_script(self.space, "1048576").returncode, 0)
        self.assertNotEqual(self.run_script(self.space, "16000000").returncode, 0)
        (self.root / "proc/meminfo").unlink()
        self.assertNotEqual(self.run_script(self.space, "1048576").returncode, 0)


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
        self.limits()
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
echo present > "$FIXTURE/live-rules"
''')
        self.command("8311-vlan-rules-hash.sh", '''
[ "${RULE_READ_FAIL:-0}" = 0 ] || exit 4
count=$(cat "$FIXTURE/rule-reads" 2>/dev/null || echo 0)
count=$((count+1)); echo "$count" > "$FIXTURE/rule-reads"
[ "${RULE_FAIL_AT:-0}" != "$count" ] || exit 4
[ "${MIXED_RULE_HASH:-0}" = 0 ] || echo diagnostic
if [ -f "$FIXTURE/live-rules" ]; then printf '%064d\\n' 1; else printf '%064d\\n' 2; fi
''')
        for name in ("8311-detect-config.sh", "8311-fix-vlans.sh", "8311-vlan-rules-hash.sh"):
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

    def test_oversized_apply_output_is_rejected_then_retried(self):
        fixer = self.root / "usr/sbin/8311-fix-vlans.sh"
        fixer.write_text(fixer.read_text().replace('echo fix >> "$OPS"', '''
if [ ! -f "$FIXTURE/large-output-seen" ]; then
    touch "$FIXTURE/large-output-seen"
    head -c 2097152 /dev/zero
    exit 0
fi
echo fix >> "$OPS"
'''), newline="\n")
        sleep = self.bin / "sleep"
        sleep.write_text(sleep.read_text().replace('if [ "$cycle" = 1 ]; then', '''
if [ "$cycle" = 1 ]; then
    cp "$FIXTURE/tmp/8311-vlans.status" "$FIXTURE/first-status"
    for file in "$FIXTURE"/tmp/8311-vlans.*; do
        [ -f "$file" ] || continue
        wc -c < "$file" >> "$FIXTURE/first-sizes"
    done
'''), newline="\n")
        ops = self.run_daemon()
        first = (self.root / "first-status").read_text().strip().split("\t")
        self.assertEqual(first[2], "0")
        self.assertEqual(first[4:6], ["error", "apply"])
        self.assertLessEqual(max(map(int, (self.root / "first-sizes").read_text().split())), 1048576)
        self.assertEqual(ops.count("fix"), 1)
        final = (self.root / "tmp/8311-vlans.status").read_text().strip().split("\t")
        self.assertEqual(final[4:], ["applied", "none", "0"])

    def test_excessive_stderr_is_also_rejected(self):
        detector = self.root / "usr/sbin/8311-detect-config.sh"
        detector.write_text('#!/bin/sh\nhead -c 2097152 /dev/zero >&2\nprintf "%064d\\n" 1\n', newline="\n")
        self.env["MAX_CYCLES"] = "1"
        self.assertNotIn("fix", self.run_daemon())
        fields = (self.root / "tmp/8311-vlans.status").read_text().strip().split("\t")
        self.assertEqual(fields[4:6], ["error", "detect"])

    @unittest.skipUnless(sys.platform == "linux", "Requires the kernel file size limit")
    def test_detector_side_files_inherit_the_size_limit(self):
        detector = self.root / "usr/sbin/8311-detect-config.sh"
        detector.write_text('''#!/bin/sh
head -c 2097152 /dev/zero > "$FIXTURE/tmp/detector-side-file" || exit 7
printf '%064d\\n' 1
''', newline="\n")
        self.env["MAX_CYCLES"] = "1"
        self.assertNotIn("fix", self.run_daemon())
        self.assertLessEqual((self.root / "tmp/detector-side-file").stat().st_size, 1048576)
        fields = (self.root / "tmp/8311-vlans.status").read_text().strip().split("\t")
        self.assertEqual(fields[4:6], ["error", "detect"])

    @unittest.skipUnless(sys.platform == "linux", "Requires real Linux flock and timeout")
    def test_timeout_descendants_preserve_exclusion_and_allow_later_recovery(self):
        import fcntl
        (self.bin / "flock").unlink()
        timeout = [shutil.which("busybox"), "timeout"] if os.environ.get("TEST_SHELL") == "busybox" else [shutil.which("timeout")]
        native = " ".join(map(shlex.quote, timeout))
        self.command("timeout", 'if [ "$2" = 5 ]; then shift 3; exec ' + native + ' -k 1 1 "$@"; fi\nexec ' + native + ' "$@"')
        fixer = self.root / "usr/sbin/8311-fix-vlans.sh"
        fixer.write_text('''#!/bin/sh
echo entered >> "$OPS"
/bin/sleep 3 & wait
''', newline="\n")
        self.env["MAX_CYCLES"] = "1"
        self.run_daemon()
        with (self.root / "tmp/8311-fix-vlans.lock").open("a") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                # A BusyBox timeout may leave a descendant alive. It must keep
                # the lock until exiting, so a second monitor cannot overlap.
                before = self.operations().count("entered")
                self.run_daemon()
                self.assertEqual(self.operations().count("entered"), before)
                deadline = time.monotonic() + 4
                while True:
                    try:
                        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                        break
                    except BlockingIOError:
                        self.assertLess(time.monotonic(), deadline)
                        time.sleep(0.02)
        fixer.write_text('#!/bin/sh\necho recovered >> "$OPS"\n', newline="\n")
        self.run_daemon()
        self.assertEqual(self.operations().count("recovered"), 1)
        fields = (self.root / "tmp/8311-vlans.status").read_text().strip().split("\t")
        self.assertEqual(fields[4:], ["applied", "none", "0"])

    def test_real_detector_failure_is_retried_without_applying_partial_state(self):
        from test_topology import staged_scripts
        staged = staged_scripts(self)
        detector = self.script(staged / "8311-detect-config.sh", True)
        shutil.copy2(detector, self.root / "usr/sbin/8311-detect-config.sh")
        self.command("brctl", "printf 'bridge fixture\\n'")
        self.command("ip", '''
cycle=$(cat "$FIXTURE/cycle" 2>/dev/null || echo 0)
printf 'link fixture\\n'
[ "$cycle" -ge "${FAIL_CYCLES:-99}" ]
''')
        self.assertNotIn("fix", self.run_daemon())
        fields = (self.root / "tmp/8311-vlans.status").read_text().strip().split("\t")
        self.assertEqual(fields[4:6], ["error", "detect"])
        for name in ("operations", "cycle"):
            (self.root / name).unlink()
        self.env["FAIL_CYCLES"] = "1"
        ops = self.run_daemon()
        self.assertEqual(ops.count("fix"), 1)
        self.assertEqual([x for x in ops if x.startswith("sleep:")], ["sleep:5"] * 4)
        fields = (self.root / "tmp/8311-vlans.status").read_text().strip().split("\t")
        self.assertEqual(fields[4:], ["applied", "none", "0"])

    def test_mixed_rule_output_is_rejected_and_transient_failure_keeps_last_success(self):
        self.env["MIXED_RULE_HASH"] = "1"
        self.run_daemon()
        fields = (self.root / "tmp/8311-vlans.status").read_text().strip().split("\t")
        self.assertEqual(fields[4:6], ["error", "rules"])
        del self.env["MIXED_RULE_HASH"]
        for name in ("operations", "cycle", "rule-reads", "fixes"):
            (self.root / name).unlink(missing_ok=True)
        self.env.update(MAX_CYCLES="9", RULE_FAIL_AT="2")
        ops = self.run_daemon()
        self.assertEqual(ops.count("fix"), 1, "failed snapshot caused a redundant rule application")
        fields = (self.root / "tmp/8311-vlans.status").read_text().strip().split("\t")
        self.assertEqual(fields[4:], ["applied", "none", "0"])
        self.assertGreater(int(fields[2]), 0)

    def test_lost_rules_are_restored_without_a_topology_change(self):
        self.env["MAX_CYCLES"] = "9"
        sleep = self.bin / "sleep"
        sleep.write_text(sleep.read_text().replace('if [ "$cycle" = 1 ]; then',
            'if [ "$cycle" = 1 ]; then\n    rm -f "$FIXTURE/live-rules"'), newline="\n")
        ops = self.run_daemon()
        self.assertEqual(ops.count("fix"), 2)
        self.assertTrue((self.root / "live-rules").exists())

    def test_interface_reappearance_forces_a_fresh_apply(self):
        sleep = self.bin / "sleep"
        sleep.write_text(sleep.read_text().replace('if [ "$cycle" = 1 ]; then', '''
if [ "$cycle" = 2 ]; then mkdir "$FIXTURE/sys/devices/virtual/net/gem-omci"; fi
if [ "$cycle" = 1 ]; then
    rmdir "$FIXTURE/sys/devices/virtual/net/gem-omci"
    rm -f "$FIXTURE/live-rules"
'''), newline="\n")
        self.assertEqual(self.run_daemon().count("fix"), 2)
        self.assertTrue((self.root / "live-rules").exists())

    def test_rule_read_failures_never_report_a_confirmed_application(self):
        self.env["RULE_READ_FAIL"] = "1"
        self.run_daemon()
        fields = (self.root / "tmp/8311-vlans.status").read_text().strip().split("\t")
        self.assertEqual(fields[2], "0")
        self.assertEqual(fields[4:6], ["error", "rules"])

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
