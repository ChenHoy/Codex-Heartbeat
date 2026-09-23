import SwiftUI
import AppKit
import HeartbeatCore

@MainActor final class Dashboard: ObservableObject {
    @Published var sessions: [SessionMonitor] = []
    @Published var warning: String?
    @Published var now = Date()
    private var loop: Task<Void, Never>?
    init() { start() }
    var hasWarning: Bool { warning != nil || sessions.contains { $0.warning } }
    var isKeepingWarm: Bool { sessions.contains { $0.threads.contains { $0.schedule.enabled } } }
    var symbol: String { hasWarning ? "heart.slash" : isKeepingWarm ? "heart.fill" : "heart" }
    func start() {
        guard loop == nil else { return }
        loop = Task {
            while !Task.isCancelled {
                do {
                    let scan = try await Task.detached { try SessionRegistry().scan() }.value
                    warning = scan.warnings.first
                    let ids = Set(scan.sessions.map(\.id))
                    for removed in sessions where !ids.contains(removed.id) { removed.stop() }
                    sessions.removeAll { !ids.contains($0.id) }
                    for registration in scan.sessions {
                        if let existing = sessions.first(where: { $0.id == registration.id }) {
                            if existing.registration != registration {
                                existing.stop(); sessions.removeAll { $0.id == registration.id }
                            } else { continue }
                        }
                        let monitor = SessionMonitor(registration: registration)
                        sessions.append(monitor); monitor.start()
                    }
                    for session in sessions { session.tick() }
                } catch { warning = "Registry unavailable: \(error.localizedDescription)" }
                now = Date()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }
    func stop() { loop?.cancel(); loop = nil; sessions.forEach { $0.stop() } }
}

@main struct CodexHeartbeatApp: App {
    @StateObject private var dashboard = Dashboard()
    init() { NSApplication.shared.setActivationPolicy(.accessory) }
    var body: some Scene {
        MenuBarExtra {
            DashboardView(dashboard: dashboard)
        } label: {
            Image(systemName: dashboard.symbol)
                .accessibilityLabel(dashboard.hasWarning ? "Codex Heartbeat warning" : "Codex Heartbeat")
                .onAppear { dashboard.start() }
        }
        .menuBarExtraStyle(.window)
    }
}

struct DashboardView: View {
    @ObservedObject var dashboard: Dashboard
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "heart").foregroundStyle(.pink)
                Text("Codex Heartbeat").font(.headline)
                Spacer()
                Text("\(dashboard.sessions.count) sessions").foregroundStyle(.secondary).font(.caption)
            }
            Text("Live monitoring · opt-in keep-warm")
                .font(.caption).foregroundStyle(.secondary)
            if let warning = dashboard.warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
            }
            ScrollView {
                VStack(spacing: 12) {
                    if dashboard.sessions.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("No managed sessions").font(.headline)
                            Text("In your project’s terminal, run:")
                            Text("codex-heartbeat").font(.system(.body, design: .monospaced)).textSelection(.enabled)
                            Text("Your normal ChatGPT login is used. Keep-warm is never enabled automatically.")
                                .font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    }
                    ForEach(dashboard.sessions) { monitor in
                        SessionView(monitor: monitor, now: dashboard.now)
                    }
                }
            }.frame(maxHeight: 540)
            Divider()
            HStack {
                Text("Local only · no analytics").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Quit") { dashboard.stop(); NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
            }
        }.padding(16).frame(width: 460)
    }
}

