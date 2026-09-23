import Foundation
import Darwin
import HeartbeatSystem

public struct ProcessIdentity: Codable, Equatable {
    public let pid: Int32
    public let startStamp: UInt64
    public let executable: String

    public static func capture(_ pid: Int32) throws -> ProcessIdentity {
        let stamp = hb_process_stamp(pid)
        var buffer = [CChar](repeating: 0, count: 4096)
        guard stamp != 0, hb_process_path(pid, &buffer, Int32(buffer.count)) > 0 else {
            throw HeartbeatError.message("Cannot validate process identity for PID \(pid)")
        }
        return ProcessIdentity(pid: pid, startStamp: stamp, executable: String(cString: buffer))
    }
    public var isAlive: Bool { (try? Self.capture(pid)) == self }
}

public struct SessionRegistration: Codable, Equatable, Identifiable {
    public let version: Int
    public let id: UUID
    public let name: String
    public let workingDirectory: String
    public let endpoint: String
    public let owner: ProcessIdentity
    public let server: ProcessIdentity
    public let cli: ProcessIdentity
    public let codexVersion: String
    public let startedAt: Date

    public init(id: UUID = UUID(), name: String, workingDirectory: String, endpoint: String,
                owner: ProcessIdentity, server: ProcessIdentity, cli: ProcessIdentity, codexVersion: String) {
        version = 1; self.id = id; self.name = name; self.workingDirectory = workingDirectory
        self.endpoint = endpoint; self.owner = owner; self.server = server; self.cli = cli
        self.codexVersion = codexVersion; startedAt = Date()
    }
    public var port: UInt16? { Self.endpointPort(endpoint) }
    public static func endpointPort(_ endpoint: String) -> UInt16? {
        guard let c = URLComponents(string: endpoint), c.scheme == "ws", c.host == "127.0.0.1",
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil, c.path.isEmpty,
              let port = c.port, (1024...65535).contains(port), endpoint == "ws://127.0.0.1:\(port)" else { return nil }
        return UInt16(port)
    }
    public var structurallyValid: Bool {
        version == 1 && port != nil && workingDirectory.hasPrefix("/") && !workingDirectory.contains("\0")
        && !name.isEmpty && name.count <= 256 && server.executable == cli.executable
        && server.pid != owner.pid && cli.pid != owner.pid && server.pid != cli.pid
        && [owner, server, cli].allSatisfy { $0.pid > 1 && $0.startStamp > 0 && $0.executable.hasPrefix("/") }
    }
    public var liveProcesses: Bool { owner.isAlive && server.isAlive && cli.isAlive }
    public var validConnection: Bool {
        guard structurallyValid, liveProcesses, let port else { return false }
        return hb_owns_listener(server.pid, port) == 1
    }
}

public struct RegistryScan {
    public var sessions: [SessionRegistration] = []
    public var warnings: [String] = []
}

public struct SessionRegistry {
    public let directory: URL
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Codex Heartbeat/Sessions", isDirectory: true)
    }
    public init(directory: URL = Self.defaultDirectory) { self.directory = directory }

    public func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(), (info.st_mode & 0o077) == 0 else {
            throw HeartbeatError.message("Registry must be a private, owned directory (mode 0700), not a symlink")
        }
        // Reject redirected ancestor paths as well, without modifying permissions on user directories.
        guard directory.standardizedFileURL.path == directory.resolvingSymlinksInPath().path else {
            throw HeartbeatError.message("Registry path contains a symlink")
        }
    }
    public func file(for id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }

    public func write(_ entry: SessionRegistration) throws {
        try prepare()
        guard entry.structurallyValid else { throw HeartbeatError.message("Invalid session registration") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(entry)
        // Foundation writes to an adjacent temporary file and renames atomically.
        // Directory mode 0700 also protects the brief period before chmod.
        try data.write(to: file(for: entry.id), options: .atomic)
        guard chmod(file(for: entry.id).path, 0o600) == 0 else { throw HeartbeatError.message("Cannot secure registry file") }
    }
    public func remove(_ entry: SessionRegistration) throws {
        // Never remove a replacement written by a different owner/process instance.
        guard let current = try? read(file(for: entry.id)), current == entry else { return }
        try FileManager.default.removeItem(at: file(for: entry.id))
    }
    public func read(_ url: URL) throws -> SessionRegistration {
        guard url.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path else {
            throw HeartbeatError.message("Registry path escaped its directory")
        }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw HeartbeatError.message("Cannot safely open registry file") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(),
              (info.st_mode & 0o077) == 0, info.st_size > 0, info.st_size <= 65536 else {
            throw HeartbeatError.message("Unsafe registry file")
        }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        guard count == bytes.count else { throw HeartbeatError.message("Incomplete registry file") }
        let result = try JSONDecoder().decode(SessionRegistration.self, from: Data(bytes))
        guard result.structurallyValid, url.lastPathComponent == result.id.uuidString + ".json" else {
            throw HeartbeatError.message("Invalid registry record")
        }
        return result
    }
    public func scan(pruneStale: Bool = true) throws -> RegistryScan {
        try prepare()
        var result = RegistryScan()
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where url.pathExtension == "json" {
            do {
                let entry = try read(url)
                if entry.liveProcesses { result.sessions.append(entry) }
                else if pruneStale { try remove(entry) }
            } catch {
                // Leave malformed/untrusted entries alone. Never signal processes from the registry.
                result.warnings.append("Ignored invalid registry entry: \(url.lastPathComponent)")
            }
        }
        result.sessions.sort { $0.startedAt < $1.startedAt }
        return result
    }
}
