import Foundation
import XCTest
import AfterGramPython
import TelegramApi

final class AfterGramPluginTests: XCTestCase {
    func testEmbeddedBackgroundQueue() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aftergram-background-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func call(_ request: [String: Any]) throws -> [String: Any] {
            var body = request;body["root"] = root.path;body["account"] = 1
            let text = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: body), encoding: .utf8))
            let response = AGPythonRuntime.dispatchJSON(text)
            let result = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(response.data(using: .utf8))) as? [String: Any])
            if let error = result["error"] as? String, !error.isEmpty { XCTFail(error) }
            return result
        }
        let source = root.appendingPathComponent("background.plugin")
        try """
        import time
        from base_plugin import BasePlugin
        from client_utils import run_on_queue, send_text
        __id__ = 'background_test'
        __name__ = 'Background'
        class BackgroundPlugin(BasePlugin):
            def on_plugin_load(self): run_on_queue(self.work)
            def work(self):
                time.sleep(0.1)
                send_text(123, 'background ready')
        """.write(to: source, atomically: true, encoding: .utf8)
        _ = try call(["op":"install", "path":source.path])
        _ = try call(["op":"enable", "id":"background_test", "enabled":true])
        var actions: [[String: Any]] = []
        let deadline = Date().addingTimeInterval(5)
        repeat {
            let response = try call(["op":"tick"])
            actions += response["actions"] as? [[String: Any]] ?? []
            if actions.isEmpty { Thread.sleep(forTimeInterval: 0.02) }
        } while actions.isEmpty && Date() < deadline
        XCTAssertEqual(actions.first?["text"] as? String, "background ready")
        _ = try call(["op":"close"])
    }
    func testTelegramWireCompatibilityWithNativeAPI() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aftergram-wire-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func call(_ request: [String: Any]) throws -> [String: Any] {
            var body = request;body["root"] = root.path;body["account"] = 1
            let text = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: body), encoding: .utf8))
            let response = AGPythonRuntime.dispatchJSON(text)
            let value = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(response.data(using: .utf8))) as? [String: Any])
            if let error = value["error"] as? String, !error.isEmpty { XCTFail(error) }
            return value
        }
        let objects: [[String: Any]] = [
            ["_": "messages.getHistory", "peer": ["_": "inputPeerSelf"], "offset_id": 11, "offset_date": 12, "add_offset": 0, "limit": 5, "max_id": 0, "min_id": 0, "hash": 0],
            ["_": "account.updateStatus", "offline": true],
            ["_": "messages.setTyping", "peer": ["_": "inputPeerSelf"], "action": ["_": "sendMessageTypingAction"], "top_msg_id": 42]
        ]
        let native = [
            Api.functions.messages.getHistory(peer: .inputPeerSelf, offsetId: 11, offsetDate: 12, addOffset: 0, limit: 5, maxId: 0, minId: 0, hash: 0).1.makeData(),
            Api.functions.account.updateStatus(offline: .boolTrue).1.makeData(),
            Api.functions.messages.setTyping(flags: 1, peer: .inputPeerSelf, topMsgId: 42, action: .sendMessageTypingAction).1.makeData()
        ]
        for (index, object) in objects.enumerated() {
            let response = try call(["op": "tl_encode", "object": object])
            let encoded = try XCTUnwrap(response["payload"] as? String)
            XCTAssertEqual(Data(base64Encoded: encoded), native[index])
        }
        let response = try call(["op": "tl_fixtures"])
        let fixtures = try XCTUnwrap(response["fixtures"] as? [[String: String]])
        XCTAssertEqual(fixtures.count, 1700)
        for fixture in fixtures {
            let name = fixture["name"] ?? "?"
            let data = try XCTUnwrap(Data(base64Encoded: fixture["payload"] ?? ""), name)
            let object = try XCTUnwrap(Api.parse(Buffer(data: data)), name)
            let output = Buffer();Api.serializeObject(object, buffer: output, boxed: true)
            XCTAssertEqual(output.makeData(), data, name)
        }
        _ = try call(["op": "close"])
    }
    func testPluginFileAndFormattedActions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aftergram-plugin-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func call(_ request: [String: Any]) throws -> [String: Any] {
            var body = request
            body["root"] = root.path;body["account"] = 1
            let data = try JSONSerialization.data(withJSONObject: body)
            let text = try XCTUnwrap(String(data: data, encoding: .utf8))
            let response = AGPythonRuntime.dispatchJSON(text)
            let decoded = try XCTUnwrap(response.data(using: .utf8))
            let value = try XCTUnwrap(try JSONSerialization.jsonObject(with: decoded) as? [String: Any])
            if let error = value["error"] as? String, !error.isEmpty { XCTFail(error) }
            return value
        }
        let source = root.appendingPathComponent("format.plugin")
        try """
        from base_plugin import BasePlugin, HookResult, HookStrategy
        from client_utils import send_text
        __id__ = 'format_test'
        __name__ = 'Format'
        class FormatPlugin(BasePlugin):
            def on_plugin_load(self): self.add_on_send_message_hook()
            def on_send_message_hook(self, account, params):
                if params.message == '.loop':
                    while True: pass
                send_text(params.peer, '😀 <b>bold</b>', parse_mode='HTML')
                return HookResult(strategy=HookStrategy.CANCEL)
        """.write(to: source, atomically: true, encoding: .utf8)
        let inspected = try call(["op": "inspect", "path": source.path])
        let report = try XCTUnwrap(inspected["report"] as? [String: Any])
        XCTAssertEqual(report["issues"] as? [String], [])
        let installed = try call(["op": "install", "path": source.path])
        XCTAssertEqual(installed["installed"] as? Bool, true)
        let enabled = try call(["op": "enable", "id": "format_test", "enabled": true])
        XCTAssertEqual(enabled["error"] as? String, "")
        let result = try call(["op": "outgoing", "peer": "123", "text": "command"])
        XCTAssertEqual(result["cancel"] as? Bool, true)
        let action = try XCTUnwrap((result["actions"] as? [[String: Any]])?.first)
        XCTAssertEqual(action["text"] as? String, "😀 bold")
        let entity = try XCTUnwrap((action["entities"] as? [[String: Any]])?.first)
        XCTAssertEqual(entity["offset"] as? Int, 3)
        XCTAssertEqual(entity["length"] as? Int, 4)
        let loop = try call(["op": "outgoing", "peer": "123", "text": ".loop"])
        XCTAssertEqual(loop["text"] as? String, ".loop")
        let status = try call(["op": "list"])
        let record = try XCTUnwrap((status["plugins"] as? [[String: Any]])?.first)
        XCTAssertEqual(record["enabled"] as? Bool, false)
        XCTAssertTrue((record["error"] as? String ?? "").contains("exceeded"))
        _ = try call(["op": "close"])
    }
    func testEmbeddedPythonLoadsSDKAndRewritesText() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aftergram-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func call(_ request: [String: Any]) throws -> [String: Any] {
            var body = request
            body["root"] = root.path
            body["account"] = 1
            let data = try JSONSerialization.data(withJSONObject: body)
            let text = try XCTUnwrap(String(data: data, encoding: .utf8))
            let result = AGPythonRuntime.dispatchJSON(text)
            let decoded = try XCTUnwrap(result.data(using: .utf8))
            let value = try XCTUnwrap(try JSONSerialization.jsonObject(with: decoded) as? [String: Any])
            if let error = value["error"] as? String, !error.isEmpty { XCTFail(error) }
            return value
        }
        // One test invokes the same native bridge used by the app, including signed
        // native Python extensions, stdlib/SDK resources and persisted registry.
        let install = try call(["op": "sample"])
        XCTAssertEqual(install["installed"] as? Bool, true)
        _ = try call(["op": "enable", "id": "hello_world", "enabled": true])
        let response = try call(["op": "outgoing", "text": ".hello iOS", "peer": "123"])
        XCTAssertEqual(response["text"] as? String, "Hello, iOS!")
        _ = try call(["op": "close"])
        let restored = try call(["op": "outgoing", "text": ".hello Again", "peer": "123"])
        XCTAssertEqual(restored["text"] as? String, "Hello, Again!")
        _ = try call(["op": "close"])
    }
}
