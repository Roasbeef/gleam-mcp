"""Independent real HTTP peers verify framing, admission and disconnect custody."""

import base64
import glob
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import select
import socket
import ssl
import subprocess
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
LIBS = glob.glob(str(ROOT / "build/dev/erlang/*/ebin"))
META = {"io.modelcontextprotocol/protocolVersion": "2026-07-28",
        "io.modelcontextprotocol/clientCapabilities": {}}


def command(expression):
    return ["erl", "-noshell", "-pa", *LIBS, "-eval",
            "logger:set_primary_config(level, emergency), application:ensure_all_started(gleam_mcp), " + expression]


def envelope(method="tools/list", mode=None):
    params = {"_meta": META.copy()}
    if mode:
        params["mode"] = mode
    return {"jsonrpc": "2.0", "id": 7, "method": method, "params": params}


def headers(method="tools/list"):
    return {"Accept": "application/json, text/event-stream",
            "Content-Type": "application/json", "MCP-Protocol-Version": "2026-07-28",
            "Mcp-Method": method}


class Lines:
    def __init__(self, stream):
        self.stream, self.pending = stream, b""
        self.seen = []

    def until(self, wanted, timeout=5):
        deadline = time.monotonic() + timeout
        while True:
            if b"\n" in self.pending:
                line, self.pending = self.pending.split(b"\n", 1)
                self.seen.append(line.decode())
                if line.decode() == wanted:
                    return
                continue
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([self.stream], [], [], remaining)[0]:
                raise TimeoutError(f"missing {wanted}; pending={self.pending!r}")
            data = os.read(self.stream.fileno(), 65536)
            if not data:
                raise EOFError(f"server exited before {wanted}")
            self.pending += data


