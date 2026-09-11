import Foundation

public enum ClipboardQueueCapturePolicy {
    public static let retryInterval: TimeInterval = 0.010
    // Some applications publish their pasteboard change after a window switch
    // or asynchronous selection handoff. Keep the wait bounded but generous.
    public static let maximumCaptureAttempts = 325
    public static let maximumCaptureWait = retryInterval * Double(maximumCaptureAttempts)
}

public enum ClipboardQueuePastePolicy {
    /// Keeps the payload stable while the destination processes Command-V.
    /// A subsequent physical paste advances synchronously before its key event,
    /// so fast users do not have to wait for this fallback delay.
    public static let advanceDelay: TimeInterval = 0.220
}
