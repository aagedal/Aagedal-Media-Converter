"""Process-level MCP framing checks against the actual standalone Swift helper."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
import os
import queue
import threading
import uuid


class MCPHelperTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temporary.cleanup)
        root = Path(cls.temporary.name)
        cls.helper = root / "mcp-helper"
        source = Path(__file__).resolve().parents[2] / "AgentHelper/AagedalMediaConverterMCP.swift"
        subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-DDEBUG", "-module-cache-path",
                        str(root / "cache"), str(source), "-o", str(cls.helper)],
                       check=True, capture_output=True, text=True)

    def live_exchange(self):
        root = Path(self.temporary.name)
        endpoint = root / "endpoint"
        if not endpoint.exists():
            source = Path(__file__).parent / "fixtures/mcp-wait-endpoint.swift"
            subprocess.run(["xcrun", "swiftc", "-module-cache-path", str(root / "cache"),
                            str(source), "-o", str(endpoint)], check=True, capture_output=True, text=True)
        port_id = str(uuid.uuid4())
        server = subprocess.Popen([str(endpoint), port_id], stdout=subprocess.PIPE, text=True)
        self.addCleanup(self.stop_process, server)
        self.assertEqual(server.stdout.readline(), "ready\n")
        helper = subprocess.Popen([str(self.helper)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, text=True,
                                  env={**os.environ, "AMC_UI_TEST_AGENT_PORT_ID": port_id})
        self.addCleanup(self.stop_process, helper)
        responses = queue.Queue()
        def read_responses():
            for line in helper.stdout:
                responses.put(json.loads(line))
        threading.Thread(target=read_responses, daemon=True).start()
        return helper, responses

    @staticmethod
    def stop_process(process):
        process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=3)
        for stream in (process.stdin, process.stdout, process.stderr):
            if stream:
                stream.close()

    @staticmethod
    def send(process, message):
        process.stdin.write(json.dumps(message) + "\n")
        process.stdin.flush()

    def test_wait_does_not_block_ping_or_job_cancellation(self):
        helper, responses = self.live_exchange()
        job_id = str(uuid.uuid4())
        self.send(helper, {"jsonrpc": "2.0", "id": "wait", "method": "tools/call",
                           "params": {"name": "wait_for_job", "arguments": {
                               "job_id": job_id, "known_state": "running", "timeout_seconds": 30}}})
        self.send(helper, {"jsonrpc": "2.0", "id": "ping", "method": "ping"})
        self.assertEqual(responses.get(timeout=3)["id"], "ping")
        self.send(helper, {"jsonrpc": "2.0", "id": "cancel", "method": "tools/call",
                           "params": {"name": "cancel_job", "arguments": {"job_id": job_id}}})
        results = [responses.get(timeout=3), responses.get(timeout=3)]
        by_id = {result["id"]: result for result in results}
        self.assertEqual(by_id["cancel"]["result"]["structuredContent"]["state"], "cancelled")
        self.assertTrue(by_id["wait"]["result"]["structuredContent"]["isTerminal"])

    def test_cancel_notification_interrupts_wait_without_cancelling_job(self):
        helper, responses = self.live_exchange()
        job_id = str(uuid.uuid4())
        self.send(helper, {"jsonrpc": "2.0", "id": 10, "method": "tools/call",
                           "params": {"name": "wait_for_job", "arguments": {
                               "job_id": job_id, "known_state": "running", "timeout_seconds": 30}}})
        self.send(helper, {"jsonrpc": "2.0", "method": "notifications/cancelled",
                           "params": {"requestId": 10}})
        response = responses.get(timeout=3)
        self.assertEqual(response["id"], 10)
        self.assertEqual(response["error"]["code"], -32800)
        self.send(helper, {"jsonrpc": "2.0", "id": 11, "method": "tools/call",
                           "params": {"name": "get_job", "arguments": {"job_id": job_id}}})
        self.assertEqual(responses.get(timeout=3)["result"]["structuredContent"]["state"], "running")

    def test_wait_capacity_is_bounded_and_cancellation_releases_workers(self):
        helper, responses = self.live_exchange()
        for identifier in range(5):
            self.send(helper, {"jsonrpc": "2.0", "id": identifier, "method": "tools/call",
                               "params": {"name": "wait_for_job", "arguments": {
                                   "job_id": str(uuid.uuid4()), "known_state": "running", "timeout_seconds": 30}}})
        rejected = responses.get(timeout=3)
        self.assertEqual(rejected["id"], 4)
        self.assertIn("Too many pending waits", rejected["error"]["message"])
        for identifier in range(4):
            self.send(helper, {"jsonrpc": "2.0", "method": "notifications/cancelled",
                               "params": {"requestId": identifier}})
        cancelled = [responses.get(timeout=3) for _ in range(4)]
        self.assertEqual({item["id"] for item in cancelled}, set(range(4)))
        self.assertTrue(all(item.get("error", {}).get("code") == -32800 for item in cancelled), cancelled)
        self.send(helper, {"jsonrpc": "2.0", "id": "after", "method": "tools/call",
                           "params": {"name": "wait_for_job", "arguments": {
                               "job_id": str(uuid.uuid4()), "known_state": "queued"}}})
        self.assertTrue(responses.get(timeout=3)["result"]["structuredContent"]["changed"])

    def test_disconnect_cancels_pending_wait_and_exits_promptly(self):
        helper, responses = self.live_exchange()
        self.send(helper, {"jsonrpc": "2.0", "id": "wait", "method": "tools/call",
                           "params": {"name": "wait_for_job", "arguments": {
                               "job_id": str(uuid.uuid4()), "known_state": "running", "timeout_seconds": 30}}})
        self.send(helper, {"jsonrpc": "2.0", "id": "ready", "method": "ping"})
        self.assertEqual(responses.get(timeout=3)["id"], "ready")
        helper.stdin.close()
        self.assertEqual(helper.wait(timeout=3), 0)

    def exchange(self, *messages):
        lines = [message if isinstance(message, str) else json.dumps(message)
                 for message in messages]
        result = subprocess.run([str(self.helper)], input="\n".join(lines) + "\n",
                                capture_output=True, text=True, timeout=5, check=True)
        self.assertEqual(result.stderr, "")
        return [json.loads(line) for line in result.stdout.splitlines()]

    def test_notifications_are_silent_and_do_not_launch_app_tools(self):
        responses = self.exchange(
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
            {"jsonrpc": "2.0", "method": "ping"},
            {"jsonrpc": "2.0", "method": "tools/list"},
            {"jsonrpc": "2.0", "method": "tools/call",
             "params": {"name": "list_presets"}},
            {"jsonrpc": "2.0", "method": "unknown"},
            {"jsonrpc": "2.0", "method": "ping", "id": "after-notifications"})
        self.assertEqual(responses, [{"jsonrpc": "2.0", "id": "after-notifications", "result": {}}])

    def test_parse_errors_differ_from_invalid_requests_and_session_recovers(self):
        responses = self.exchange('{', 'null', '[]', '42',
                                  {"jsonrpc": "1.0", "method": "ping", "id": 1},
                                  {"jsonrpc": "2.0", "method": 12, "id": 2},
                                  {"jsonrpc": "2.0", "method": "ping", "id": 3})
        self.assertEqual([response["error"]["code"] for response in responses[:-1]],
                         [-32700, -32600, -32600, -32600, -32600, -32600])
        self.assertTrue(all(response["id"] is None for response in responses[:-1]))
        self.assertEqual(responses[-1]["id"], 3)
        self.assertEqual(responses[-1]["result"], {})

    def test_invalid_request_ids_are_rejected(self):
        for identifier in (None, True, False, [], {}, 1.5):
            with self.subTest(identifier=identifier):
                response, = self.exchange({"jsonrpc": "2.0", "method": "ping", "id": identifier})
                self.assertEqual(response["error"]["code"], -32600)
                self.assertIsNone(response["id"])

    def test_string_and_integer_ids_round_trip(self):
        for identifier in ("", "client-request", 0, -1, 9007199254740991):
            with self.subTest(identifier=identifier):
                response, = self.exchange({"jsonrpc": "2.0", "method": "ping", "id": identifier})
                self.assertEqual(response, {"jsonrpc": "2.0", "id": identifier, "result": {}})

    def test_parameters_require_an_object(self):
        for parameters in (None, [], "wrong", 1, True):
            with self.subTest(parameters=parameters):
                response, = self.exchange({"jsonrpc": "2.0", "method": "tools/list", "id": 1,
                                           "params": parameters})
                self.assertEqual(response["id"], 1)
                self.assertEqual(response["error"]["code"], -32602)

    def test_notification_method_with_id_is_an_unknown_request(self):
        response, = self.exchange({"jsonrpc": "2.0", "method": "notifications/initialized", "id": 1})
        self.assertEqual(response["error"]["code"], -32601)

    def test_initialize_and_tool_discovery_work_in_same_process(self):
        responses = self.exchange(
            {"jsonrpc": "2.0", "method": "initialize", "id": 1,
             "params": {"protocolVersion": "2025-06-18", "clientInfo": {"name": "test"}}},
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
            {"jsonrpc": "2.0", "method": "tools/list", "id": 2})
        self.assertEqual(len(responses), 2)
        self.assertEqual(responses[0]["result"]["protocolVersion"], "2025-06-18")
        self.assertEqual({tool["name"] for tool in responses[1]["result"]["tools"]},
                         {"inspect_media", "list_media", "list_presets", "list_jobs",
                          "get_app_status", "plan_conversion", "get_plan",
                          "submit_conversion", "get_job", "wait_for_job", "cancel_job"})
        media_tool = next(tool for tool in responses[1]["result"]["tools"]
                          if tool["name"] == "list_media")
        self.assertEqual(media_tool["inputSchema"]["properties"]["limit"]["maximum"], 100)
        self.assertEqual(media_tool["inputSchema"]["required"], [])
        jobs_tool = next(tool for tool in responses[1]["result"]["tools"]
                         if tool["name"] == "list_jobs")
        self.assertEqual(jobs_tool["inputSchema"]["properties"]["limit"]["maximum"], 100)


if __name__ == "__main__":
    unittest.main()
