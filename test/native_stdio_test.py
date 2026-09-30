"""Real pipes exercise the library's bounded OTP stdin reader and EOF behavior."""

import glob
import json
import os
from pathlib import Path
import select
import subprocess
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
LIBS = glob.glob(str(ROOT / "build/dev/erlang/*/ebin"))


def command(expression):
    return ["erl", "-noshell", "-pa", *LIBS, "-eval", expression]


FIXTURE = command(
    "case support@server_fixture:run() of "
    "{ok,nil} -> erlang:halt(0); "
    "{error,Reason} -> io:format(standard_error,\"~p~n\",[Reason]), erlang:halt(2) end."
)


def request(method, identifier=None, params=None):
    value = {"jsonrpc": "2.0", "method": method}
    if identifier is not None:
        value["id"] = identifier
    if params is not None:
        value["params"] = params
    return value


def initialize():
    return request(
        "initialize", 1,
        {"protocolVersion": "2025-06-18", "capabilities": {},
         "clientInfo": {"name": "native-test", "version": "1"}},
    )


def framed(values, delimiter="\n"):
    return (delimiter.join(json.dumps(value, ensure_ascii=False) for value in values)
            + delimiter).encode()


class FrameReader:
    """Read a complete frame under one deadline and retain pipelined bytes."""

    def __init__(self, stream):
        self.stream = stream
        self.pending = b""

    def read(self, timeout):
        deadline = time.monotonic() + timeout
        while b"\n" not in self.pending:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("The server did not finish a protocol frame before the deadline.")
            ready, _, _ = select.select([self.stream], [], [], remaining)
            if not ready:
                raise TimeoutError("The server did not finish a protocol frame before the deadline.")
            chunk = os.read(self.stream.fileno(), 65536)
            if not chunk:
                raise EOFError("The server closed stdout before completing a frame.")
            self.pending += chunk
        line, self.pending = self.pending.split(b"\n", 1)
        return line


class NativeStdio(unittest.TestCase):
    def fixture(self, data):
        return subprocess.run(FIXTURE, input=data, capture_output=True, timeout=10)

    def test_pipelined_crlf_requests_drain_at_eof(self):
        values = [
            initialize(), request("notifications/initialized"),
            request("tools/list", 2),
            request("tools/call", "unicode", {"name": "echo", "arguments": {"text": "漢😀é"}}),
            request("tools/call", 4, {"name": "failed", "arguments": {}}),
        ]
        result = self.fixture(framed(values, "\r\n"))
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        answers = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual([answer["id"] for answer in answers], [1, 2, "unicode", 4])
        self.assertEqual(answers[2]["result"]["structuredContent"], {"text": "漢😀é"})
        self.assertEqual(json.loads(answers[2]["result"]["content"][0]["text"]), {"text": "漢😀é"})
        self.assertTrue(answers[3]["result"]["isError"])

    def test_interactive_short_line_responds_before_stdin_closes(self):
        with subprocess.Popen(FIXTURE, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE) as child:
            try:
                child.stdin.write(framed([initialize()]))
                child.stdin.flush()
                answer = json.loads(FrameReader(child.stdout).read(3))
                self.assertEqual(answer["id"], 1)
                child.stdin.close()
                self.assertEqual(child.wait(timeout=5), 0, child.stderr.read().decode())
            finally:
                if child.poll() is None:
                    child.kill()
                    child.wait()

    def test_frame_reader_bounds_partial_frames_and_retains_extra_bytes(self):
        incoming, outgoing = os.pipe()
        with os.fdopen(incoming, "rb", buffering=0) as stream, os.fdopen(outgoing, "wb", buffering=0) as writer:
            reader = FrameReader(stream)
            writer.write(b"partial")
            with self.assertRaises(TimeoutError):
                reader.read(0.02)
            writer.write(b"\nsecond\n")
            self.assertEqual(reader.read(1), b"partial")
            self.assertEqual(reader.read(1), b"second")

    def test_eof_drains_but_does_not_leave_blocked_callback_running(self):
        result = self.fixture(framed([
            initialize(), request("notifications/initialized"),
            request("tools/call", 2, {"name": "blocked", "arguments": {}}),
        ]))
        self.assertEqual(result.returncode, 2)
        self.assertIn(b"request_timed_out", result.stderr)
        answers = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual([answer["id"] for answer in answers], [1])

    def test_native_byte_cap_counts_unicode_bytes(self):
        expression = "io:format(\"~p~n\",[gleam_mcp_ffi:stdio_read_line(8)]),erlang:halt(0)."
        exact = subprocess.run(command(expression), input=("é" * 4 + "\n").encode(),
                               capture_output=True, timeout=5)
        self.assertEqual(exact.returncode, 0)
        self.assertIn(b"{ok,{some,", exact.stdout)
        excess = subprocess.run(command(expression), input=("é" * 5 + "\n").encode(),
                                capture_output=True, timeout=5)
        self.assertEqual(excess.stdout.strip(), b"{error,line_too_long}")

    def test_partial_final_line_and_invalid_unicode_are_observable(self):
        result = self.fixture(json.dumps(request("ping", "final")).encode())
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertEqual(json.loads(result.stdout)["id"], "final")
        invalid = self.fixture(b"\xff\n")
        self.assertEqual(invalid.returncode, 2)
        self.assertIn(b"read_failed", invalid.stderr)


if __name__ == "__main__":
    os.chdir(ROOT)
    unittest.main()
