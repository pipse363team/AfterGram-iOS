import Foundation
import XCTest
import AfterGramPython

final class AfterGramPluginTests: XCTestCase {
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
