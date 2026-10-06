"""Edge cases in firmware helpers, using ordinary files and isolated commands."""
import base64
import importlib.util
import shlex
import unittest

from test_regressions import ROOT, ShellFixture, shell_path


class HelperTests(ShellFixture):
    def test_failed_environment_reader_discards_partial_values(self):
        script = self.script("files/common/usr/sbin/fwenv_get")
        self.command("fw_printenv", 'printf "%s" "$VALUE"; exit 7')
        for encoded in (False, True):
            self.env["VALUE"] = "Qg==" if encoded else "B"
            for default in ("", "fallback"):
                with self.subTest(encoded=encoded, default=default):
                    result = self.run_script(script, *(["--base64"] if encoded else []), "--", "test", default)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(result.stdout, default + "\n" if default else "")

    def source_and_run(self, path, body):
        runner = self.root / "run-helper.sh"
        runner.write_text('. ' + shlex.quote(shell_path(path)) + '\n' + body, newline="\n")
        return self.run_script(runner)

    def test_environment_getter_preserves_options_backslashes_and_unicode(self):
        script = self.script("files/common/usr/sbin/fwenv_get")
        self.command("fw_printenv", 'printf "%s" "$VALUE"')
        for value in ("-n", r"literal\n\t\\", "猫棒配置", "a=b&c"):
            for encoded in (False, True):
                with self.subTest(value=value, encoded=encoded):
                    self.env["VALUE"] = base64.b64encode(value.encode()).decode() if encoded else value
                    result = self.run_script(script, *(["--base64"] if encoded else []), "test")
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout, value + "\n")

    def test_signed_byte_includes_the_minimum_negative_value(self):
        script = self.script("files/common/lib/functions/int.sh")
        result = self.source_and_run(script, 'int8 127\nint8 128\nint8 255\n')
        self.assertEqual(result.stdout.splitlines(), ["127", "-128", "-1"])

    def test_version_fallback_and_setters_use_only_valid_arguments(self):
        script = self.script("files/common/lib/8311.sh", True)
        (self.root / "lib/functions").mkdir(parents=True)
        for name in ("pon.sh", "8311_backend.sh", "functions/hexbin.sh"):
            (self.root / "lib" / name).write_text(":\n")
        result = self.source_and_run(script, '''
fwenv_get_8311() { [ "$1" = sw_verA ] && printf 'version-a'; }
to_console() { cat >/dev/null; }
_set_8311_sw_ver() { printf '%s:%s\n' "$1" "$2" >> "$OPS"; }
get_8311_sw_ver B
printf '\n'
set_8311_sw_ver C invalid && exit 99
set_8311_sw_ver A '' && exit 99
set_8311_sw_ver B valid
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "version-a\n")
        self.assertEqual(self.operations(), ["B:valid"])

    def test_mib_replacements_preserve_sed_metacharacters(self):
        script = self.script("files/common/lib/8311.sh", True)
        (self.root / "lib/functions").mkdir(parents=True)
        for name in ("pon.sh", "8311_backend.sh", "functions/hexbin.sh"):
            (self.root / "lib" / name).write_text(":\n")
        mib = self.root / "mib"
        mib.write_text('256 0 "vendor" "old" 1\n')
        result = self.source_and_run(script, '''
_mib_file() { printf '%s/mib' "$FIXTURE"; }
_mib_update 256 2 '"R&D#1\\rev"'
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(mib.read_text(), '256 0 "vendor" "R&D#1\\rev" 1\n')

    def test_bfw_setters_do_not_depend_on_callers_global_variables(self):
        script = self.script("files/bfw/lib/8311_backend.sh")
        self.command("uci", 'printf "%s\n" "$*" >> "$OPS"')
        runner = self.root / "run-helper.sh"
        runner.write_text('_lib_8311() { :; }\n. ' + shlex.quote(shell_path(script)) + '''
HW_VERSION=wrong LCT_MAC=wrong
_set_8311_hw_ver revision-2
_set_8311_lct_mac 00:11:22:33:44:55
''', newline="\n")
        result = self.run_script(runner)
        self.assertEqual(result.returncode, 0, result.stderr)
        output = "\n".join(self.operations())
        self.assertIn("sysinfo_conf.HardwareVersion.value=revision-2", output)
        self.assertIn("factory_conf.brmac.value=00:11:22:33:44:55", output)
        self.assertNotIn("wrong", output)

    def test_me_list_escapes_device_text_before_adding_controlled_links(self):
        script = self.script("files/basic/usr/bin/luci-me-dump")
        self.command("omci_pipe.sh", "printf '%s\\n' '| 256 | 0 | <img src=x>&text'\n")
        result = self.run_script(script)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('showPonMe(256, 0)', result.stdout)
        self.assertIn('&lt;img src=x&gt;&amp;text', result.stdout)
        self.assertNotIn('<img', result.stdout)
        self.command("omci_pipe.sh", "exit 1")
        self.assertNotEqual(self.run_script(script).returncode, 0)


class ExtendedVlanTests(ShellFixture):
    def setUp(self):
        super().setUp()
        library = self.script("files/common/lib/8311-omci-lib.sh")
        self.library = library
        decoder = self.script("files/common/usr/sbin/8311-extvlan-decode.sh")
        self.command("omci_pipe.sh", 'printf "%s\\n" "${ME_LIST:-empty}"; [ "${OMCI_FAIL:-0}" = 0 ] || exit 7')
        # Model the external matcher's documented statuses: 0 match, 1 none, 2 error.
        self.command("pcre2grep", '''
IFS= read -r listing || exit 1
case "$listing" in empty) exit 1 ;; table) echo 0 ;; *) exit 2 ;; esac
''')
        self.runner = self.root / "decode-vlans.sh"
        self.runner.write_text('''
_lib_int() { :; }
_lib_hexbin() { :; }
. ''' + shlex.quote(shell_path(library)) + '''
omci="$TEST_BIN/omci_pipe.sh"
pcre="$TEST_BIN/pcre2grep"
mibattrdata() {
    [ "${ATTR_FAIL:-0}" = 0 ] || return 8
    echo 00000000000000000000000000000000
}
. ''' + shlex.quote(shell_path(decoder)) + '\n', newline="\n")

    def test_absent_extended_vlan_tables_are_a_successful_empty_result(self):
        for args in ((), ("-t",)):
            with self.subTest(args=args):
                result = self.run_script(self.runner, *args)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, "No Extended VLAN Tables Detected\n")

    def test_failed_reads_never_become_empty_success_or_partial_tables(self):
        for failure in ("OMCI_FAIL", "ATTR_FAIL"):
            with self.subTest(failure=failure):
                self.env.update(ME_LIST="table", **{failure: "1"})
                result = self.run_script(self.runner, "-t")
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("No Extended VLAN Tables Detected", result.stdout)
                del self.env[failure]

    def test_present_table_decodes_and_matcher_errors_are_rejected(self):
        self.env["ME_LIST"] = "table"
        result = self.run_script(self.runner, "-t")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Extended VLAN table 0\n", result.stdout)
        self.assertIn("\t".join(["0"] * 15) + "\n", result.stdout)
        self.env["ME_LIST"] = "parser-error"
        self.assertNotEqual(self.run_script(self.runner).returncode, 0)

    def test_attribute_helpers_reject_partial_output_from_failed_reads(self):
        self.command("attribute-parser", "echo '16 TBL'")
        for operation, upstream in (("mibattr", "mib"), ("mibattrdata", "mibattr")):
            with self.subTest(operation=operation):
                self.runner.write_text('''
_lib_int() { :; }
_lib_hexbin() { :; }
. ''' + shlex.quote(shell_path(self.library)) + '\n' + upstream + '''() { echo partial; return 7; }
pcre="$TEST_BIN/attribute-parser"
''' + operation + ' 171 0 6\n', newline="\n")
                result = self.run_script(self.runner)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")


