import Foundation

public struct CommandResult: Sendable {
    public let output: String
    public let status: Int32
    public var succeeded: Bool { status == 0 }
}

public enum Shell {
    /// Runs a tool directly, with no shell involved. Stops it after `timeout` seconds.
    public static func run(_ path: String, _ arguments: [String] = [], timeout: TimeInterval = 30, includeErrors: Bool = true) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = includeErrors ? pipe : FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return CommandResult(output: "\(error.localizedDescription)", status: -1)
        }
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()
        return CommandResult(output: String(decoding: data, as: UTF8.self), status: process.terminationStatus)
    }

    /// Wraps a value so /bin/sh reads it as one literal word.
    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

public protocol PrivilegedRunner: Sendable {
    func run(script: String) throws -> String
}

/// Runs a script as root through macOS's own password dialog. The app never sees the password.
public struct AdminPromptRunner: PrivilegedRunner {
    public init() {}

    public func run(script: String) throws -> String {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("hs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("run.sh")
        try script.write(to: file, atomically: true, encoding: .utf8)
        let result = Shell.run("/usr/bin/osascript", [
            "-e", "on run argv",
            "-e", "do shell script (\"/bin/sh \" & quoted form of item 1 of argv) with administrator privileges",
            "-e", "end run",
            file.path,
        ], timeout: 600)
        guard result.succeeded else {
            if result.output.contains("-128") { throw FixError("You cancelled the password prompt, so nothing changed.") }
            throw FixError(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result.output
    }
}
