import Foundation
import Darwin
import HeartbeatCore
import HeartbeatSystem

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("codex-heartbeat: " + message + "\n").utf8))
    exit(1)
}

func stopOwned(_ process: Process, identity: ProcessIdentity?, graceSteps: Int = 30) {
    guard process.isRunning else { return }
    if let identity, !identity.isAlive { return }
    // Process is a direct child handle, never reconstructed from registry data.
    // Even if libproc identity capture failed, terminate the child we launched.
    process.terminate()
    for _ in 0..<graceSteps {
        if !process.isRunning { return }
        usleep(100_000)
    }
    if process.isRunning, let current = identity ?? (try? ProcessIdentity.capture(process.processIdentifier)), current.isAlive {
        kill(current.pid, SIGKILL)
        process.waitUntilExit()
    }
}

// Separate supervisor survives a launcher crash and shuts down its own App Server.
// It receives process identity, never credentials, via stdin. No registry-based killing.
func supervise() throws {
    hb_install_signals()
    let input = FileHandle.standardInput.readDataToEndOfFile()
    let spec = try JSONDecoder().decode(SupervisorSpec.self, from: input)
    guard spec.owner.isAlive, SessionRegistration.endpointPort(spec.endpoint) != nil else {
        throw HeartbeatError.message("Invalid supervisor owner or endpoint")
    }
    let server = Process()
    server.executableURL = URL(fileURLWithPath: spec.executable)
    server.currentDirectoryURL = URL(fileURLWithPath: spec.cwd)
    server.arguments = ["app-server", "--listen", spec.endpoint, "-c", "analytics.enabled=false", "-c", "feedback.enabled=false"]
    server.standardInput = FileHandle.nullDevice
    server.standardOutput = FileHandle.nullDevice
    server.standardError = FileHandle.nullDevice
    try server.run()
    let identity = try? ProcessIdentity.capture(server.processIdentifier)
    defer { stopOwned(server, identity: identity) }
    guard let identity else { throw HeartbeatError.message("Cannot identify App Server") }
    let port = SessionRegistration.endpointPort(spec.endpoint)!
    var ready = false
    for _ in 0..<150 {
        if !spec.owner.isAlive || !server.isRunning || hb_received_signal() != 0 { break }
        if hb_owns_listener(identity.pid, port) == 1 { ready = true; break }
        usleep(100_000)
    }
    guard ready else { throw HeartbeatError.message("App Server failed to bind its private loopback endpoint") }
    FileHandle.standardOutput.write(try JSONEncoder().encode(identity))
    try FileHandle.standardOutput.close()
    while spec.owner.isAlive && server.isRunning && hb_received_signal() == 0 { usleep(200_000) }
}

struct SupervisorSpec: Codable {
    let owner: ProcessIdentity
    let executable: String
    let cwd: String
    let endpoint: String
}