struct SessionView: View {
    @ObservedObject var monitor: SessionMonitor
    let now: Date
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(monitor.registration.name).font(.headline).lineLimit(1)
                Spacer()
                if monitor.warning { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                Button { NSWorkspace.shared.open(URL(fileURLWithPath: monitor.registration.workingDirectory, isDirectory: true)) }
                    label: { Image(systemName: "folder") }
                    .buttonStyle(.borderless).help("Open working directory in Finder")
            }
            Text(monitor.registration.workingDirectory).font(.caption).foregroundStyle(.secondary)
                .lineLimit(2).textSelection(.enabled)
            Text(monitor.connectionMessage).font(.caption).foregroundStyle(monitor.warning ? .orange : .secondary)
            if monitor.connectionStatus == .disconnected {
                Button("Reconnect") { monitor.reconnect() }.controlSize(.small)
            }
            if monitor.threads.isEmpty {
                Text("Waiting for the terminal to open a thread…").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(monitor.threads) { thread in
                ThreadView(thread: thread, monitor: monitor, now: now)
            }
        }.padding(12).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct ThreadView: View {
    let thread: MonitoredThread
    @ObservedObject var monitor: SessionMonitor
    let now: Date
    private var color: Color {
        switch thread.usage?.pressure { case .orange: return .orange; case .red: return .red; default: return .green }
    }
    private func count(_ number: Int64?) -> String { number.map { $0.formatted() } ?? "—" }
    private var elapsed: String {
        let seconds = max(0, Int(now.timeIntervalSince(thread.lastActivity)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack {
                Circle().fill(thread.status == .active ? .green : thread.status == .idle ? .secondary : .orange).frame(width: 7, height: 7)
                Text(thread.status.rawValue.capitalized).font(.subheadline.weight(.medium))
                if let name = thread.name { Text(name).lineLimit(1).font(.caption) }
                Spacer()
                Text("Activity \(elapsed) ago").font(.caption2).foregroundStyle(.secondary)
            }
            if thread.cwd != monitor.registration.workingDirectory {
                Text(thread.cwd).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let usage = thread.usage, let used = usage.fractionUsed, !thread.contextIsStale {
                ProgressView(value: used).tint(color)
                HStack {
                    Text("≈\(Int((usage.percentRemaining ?? 0).rounded()))% context remaining").foregroundStyle(color)
                    Spacer()
                    Text("Window \(count(usage.modelContextWindow))")
                }.font(.caption)
            } else {
                Text(thread.contextIsStale ? "Context estimate stale after compaction" : "Context usage not yet reported")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                metric("Latest input", thread.usage?.last.inputTokens, "Cached input", thread.usage?.last.cachedInputTokens)
                metric("Cache write", thread.usage?.last.cacheWriteInputTokens, "Latest total", thread.usage?.last.totalTokens)
                metric("Output", thread.usage?.last.outputTokens, "Reasoning output", thread.usage?.last.reasoningOutputTokens)
                metric("Thread total", thread.usage?.total.totalTokens, "Context window", thread.usage?.modelContextWindow)
            }.font(.caption2).monospacedDigit()
            Toggle("Keep Warm", isOn: Binding(
                get: { thread.schedule.enabled },
                set: { monitor.setKeepWarm($0, threadID: thread.id) }
            )).controlSize(.small).disabled(thread.status != .idle && !thread.schedule.enabled)
            Text(HeartbeatSafety.disclosure).font(.caption2).foregroundStyle(.secondary)
            if let due = thread.schedule.due {
                let minutes = max(1, Int(ceil((due - ProcessInfo.processInfo.systemUptime) / 60)))
                Text("Next heartbeat in ≈\(minutes)m · \(thread.schedule.pulses)/2 sent")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let date = thread.lastHeartbeat {
                Label("Heartbeat sent at \(date.formatted(date: .omitted, time: .shortened))", systemImage: "heart.fill")
                    .font(.caption2).foregroundStyle(thread.heartbeatError ? .orange : .secondary)
            }
            if let note = thread.note { Text(note).font(.caption2).foregroundStyle(.secondary) }
            if !thread.schedule.enabled, let reason = thread.schedule.stoppedReason {
                Text("Keep-warm off · \(reason)").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
    private func metric(_ first: String, _ value: Int64?, _ second: String, _ other: Int64?) -> some View {
        GridRow {
            Text(first).foregroundStyle(.secondary); Text(count(value))
            Text(second).foregroundStyle(.secondary); Text(count(other))
        }
    }
}
