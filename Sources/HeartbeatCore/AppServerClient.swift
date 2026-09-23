import Foundation

/// Monitoring RPCs are read-only. The only model mutation is the narrowly
/// constructed, opt-in heartbeat turn below; no generic caller can start turns.
@MainActor public final class AppServerClient {
    public static let allowedMethods: Set<String> = ["initialize", "thread/loaded/list", "thread/read", "thread/resume"]
    public var onNotification: ((String, [String: Any]) -> Void)?
    public var onDisconnect: (() -> Void)?
    private let socket: URLSessionWebSocketTask
    private let session: URLSession
    private let endpoint: URL
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var receiver: Task<Void, Never>?
    private var closed = false
    private var ownedHeartbeatTurns: [String: String] = [:]
    // Kept only in memory for controlled protocol tests, never logged or persisted.
    var lastProtocolError: String?

    public init(endpoint: URL) {
        self.endpoint = endpoint
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.connectionProxyDictionary = [:]
        session = URLSession(configuration: config)
        socket = session.webSocketTask(with: endpoint)
        socket.maximumMessageSize = 16 * 1024 * 1024
    }
    public func connect() async throws {
        guard SessionRegistration.endpointPort(endpoint.absoluteString) != nil else {
            throw HeartbeatError.message("Refusing non-loopback endpoint")
        }
        socket.resume()
        receiver = Task { [weak self] in
            guard let self else { return }
            do {
                while !Task.isCancelled && !self.closed {
                    let message = try await self.socket.receive()
                    let data: Data
                    switch message {
                    case .data(let value): data = value
                    case .string(let value): data = Data(value.utf8)
                    @unknown default: continue
                    }
                    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    if let method = object["method"] as? String {
                        // Requests belong to the interactive CLI. Never approve or execute them.
                        if object["id"] == nil {
                            self.onNotification?(method, object["params"] as? [String: Any] ?? [:])
                        }
                    } else if let id = object["id"] as? Int, let continuation = self.pending.removeValue(forKey: id) {
                        if let error = object["error"] as? [String: Any] {
                            self.lastProtocolError = error["message"] as? String
                            if self.lastProtocolError?.contains("no rollout found") == true {
                                continuation.resume(throwing: HeartbeatError.threadNotMaterialized)
                                continue
                            }
                            let experimental = (error["message"] as? String ?? "").localizedCaseInsensitiveContains("experimental")
                            continuation.resume(throwing: HeartbeatError.message(experimental
                                ? "App Server requires experimentalApi for this request"
                                : "App Server request failed (code \(error["code"] as? Int ?? -1))"))
                        } else {
                            continuation.resume(returning: object["result"] as? [String: Any] ?? [:])
                        }
                    }
                }
            } catch {
                if !self.closed { self.close(); self.onDisconnect?() }
            }
        }
        _ = try await request("initialize", params: [
            "clientInfo": ["name": "codex_heartbeat", "title": "Codex Heartbeat", "version": "0.1.0"],
            "capabilities": ["experimentalApi": false]
        ])
        try await send(["method": "initialized"])
    }
    public func request(_ method: String, params: [String: Any] = [:]) async throws -> [String: Any] {
        guard Self.allowedMethods.contains(method) else { throw HeartbeatError.message("Monitoring client refuses mutating method \(method)") }
        let keys: Set<String>
        switch method {
        case "initialize": keys = ["clientInfo", "capabilities"]
        case "thread/loaded/list": keys = ["cursor", "limit"]
        case "thread/read": keys = ["threadId", "includeTurns"]
        default: keys = ["threadId", "excludeTurns"]
        }
        guard Set(params.keys).isSubset(of: keys),
              method != "thread/resume" || params["excludeTurns"] as? Bool == true,
              method != "thread/read" || params["includeTurns"] as? Bool != true else {
            throw HeartbeatError.message("Monitoring client refuses configuration overrides or history hydration")
        }
        return try await rawRequest(method, params: params)
    }
    public func startHeartbeat(threadID: String) async throws -> String {
        guard !threadID.isEmpty else { throw HeartbeatError.message("Missing heartbeat thread") }
        // No sticky model, effort, sandbox, or approval overrides: Codex's
        // turn/start schema says these also affect subsequent user turns.
        let result = try await rawRequest("turn/start", params: [
            "threadId": threadID,
            "input": [["type": "text", "text": HeartbeatSafety.prompt]]
        ])
        guard let turn = result["turn"] as? [String: Any], let id = turn["id"] as? String else {
            throw HeartbeatError.message("Heartbeat turn started without a usable turn ID")
        }
        ownedHeartbeatTurns[id] = threadID
        return id
    }
    public func interruptHeartbeat(threadID: String, turnID: String) async throws {
        guard ownedHeartbeatTurns[turnID] == threadID else {
            throw HeartbeatError.message("Cannot interrupt a turn this client did not start")
        }
        _ = try await rawRequest("turn/interrupt", params: ["threadId": threadID, "turnId": turnID])
    }
    private func rawRequest(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        guard !closed else { throw HeartbeatError.message("App Server disconnected") }
        nextID += 1; let id = nextID
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task {
                do { try await self.send(["id": id, "method": method, "params": params]) }
                catch { self.pending.removeValue(forKey: id)?.resume(throwing: HeartbeatError.message("App Server send failed")) }
            }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                self?.pending.removeValue(forKey: id)?.resume(throwing: HeartbeatError.message("App Server request timed out"))
            }
        }
    }
    private func send(_ object: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }
    public func close() {
        guard !closed else { return }
        closed = true
        receiver?.cancel(); receiver = nil
        socket.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel()
        let waiting = pending; pending.removeAll()
        for continuation in waiting.values { continuation.resume(throwing: HeartbeatError.message("App Server disconnected")) }
    }
}
