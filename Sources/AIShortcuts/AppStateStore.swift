import AIShortcutsCore
import Foundation

@MainActor
final class AppStateStore {
    private enum Key {
        static let dataSharingAcknowledged = "dataSharingAcknowledged.v1"
        static let permissionsRequested = "permissionsRequested.v1"
        static let fullBudgetState = "dailyBudgetState.v1"
        static let safetyIdentifier = "safetyIdentifier.v1"
        static let disabledShortcutActions = "disabledShortcutActions.v1"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var dataSharingAcknowledged: Bool {
        get { defaults.bool(forKey: Key.dataSharingAcknowledged) }
        set { defaults.set(newValue, forKey: Key.dataSharingAcknowledged) }
    }

    var permissionsRequested: Bool {
        get { defaults.bool(forKey: Key.permissionsRequested) }
        set { defaults.set(newValue, forKey: Key.permissionsRequested) }
    }

    var safetyIdentifier: String {
        if let existing = defaults.string(forKey: Key.safetyIdentifier), !existing.isEmpty {
            return existing
        }
        let identifier = "ai-shortcuts-\(UUID().uuidString.lowercased())"
        defaults.set(identifier, forKey: Key.safetyIdentifier)
        return identifier
    }

    var enabledShortcutActions: Set<AIShortcutAction> {
        let disabledRawValues = disabledShortcutRawValues
        return Set(AIShortcutAction.allCases.filter {
            !disabledRawValues.contains($0.rawValue)
        })
    }

    func setShortcut(_ action: AIShortcutAction, enabled: Bool) {
        var disabled = disabledShortcutRawValues
        if enabled {
            disabled.remove(action.rawValue)
        } else {
            disabled.insert(action.rawValue)
        }
        defaults.set(disabled.sorted(), forKey: Key.disabledShortcutActions)
    }

    private var disabledShortcutRawValues: Set<UInt32> {
        Set((defaults.array(forKey: Key.disabledShortcutActions) ?? []).compactMap {
            ($0 as? NSNumber)?.uint32Value
        })
    }

    func loadFullBudgetState() -> DailyBudgetState? {
        loadBudgetState(forKey: Key.fullBudgetState)
    }

    func saveFullBudgetState(_ state: DailyBudgetState) {
        saveBudgetState(state, forKey: Key.fullBudgetState)
    }

    private func loadBudgetState(forKey key: String) -> DailyBudgetState? {
        guard let data = defaults.data(forKey: key) else {
            return nil
        }
        return try? JSONDecoder().decode(DailyBudgetState.self, from: data)
    }

    private func saveBudgetState(_ state: DailyBudgetState, forKey key: String) {
        guard let data = try? JSONEncoder().encode(state) else {
            return
        }
        defaults.set(data, forKey: key)
    }
}
