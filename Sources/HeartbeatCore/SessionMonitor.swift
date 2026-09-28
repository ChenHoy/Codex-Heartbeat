import Foundation
import Combine

public struct MonitoredThread: Identifiable {
    public let id: String
    public var name: String?
    public var cwd: String
    public var status: SessionStatus
    public var usage: ThreadUsage?
    public var usageUpdatedAt: Date?
    public var lastActivity: Date
    public var schedule = HeartbeatSchedule()
    public var lastHeartbeat: Date?
    public var heartbeatError = false
    public var note: String?
    public var contextIsStale = false
}

@MainActor public final class SessionMonitor: ObservableObject, Identifiable {
    public let registration: SessionRegistration
    public nonisolated let id: UUID
    @Published public private(set) var threads: [MonitoredThread] = []
    @Published public private(set) var connectionStatus: SessionStatus = .disconnected
    @Published public private(set) var connectionMessage = "Connecting…"
    @Published public private(set) var threadWarnings: [String: String] = [:]
    public var threadWarning: String? { threadWarnings.keys.sorted().compactMap { threadWarnings[$0] }.first }
    private var client: AppServerClient?
    private var task: Task<Void, Never>?
    private var attached = Set<String>()
    private var startingHeartbeat = Set<String>()
    private var heartbeatTurns: [String: String] = [:] // thread ID -> turn ID
    private var knownHeartbeatTurns = Set<String>()
    private var deferredEvents: [String: [(String, [String: Any])]] = [:]
    private var refreshing = false
    public var warning: Bool { !threadWarnings.isEmpty || connectionStatus == .failed || connectionStatus == .disconnected || threads.contains { $0.status == .failed || $0.heartbeatError } }
    public init(registration: SessionRegistration) { self.registration = registration; id = registration.id }

