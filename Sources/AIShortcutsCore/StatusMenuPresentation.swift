import Foundation

public enum StatusMenuPresentation {
    public static func headline(
        busy: Bool,
        enabled: Bool,
        currentAction: String?
    ) -> String {
        if busy {
            return currentAction.map { "Working · \($0)" } ?? "Working…"
        }
        if enabled {
            return "Ready for shortcuts"
        }
        return "Setup required"
    }
}
