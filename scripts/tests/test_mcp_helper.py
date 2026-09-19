"""Process-level MCP framing checks against the actual standalone Swift helper."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


class MCPHelperTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temporary.cleanup)
        root = Path(cls.temporary.name)
        cls.helper = root / "mcp-helper"
        source = Path(__file__).resolve().parents[2] / "AgentHelper/AagedalMediaConverterMCP.swift"
        subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-module-cache-path",
                        str(root / "cache"), str(source), "-o", str(cls.helper)],
                       check=True, capture_output=True, text=True)

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
                         {"inspect_media", "list_presets", "plan_conversion",
                          "submit_conversion", "get_job", "cancel_job"})


if __name__ == "__main__":
    unittest.main()
