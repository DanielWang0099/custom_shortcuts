import Darwin
import Foundation

public enum BoundedProcessOutput {
    public static func capture(
        executableURL: URL,
        arguments: [String] = [],
        timeoutNanoseconds: UInt64
    ) async -> Data? {
        guard timeoutNanoseconds > 0 else {
            return nil
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIShortcuts-\(UUID().uuidString).stdout")
        guard FileManager.default.createFile(
            atPath: outputURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ), let outputHandle = try? FileHandle(forWritingTo: outputURL) else {
            return nil
        }
        defer {
            try? outputHandle.close()
            try? FileManager.default.removeItem(at: outputURL)
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputHandle
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let timeoutSeconds = Double(timeoutNanoseconds) / 1_000_000_000
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while process.isRunning, !Task.isCancelled, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        guard !Task.isCancelled, !process.isRunning else {
            await terminate(process)
            return nil
        }
        guard process.terminationStatus == 0 else {
            return nil
        }

        try? outputHandle.synchronize()
        try? outputHandle.close()
        return try? Data(contentsOf: outputURL, options: [.mappedIfSafe])
    }

    private static func terminate(_ process: Process) async {
        guard process.isRunning else {
            return
        }
        process.terminate()
        for _ in 0..<10 where process.isRunning {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
    }
}
