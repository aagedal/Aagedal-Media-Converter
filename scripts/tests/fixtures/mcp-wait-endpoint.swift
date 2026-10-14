// Minimal app endpoint for process-level helper concurrency tests.
import Foundation
import CoreFoundation

nonisolated(unsafe) var cancelled = false
let name = "com.aagedal.tests.agent.\(CommandLine.arguments[1])"
let callback: CFMessagePortCallBack = { _, _, data, _ in
    guard let data,
          let request = try? JSONSerialization.jsonObject(with: data as Data) as? [String: Any],
          let requestID = request["requestID"] as? String else { return nil }
    if request["tool"] as? String == "cancel_job" { cancelled = true }
    let response: [String: Any] = [
        "schemaVersion": 1, "requestID": requestID,
        "result": ["state": cancelled ? "cancelled" : "running"]
    ]
    let encoded = try! JSONSerialization.data(withJSONObject: response)
    return Unmanaged.passRetained(encoded as CFData)
}
var context = CFMessagePortContext()
var free = DarwinBoolean(false)
let port = CFMessagePortCreateLocal(nil, name as CFString, callback, &context, &free)!
let source = CFMessagePortCreateRunLoopSource(nil, port, 0)!
CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .defaultMode)
FileHandle.standardOutput.write(Data("ready\n".utf8))
CFRunLoopRun()
