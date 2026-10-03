"""Image and boot-selection regressions; all block devices and writes are fixtures."""
import shlex
import struct
import sys
import time
import zlib

from test_regressions import ShellFixture, shell_path


class BankCheckTests(ShellFixture):
    def setUp(self):
        super().setUp()
        self.check = self.script("files/common/usr/sbin/8311-bank-check.sh", True)
        (self.root / "dev").mkdir()
        (self.root / "proc").mkdir()
        self.command("fw_printenv", 'printf "%s" "${BANK_VALID:-true}"')
        (self.root / "proc/mtd").write_text('mtd9: 00001000 00000100 "rootfsA"\n'
                                            'mtd13: 00001000 00000100 "rootfsB"\n')
        self.command("ubinfo", '''
case "$3" in
  kernelA) id=0 ;; rootfsA) id=1 ;; bootcoreA) id=2 ;;
  kernelB) id=4 ;; bootcoreB) id=5 ;; rootfsB) id=6 ;; *) exit 1 ;;
esac
[ "${MISSING_VOLUME:-}" != "$3" ] || exit 1
printf 'Volume ID: %s\nSize: 1 LEBs (4096 bytes, 4 KiB)\n' "$id"
''')
        helper = self.root / "binary_tools.py"
        helper.write_text('''import pathlib,sys,zlib
kind,*args=sys.argv[1:]
if kind == 'crc32':
    data=pathlib.Path(args[0]).read_bytes() if args else sys.stdin.buffer.read()
    print('%08x' % zlib.crc32(data))
else:
    start=int(args[args.index('-s')+1]); length=int(args[args.index('-n')+1])
    print(pathlib.Path(args[-1]).read_bytes()[start:start+length].hex(),end='')
''', encoding="utf-8")
        for name in ("crc32", "hexdump"):
            self.command(name, "exec " + shlex.quote(sys.executable.replace("\\", "/")) + " " +
                         shlex.quote(shell_path(helper)) + " " + name + ' "$@"')
        self.command("mount", '''
[ "${MOUNT_FAIL:-0}" = 0 ] || exit 1
echo mount >> "$OPS"
mkdir -p "$6/etc" "$6/bin"
printf init > "$6/etc/inittab"
printf preinit > "$6/etc/preinit"
[ "${INCOMPLETE_ROOTFS:-0}" = 0 ] || exit 0
printf executable > "$6/bin/busybox"
''')
        self.command("umount", 'echo umount >> "$OPS"')
        kernel = self.uimage(b"kernel payload" * 30)
        bootcore = self.uimage(b"bootcore payload" * 30)
        rootfs = bytearray(128)
        rootfs[:4] = b"hsqs"
        struct.pack_into("<HH", rootfs, 28, 4, 0)
        struct.pack_into("<Q", rootfs, 40, len(rootfs))
        for index, data in ((0, kernel), (1, rootfs), (2, bootcore),
                            (4, kernel), (5, bootcore), (6, rootfs)):
            (self.root / f"dev/ubi0_{index}").write_bytes(data)

    @staticmethod
    def uimage(payload):
        header = bytearray(struct.pack(">7I4B32s", 0x27051956, 0, 0, len(payload), 0, 0,
                                       zlib.crc32(payload), 5, 5, 2, 0, b"fixture"))
        struct.pack_into(">I", header, 4, zlib.crc32(header))
        return header + payload

    def test_complete_images_with_remapped_volume_ids_are_recognized(self):
        for bank in ("A", "B"):
            result = self.run_script(self.check, bank)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(result.stdout.strip(), "ready")
            self.assertEqual(list((self.root / "tmp").glob("8311-bank-check.*")), [])
        self.assertEqual(self.operations(), ["mount", "umount"] * 2)

    def test_empty_missing_corrupt_and_truncated_components_are_rejected(self):
        for index in (4, 5, 6):
            path = self.root / f"dev/ubi0_{index}"
            original = path.read_bytes()
            damaged = bytearray(original)
            damaged[0 if index == 6 else -1] ^= 1
            for content in (b"\xff" * 4096, original[:20], damaged):
                with self.subTest(index=index, content=len(content)):
                    path.write_bytes(content)
                    self.assertNotEqual(self.run_script(self.check, "B").returncode, 0)
                    self.assertEqual(list((self.root / "tmp").glob("8311-bank-check.*")), [])
            path.write_bytes(original)
        self.env["MISSING_VOLUME"] = "bootcoreB"
        self.assertNotEqual(self.run_script(self.check, "B").returncode, 0)

    def test_rootfs_mount_failure_and_missing_boot_files_fail_closed(self):
        for failure in ("MOUNT_FAIL", "INCOMPLETE_ROOTFS"):
            self.env[failure] = "1"
            self.assertNotEqual(self.run_script(self.check, "B").returncode, 0)
            self.assertEqual(list((self.root / "tmp").glob("8311-bank-check.*")), [])
            del self.env[failure]

    def test_invalid_bank_never_reaches_devices(self):
        self.assertNotEqual(self.run_script(self.check, "B;reboot").returncode, 0)
        self.assertEqual(self.operations(), [])

    def test_incomplete_install_marker_blocks_otherwise_recognizable_images(self):
        self.env["BANK_VALID"] = "false"
        self.assertNotEqual(self.run_script(self.check, "B").returncode, 0)
        self.assertEqual(self.operations(), [])


