import XCTest
import Foundation
import Darwin
@testable import HeartbeatCore
import HeartbeatSystem

final class CoreTests: XCTestCase {
    func usage(_ used: Int64, window: String = "1000", cacheWrite: String = ",\"cacheWriteInputTokens\":7") throws -> ThreadUsage {
        let last = "{\"inputTokens\":500,\"cachedInputTokens\":400\(cacheWrite),\"outputTokens\":20,\"reasoningOutputTokens\":10,\"totalTokens\":\(used)}"
        let json = "{\"last\":\(last),\"total\":{\"inputTokens\":90000,\"cachedInputTokens\":80000,\"outputTokens\":500,\"reasoningOutputTokens\":100,\"totalTokens\":90500},\"modelContextWindow\":\(window)}"
        return try JSONDecoder().decode(ThreadUsage.self, from: Data(json.utf8))
    }
    func testContextUsesLatestTotalNotLifetimeOrDoubleCountedCache() throws {
        let value = try usage(600)
        XCTAssertEqual(value.fractionUsed!, 0.6, accuracy: 0.0001)
        XCTAssertEqual(value.percentRemaining!, 40, accuracy: 0.0001)
        XCTAssertEqual(value.last.cacheWriteInputTokens, 7)
        XCTAssertEqual(value.total.totalTokens, 90500)
    }
    func testContextUnknownAndClamp() throws {
        XCTAssertNil(try usage(100, window: "null").fractionUsed)
        XCTAssertNil(try usage(100, window: "0").fractionUsed)
        XCTAssertNil(try usage(100, window: "-1").fractionUsed)
        XCTAssertEqual(try usage(1200).fractionUsed, 1)
        XCTAssertEqual(try usage(0).percentRemaining, 100)
    }
    func testThresholdBoundaries() throws {
        XCTAssertEqual(try usage(600).pressure, .normal)
        XCTAssertEqual(try usage(601).pressure, .orange)
        XCTAssertEqual(try usage(800).pressure, .orange)
        XCTAssertEqual(try usage(801).pressure, .red)
    }
    func testMissingCacheWriteDefaultsToZeroAndNegativeCountsFail() throws {
        XCTAssertEqual(try usage(100, cacheWrite: "").last.cacheWriteInputTokens, 0)
        XCTAssertThrowsError(try usage(-1))
    }
    func testRealProtocolEventShapeDecodes() throws {
        let value = try usage(650)
        let data = try JSONEncoder().encode(value)
        let event = "{\"threadId\":\"thread-1\",\"turnId\":\"turn-2\",\"tokenUsage\":\(String(decoding: data, as: UTF8.self))}"
        let decoded = try JSONDecoder().decode(UsageNotification.self, from: Data(event.utf8))
        XCTAssertEqual(decoded.threadId, "thread-1")
        XCTAssertEqual(decoded.turnId, "turn-2")
        XCTAssertEqual(decoded.tokenUsage, value)
    }
    func testExplicitActivationAndTwoPulseLimit() {
        var schedule = HeartbeatSchedule()
        XCTAssertFalse(schedule.takeDuePulse(now: 999999, idle: true))
        schedule.enable(now: 100, idle: true)
        XCTAssertEqual(schedule.due, 1600)
        XCTAssertFalse(schedule.takeDuePulse(now: 1599, idle: true))
        XCTAssertTrue(schedule.takeDuePulse(now: 1600, idle: true))
        XCTAssertEqual(schedule.due, 3100)
        XCTAssertTrue(schedule.takeDuePulse(now: 3100, idle: true))
        XCTAssertTrue(schedule.enabled) // Remains immediately disableable while pulse two is in flight.
        XCTAssertNil(schedule.due)
        XCTAssertFalse(schedule.takeDuePulse(now: 10000, idle: true))
        XCTAssertEqual(schedule.pulses, 2)
    }
    func testActivityImmediatelyCancelsAndDoesNotAutoRearm() {
        var schedule = HeartbeatSchedule()
        schedule.enable(now: 0, idle: true)
        schedule.activity()
        schedule.becameIdle(now: 1600)
        XCTAssertFalse(schedule.enabled)
        XCTAssertNil(schedule.due)
        XCTAssertFalse(schedule.takeDuePulse(now: 4000, idle: true))
    }
    func testBusySessionNoPulseAndIdleTransition() {
        var schedule = HeartbeatSchedule()
        schedule.enable(now: 0, idle: false)
        XCTAssertNil(schedule.due)
        schedule.becameIdle(now: 200)
        XCTAssertEqual(schedule.due, 1700)
        XCTAssertFalse(schedule.takeDuePulse(now: 1800, idle: false))
    }
    func testFailureDisableCompactionAndTerminationCancel() {
        for reason in ["failure", "disabled", "compaction", "termination", "disconnected"] {
            var schedule = HeartbeatSchedule()
            schedule.enable(now: 0, idle: true); schedule.stop(reason)
            XCTAssertFalse(schedule.enabled); XCTAssertNil(schedule.due)
            XCTAssertEqual(schedule.stoppedReason, reason)
        }
    }
    func testLateWakeAndReactivationCannotBurst() {
        var schedule = HeartbeatSchedule()
        schedule.enable(now: 0, idle: true)
        XCTAssertTrue(schedule.takeDuePulse(now: 20000, idle: true))
        XCTAssertEqual(schedule.due, 21500)
        XCTAssertFalse(schedule.takeDuePulse(now: 20000, idle: true))
        schedule.stop("disabled"); schedule.enable(now: 20001, idle: true)
        XCTAssertFalse(schedule.takeDuePulse(now: 20002, idle: true))
        XCTAssertEqual(schedule.due, 21501)
    }
    func testIndependentSessionSchedules() {
        var first = HeartbeatSchedule(); var second = HeartbeatSchedule()
        first.enable(now: 0, idle: true)
        XCTAssertTrue(first.takeDuePulse(now: 1500, idle: true))
        XCTAssertFalse(second.takeDuePulse(now: 1500, idle: true))
    }
    func testHeartbeatPromptIsMinimalAndDisclosed() {
        XCTAssertTrue(HeartbeatSafety.prompt.contains("Do not call tools"))
        XCTAssertTrue(HeartbeatSafety.prompt.contains("Reply only OK"))
        XCTAssertTrue(HeartbeatSafety.disclosure.contains("allowance"))
    }
    func testEndpointValidation() {
        XCTAssertEqual(SessionRegistration.endpointPort("ws://127.0.0.1:9001"), 9001)
        for value in ["ws://0.0.0.0:9001", "ws://localhost:9001", "ws://127.0.0.1:80", "ws://127.0.0.1:9001/", "ws://evil.test:9001", "ws://user:secret@127.0.0.1:9001", "ws://127.0.0.1:9001?x=y", "ws://127.0.0.1:99999", "ws://127.0.0.1:09001"] {
            XCTAssertNil(SessionRegistration.endpointPort(value), value)
        }
    }
    func testArgumentConstructionPreservesLiteralShellMetacharacters() throws {
        let cwd = URL(fileURLWithPath: "/tmp/project;$(touch NEVER)")
        let prompt = "Say 'hello'; `touch NEVER` $(env)"
        let plan = try LaunchPlan(executable: URL(fileURLWithPath: "/usr/bin/codex"), workingDirectory: cwd,
                                  port: 9001, name: "a; b", arguments: ["--model", "some-model", prompt])
        XCTAssertEqual(plan.cliArguments, ["--remote", "ws://127.0.0.1:9001", "--model", "some-model", prompt])
        XCTAssertFalse(plan.serverArguments.contains("sh"))
        XCTAssertEqual(plan.serverArguments.prefix(3), ["app-server", "--listen", "ws://127.0.0.1:9001"])
    }
    func testManagedPlanCannotRedirectOrRunUnmanagedCommand() {
        for args in [["--remote", "ws://evil:1"], ["--remote=ws://evil:1", "resume"], ["exec"], ["login"], ["--no-daemon"]] {
            XCTAssertThrowsError(try LaunchPlan(executable: URL(fileURLWithPath: "/usr/bin/codex"), workingDirectory: URL(fileURLWithPath: "/tmp"), port: 9001, name: nil, arguments: args))
        }
    }
    func testCLICompatibilityRouting() {
        let cwd = URL(fileURLWithPath: "/tmp/project")
        for args in [[], ["--model", "gpt-6-sol"], ["--config", "x=y", "A prompt"],
                     ["resume"], ["resume", "--last"], ["-m", "gpt-6-sol", "resume", "--last"],
                     ["fork", "--last"], ["--image", "exec", "photo.png"],
                     ["--", "resume"], ["--", "--remote"],
                     ["resume", "--", "--help"]] {
            XCTAssertEqual(CLIInvocation(arguments: args, workingDirectory: cwd).route, .managed, "\(args)")
        }
        for args in [["exec", "hello"], ["login"], ["mcp", "list"], ["app-server"],
                     ["--help"], ["resume", "--help"], ["--version"], ["--remote", "ws://127.0.0.1:9002"],
                     ["resume", "--remote=unix:///tmp/codex.sock"], ["--no-daemon"], ["--future-option", "value"]] {
            XCTAssertEqual(CLIInvocation(arguments: args, workingDirectory: cwd).route, .passthrough, "\(args)")
        }
    }
    func testResumePreservesDirectoryChoiceAndArguments() throws {
        let cwd = URL(fileURLWithPath: "/tmp/project")
        let args = ["--model", "gpt-6-sol", "resume", "--last"]
        let invocation = CLIInvocation(arguments: args, workingDirectory: cwd)
        XCTAssertEqual(invocation.workingDirectory.path, cwd.path)
        let plan = try LaunchPlan(executable: URL(fileURLWithPath: "/usr/bin/codex"), workingDirectory: invocation.workingDirectory,
                                  port: 9001, name: nil, arguments: args)
        XCTAssertEqual(plan.cliArguments, ["--remote", "ws://127.0.0.1:9001"] + args)
        XCTAssertFalse(plan.cliArguments.contains("--cd"), "Resume must retain Codex's saved-directory choice")
        let explicit = CLIInvocation(arguments: ["--cd", "../other", "resume", "--last"], workingDirectory: cwd)
        XCTAssertEqual(explicit.workingDirectory.standardizedFileURL.path, "/tmp/other")
    }
    func record() -> SessionRegistration {
        SessionRegistration(name: "Project", workingDirectory: "/private/tmp/project", endpoint: "ws://127.0.0.1:9001",
                            owner: ProcessIdentity(pid: 999991, startStamp: 1, executable: "/wrapper"),
                            server: ProcessIdentity(pid: 999992, startStamp: 2, executable: "/codex"),
                            cli: ProcessIdentity(pid: 999993, startStamp: 3, executable: "/codex"), codexVersion: "0.156.1")
    }
    func tempRegistry() throws -> SessionRegistry {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().appendingPathComponent("heartbeat-test-" + UUID().uuidString)
        let registry = SessionRegistry(directory: url)
        try registry.prepare()
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return registry
    }
    func testRegistryRoundTripPrivateAtomicAndStalePruning() throws {
        let registry = try tempRegistry(); let entry = record()
        let directoryMode = try FileManager.default.attributesOfItem(atPath: registry.directory.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(directoryMode?.intValue, 0o700)
        try registry.write(entry)
        XCTAssertEqual(try registry.read(registry.file(for: entry.id)), entry)
        let mode = try FileManager.default.attributesOfItem(atPath: registry.file(for: entry.id).path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        XCTAssertTrue(try registry.scan().sessions.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: registry.file(for: entry.id).path))
    }
    func testMalformedRecordsAndSymlinksIgnoredWithoutDeletion() throws {
        let registry = try tempRegistry()
        let invalid = registry.directory.appendingPathComponent(UUID().uuidString + ".json")
        try Data("{}".utf8).write(to: invalid); chmod(invalid.path, 0o600)
        let link = registry.directory.appendingPathComponent(UUID().uuidString + ".json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: invalid)
        let scan = try registry.scan()
        XCTAssertEqual(scan.warnings.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: invalid.path))
        XCTAssertThrowsError(try registry.read(link))
    }
    func testWorldReadableRegistryAndFilesAreRejected() throws {
        let registry = try tempRegistry(); let entry = record()
        try registry.write(entry)
        chmod(registry.file(for: entry.id).path, 0o644)
        XCTAssertThrowsError(try registry.read(registry.file(for: entry.id)))
        chmod(registry.directory.path, 0o755)
        XCTAssertThrowsError(try registry.prepare())
    }
    func testPIDReuseStampRejected() throws {
        let current = try ProcessIdentity.capture(getpid())
        XCTAssertTrue(current.isAlive)
        XCTAssertFalse(ProcessIdentity(pid: current.pid, startStamp: current.startStamp + 1, executable: current.executable).isAlive)
        XCTAssertFalse(ProcessIdentity(pid: current.pid, startStamp: current.startStamp, executable: "/wrong").isAlive)
    }
    @MainActor func testMonitoringCannotSendModelTurns() async throws {
        let rpc = AppServerClient(endpoint: URL(string: "ws://127.0.0.1:9001")!)
        for method in ["turn/start", "turn/steer", "command/exec", "thread/start", "config/value/write"] {
            do { _ = try await rpc.request(method); XCTFail("Mutation allowed: \(method)") }
            catch { XCTAssertTrue(error.localizedDescription.contains("refuses mutating")) }
        }
        rpc.close()
    }
    @MainActor func testMonitorCompactionAndErrorCancelReminders() throws {
        let monitor = SessionMonitor(registration: record())
        monitor.consume(method: "thread/started", params: ["thread": ["id": "t", "cwd": "/tmp", "updatedAt": 1, "status": ["type": "idle"]]])
        XCTAssertEqual(monitor.threads.count, 1)
        let data = try JSONEncoder().encode(usage(650))
        let object = try JSONSerialization.jsonObject(with: data)
        monitor.consume(method: "thread/tokenUsage/updated", params: ["threadId": "t", "turnId": "turn", "tokenUsage": object])
        XCTAssertEqual(monitor.threads[0].usage?.last.totalTokens, 650)
        monitor.consume(method: "item/started", params: ["threadId": "t", "item": ["type": "contextCompaction"]])
        XCTAssertTrue(monitor.threads[0].contextIsStale)
        XCTAssertEqual(monitor.threads[0].schedule.stoppedReason, "Context compacted")
        monitor.consume(method: "error", params: ["threadId": "t"])
        XCTAssertEqual(monitor.threads[0].status, .failed)
        XCTAssertFalse(monitor.threads[0].schedule.enabled)
    }
    @MainActor func testMalformedThreadSummarySurfacesWarningAndRecovers() {
        let monitor = SessionMonitor(registration: record())
        monitor.consume(method: "thread/started", params: ["thread": ["id": "broken"]])
        XCTAssertTrue(monitor.warning)
        XCTAssertTrue(monitor.threadWarning?.contains("broken") == true)
        XCTAssertTrue(monitor.threads.isEmpty)
        monitor.consume(method: "thread/started", params: ["thread": ["id": "broken", "cwd": "/tmp", "updatedAt": 1, "status": ["type": "idle"]]])
        XCTAssertNil(monitor.threadWarning)
        XCTAssertEqual(monitor.threads.count, 1)
        XCTAssertFalse(monitor.threads[0].schedule.enabled)
    }
    @MainActor func testResumeCannotOverrideUserConfiguration() async {
        let rpc = AppServerClient(endpoint: URL(string: "ws://127.0.0.1:9001")!)
        let cases: [[String: Any]] = [
            ["threadId": "t", "excludeTurns": true, "sandbox": "danger-full-access"],
            ["threadId": "t", "excludeTurns": true, "config": ["x": "y"]],
            ["threadId": "t", "excludeTurns": false]
        ]
        for params in cases {
            do { _ = try await rpc.request("thread/resume", params: params); XCTFail("Unsafe resume allowed") }
            catch { XCTAssertTrue(error.localizedDescription.contains("refuses configuration")) }
        }
        rpc.close()
    }
}