class NativeHttp(unittest.TestCase):
    fixture_name = "server"

    def setUp(self):
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            self.port = probe.getsockname()[1]
        self.child = subprocess.Popen(command(f"support@http_fixture:{self.fixture_name}({self.port})."),
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.lines = Lines(self.child.stdout)
        self.lines.until("READY")

    def tearDown(self):
        self.child.terminate()
        self.child.communicate(timeout=5)

    def post(self, value, extra=None, path="/mcp", method="POST"):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        incoming = headers(value["method"])
        incoming.update(extra or {})
        connection.request(method, path, json.dumps(value).encode(), incoming)
        return connection, connection.getresponse()

    def test_native_sse_response_finishes_and_worker_dies(self):
        connection, response = self.post(envelope())
        self.assertEqual(response.status, 200)
        self.assertEqual(response.getheader("Content-Type"), "text/event-stream")
        data = response.read().decode()
        self.assertEqual(json.loads(data.split("data: ")[1])["id"], 7)
        self.lines.until("WORKER_STARTED")
        self.lines.until("WORKER_DOWN")
        connection.close()

    def test_origin_is_validated_before_routing_and_admission(self):
        connection, response = self.post(envelope(), {"Origin": "http://evil.example"},
                                         path="/wrong", method="GET")
        self.assertEqual(response.status, 403)
        response.read()
        connection.close()
        connection, response = self.post(envelope(), {"Origin": "http://allowed.example"})
        self.assertEqual(response.status, 200)
        response.read()
        connection.close()

    def test_header_version_and_unknown_method_errors_are_pre_effect(self):
        cases = [(envelope(), {"Mcp-Method": "tools/call"}, 400, -32020),
                 (envelope("unknown"), {}, 404, -32601)]
        unsupported = envelope()
        unsupported["params"]["_meta"]["io.modelcontextprotocol/protocolVersion"] = "1900-01-01"
        cases.append((unsupported, {"MCP-Protocol-Version": "1900-01-01"}, 400, -32022))
        for body, extra, status, code in cases:
            connection, response = self.post(body, extra)
            self.assertEqual(response.status, status)
            answer = json.loads(response.read())
            self.assertEqual(answer["error"]["code"], code)
            if code == -32022:
                self.assertEqual(answer["error"]["data"],
                                 {"supported": ["2026-07-28"], "requested": "1900-01-01"})
            connection.close()
        self.assertFalse(select.select([self.child.stdout], [], [], 0.1)[0],
                         "an invalid request admitted a callback")

    def test_notification_acceptance_has_no_request_metadata_requirement(self):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        body = {"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {"requestId": 7}}
        connection.request("POST", "/mcp", json.dumps(body), {"Content-Type": "application/json"})
        response = connection.getresponse()
        self.assertEqual(response.status, 202)
        self.assertEqual(response.read(), b"")
        connection.close()
        self.assertFalse(select.select([self.child.stdout], [], [], 0.1)[0])

    def test_mrtr_is_a_new_explicit_request_with_opaque_state(self):
        body = envelope(mode="mrtr")
        connection, response = self.post(body)
        answer = json.loads(response.read().decode().removeprefix("data: "))
        self.assertEqual(answer["result"]["resultType"], "input_required")
        self.assertEqual(answer["result"]["requestState"], "opaque-state")
        connection.close()
        self.lines.until("WORKER_STARTED")
        self.lines.until("WORKER_DOWN")
        body["id"] = 8
        body["params"]["requestState"] = answer["result"]["requestState"]
        connection, response = self.post(body)
        answer = json.loads(response.read().decode().removeprefix("data: "))
        self.assertEqual(answer["id"], 8)
        self.assertEqual(answer["result"]["resultType"], "complete")
        connection.close()
        self.lines.until("WORKER_STARTED")
        self.lines.until("WORKER_DOWN")

    def test_custom_header_mirrors_are_validated_before_handler(self):
        body = envelope("tools/call")
        body["params"].update(name="echo", arguments={"tenant": "漢😀"})
        for extra in ({"Mcp-Name": "echo"},
                      {"Mcp-Name": "wrong", "Mcp-Param-Tenant": "=?base64?5ryi8J+YgA==?="},
                      {"Mcp-Name": "echo", "Mcp-Param-Tenant": "=?base64?invalid!?="},
                      {"Mcp-Name": "echo", "Mcp-Param-Tenant": "different"}):
            connection, response = self.post(body, extra)
            self.assertEqual(response.status, 400)
            self.assertEqual(json.loads(response.read())["error"]["code"], -32020)
            connection.close()
        self.assertFalse(select.select([self.child.stdout], [], [], 0.1)[0])
        encoded = "=?base64?" + base64.b64encode("漢😀".encode()).decode() + "?="
        connection, response = self.post(body, {"Mcp-Name": "echo", "Mcp-Param-Tenant": encoded})
        self.assertEqual(response.status, 200)
        response.read()
        connection.close()
        self.lines.until("WORKER_STARTED")
        self.lines.until("WORKER_DOWN")

    def test_disconnect_cancels_and_joins_blocked_callback(self):
        connection, response = self.post(envelope(mode="block"))
        self.assertEqual(response.status, 200)
        self.lines.until("WORKER_STARTED")
        response.close()
        connection.close()
        self.lines.until("WORKER_DOWN")

    def test_subscription_disconnect_cancels_and_joins_callback(self):
        connection, response = self.post(envelope("subscriptions/listen"))
        self.assertEqual(response.status, 200)
        self.lines.until("WORKER_STARTED")
        line = response.readline().decode()
        acknowledged = json.loads(line.removeprefix("data: "))
        self.assertEqual(acknowledged["method"], "notifications/subscriptions/acknowledged")
        self.assertEqual(acknowledged["params"]["notifications"], {})
        self.assertEqual(acknowledged["params"]["_meta"]["io.modelcontextprotocol/subscriptionId"], 7)
        response.close()
        connection.close()
        self.lines.until("WORKER_DOWN")


class NativeRegistry(unittest.TestCase):
    fixture_name = "registry"
    setUp = NativeHttp.setUp
    tearDown = NativeHttp.tearDown
    post = NativeHttp.post

    def test_default_registry_lists_without_initialize(self):
        connection, response = self.post(envelope())
        self.assertEqual(response.status, 200)
        answer = json.loads(response.read().decode().removeprefix("data: "))
        self.assertEqual(answer["result"]["tools"], [])
        connection.close()

    def test_default_registry_acknowledges_and_keeps_subscription_open(self):
        body = envelope("subscriptions/listen")
        body["params"]["notifications"] = {"toolsListChanged": True}
        connection, response = self.post(body)
        self.assertEqual(response.status, 200)
        acknowledgement = json.loads(response.readline().decode().removeprefix("data: "))
        self.assertEqual(acknowledgement["method"], "notifications/subscriptions/acknowledged")
        self.assertEqual(acknowledgement["params"]["notifications"], {})
        self.assertEqual(acknowledgement["params"]["_meta"]["io.modelcontextprotocol/subscriptionId"], 7)
        self.assertEqual(response.readline(), b"\n")
        self.assertFalse(select.select([response.fp], [], [], 0.1)[0], "subscription closed immediately after acknowledgement")
        response.close()
        connection.close()


class NativeAdmissionHttp(unittest.TestCase):
    fixture_name = "server_auth"
    setUp = NativeHttp.setUp
    tearDown = NativeHttp.tearDown

    def test_unbounded_rejected_framing_closes_without_waiting_for_body(self):
        for framing in ({"Content-Length": str(9 * 1024 * 1024)},
                        {"Transfer-Encoding": "chunked"}):
            with self.subTest(framing=framing):
                connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=3)
                try:
                    connection.putrequest("POST", "/mcp")
                    for name, value in framing.items():
                        connection.putheader(name, value)
                    connection.endheaders()
                    response = connection.getresponse()
                    self.assertEqual(response.status, 401)
                    self.assertEqual(response.getheader("Connection"), "close")
                    self.assertEqual(response.read(), b"")
                finally:
                    connection.close()
        self.assertFalse(select.select([self.child.stdout], [], [], 0.1)[0],
                         "unsupported rejection framing admitted a callback")

    def test_admitted_unbounded_or_ambiguous_framing_is_refused_before_read(self):
        for framing in (("Content-Length", str(9 * 1024 * 1024)),
                        ("Transfer-Encoding", "chunked"),
                        ("Content-Length", "invalid"),
                        ("Content-Length", "duplicate")):
            with self.subTest(framing=framing):
                connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=3)
                try:
                    connection.putrequest("POST", "/mcp")
                    connection.putheader("Authorization", "Bearer fixture-token")
                    if framing[1] == "duplicate":
                        connection.putheader("Content-Length", "10")
                        connection.putheader("Content-Length", "11")
                    else:
                        connection.putheader(*framing)
                    connection.endheaders()
                    if framing[1] == "duplicate":
                        # Mist refuses the repeated wire field before SDK admission.
                        # A timeout is a failure: no body is needed to detect it.
                        with self.assertRaises((http.client.RemoteDisconnected, ConnectionResetError)):
                            connection.getresponse()
                    else:
                        response = connection.getresponse()
                        self.assertEqual(response.status, 400)
                        self.assertEqual(response.getheader("Connection"), "close")
                        self.assertEqual(json.loads(response.read())["error"]["code"], -32700)
                finally:
                    connection.close()
        self.assertFalse(select.select([self.child.stdout], [], [], 0.1)[0],
                         "invalid admitted framing dispatched a callback")

    def test_rejected_bodies_are_discarded_before_keepalive_reuse(self):
        # Separate header/body writes reproduce Linux's unread-body reset path.
        body = b"untrusted request body" * 8192
        cases = [(None, None, "POST", 401),
                 ("Bearer wrong-token", None, "POST", 401),
                 ("Bearer fixture-token", "http://evil.example", "POST", 403),
                 ("Bearer fixture-token", None, "GET", 405)]
        for auth, origin, method, status in cases:
            with self.subTest(status=status, auth=auth):
                connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
                try:
                    connection.putrequest(method, "/mcp")
                    connection.putheader("Content-Length", str(len(body)))
                    if auth:
                        connection.putheader("Authorization", auth)
                    if origin:
                        connection.putheader("Origin", origin)
                    connection.endheaders()
                    connection.send(body)
                    original_socket = connection.sock
                    self.assertIsNotNone(original_socket)
                    response = connection.getresponse()
                    self.assertEqual(response.status, status)
                    self.assertEqual(response.read(), b"")
                    self.assertFalse(select.select([self.child.stdout], [], [], 0.1)[0],
                                     "a refused request admitted a callback")

                    # A second refusal must retain framing on the same socket.
                    connection.request("POST", "/mcp", b"next body")
                    self.assertIs(connection.sock, original_socket, "the second refusal silently reconnected")
                    response = connection.getresponse()
                    self.assertEqual(response.status, 401)
                    self.assertEqual(response.read(), b"")
                finally:
                    connection.close()
        self.assertFalse(select.select([self.child.stdout], [], [], 0.1)[0],
                         "discarding an unauthorized body admitted a callback")

