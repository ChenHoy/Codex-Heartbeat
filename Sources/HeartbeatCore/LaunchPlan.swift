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
        guard arguments.allSatisfy({ !$0.contains("\0") }),
              CLIInvocation(arguments: arguments, workingDirectory: workingDirectory).route == .managed else {
            throw HeartbeatError.message("This Codex command cannot use a managed App Server")
        }
        self.executable = executable.resolvingSymlinksInPath()
        self.workingDirectory = workingDirectory.standardizedFileURL.resolvingSymlinksInPath()
        self.endpoint = endpoint
        self.name = name ?? self.workingDirectory.lastPathComponent
        guard !self.name.isEmpty, self.name.count <= 256 else { throw HeartbeatError.message("Name must be 1–256 characters") }
        // chdir supplies Codex's ordinary current-directory default. Injecting
        // --cd would override its saved-directory choice for `resume`/`fork`.
        cliArguments = ["--remote", endpoint] + arguments
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
