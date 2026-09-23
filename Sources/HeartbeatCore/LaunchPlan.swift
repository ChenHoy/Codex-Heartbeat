import Foundation

public struct LaunchPlan {
    public let executable: URL
    public let workingDirectory: URL
    public let endpoint: String
    public let name: String
    public let cliArguments: [String]
    public var serverArguments: [String] {
        ["app-server", "--listen", endpoint, "-c", "analytics.enabled=false", "-c", "feedback.enabled=false"]
    }
    public init(executable: URL, workingDirectory: URL, port: UInt16, name: String?, arguments: [String]) throws {
        let endpoint = "ws://127.0.0.1:\(port)"
        guard SessionRegistration.endpointPort(endpoint) != nil, executable.path.hasPrefix("/"),
              !executable.path.contains("\0"), !workingDirectory.path.contains("\0") else {
            throw HeartbeatError.message("Invalid launch path or port")
        }
        // Explicit allowlist: positional prompt, --model, --no-alt-screen.
        // Other flags could redirect the CLI or make its cwd/config differ from the managed session.
        var index = 0
        var promptSeen = false
        while index < arguments.count {
            let arg = arguments[index]
            guard !arg.contains("\0") else { throw HeartbeatError.message("NUL in argument") }
            if arg == "--model" || arg == "-m" {
                index += 1
                guard index < arguments.count, !arguments[index].isEmpty, !arguments[index].contains("\0") else {
                    throw HeartbeatError.message("--model requires a value")
                }
            } else if arg == "--no-alt-screen" {
                // Allowed without a value.
            } else if arg.hasPrefix("-") || promptSeen || ["resume", "fork", "exec", "app-server"].contains(arg) {
                throw HeartbeatError.message("Unsupported CLI argument: use only --model, --no-alt-screen and one quoted prompt")
            } else { promptSeen = true }
            index += 1
        }
        self.executable = executable.resolvingSymlinksInPath()
        self.workingDirectory = workingDirectory.standardizedFileURL.resolvingSymlinksInPath()
        self.endpoint = endpoint
        self.name = name ?? self.workingDirectory.lastPathComponent
        guard !self.name.isEmpty, self.name.count <= 256 else { throw HeartbeatError.message("Name must be 1–256 characters") }
        cliArguments = ["--remote", endpoint, "--cd", self.workingDirectory.path] + arguments
    }
    public static func findCodex(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> URL {
        let paths = (environment["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin").split(separator: ":")
        for path in paths where path.hasPrefix("/") {
            let candidate = URL(fileURLWithPath: String(path)).appendingPathComponent("codex")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate.resolvingSymlinksInPath() }
        }
        throw HeartbeatError.message("codex was not found on PATH. Install Codex CLI and run codex login first.")
    }
}