class PythonPeer(unittest.TestCase):
    def client(self, mode, timeout=2000, fixture="client"):
        observed = []
        closed = threading.Event()

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *args):
                pass

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                observed.append((body, self.headers))
                self.send_response(200)
                if mode in ("listen_json_success", "listen_json_error"):
                    message = {"jsonrpc": "2.0", "id": 7}
                    if mode == "listen_json_error":
                        message["error"] = {"code": -32601, "message": "unsupported subscription"}
                    else:
                        message["result"] = {"resultType": "complete", "_meta": {"io.modelcontextprotocol/subscriptionId": 7}}
                    data = json.dumps(message).encode()
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)
                    self.wfile.flush()
                    self.connection.settimeout(5)
                    try:
                        if self.connection.recv(1) == b"":
                            closed.set()
                    except OSError:
                        pass
                    return
                if mode == "mrtr":
                    data = json.dumps({"jsonrpc": "2.0", "id": 7, "result": {"resultType": "input_required", "requestState": "opaque-state"}}).encode()
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)
                    return
                if mode == "json":
                    data = json.dumps({"jsonrpc": "2.0", "id": 7, "result": {"text": "漢😀"}}, ensure_ascii=False).encode()
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)
                    return
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Connection", "close")
                self.end_headers()
                if mode.startswith("listen"):
                    acknowledgement = {"jsonrpc": "2.0", "method": "notifications/subscriptions/acknowledged",
                                       "params": {"notifications": {}, "_meta": {"io.modelcontextprotocol/subscriptionId": 8 if mode == "listen_wrong_id" else 7}}}
                    messages = [acknowledgement]
                    if mode == "listen_progress_first":
                        messages = [{"jsonrpc": "2.0", "method": "notifications/progress", "params": {"progress": 1}}]
                    elif mode == "listen_accept_prompts":
                        acknowledgement["params"]["notifications"] = {"promptsListChanged": True}
                    elif mode == "listen_accept_resources":
                        acknowledgement["params"]["notifications"] = {"resourcesListChanged": True}
                    elif mode == "listen_accept_resource_subscription":
                        acknowledgement["params"]["notifications"] = {"resourceSubscriptions": ["memory://one"]}
                    elif mode == "listen_unrequested":
                        messages.append({"jsonrpc": "2.0", "method": "notifications/tools/list_changed",
                                         "params": {"_meta": {"io.modelcontextprotocol/subscriptionId": 7}}})
                    if mode.startswith("listen_final_"):
                        result = {"resultType": "complete", "_meta": {"io.modelcontextprotocol/subscriptionId": 7}}
                        if mode == "listen_final_wrong_id":
                            result["_meta"]["io.modelcontextprotocol/subscriptionId"] = 8
                        elif mode == "listen_final_missing_id":
                            del result["_meta"]
                        elif mode == "listen_final_missing_type":
                            del result["resultType"]
                        elif mode == "listen_final_wrong_type":
                            result["resultType"] = "input_required"
                        messages.append({"jsonrpc": "2.0", "id": 7, "result": result})
                    for message in messages:
                        self.wfile.write(("data: " + json.dumps(message) + "\n\n").encode())
                    self.wfile.flush()
                    self.connection.settimeout(5)
                    try:
                        if self.connection.recv(1) == b"":
                            closed.set()
                    except OSError:
                        pass
                    return
                if mode == "timeout":
                    self.connection.settimeout(5)
                    try:
                        if self.connection.recv(1) == b"":
                            closed.set()
                    except OSError:
                        pass
                    return
                data = b": keepalive\r\n\r\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{\"progress\":1}}\r\n\r\n"
                if mode != "interrupted":
                    identifier = 99 if mode == "wrong_id" else 7
                    data += (f'data: {{"jsonrpc": "2.0",\r\ndata: "id": {identifier}, "result": {{"text": "漢😀"}}}}\r\n\r\n').encode()
                for offset in range(0, len(data), 3):
                    self.wfile.write(data[offset:offset + 3])
                    self.wfile.flush()
                    time.sleep(0.001)
                self.close_connection = True

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        server.daemon_threads = True
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            port = server.server_address[1]
            delay = 2000 if mode == "timeout" or mode.startswith("listen") else 0
            expression = f'support@http_fixture:{fixture}(<<"http://127.0.0.1:{port}/mcp">>, {timeout}), timer:sleep({delay}), erlang:halt().'
            if delay:
                child = subprocess.Popen(command(expression), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                try:
                    reader = Lines(child.stdout)
                    reader.until("DRAINED" if mode.startswith("listen") else "FAILED")
                    self.assertTrue(closed.wait(0.5), "the client returned before closing its native socket")
                    stdout, stderr = child.communicate(timeout=10)
                    stdout = ("\n".join(reader.seen) + "\n").encode() + stdout
                finally:
                    if child.poll() is None:
                        child.kill()
                        child.communicate(timeout=5)
                self.assertEqual(child.returncode, 0, stderr.decode())
            else:
                child = subprocess.run(command(expression), capture_output=True, timeout=10)
                stdout, stderr = child.stdout, child.stderr
                self.assertEqual(child.returncode, 0, stderr.decode())
            self.assertEqual(len(observed), 1, "an effect request was automatically replayed")
            self.assertEqual(observed[0][1]["Mcp-Method"], observed[0][0]["method"])
            self.assertEqual(observed[0][1]["MCP-Protocol-Version"], "2026-07-28")
            self.assertIn("application/json", observed[0][1]["Accept"])
            self.assertIn("text/event-stream", observed[0][1]["Accept"])
            if fixture == "client_tool":
                self.assertEqual(observed[0][1]["Mcp-Name"], "=?base64?5ryi8J+YgA==?=")
                self.assertEqual(observed[0][1]["Mcp-Param-Tenant"], "=?base64?IHBhZGRlZCA=?=")
            return stdout.decode().strip(), closed
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=3)

    def test_retained_subscription_cancel_closes_and_drains_socket(self):
        result, closed = self.client("listen", fixture="client_listen")
        self.assertEqual(result, "ACKNOWLEDGED\nDRAINED")
        self.assertTrue(closed.wait(1))

    def test_subscription_rejects_progress_before_acknowledgement(self):
        result, closed = self.client("listen_progress_first", fixture="client_listen")
        self.assertEqual(result, "FAILED\nDRAINED")
        self.assertTrue(closed.wait(1))

    def test_subscription_rejects_wrong_identity(self):
        result, closed = self.client("listen_wrong_id", fixture="client_listen")
        self.assertEqual(result, "FAILED\nDRAINED")
        self.assertTrue(closed.wait(1))

    def test_subscription_rejects_unaccepted_notification(self):
        result, closed = self.client("listen_unrequested", fixture="client_listen")
        self.assertEqual(result, "FAILED\nDRAINED")
        self.assertTrue(closed.wait(1))

    def test_subscription_rejects_unsupported_acknowledged_sources(self):
        for mode in ("listen_accept_prompts", "listen_accept_resources", "listen_accept_resource_subscription"):
            with self.subTest(source=mode):
                result, closed = self.client(mode, fixture="client_listen")
                self.assertEqual(result, "FAILED\nDRAINED")
                self.assertTrue(closed.wait(1))

    def test_subscription_json_success_before_acknowledgement_is_rejected(self):
        result, _ = self.client("listen_json_success", timeout=500, fixture="client_listen_final")
        self.assertEqual(result, "FAILED\nDRAINED")

    def test_subscription_rpc_error_can_end_before_acknowledgement(self):
        result, _ = self.client("listen_json_error", timeout=500, fixture="client_listen_final")
        self.assertEqual(result, "COMPLETED\nDRAINED")

    def test_subscription_final_requires_matching_identity_and_complete_type(self):
        for mode in ("listen_final_wrong_id", "listen_final_missing_id", "listen_final_missing_type", "listen_final_wrong_type"):
            with self.subTest(final=mode):
                result, _ = self.client(mode, fixture="client_listen_final")
                self.assertEqual(result, "FAILED\nDRAINED")

    def test_subscription_valid_graceful_final_is_accepted(self):
        result, _ = self.client("listen_final_valid", fixture="client_listen_final")
        self.assertEqual(result, "COMPLETED\nDRAINED")

    def test_mrtr_suspension_is_preserved_without_automatic_retry(self):
        result, _ = self.client("mrtr")
        self.assertEqual(json.loads(result)["result"],
                         {"resultType": "input_required", "requestState": "opaque-state"})

    def test_client_derives_encoded_name_and_parameter_headers(self):
        result, _ = self.client("json", fixture="client_tool")
        self.assertEqual(json.loads(result)["id"], 7)

    def test_json_response(self):
        result, _ = self.client("json")
        self.assertEqual(json.loads(result)["result"]["text"], "漢😀")

    def test_fragmented_sse_multiline_unicode_and_comments(self):
        result, _ = self.client("sse")
        self.assertEqual(json.loads(result)["result"]["text"], "漢😀")

    def test_unrelated_response_is_refused(self):
        result, _ = self.client("wrong_id")
        self.assertEqual(result, "FAILED")

    def test_interrupted_stream_is_not_replayed(self):
        result, _ = self.client("interrupted")
        self.assertEqual(result, "FAILED")

    def test_deadline_closes_connection_before_client_returns(self):
        result, closed = self.client("timeout", 200)
        self.assertEqual(result, "FAILED")
        self.assertTrue(closed.wait(1), "deadline returned before native TCP connection closed")


