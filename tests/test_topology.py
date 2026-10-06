"""Exercise the upstream VLAN scripts as installed by both firmware builders."""
import hashlib
import shlex
import shutil

from test_regressions import ROOT, ShellFixture, shell_path


def staged_scripts(fixture):
    stage = fixture.root / "staged"
    target = stage / "usr/sbin"
    target.mkdir(parents=True)
    for name in ("8311-detect-config.sh", "8311-fix-vlans.sh"):
        # Normalize the Windows checkout exactly as a Linux checkout would.
        (target / name).write_text((ROOT / "8311-xgspon-bypass" / name).read_text(), newline="\n")
    patch = ROOT / "patches/8311-xgspon-bypass-failures.patch"
    runner = fixture.root / "apply-patch.sh"
    runner.write_text("patch --batch --forward --fuzz=0 -p1 -d " + shlex.quote(shell_path(stage)) +
                      " -i " + shlex.quote(shell_path(patch)) + "\n", newline="\n")
    result = fixture.run_script(runner)
    fixture.assertEqual(result.returncode, 0, result.stdout + result.stderr)
    return target


class TopologyTests(ShellFixture):
    def setUp(self):
        super().setUp()
        self.staged = staged_scripts(self)
        self.detect = self.script(self.staged / "8311-detect-config.sh", True)
        self.command("ip", "printf 'link fixture\\n'")
        self.command("brctl", "printf 'bridge fixture\\n'")

    def assert_failed(self):
        result = self.run_script(self.detect, "-H")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertEqual(list((self.root / "tmp").glob("8311-topology.*")), [])

    def port(self):
        path = self.root / "sys/devices/virtual/net/sw0/lower_eth0_0/brport/state"
        path.parent.mkdir(parents=True)
        path.write_text("3\n")
        return path

    def test_healthy_hash_preserves_snapshot_bytes_with_and_without_ports(self):
        for with_port in (False, True):
            port = self.port() if with_port else None
            expected = "link fixture\nbridge fixture\n"
            if port:
                expected += shell_path(port) + ": 3\n"
            result = self.run_script(self.detect, "-H")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, hashlib.sha256(expected.encode()).hexdigest() + "\n")
            self.assertEqual(list((self.root / "tmp").glob("8311-topology.*")), [])

    def test_failed_queries_discard_empty_and_partial_output(self):
        for name in ("ip", "brctl"):
            for output in ("", "partial"):
                with self.subTest(command=name, output=output):
                    self.command(name, f"printf '%s' '{output}'; exit 7")
                    self.assert_failed()
            self.command(name, "printf 'fixture\\n'")

    def test_failed_port_read_discards_partial_output(self):
        self.port()
        self.command("cat", "printf '3\\n'; exit 7")
        self.assert_failed()

    def test_failed_hash_and_mixed_output_are_rejected(self):
        digest = "a" * 64
        for body in (f"printf '%s  -\\n' '{digest}'; exit 7",
                     f"printf 'diagnostic\\n%s  -\\n' '{digest}'",
                     f"printf '%s  - extra\\n' '{digest}'"):
            with self.subTest(body=body):
                self.command("sha256sum", body)
                self.assert_failed()

    def test_failed_temporary_file_creation_is_rejected(self):
        self.command("mktemp", "exit 7")
        self.assert_failed()

    def test_failed_detection_never_applies_a_cached_configuration(self):
        root = self.root / "root"
        root.mkdir()
        (root / "8311-vlans-lib.sh").write_text('''
tc_flower_add() { echo applied >> "$OPS"; }
tc_flower_clear() { echo cleared >> "$OPS"; }
''', newline="\n")
        config = self.root / "tmp/8311-config.sh"
        config.write_text('''STATE_HASH=old
INTERNET_VLAN=0
INTERNET_PMAP=pmapper4354
UNICAST_VLAN=41
''', newline="\n")
        fixer = self.script(self.staged / "8311-fix-vlans.sh", True)
        fixer.write_text(fixer.read_text().replace("/root/", shell_path(root) + "/"), newline="\n")
        for body in ("printf 'old\\n'; exit 7", '[ "$1" = -H ] && { echo new; exit 0; }; exit 7'):
            self.command("8311-detect-config.sh", body)
            shutil.copy2(self.bin / "8311-detect-config.sh", root / "8311-detect-config.sh")
            result = self.run_script(fixer)
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(self.operations(), [])
