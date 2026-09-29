import Foundation

public enum SessionStatus: String, Codable { case active, idle, disconnected, failed }
public enum ContextPressure: String { case normal, orange, red }

public struct TokenBreakdown: Codable, Equatable {
    public let inputTokens: Int64
    public let cachedInputTokens: Int64
    public let cacheWriteInputTokens: Int64
    public let outputTokens: Int64
    public let reasoningOutputTokens: Int64
    public let totalTokens: Int64

    enum CodingKeys: String, CodingKey {
        case inputTokens, cachedInputTokens, cacheWriteInputTokens, outputTokens, reasoningOutputTokens, totalTokens
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        inputTokens = try c.decode(Int64.self, forKey: .inputTokens)
        cachedInputTokens = try c.decode(Int64.self, forKey: .cachedInputTokens)
        cacheWriteInputTokens = try c.decodeIfPresent(Int64.self, forKey: .cacheWriteInputTokens) ?? 0
        outputTokens = try c.decode(Int64.self, forKey: .outputTokens)
        reasoningOutputTokens = try c.decode(Int64.self, forKey: .reasoningOutputTokens)
        totalTokens = try c.decode(Int64.self, forKey: .totalTokens)
        guard [inputTokens, cachedInputTokens, cacheWriteInputTokens, outputTokens, reasoningOutputTokens, totalTokens].allSatisfy({ $0 >= 0 }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Negative token count"))
        }
    }
}

public struct ThreadUsage: Codable, Equatable {
    public let last: TokenBreakdown
    public let total: TokenBreakdown
    public let modelContextWindow: Int64?
    // Latest request's total is a context estimate, not lifetime cumulative usage.
    // Cached input is already included in inputTokens; never add it again.
    public var fractionUsed: Double? {
        guard let window = modelContextWindow, window > 0 else { return nil }
        return min(1, max(0, Double(last.totalTokens) / Double(window)))
    }
    public var percentRemaining: Double? { fractionUsed.map { (1 - $0) * 100 } }
    public var pressure: ContextPressure {
        guard let used = fractionUsed else { return .normal }
        if used > 0.8 { return .red }
        if used > 0.6 { return .orange }
        return .normal
    }
}

public struct UsageNotification: Decodable {
    public let threadId: String
    public let turnId: String
    public let tokenUsage: ThreadUsage
}

public struct ThreadSummary: Decodable {
    public struct Status: Decodable { public let type: String }
    public let id: String
    public let name: String?
    public let model: String?
    public let cwd: String
    public let status: Status
    public let updatedAt: Int64
    public let parentThreadId: String?
    public var sessionStatus: SessionStatus {
        switch status.type {
        case "active": return .active
        case "idle": return .idle
        case "systemError": return .failed
        default: return .disconnected
        }
    }
}

public enum HeartbeatSafety {
    // User explicitly accepts prompt-based behavior. This is guidance to the
    // model, not a protocol-level guarantee that it cannot call a tool.
    public static let prompt = "Do nothing. Do not call tools, inspect files, or change anything. Reply only OK."
    public static let disclosure = "Heartbeats are real Codex turns and use your allowance. The no-tools instruction is best effort."
}

public enum HeartbeatError: Error, LocalizedError {
    case message(String)
    case threadNotMaterialized
    public var errorDescription: String? {
        switch self {
        case .message(let s): return s
        case .threadNotMaterialized: return "Waiting for the thread’s first user turn"
        }
    }
}

/// Fixed two-pulse policy for explicitly enabled heartbeat turns.
/// Monotonic time prevents clock changes/sleep catch-up from sending rapid pulses.
public struct HeartbeatSchedule: Equatable {
    public static let interval: TimeInterval = 25 * 60
    public private(set) var enabled = false
    public private(set) var pulses = 0
    public private(set) var due: TimeInterval?
    public private(set) var lastPulse: TimeInterval?
    public private(set) var stoppedReason: String?

    public init() {}
    public mutating func enable(now: TimeInterval, idle: Bool) {
        enabled = true; pulses = 0; stoppedReason = nil
        due = idle ? max(now + Self.interval, (lastPulse ?? -Self.interval) + Self.interval) : nil
    }
    public mutating func stop(_ reason: String) {
        enabled = false; due = nil; stoppedReason = reason
    }
    public mutating func activity() { stop("Stopped by user activity") }
    public mutating func becameIdle(now: TimeInterval) {
        guard enabled, due == nil, pulses < 2 else { return }
        due = max(now + Self.interval, (lastPulse ?? -Self.interval) + Self.interval)
    }
    public mutating func takeDuePulse(now: TimeInterval, idle: Bool) -> Bool {
        guard enabled, idle, let due, now >= due, pulses < 2,
              lastPulse.map({ now - $0 >= Self.interval }) ?? true else { return false }
        pulses += 1; lastPulse = now
        self.due = pulses == 2 ? nil : now + Self.interval
        return true
    }
}
