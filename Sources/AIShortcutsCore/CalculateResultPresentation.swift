import Foundation

public enum CalculateResultPresentation {
    /// Unwraps the schema-enforced `{"answer": "..."}` JSON envelope and returns
    /// only the answer text. Falls back to raw text when the model returned
    /// plain text instead of JSON so no answer is silently dropped. A parsed
    /// JSON envelope with a blank or missing answer yields nil.
    public static func displayText(for result: String) -> String? {
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        guard isJSONObject(trimmed) else {
            return trimmed
        }
        return jsonAnswer(in: trimmed)
    }

    /// Returns the same normalized answer that Calculate places on the clipboard.
    public static func clipboardText(for result: String) -> String? {
        displayText(for: result)
    }

    private static func isJSONObject(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8) else {
            return false
        }
        let parsed: Any?
        do {
            parsed = try JSONSerialization.jsonObject(with: data)
        } catch {
            return false
        }
        return parsed is [String: Any]
    }

    private static func jsonAnswer(in text: String) -> String? {
        guard let data = text.data(using: .utf8) else {
            return nil
        }
        let parsed: Any?
        do {
            parsed = try JSONSerialization.jsonObject(with: data)
        } catch {
            return nil
        }
        guard let answer = parsed as? [String: Any],
              let answerText = answer["answer"] as? String else {
            return nil
        }
        let trimmedAnswer = answerText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedAnswer.isEmpty ? nil : trimmedAnswer
    }
}

public enum CalculateResultDismissalPolicy {
    public static func shouldDismiss(
        initialMouseX: Double,
        initialMouseY: Double,
        currentMouseX: Double,
        currentMouseY: Double,
        panelMinX: Double,
        panelMinY: Double,
        panelWidth: Double,
        panelHeight: Double
    ) -> Bool {
        let hasMoved = initialMouseX != currentMouseX
            || initialMouseY != currentMouseY
        guard hasMoved else {
            return false
        }
        let isInsidePanel = currentMouseX >= panelMinX
            && currentMouseX <= panelMinX + panelWidth
            && currentMouseY >= panelMinY
            && currentMouseY <= panelMinY + panelHeight
        return !isInsidePanel
    }
}