class BankControlTests(ShellFixture):
    def setUp(self):
        super().setUp()
        self.control = self.script("files/common/usr/sbin/8311-bankctl.sh", True)
        # BusyBox ash can implement sleep internally. Resolve both timer and
        # destructive reboot explicitly to fixtures, even after fixture cleanup.
        self.control.write_text(self.control.read_text().replace("\n", '''
sleep() { "$TEST_BIN/sleep" "$@"; }
reboot() { "$TEST_BIN/reboot" "$@"; }
''', 1), encoding="utf-8", newline="\n")
        for directory in ("proc", "usr/sbin", "env"):
            (self.root / directory).mkdir(parents=True)
        (self.root / "proc/cmdline").write_text("rootfsname=rootfsA\n")
        (self.root / "env/commit_bank").write_text("A")
        self.command("fwenv_get", 'cat "$FIXTURE/env/$1" 2>/dev/null')
        self.command("fwenv_set", '''
[ "$1" = -- ] || exit 99
echo "env:$2:$3" >> "$OPS"
[ "${ENV_FAIL:-0}" = 0 ] || exit 1
[ "${BAD_ENV_READBACK:-0}" = 0 ] || exit 0
printf '%s' "$3" > "$FIXTURE/env/$2"
''')
        self.command("flock", '[ "${LOCK_BUSY:-0}" = 0 ]')
        self.command("sleep", ":")
        self.command("reboot", 'echo reboot >> "$OPS"; touch "$FIXTURE/rebooted"')
        checker = self.root / "usr/sbin/8311-bank-check.sh"
        checker.write_text('#!/bin/sh\n[ "${INVALID_BANK:-}" != "$1" ]\n', newline="\n")
        checker.chmod(0o755)

    def assert_rebooted(self):
        for _ in range(50):
            if (self.root / "rebooted").exists():
                return
            time.sleep(0.01)
        self.fail("reboot was not scheduled")

    def test_trial_preserves_default_and_selects_only_one_boot(self):
        result = self.run_script(self.control, "trial", "B")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_rebooted()
        self.assertEqual((self.root / "env/commit_bank").read_text(), "A")
        self.assertEqual((self.root / "env/img_activate").read_text(), "B")
        self.assertEqual(self.operations(), ["env:img_validB:true", "env:img_activate:B", "reboot"])

    def test_confirm_commits_only_the_running_trial(self):
        (self.root / "proc/cmdline").write_text("rootfsname=rootfsB\n")
        result = self.run_script(self.control, "commit")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.operations(), ["env:commit_bank:B"])

    def test_empty_bank_busy_installer_and_failed_writes_never_reboot(self):
        for key, value in (("INVALID_BANK", "B"), ("LOCK_BUSY", "1"),
                           ("ENV_FAIL", "1"), ("BAD_ENV_READBACK", "1")):
            with self.subTest(key=key):
                self.env[key] = value
                self.assertNotEqual(self.run_script(self.control, "trial", "B").returncode, 0)
                self.assertNotIn("reboot", self.operations())
                del self.env[key]

    def test_trial_cannot_overwrite_fallback_and_pending_trial_cannot_be_confirmed(self):
        (self.root / "proc/cmdline").write_text("rootfsname=rootfsB\n")
        self.assertNotEqual(self.run_script(self.control, "trial", "A").returncode, 0)
        (self.root / "env/img_activate").write_text("B")
        self.assertNotEqual(self.run_script(self.control, "commit").returncode, 0)
        self.assertEqual(self.operations(), [])

    def test_reboot_checks_the_effective_next_bank(self):
        (self.root / "env/img_activate").write_text("B")
        self.env["INVALID_BANK"] = "B"
        self.assertNotEqual(self.run_script(self.control, "reboot").returncode, 0)
        self.assertEqual(self.operations(), [])


class VlanRuleHashTests(ShellFixture):
    def setUp(self):
        super().setUp()
        self.hash = self.script("files/common/usr/sbin/8311-vlan-rules-hash.sh", True)
        (self.root / "sys/class/net/eth0_0").mkdir(parents=True)
        self.command("tc", '''
[ "${TC_FAIL:-0}" = 0 ] || exit 1
cat "$FIXTURE/filter"
''')
        (self.root / "filter").write_text("filter protocol all pref 2 flower handle 0x2\n"
                                          "  action order 1: vlan push id 41 protocol 802.1Q pass\n"
                                          "  index 7 ref 1 bind 1 installed 1 sec used 1 sec\n"
                                          "  in_hw in_hw_count 1\n")

    def test_lifetime_changes_do_not_reapply_but_rule_loss_or_action_changes_do(self):
        first = self.run_script(self.hash)
        self.assertEqual(first.returncode, 0, first.stderr)
        path = self.root / "filter"
        original = path.read_text()
        path.write_text(original.replace("installed 1 sec used 1 sec", "installed 60 sec used 32 sec"))
        self.assertEqual(self.run_script(self.hash).stdout, first.stdout)
        path.write_text(original.replace("push id 41", "push id 99"))
        self.assertNotEqual(self.run_script(self.hash).stdout, first.stdout)
        path.write_text("")
        self.assertNotEqual(self.run_script(self.hash).stdout, first.stdout)

    def test_failed_tc_reads_do_not_become_a_valid_empty_snapshot(self):
        self.env["TC_FAIL"] = "1"
        result = self.run_script(self.hash)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertEqual(list((self.root / "tmp").glob("8311-rule-state.*")), [])