class AlternateInfoTests(ShellFixture):
    def setUp(self):
        super().setUp()
        self.info = self.script("files/common/usr/sbin/alternate_firmware_info", True)
        # Replace the device-type check only; no real device is ever opened.
        self.info.write_text(self.info.read_text().replace('[ ! -b "$MTDALTBLOCK" ]', '[ ! -f "$MTDALTBLOCK" ]'), newline="\n")
        for folder in ("lib", "proc", "dev"):
            (self.root / folder).mkdir()
        (self.root / "lib/8311.sh").write_text('inactive_fwbank() { echo B; }\n')
        (self.root / "proc/mtd").write_text('mtd13: 00001000 00000100 "rootfsB"\n')
        (self.root / "dev/mtdblock13").write_bytes(b"fixture")
        self.command("flock", '[ "${LOCK_BUSY:-0}" = 0 ]')
        self.command("mount", '''
[ "${MOUNT_FAIL:-0}" = 0 ] || exit 1
echo mounted >> "$OPS"
mkdir -p "$6/etc"
printf '%s\n' "$BANNER" > "$6/etc/banner"
''')
        self.command("umount", '[ -d "$1/etc" ] && rm -r "$1/etc"; exit 0')

    def test_both_legacy_banner_formats_and_atomic_cache_are_correct(self):
        for banner, variant in (("8311 Community Firmware MOD [basic] - v2.0 (abc123)", "basic"),
                                ("8311 Community Firmware MOD - v1.0 (abc123)", "bfw")):
            self.env["BANNER"] = banner
            result = self.run_script(self.info)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.splitlines(), ["FW_VARIANT=" + variant,
                             "FW_VERSION=" + ("v2.0" if variant == "basic" else "v1.0"), "FW_REVISION=abc123"])
            cache = self.root / "tmp/8311-alt-firmware"
            self.assertEqual(cache.read_text(), result.stdout)
            self.assertEqual(self.run_script(self.info).stdout, result.stdout)
            cache.unlink()
        self.assertEqual(self.operations(), ["mounted", "mounted"])

    def test_busy_installer_and_failed_mount_leave_no_cache_or_mount_directory(self):
        for failure in ("LOCK_BUSY", "MOUNT_FAIL"):
            self.env[failure] = "1"
            self.assertNotEqual(self.run_script(self.info).returncode, 0)
            self.assertFalse((self.root / "tmp/8311-alt-firmware").exists())
            self.assertFalse(any(path.is_dir() for path in (self.root / "tmp").iterdir()))
            del self.env[failure]