class NativeHttps(unittest.TestCase):
    def test_untrusted_certificate_is_rejected_before_application_post(self):
        observed = []
        rejected = []
        handshake_failed = threading.Event()

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_POST(self):
                observed.append(self.path)
                self.send_response(200)
                self.send_header("Content-Length", "0")
                self.end_headers()

        with tempfile.TemporaryDirectory(prefix="gleam-mcp-tls-") as directory:
            directory = Path(directory)
            certificate = directory / "certificate.pem"
            key = directory / "key.pem"
            config = directory / "openssl.cnf"
            config.write_text("""[req]
prompt = no
distinguished_name = distinguished_name
x509_extensions = extensions
[distinguished_name]
CN = localhost
[extensions]
subjectAltName = DNS:localhost,IP:127.0.0.1
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
""")
            generated = subprocess.run([
                "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                "-days", "1", "-config", str(config), "-keyout", str(key),
                "-out", str(certificate),
            ], capture_output=True, timeout=15)
            self.assertEqual(generated.returncode, 0, generated.stderr.decode())
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain(certificate, key)

            class Server(ThreadingHTTPServer):
                def get_request(self):
                    connection, address = super().get_request()
                    secured = context.wrap_socket(connection, server_side=True,
                                                  do_handshake_on_connect=False)
                    secured.settimeout(3)
                    try:
                        secured.do_handshake()
                    except ssl.SSLError as error:
                        rejected.append(str(error))
                        handshake_failed.set()
                        secured.close()
                        raise OSError("the client rejected the ephemeral certificate") from error
                    except BaseException:
                        secured.close()
                        raise
                    return secured, address

            server = Server(("127.0.0.1", 0), Handler)
            server.daemon_threads = True
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                port = server.server_address[1]
                expression = f'support@http_fixture:client(<<"https://127.0.0.1:{port}/mcp">>, 2000), erlang:halt().'
                result = subprocess.run(command(expression), capture_output=True, timeout=8)
                self.assertEqual(result.returncode, 0, result.stderr.decode())
                self.assertIn("FAILED", result.stdout.decode().splitlines())
                self.assertTrue(handshake_failed.wait(1), "the peer did not observe TLS certificate rejection")
                self.assertTrue(any("UNKNOWN_CA" in error or "BAD_CERTIFICATE" in error
                                    for error in rejected), rejected)
                self.assertEqual(observed, [], "the untrusted HTTPS peer admitted an application POST")
            finally:
                server.shutdown()
                server.server_close()
                thread.join(timeout=4)


if __name__ == "__main__":
    unittest.main()
