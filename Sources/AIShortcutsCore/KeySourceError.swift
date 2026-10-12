import Foundation

public enum KeySourceError: LocalizedError, Equatable {
    case missingKey

    public var errorDescription: String? {
        "No API key was configured."
    }
}
