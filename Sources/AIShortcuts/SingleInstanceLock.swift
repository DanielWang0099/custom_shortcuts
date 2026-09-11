import Darwin
import Foundation

final class SingleInstanceLock {
    private let fileDescriptor: Int32

    init?(timeout: TimeInterval = 2.0) {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AI Shortcuts")
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            return nil
        }

        let path = directory.appendingPathComponent("instance.lock").path
        let descriptor = open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            return nil
        }

        let deadline = Date().addingTimeInterval(timeout)
        var acquired = false
        while true {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                acquired = true
                break
            }
            if Date() >= deadline {
                break
            }
            // Sleep 50ms before retrying in case a previous instance is shutting down
            // (e.g. macOS "Quit & Reopen" when granting screen recording permissions)
            usleep(50_000)
        }

        guard acquired else {
            close(descriptor)
            return nil
        }
        fileDescriptor = descriptor
    }

    deinit {
        flock(fileDescriptor, LOCK_UN)
        close(fileDescriptor)
    }
}
