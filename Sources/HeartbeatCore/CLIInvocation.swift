import Foundation

/// Routes the installed CLI's interactive commands through our private App
/// Server. Other commands are executed verbatim by Codex without registration.
public struct CLIInvocation {
    public enum Route: Equatable { case managed, passthrough }
    public let route: Route
    public let workingDirectory: URL
    public let arguments: [String]

    private static let commands: Set<String> = [
        "agents", "exec", "e", "review", "login", "logout", "mcp", "plugin",
        "app-server", "remote-control", "app", "completion", "update", "doctor",
        "sandbox", "debug", "apply", "a", "resume", "queue", "archive",
        "delete", "migrate-rollouts", "unarchive", "fork", "cloud",
        "exec-server", "features", "help"
    ]
    private static let valueOptions: Set<String> = [
        "-c", "--config", "--enable", "--disable", "-i", "--image",
        "-m", "--model", "--local-provider", "-p", "--profile",
        "-s", "--sandbox", "-C", "--cd", "--add-dir", "-a",
        "--ask-for-approval", "--remote", "--remote-auth-token-env"
    ]
    private static let switches: Set<String> = [
        "--strict-config", "--oss", "--approve-for-me",
        "--dangerously-bypass-approvals-and-sandbox", "--dangerously-bypass-hook-trust",
        "--worktree", "--search", "--no-alt-screen", "--no-daemon"
    ]

    public init(arguments: [String], workingDirectory: URL) {
        self.arguments = arguments
        let baseDirectory = URL(fileURLWithPath: workingDirectory.path, isDirectory: true).standardizedFileURL
        var directory = baseDirectory
        var position = 0
        var firstPositional: String?
        var unknownOption = false
        var explicitRemote = false
        var noDaemon = false
        var helpOrVersion = false
        while position < arguments.count {
            let argument = arguments[position]
            if argument == "--" {
                // Tokens after -- are literal positional text, even if they
                // spell --remote, --help, or another CLI option.
                if firstPositional == nil { firstPositional = "" }
                break
            }
            if ["--help", "-h", "--version", "-V"].contains(argument) { helpOrVersion = true }
            if argument == "--remote" || argument.hasPrefix("--remote=") ||
               argument == "--remote-auth-token-env" || argument.hasPrefix("--remote-auth-token-env=") {
                explicitRemote = true
            }
            if argument == "--no-daemon" { noDaemon = true }
            if argument == "--cd" || argument == "-C" {
                if position + 1 < arguments.count {
                    directory = URL(fileURLWithPath: arguments[position + 1], relativeTo: baseDirectory).standardizedFileURL
                }
            } else if argument.hasPrefix("--cd=") {
                directory = URL(fileURLWithPath: String(argument.dropFirst(5)), relativeTo: baseDirectory).standardizedFileURL
            } else if argument.hasPrefix("-C"), argument.count > 2 {
                directory = URL(fileURLWithPath: String(argument.dropFirst(2)), relativeTo: baseDirectory).standardizedFileURL
            }
            if firstPositional != nil { position += 1; continue }
            if argument == "-i" || argument == "--image" {
                // Clap accepts one or more image paths. A path named `exec`
                // must not be mistaken for a Codex subcommand.
                position += 1
                if position >= arguments.count || arguments[position].hasPrefix("-") { unknownOption = true }
                while position < arguments.count && !arguments[position].hasPrefix("-") { position += 1 }
                continue
            } else if Self.valueOptions.contains(argument) {
                position += 1
                if position >= arguments.count { unknownOption = true }
            } else if argument.hasPrefix("-") {
                if !Self.switches.contains(argument) && !Self.isKnownInlineOption(argument) {
                    unknownOption = true
                }
            } else {
                firstPositional = argument
            }
            position += 1
        }
        self.workingDirectory = directory
        if explicitRemote || noDaemon || helpOrVersion || unknownOption ||
           (firstPositional.map { Self.commands.contains($0) && $0 != "resume" && $0 != "fork" } ?? false) {
            route = .passthrough
        } else { route = .managed }
    }

    private static func isKnownInlineOption(_ value: String) -> Bool {
        if value.hasPrefix("--"), let equals = value.firstIndex(of: "=") {
            return valueOptions.contains(String(value[..<equals]))
        }
        return ["-c", "-i", "-m", "-p", "-s", "-C", "-a"].contains { value.hasPrefix($0) && value.count > $0.count }
    }
}
