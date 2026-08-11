import Foundation

public enum ClipboardQueueCapturePolicy {
    public static let retryInterval: TimeInterval = 0.018
    // Some applications publish their pasteboard change after a window switch
    // or asynchronous selection handoff. Keep the wait bounded but generous.
    public static let maximumCaptureAttempts = 180
    public static let maximumCaptureWait = retryInterval * Double(maximumCaptureAttempts)
}
