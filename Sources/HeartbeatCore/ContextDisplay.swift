import Foundation

public enum ContextDisplayMode: String, CaseIterable {
    case modelCapacity
    case sessionWindow

    public var label: String {
        self == .modelCapacity ? "Model capacity" : "Codex session window"
    }

    public func window(model: String?, usage: ThreadUsage?) -> Int64? {
        self == .modelCapacity ? ModelContextCatalog.capacity(for: model) : usage?.modelContextWindow
    }

    public func fractionUsed(model: String?, usage: ThreadUsage?) -> Double? {
        guard let usage, let window = window(model: model, usage: usage), window > 0 else { return nil }
        return min(1, max(0, Double(usage.last.totalTokens) / Double(window)))
    }
}

public enum ModelContextCatalog {
    // Published native capacities, verified 2026-09-29:
    // https://developers.openai.com/api/docs/models/gpt-6-sol
    // https://developers.openai.com/api/docs/models/gpt-6-astra
    // https://developers.openai.com/api/docs/models/gpt-6-luna
    // https://developers.openai.com/api/docs/models/gpt-5.6-sol
    // https://developers.openai.com/api/docs/models/gpt-5.6-terra
    // https://developers.openai.com/api/docs/models/gpt-5.6-luna
    // Exact IDs only: unknown models must not inherit a guessed family capacity.
    public static func capacity(for model: String?) -> Int64? {
        guard let model else { return nil }
        switch model {
        case "gpt-6-astra", "gpt-6-sol", "gpt-6-luna",
             "gpt-5.6", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna":
            return 1_050_000
        default: return nil
        }
    }
}
