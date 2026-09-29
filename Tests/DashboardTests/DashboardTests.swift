import XCTest
import SwiftUI
import AppKit
@testable import CodexHeartbeat
import HeartbeatCore

final class DashboardTests: XCTestCase {
    @MainActor func testPerThreadModelChangesInvalidateOldUsage() throws {
        let identity = try ProcessIdentity.capture(ProcessInfo.processInfo.processIdentifier)
        let record = SessionRegistration(name: "Models", workingDirectory: "/tmp", endpoint: "ws://127.0.0.1:9001",
                                         owner: identity, server: identity, cli: identity, codexVersion: "test")
        let monitor = SessionMonitor(registration: record)
        for (id, model) in [("a", "gpt-6-sol"), ("b", "gpt-5.6-terra")] {
            monitor.consume(method: "thread/started", params: ["thread": ["id": id, "model": model, "cwd": "/tmp",
                "updatedAt": 0, "status": ["type": "idle"]]])
        }
        let tokens: [String: Any] = ["inputTokens": 100000, "cachedInputTokens": 80000,
            "outputTokens": 5, "reasoningOutputTokens": 0, "totalTokens": 100005]
        let event: [String: Any] = ["threadId": "a", "turnId": "turn", "tokenUsage": ["last": tokens, "total": tokens, "modelContextWindow": 258400]]
        monitor.consume(method: "thread/tokenUsage/updated", params: event)
        monitor.consume(method: "thread/settings/updated", params: ["threadId": "a", "threadSettings": ["model": "custom"]])
        XCTAssertEqual(monitor.threads[0].model, "custom")
        XCTAssertTrue(monitor.threads[0].contextIsStale)
        XCTAssertEqual(monitor.threads[1].model, "gpt-5.6-terra")
        monitor.consume(method: "thread/tokenUsage/updated", params: event)
        XCTAssertFalse(monitor.threads[0].contextIsStale)
        XCTAssertNil(ContextDisplayMode.modelCapacity.window(model: monitor.threads[0].model, usage: monitor.threads[0].usage))
    }
    @MainActor func testSessionScrollAreaHasVisibleHeight() async throws {
        let identity = try ProcessIdentity.capture(ProcessInfo.processInfo.processIdentifier)
        let suite = "HeartbeatDashboardTests-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        for mode in ContextDisplayMode.allCases {
            preferences.set(mode.rawValue, forKey: "contextDisplayMode")
            for count in [0, 1, 4] {
                for scheme in [ColorScheme.light, .dark] {
                    let dashboard = Dashboard(startMonitoring: false)
                    for index in 0..<count {
                        let record = SessionRegistration(name: "Session \(index)", workingDirectory: "/tmp/project-\(index)",
                            endpoint: "ws://127.0.0.1:9001", owner: identity, server: identity, cli: identity, codexVersion: "test")
                        let monitor = SessionMonitor(registration: record)
                        monitor.consume(method: "thread/started", params: ["thread": ["id": "t", "cwd": record.workingDirectory,
                            "model": "gpt-6-sol", "updatedAt": Int(Date().timeIntervalSince1970), "status": ["type": "idle"]]])
                        if index % 2 == 1 {
                            let tokens: [String: Any] = ["inputTokens": 12000, "cachedInputTokens": 8000,
                                "outputTokens": 5, "reasoningOutputTokens": 0, "totalTokens": 12005]
                            monitor.consume(method: "thread/tokenUsage/updated", params: ["threadId": "t", "turnId": "turn",
                                "tokenUsage": ["last": tokens, "total": tokens, "modelContextWindow": 258400]])
                        }
                        dashboard.sessions.append(monitor)
                    }
                    let host = NSHostingView(rootView: DashboardView(dashboard: dashboard).environment(\.colorScheme, scheme).defaultAppStorage(preferences))
                    host.frame = NSRect(origin: .zero, size: host.fittingSize)
                    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                    window.contentView = host
                    window.orderFront(nil)
                    defer { window.orderOut(nil) }
                    try await Task.sleep(nanoseconds: 100_000_000)
                    host.layoutSubtreeIfNeeded()
                    func scrollViews(_ view: NSView) -> [NSScrollView] {
                        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
                    }
                    let scroll = try XCTUnwrap(scrollViews(host).first)
                    XCTAssertEqual(scroll.frame.height, count == 0 ? 140 : 420, accuracy: 1)
                    XCTAssertGreaterThan(scroll.contentView.bounds.height, 0)
                    XCTAssertEqual(host.frame.width, 460, accuracy: 1)
                    if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                        try bitmap.representation(using: .png, properties: [:])?.write(to:
                            URL(fileURLWithPath: "/private/tmp/heartbeat-dashboard-\(count)-\(scheme)-\(mode.rawValue).png"))
                    }
                    if count > 1 {
                        XCTAssertGreaterThan(scroll.documentView?.frame.height ?? 0, scroll.contentView.bounds.height)
                        scroll.contentView.scroll(to: NSPoint(x: 0, y: 310))
                        scroll.reflectScrolledClipView(scroll.contentView)
                        host.layoutSubtreeIfNeeded()
                        XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, 0)
                        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                            host.cacheDisplay(in: host.bounds, to: bitmap)
                            try bitmap.representation(using: .png, properties: [:])?.write(to:
                                URL(fileURLWithPath: "/private/tmp/heartbeat-dashboard-scrolled-\(scheme)-\(mode.rawValue).png"))
                        }
                    }
                }
            }
        }
    }
}