func launch() throws -> Int32 {
    var args = Array(CommandLine.arguments.dropFirst())
    if args == ["--help"] || args == ["-h"] {
        print("""
        Usage: codex-heartbeat [--name NAME] [--cd DIR] [-- --model MODEL --no-alt-screen "PROMPT"]
               codex-heartbeat --list
               codex-heartbeat --prune

        Starts a dedicated loopback App Server and the normal interactive Codex TUI.
        Uses your existing codex login. No API key is required.
        Keep Warm is opt-in per session in the menu app. Heartbeats are real
        Codex turns, consume allowance, and use a best-effort no-tools prompt.
        """)
        return 0
    }
    let registry = SessionRegistry()
    if args == ["--list"] || args == ["--prune"] {
        let result = try registry.scan()
        for entry in result.sessions { print("\(entry.id)  \(entry.name)  \(entry.workingDirectory)") }
        for warning in result.warnings { print(warning) }
        print("\(result.sessions.count) managed session(s). Stale records removed; no processes signalled.")
        return 0
    }
    var name: String?
    var directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    while !args.isEmpty && args[0] != "--" {
        let flag = args.removeFirst()
        guard ["--name", "--cd"].contains(flag), !args.isEmpty else {
            throw HeartbeatError.message("Unknown option. Use --help; put supported Codex arguments after --.")
        }
        let value = args.removeFirst()
        if flag == "--name" { name = value }
        else { directory = URL(fileURLWithPath: value, relativeTo: directory).standardizedFileURL }
    }
    if args.first == "--" { args.removeFirst() }
    guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else {
        throw HeartbeatError.message("Run this command in an interactive terminal (a TTY is required)")
    }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
        throw HeartbeatError.message("Working directory does not exist")
    }
    let codex = try LaunchPlan.findCodex()
    let port = hb_free_port()
    guard port >= 1024 else { throw HeartbeatError.message("Cannot allocate loopback port") }
    let plan = try LaunchPlan(executable: codex, workingDirectory: directory, port: UInt16(port), name: name, arguments: args)
    let versionProcess = Process(); let versionPipe = Pipe()
    versionProcess.executableURL = codex; versionProcess.arguments = ["--version"]
    versionProcess.standardOutput = versionPipe; versionProcess.standardError = FileHandle.nullDevice
    try versionProcess.run()
    let version = String(decoding: versionPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    versionProcess.waitUntilExit()
    guard versionProcess.terminationStatus == 0 else { throw HeartbeatError.message("Cannot run Codex CLI") }
    try registry.prepare()
    _ = try registry.scan()
    hb_install_signals()
    let owner = try ProcessIdentity.capture(getpid())
    let supervisor = Process(); let input = Pipe(); let output = Pipe()
    supervisor.executableURL = URL(fileURLWithPath: owner.executable)
    supervisor.arguments = ["--internal-supervisor"]
    supervisor.standardInput = input; supervisor.standardOutput = output; supervisor.standardError = FileHandle.nullDevice
    try supervisor.run()
    let supervisorIdentity = try? ProcessIdentity.capture(supervisor.processIdentifier)
    // The supervisor needs its own 3-second server cleanup budget before we
    // consider forcing it down. Equal deadlines can orphan its App Server.
    defer { stopOwned(supervisor, identity: supervisorIdentity, graceSteps: 60) }
    let spec = SupervisorSpec(owner: owner, executable: codex.path, cwd: plan.workingDirectory.path, endpoint: plan.endpoint)
    input.fileHandleForWriting.write(try JSONEncoder().encode(spec))
    try input.fileHandleForWriting.close()
    // Supervisor has a bounded 15-second startup deadline and closes this pipe on success/failure.
    let ready = output.fileHandleForReading.readDataToEndOfFile()
    guard let server = try? JSONDecoder().decode(ProcessIdentity.self, from: ready), server.isAlive else {
        throw HeartbeatError.message("App Server startup failed. Check codex app-server --help and your Codex configuration.")
    }
    print("Codex Heartbeat · \(plan.name) · managed on \(plan.endpoint)")
    print("Keep Warm is off by default. Enable it per thread in the menu app; heartbeats consume allowance.")
    guard chdir(plan.workingDirectory.path) == 0 else { throw HeartbeatError.message("Cannot enter the working directory") }
    let strings = ([codex.path] + plan.cliArguments).map { strdup($0)! }
    defer { strings.forEach { free($0) } }
    var argv: [UnsafeMutablePointer<CChar>?] = strings.map { $0 } + [nil]
    let cliPID = hb_spawn_terminal(codex.path, &argv)
    guard cliPID > 1 else { throw HeartbeatError.message("Cannot launch interactive Codex") }
    var cli: ProcessIdentity?
    for _ in 0..<100 {
        if let found = try? ProcessIdentity.capture(cliPID), found.executable == server.executable { cli = found; break }
        usleep(10_000)
    }
    var cliExited = false
    defer {
        if !cliExited {
            var status: Int32 = 0
            // This is our unreaped posix_spawn child, not a PID from a registry.
            // Reap before signalling so an already exited child is not targeted.
            if hb_poll_child(cliPID, &status) == 1 { cliExited = true }
            if !cliExited { kill(cliPID, SIGTERM) }
            for _ in 0..<30 {
                if cliExited || hb_poll_child(cliPID, &status) == 1 { cliExited = true; break }
                usleep(100_000)
            }
            if !cliExited { kill(cliPID, SIGKILL) }
        }
    }
    guard let cli else { throw HeartbeatError.message("Interactive Codex exited during startup") }
    let registration = SessionRegistration(name: plan.name, workingDirectory: plan.workingDirectory.path,
        endpoint: plan.endpoint, owner: owner, server: server, cli: cli, codexVersion: version)
    try registry.write(registration)
    defer { try? registry.remove(registration) }
    var exitCode: Int32 = 0
    while hb_received_signal() == 0 && supervisor.isRunning && server.isAlive {
        if hb_poll_child(cliPID, &exitCode) == 1 { cliExited = true; return exitCode }
        usleep(100_000)
    }
    return hb_received_signal() == 0 ? 1 : Int32(128 + hb_received_signal())
}

do {
    if CommandLine.arguments == [CommandLine.arguments[0], "--internal-supervisor"] { try supervise() }
    else { exit(try launch()) }
} catch { fail(error.localizedDescription) }
