import XCTest
import Foundation
import Darwin
@testable import HeartbeatCore
import HeartbeatSystem

/// Opt-in local test. HEARTBEAT_LIVE_TURN=1 sends one prompt-only heartbeat
/// through the production AppServerClient and consumes Codex allowance.
final class IntegrationTests: XCTestCase {
    @MainActor func testSupervisorStopsItsOwnServer() async throws {
        guard ProcessInfo.processInfo.environment["HEARTBEAT_INTEGRATION"] == "1" else {
            throw XCTSkip("Set HEARTBEAT_INTEGRATION=1 for lifecycle verification")
        }
        let executable = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("codex-heartbeat")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw XCTSkip("Build codex-heartbeat beside the test bundle first")
        }
        let owner = try ProcessIdentity.capture(getpid())
        let ownerObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(owner))
        let port = hb_free_port()
        let child = Process(); let input = Pipe(); let output = Pipe()
        child.executableURL = executable; child.arguments = ["--internal-supervisor"]
        child.standardInput = input; child.standardOutput = output; child.standardError = FileHandle.nullDevice
        try child.run()
        defer { if child.isRunning { child.terminate() } }
        let spec: [String: Any] = ["owner": ownerObject, "executable": try LaunchPlan.findCodex().path,
                                   "cwd": NSTemporaryDirectory(), "endpoint": "ws://127.0.0.1:\(port)"]
        input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: spec))
        try input.fileHandleForWriting.close()
        let data = await Task.detached { output.fileHandleForReading.readDataToEndOfFile() }.value
        let server = try JSONDecoder().decode(ProcessIdentity.self, from: data)
        XCTAssertTrue(server.isAlive)
        XCTAssertEqual(hb_owns_listener(server.pid, UInt16(port)), 1)
        child.terminate()
        for _ in 0..<80 {
            if !child.isRunning && !server.isAlive { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertFalse(child.isRunning)
        XCTAssertFalse(server.isAlive, "Supervisor left its owned App Server alive")
    }

    @MainActor func testInstalledServerAndPassiveSubscription() async throws {
        guard ProcessInfo.processInfo.environment["HEARTBEAT_INTEGRATION"] == "1" else {
            throw XCTSkip("Set HEARTBEAT_INTEGRATION=1 for the real local App Server test")
        }
        let binary = try LaunchPlan.findCodex()
        let liveTurn = ProcessInfo.processInfo.environment["HEARTBEAT_LIVE_TURN"] == "1"
        let workingDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("heartbeat-probe-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workingDirectory) }
        let port = hb_free_port(); XCTAssertGreaterThan(port, 1023)
        let endpoint = URL(string: "ws://127.0.0.1:\(port)")!
        let server = Process()
        server.executableURL = binary
        server.arguments = ["app-server", "--listen", endpoint.absoluteString, "-c", "analytics.enabled=false", "-c", "feedback.enabled=false"]
        server.standardOutput = FileHandle.nullDevice; server.standardError = FileHandle.nullDevice
        server.standardInput = FileHandle.nullDevice
        try server.run()
        defer {
            if server.isRunning { server.terminate(); server.waitUntilExit() }
        }
        for _ in 0..<100 {
            if hb_owns_listener(server.processIdentifier, UInt16(port)) == 1 { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(hb_owns_listener(server.processIdentifier, UInt16(port)), 1)
        XCTAssertEqual(hb_owns_listener(getpid(), UInt16(port)), 0)
        // Test-only client represents the interactive TUI; production monitor cannot thread/start.
        let owner = URLSession(configuration: .ephemeral).webSocketTask(with: endpoint)
        owner.resume()
        defer { owner.cancel(with: .goingAway, reason: nil) }
        let deadline = Task {
            try? await Task.sleep(nanoseconds: 90_000_000_000)
            if !Task.isCancelled { owner.cancel(with: .goingAway, reason: nil) }
        }
        defer { deadline.cancel() }
        func send(_ object: [String: Any]) async throws {
            try await owner.send(.string(String(decoding: JSONSerialization.data(withJSONObject: object), as: UTF8.self)))
        }
        func response(_ id: Int) async throws -> [String: Any] {
            while true {
                let msg = try await owner.receive()
                let data: Data
                switch msg { case .string(let s): data = Data(s.utf8); case .data(let d): data = d; @unknown default: continue }
                let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                if object["id"] as? Int == id {
                    if object["error"] != nil { throw HeartbeatError.message("Integration RPC failed for id \(id)") }
                    return object["result"] as? [String: Any] ?? [:]
                }
            }
        }
        try await send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "heartbeat_integration", "version": "0.1.0"]]])
        _ = try await response(1)
        print("PROBE: first connection initialized")
        try await send(["method": "initialized"])
        try await send(["id": 2, "method": "thread/start", "params": [
            "cwd": workingDirectory.path, "ephemeral": false, "sandbox": "read-only", "approvalPolicy": "never",
            "baseInstructions": "You are a protocol verification assistant. Reply exactly OK. Never invoke tools, access files, or do project work."
        ]])
        let started = try await response(2)
        print("PROBE: persistent empty thread created without a turn")
        let thread = try XCTUnwrap(started["thread"] as? [String: Any])
        let threadID = try XCTUnwrap(thread["id"] as? String)
        // Materialize history without invoking a model: newly started empty threads
        // have no rollout yet and cannot be rejoined by another client in 0.156.1.
        try await send(["id": 20, "method": "thread/inject_items", "params": [
            "threadId": threadID,
            "items": [["type": "message", "role": "user", "content": [["type": "input_text", "text": "Local protocol probe; no model turn requested."]]]]
        ]])
        _ = try await response(20)
        let monitor = AppServerClient(endpoint: endpoint)
        defer { monitor.close() }
        try await monitor.connect()
        print("PROBE: second connection initialized")
        let list = try await monitor.request("thread/loaded/list")
        print("PROBE: loaded thread list received")
        XCTAssertTrue((list["data"] as? [String] ?? []).contains(threadID))
        let resumed: [String: Any]
        do { resumed = try await monitor.request("thread/resume", params: ["threadId": threadID, "excludeTurns": true]) }
        catch {
            let detail = (monitor.lastProtocolError ?? "No detail").replacingOccurrences(of: "[A-Za-z0-9_./+=-]{40,}", with: "<redacted>", options: .regularExpression)
            XCTFail("Resume failure: \(error.localizedDescription); \(detail)"); return
        }
        print("PROBE: passive subscription established")
        XCTAssertEqual((resumed["thread"] as? [String: Any])?["id"] as? String, threadID)
        let read = try await monitor.request("thread/read", params: ["threadId": threadID, "includeTurns": false])
        let current = try XCTUnwrap(read["thread"] as? [String: Any])
        XCTAssertEqual((current["status"] as? [String: Any])?["type"] as? String, "idle")
        XCTAssertTrue((current["turns"] as? [Any] ?? []).isEmpty)
        // Confirm this second connection receives thread notifications without a model turn.
        let notification = expectation(description: "Passive client receives thread/name/updated")
        monitor.onNotification = { method, params in
            if method == "thread/name/updated", params["threadId"] as? String == threadID { notification.fulfill() }
        }
        try await send(["id": 3, "method": "thread/name/set", "params": ["threadId": threadID, "name": "Heartbeat protocol probe"]])
        _ = try await response(3)
        await fulfillment(of: [notification], timeout: 5)
        if liveTurn {
            let usageEvent = expectation(description: "Real thread/tokenUsage/updated")
            let completed = expectation(description: "Real turn/completed")
            var gotUsage = false
            var toolItems: [String] = []
            monitor.onNotification = { method, params in
                guard params["threadId"] as? String == threadID else { return }
                if method == "thread/tokenUsage/updated", !gotUsage,
                   let data = try? JSONSerialization.data(withJSONObject: params),
                   let value = try? JSONDecoder().decode(UsageNotification.self, from: data) {
                    gotUsage = true
                    XCTAssertGreaterThan(value.tokenUsage.last.inputTokens, 0)
                    XCTAssertNotNil(value.tokenUsage.modelContextWindow)
                    print("LIVE USAGE: input=\(value.tokenUsage.last.inputTokens) cached=\(value.tokenUsage.last.cachedInputTokens) cacheWrite=\(value.tokenUsage.last.cacheWriteInputTokens) total=\(value.tokenUsage.last.totalTokens) window=\(value.tokenUsage.modelContextWindow ?? 0)")
                    usageEvent.fulfill()
                }
                if method == "item/started", let item = params["item"] as? [String: Any], let type = item["type"] as? String,
                   !["userMessage", "agentMessage", "reasoning"].contains(type) { toolItems.append(type) }
                if method == "turn/completed" {
                    XCTAssertEqual((params["turn"] as? [String: Any])?["status"] as? String, "completed")
                    completed.fulfill()
                }
            }
            let heartbeatID = try await monitor.startHeartbeat(threadID: threadID)
            XCTAssertFalse(heartbeatID.isEmpty)
            await fulfillment(of: [usageEvent, completed], timeout: 60)
            XCTAssertTrue(toolItems.isEmpty, "Unexpected tool items in test turn: \(toolItems)")
        }
        try await send(["id": 4, "method": "thread/archive", "params": ["threadId": threadID]])
        _ = try await response(4)
    }
}
