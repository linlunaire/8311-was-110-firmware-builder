"""Shared streaming I/O uses real FIFOs and native shell tools, even on MSYS."""
import hashlib
import os
import shlex

from test_regressions import ShellFixture, shell_command, shell_path


class StreamingTests(ShellFixture):
    def setUp(self):
        super().setUp()
        library = self.script("files/common/lib/8311-limits.sh")
        self.runner = self.root / "digest.sh"
        self.runner.write_text('. ' + shlex.quote(shell_path(library)) + '''
algorithm="$1"; expected="$2"; shift 2
stream_digest "$FIXTURE/tmp" "$algorithm" "$expected" "$@"
''', newline="\n")
        self.guarded_runner = self.root / "guarded-digest.sh"
        command = (["bash"] if os.name == "nt" else shell_command()) + [shell_path(self.runner)]
        self.guarded_runner.write_text('exec timeout -k 1 10 ' + shlex.join(command) + ' "$@"\n', newline="\n")
        self.data = b"\x00binary payload\n" * 10000
        (self.root / "input").write_bytes(self.data)
        self.command("reader", 'cat "$FIXTURE/input"; [ "${READ_FAIL:-0}" = 0 ]')

    def digest(self, algorithm="sha256sum", expected=None):
        result = self.run_script(self.guarded_runner, algorithm, len(self.data) if expected is None else expected, "reader")
        self.assertNotIn(result.returncode, (124, 137), "stream needed the external watchdog to terminate")
        self.assertEqual(list((self.root / "tmp").iterdir()), [], "stream left temporary files or FIFOs")
        return result

    def assert_rejected(self, **kwargs):
        result = self.digest(**kwargs)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(result.stdout, "")

    def test_binary_stream_has_exact_hash_and_length(self):
        result = self.digest()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.split()[0], hashlib.sha256(self.data).hexdigest())

    def test_matching_hash_cannot_hide_short_or_long_stream(self):
        for expected in (len(self.data) - 1, len(self.data) + 1):
            with self.subTest(expected=expected):
                self.assert_rejected(expected=expected)

    def test_producer_failure_after_correct_bytes_is_rejected(self):
        self.env["READ_FAIL"] = "1"
        self.assert_rejected()

    def test_failed_hash_after_output_and_early_consumer_exit_do_not_hang(self):
        for body in ("sha256sum; exit 7", "exit 7"):
            with self.subTest(body=body):
                self.command("failed-hash", body)
                self.assert_rejected(algorithm="failed-hash")

    def test_counter_and_tee_failures_are_not_hidden(self):
        for command, body in (("wc", f"printf '{len(self.data)}\\n'; exit 7"),
                              ("tee", '/usr/bin/tee "$@"; exit 7')):
            with self.subTest(command=command):
                self.command(command, body)
                self.assert_rejected()
                (self.bin / command).unlink()

    def test_tee_exit_before_fifo_handshake_does_not_hang(self):
        self.command("tee", "exit 7")
        self.assert_rejected()

    def test_termination_cancels_waiting_workers(self):
        self.command("tee", 'kill -TERM "$PPID"; while :; do :; done')
        self.assert_rejected()

    def test_fifo_creation_failure_cleans_up(self):
        self.command("mkfifo", "exit 7")
        self.assert_rejected()