class FactoryResetTests(ShellFixture):
    def setUp(self):
        super().setUp()
        self.reset = self.script("files/reset/etc/init.d/_8311-reset_fwenvs.sh", True)
        (self.root / "lib").mkdir()
        (self.root / "lib/8311.sh").write_text('to_console() { cat >/dev/null; }\n')
        self.command("fw_printenv", '''
printf '%s\n' '8311_loid=private-fixture' '8311_hostname=fixture' 'commit_bank=A'
[ "${READ_FAIL:-0}" = 0 ]
''')
        self.command("fwenv_set", '[ "$1" = -- ] || exit 99; echo "$2" >> "$OPS"; [ "${WRITE_FAIL:-0}" = 0 ]')
        self.command("reboot", 'echo reboot >> "$OPS"')
        self.runner = self.root / "reset-runner.sh"
        self.runner.write_text('. ' + shlex.quote(shell_path(self.reset)) + '\nboot\n', newline="\n")

    def test_failed_environment_read_creates_no_reset_marker_and_never_clears_values(self):
        self.env["READ_FAIL"] = "1"
        self.assertNotEqual(self.run_script(self.runner).returncode, 0)
        self.assertEqual(self.operations(), [])
        self.assertFalse((self.root / "ptconf/8311/fwenvs_backup.env").exists())
        self.assertEqual(list((self.root / "tmp").glob("8311-reset.*")), [])

    def test_partial_write_stops_reset_preserves_backup_and_never_reboots(self):
        self.env["WRITE_FAIL"] = "1"
        self.assertNotEqual(self.run_script(self.runner).returncode, 0)
        self.assertEqual(self.operations(), ["8311_loid"])
        backup = (self.root / "ptconf/8311/fwenvs_backup.env").read_text()
        self.assertIn("8311_loid=private-fixture", backup)
        self.assertNotIn("commit_bank", backup)


class TranslationTests(unittest.TestCase):
    def test_duplicate_handling_reload_and_aligned_binary_output(self):
        spec = importlib.util.spec_from_file_location("po2lmo", ROOT / "tools/po2lmo.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        lmo = module.Lmo()
        first = lmo.add_entry(20, 0, b"a")
        duplicate = lmo.add_entry(20, 0, b"second")
        self.assertEqual((first.dup, duplicate.dup), (1, 1))
        lmo.skip_dup = True
        self.assertIsNone(lmo.add_entry(20, 0, b"skip"))
        lmo.load_from_list([module.LmoEntry(10, 0, val=b"xyz")])
        self.assertIsNone(lmo.add_entry(10, 0, b"skip"))
        self.assertIsNotNone(lmo.add_entry(20, 0, b"a"))
        data = lmo.save_to_bin()
        self.assertEqual(data[:8], b"xyz\x00a\x00\x00\x00")
        self.assertEqual(len(data), 8 + 2 * 16 + 4)
        self.assertEqual(int.from_bytes(data[-4:], "big"), 8)


if __name__ == "__main__":
    unittest.main()