    public func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            do {
                guard self.registration.validConnection, let url = URL(string: self.registration.endpoint) else {
                    throw HeartbeatError.message("Process identity or listener ownership could not be verified")
                }
                let rpc = AppServerClient(endpoint: url)
                self.client = rpc
                rpc.onNotification = { [weak self] method, params in self?.consume(method: method, params: params) }
                rpc.onDisconnect = { [weak self] in self?.disconnect("App Server disconnected") }
                try await rpc.connect()
                self.connectionStatus = .idle; self.connectionMessage = "Connected"
                while !Task.isCancelled {
                    guard self.registration.validConnection else { throw HeartbeatError.message("Session ended or listener identity changed") }
                    try await self.refresh(rpc)
                    self.tick()
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                }
            } catch {
                if !Task.isCancelled { self.disconnect(error.localizedDescription) }
            }
        }
    }
    public func stop() {
        task?.cancel(); task = nil
        client?.onNotification = nil; client?.onDisconnect = nil
        client?.close(); client = nil
        for index in threads.indices { threads[index].schedule.stop("Monitoring stopped") }
        startingHeartbeat.removeAll(); heartbeatTurns.removeAll(); knownHeartbeatTurns.removeAll(); deferredEvents.removeAll()
    }
    public func reconnect() {
        stop(); attached.removeAll()
        connectionStatus = .disconnected; connectionMessage = "Connecting…"
        start()
    }
    public func refreshNow() async {
        guard connectionMessage != "Connecting…" else { return }
        guard connectionStatus == .idle, let client else { reconnect(); return }
        do { try await refresh(client) }
        catch { disconnect(error.localizedDescription) }
    }
    private func disconnect(_ message: String) {
        connectionStatus = .disconnected; connectionMessage = message
        for index in threads.indices {
            threads[index].status = .disconnected
            threads[index].schedule.stop("Disconnected")
        }
        startingHeartbeat.removeAll(); heartbeatTurns.removeAll(); knownHeartbeatTurns.removeAll(); deferredEvents.removeAll()
        client?.onNotification = nil; client?.onDisconnect = nil
        client?.close(); client = nil
    }
    private func refresh(_ rpc: AppServerClient) async throws {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        var cursor: String?
        var loaded = Set<String>()
        repeat {
            var params: [String: Any] = ["limit": 100]
            if let cursor { params["cursor"] = cursor }
            let list = try await rpc.request("thread/loaded/list", params: params)
            loaded.formUnion(list["data"] as? [String] ?? [])
            cursor = list["nextCursor"] as? String
        } while cursor != nil && !Task.isCancelled
        threadWarnings = threadWarnings.filter { loaded.contains($0.key) }
        for id in loaded.sorted() {
            do {
            let result = try await rpc.request("thread/read", params: ["threadId": id, "includeTurns": false])
            guard let summary = readSummary(result["thread"], threadID: id) else { continue }
            guard summary.parentThreadId == nil else { continue }
            upsert(summary)
            if !attached.contains(id) {
                // Rejoin only threads reported as loaded. No model turn, config overrides,
                // new thread or history hydration is requested. CLI remains the interactive client.
                _ = try await rpc.request("thread/resume", params: ["threadId": id, "excludeTurns": true])
                attached.insert(id)
                connectionMessage = "Connected"
            }
            } catch HeartbeatError.threadNotMaterialized {
                // Codex creates the rollout lazily. Waiting is passive; do not
                // create history or send a turn merely to make monitoring work.
                connectionMessage = "Connected · waiting for the first user turn"
            }
        }
        for index in threads.indices where !loaded.contains(threads[index].id) {
            threads[index].status = .disconnected
            threads[index].schedule.stop("Thread unloaded")
            attached.remove(threads[index].id)
        }
    }
    private func upsert(_ summary: ThreadSummary) {
        if let index = threads.firstIndex(where: { $0.id == summary.id }) {
            threads[index].name = summary.name; threads[index].cwd = summary.cwd
            updateStatus(index, summary.sessionStatus)
            // A heartbeat updates this server timestamp too. Turn events,
            // rather than updatedAt, identify actual user activity.
        } else {
            threads.append(MonitoredThread(id: summary.id, name: summary.name, cwd: summary.cwd,
                                          status: summary.sessionStatus,
                                          lastActivity: Date(timeIntervalSince1970: Double(summary.updatedAt))))
        }
    }
    private func updateStatus(_ index: Int, _ status: SessionStatus) {
        let old = threads[index].status
        threads[index].status = status
        let heartbeatActive = startingHeartbeat.contains(threads[index].id) || heartbeatTurns[threads[index].id] != nil
        if status == .active && old != .active && !heartbeatActive {
            threads[index].schedule.activity(); threads[index].lastActivity = Date()
        }
        if status == .idle && old == .active && !heartbeatActive {
            threads[index].lastActivity = Date(); threads[index].schedule.becameIdle(now: uptime)
        }
        if status == .failed || status == .disconnected { threads[index].schedule.stop(status.rawValue.capitalized) }
    }
    private var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }
    public func setKeepWarm(_ enabled: Bool, threadID: String) {
        guard let index = threads.firstIndex(where: { $0.id == threadID }) else { return }
        if enabled && connectionStatus == .idle && threads[index].status == .idle && attached.contains(threadID) {
            threads[index].schedule.enable(now: uptime, idle: true)
            threads[index].heartbeatError = false
            threads[index].note = nil
        } else {
            threads[index].schedule.stop("Disabled")
            interruptIfOwned(threadID)
        }
    }
    public func tick() {
        for index in threads.indices {
            let id = threads[index].id
            guard !startingHeartbeat.contains(id), heartbeatTurns[id] == nil,
                  connectionStatus == .idle, attached.contains(id), registration.validConnection else { continue }
            if threads[index].schedule.takeDuePulse(now: uptime, idle: threads[index].status == .idle) {
                startingHeartbeat.insert(id)
                Task { [weak self] in await self?.sendHeartbeat(threadID: id) }
            }
        }
    }
    private func sendHeartbeat(threadID: String) async {
        guard let rpc = client, let index = threads.firstIndex(where: { $0.id == threadID }),
              startingHeartbeat.contains(threadID), registration.validConnection,
              threads[index].status == .idle,
              threads[index].schedule.enabled else {
            if let index = threads.firstIndex(where: { $0.id == threadID }), threads[index].status == .active {
                userActivity(index)
            }
            startingHeartbeat.remove(threadID); return
        }
        do {
            let turnID = try await rpc.startHeartbeat(threadID: threadID)
            startingHeartbeat.remove(threadID)
            guard let index = threads.firstIndex(where: { $0.id == threadID }) else {
                try? await rpc.interruptHeartbeat(threadID: threadID, turnID: turnID); return
            }
            knownHeartbeatTurns.insert(turnID)
            heartbeatTurns[threadID] = turnID
            threads[index].lastHeartbeat = Date()
            threads[index].note = "Heartbeat \(threads[index].schedule.pulses)/2 sent · awaiting OK"
            let events = deferredEvents.removeValue(forKey: threadID) ?? []
            for (method, params) in events { consume(method: method, params: params) }
            if threads[index].schedule.stoppedReason != nil {
                interruptIfOwned(threadID)
            }
        } catch {
            startingHeartbeat.remove(threadID)
            deferredEvents.removeValue(forKey: threadID)
            failHeartbeat(threadID, "Heartbeat failed: \(error.localizedDescription)")
        }
    }
    private func failHeartbeat(_ threadID: String, _ reason: String) {
        guard let index = threads.firstIndex(where: { $0.id == threadID }) else { return }
        threads[index].schedule.stop(reason)
        threads[index].heartbeatError = true
        threads[index].note = reason
    }
    private func interruptIfOwned(_ threadID: String) {
        guard let turnID = heartbeatTurns[threadID], let rpc = client else { return }
        Task { try? await rpc.interruptHeartbeat(threadID: threadID, turnID: turnID) }
    }
    private func userActivity(_ index: Int) {
        threads[index].lastActivity = Date()
        threads[index].schedule.activity()
    }
    public func consume(method: String, params: [String: Any]) {
        if method == "thread/started" {
            let object = params["thread"] as? [String: Any]
            if let summary = readSummary(object, threadID: object?["id"] as? String ?? "unknown"),
               summary.parentThreadId == nil { upsert(summary) }
            return
        }
        guard let id = params["threadId"] as? String, let index = threads.firstIndex(where: { $0.id == id }) else { return }
        let turnID = params["turnId"] as? String ?? (params["turn"] as? [String: Any])?["id"] as? String
        let ownTurn = turnID.map { knownHeartbeatTurns.contains($0) } ?? false
        if startingHeartbeat.contains(id), !ownTurn,
           ["turn/started", "turn/completed", "item/started", "item/completed", "error"].contains(method) {
            deferredEvents[id, default: []].append((method, params))
            return
        }
        switch method {
        case "thread/tokenUsage/updated":
            guard let notification = decode(UsageNotification.self, params) else {
                threads[index].schedule.stop("Invalid telemetry")
                threads[index].note = "Invalid token telemetry received"; return
            }
            threads[index].usage = notification.tokenUsage
            threads[index].usageUpdatedAt = Date()
            threads[index].contextIsStale = false
            if !knownHeartbeatTurns.contains(notification.turnId) && !startingHeartbeat.contains(id) { userActivity(index) }
        case "thread/status/changed":
            if let status = params["status"] as? [String: Any], let type = status["type"] as? String {
                updateStatus(index, type == "active" ? .active : type == "idle" ? .idle : type == "systemError" ? .failed : .disconnected)
            }
        case "turn/started":
            if !ownTurn { userActivity(index); interruptIfOwned(id) }
            threads[index].status = .active
        case "turn/steered":
            userActivity(index); interruptIfOwned(id)
            threads[index].status = .active
        case "turn/completed":
            let turn = params["turn"] as? [String: Any]
            let result = turn?["status"] as? String
            if ownTurn {
                threads[index].status = .idle
                heartbeatTurns.removeValue(forKey: id)
                if threads[index].heartbeatError { break }
                if result == "completed" {
                    threads[index].note = "Heartbeat \(threads[index].schedule.pulses)/2 completed"
                    if threads[index].schedule.pulses == 2 { threads[index].schedule.stop("Finished two heartbeats") }
                }
                else if result == "interrupted", let reason = threads[index].schedule.stoppedReason,
                        reason != "Finished two heartbeats" {
                    threads[index].note = "Heartbeat interrupted · \(reason)"
                } else { failHeartbeat(id, "Heartbeat \(result ?? "failed")") }
            } else {
                updateStatus(index, result == "failed" ? .failed : .idle)
                userActivity(index)
            }
        case "error":
            if ownTurn || startingHeartbeat.contains(id) { failHeartbeat(id, "Heartbeat failed · see the terminal") }
            else {
                threads[index].status = .failed; threads[index].schedule.stop("App Server error")
                threads[index].note = "App Server reported an error; see the terminal"
            }
        case "thread/compacted":
            compacted(index)
        case "item/started", "item/completed":
            let item = params["item"] as? [String: Any]
            if item?["type"] as? String == "contextCompaction" { compacted(index) }
            else if ownTurn {
                if method == "item/started", let type = item?["type"] as? String,
                   !["userMessage", "agentMessage", "reasoning"].contains(type) {
                    failHeartbeat(id, "Heartbeat attempted \(type); schedule stopped")
                    interruptIfOwned(id)
                }
            } else if !startingHeartbeat.contains(id) { userActivity(index) }
        case "thread/closed", "thread/archived":
            updateStatus(index, .disconnected)
        default: break
        }
    }
    private func compacted(_ index: Int) {
        threads[index].schedule.stop("Context compacted")
        interruptIfOwned(threads[index].id)
        threads[index].contextIsStale = true
        threads[index].note = "Context compacted · waiting for fresh usage"
    }
    private func readSummary(_ object: Any?, threadID: String) -> ThreadSummary? {
        do {
            guard let object = object as? [String: Any] else {
                throw HeartbeatError.message("Missing thread summary")
            }
            let data = try JSONSerialization.data(withJSONObject: object)
            let summary = try JSONDecoder().decode(ThreadSummary.self, from: data)
            threadWarnings.removeValue(forKey: threadID)
            return summary
        } catch {
            threadWarnings[threadID] = "Unable to decode thread \(threadID). Monitoring will retry on refresh."
            return nil
        }
    }
    private func decode<T: Decodable>(_ type: T.Type, _ object: [String: Any]) -> T? {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
