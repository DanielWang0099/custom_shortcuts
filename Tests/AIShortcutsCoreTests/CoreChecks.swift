import AIShortcutsCore
import Darwin
import Foundation

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) throws {
    guard condition() else {
        throw CheckFailure(description: message)
    }
}

private func require<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else {
        throw CheckFailure(description: message)
    }
    return value
}

@main
struct CoreChecks {
    static func main() async {
        var failures = 0

        failures += await run("key source parsing", keySourceParsing)
        failures += await run("AI output contracts", outputContractChecks)
        failures += await run("math syntax contracts", mathSyntaxChecks)
        failures += await run("structured AI output parsing", structuredOutputChecks)
        failures += await run("prompt and replacement policies", promptAndPolicyChecks)
        failures += await run("status menu headlines", statusMenuHeadlineChecks)
        failures += await run("calculate result presentation", calculateResultPresentationChecks)
        failures += await run("calculate result dismissal", calculateResultDismissalChecks)
        failures += await run("explanation conversation memory", explanationMemoryChecks)
        failures += await run("sequential clipboard FIFO", sequentialClipboardChecks)
        failures += await run("sequential clipboard cross-window capture", sequentialClipboardCaptureChecks)
        failures += await run("sequential clipboard single press", sequentialClipboardSinglePressChecks)
        failures += await run("Insert matching and privacy", insertMatchingChecks)
        failures += await run("daily token budget", tokenBudgetChecks)
        failures += await run("Responses request contract", requestContractCheck)
        failures += await run("mocked Responses success", mockedSuccessCheck)
        failures += await run("mocked Responses errors", mockedErrorChecks)

        if failures == 0 {
            print("All AI Shortcuts core checks passed.")
        } else {
            print("\(failures) AI Shortcuts core check(s) failed.")
            exit(EXIT_FAILURE)
        }
    }

    private static func run(
        _ name: String,
        _ check: () async throws -> Void
    ) async -> Int {
        do {
            try await check()
            print("PASS \(name)")
            return 0
        } catch {
            print("FAIL \(name): \(error)")
            return 1
        }
    }

    private static func keySourceParsing() async throws {
        let source = """
        OTHER_KEY=ignore-me
        OPENAI_USAGE_MODEL=gpt-example
        OPENAI_API_KEY='test-secret-value'
        """
        let parsed = try KeySourceParser.parseOpenAIKey(from: source)
        try expect(
            parsed == "test-secret-value",
            "Did not parse the exact OPENAI_API_KEY assignment."
        )
        let exported = try KeySourceParser.parseOpenAIKey(
            from: #"export OPENAI_API_KEY = "test-value""#
        )
        try expect(
            exported == "test-value",
            "Did not parse export/double-quoted syntax."
        )
        do {
            _ = try KeySourceParser.parseOpenAIKey(
                from: "OPENAI_MODEL=gpt-5.4-2026-03-05"
            )
            throw CheckFailure(description: "Missing key did not fail closed.")
        } catch KeySourceError.missingKey {
            // Expected.
        }
    }

    private static func outputContractChecks() async throws {
        let plainSource = "Price: $5.00\nVisible *asterisks* stay literal."
        let markdownSource = "# Result\n\n- Total: \\(x^2\\)"
        try expect(
            AIOutputFormatDetector.detect(plainSource) == .plainText,
            "Plain text with currency and literal punctuation was misclassified."
        )
        try expect(
            AIOutputFormatDetector.detect(markdownSource) == .markdown,
            "Markdown with a list and math was not detected."
        )

        let document = AIOutputDocument(
            format: .markdown,
            source: "  # Result\r\n\r\nValue: \\(x^2\\)  "
        )
        try expect(
            document.source == "# Result\n\nValue: \\(x^2\\)",
            "AI output documents did not normalize source text."
        )

        try expect(
            AIOutputPolicy.allowedFormats(for: .ocr) == [.plainText]
                && AIOutputPolicy.allowedFormats(
                    for: .refine,
                    selectedText: markdownSource
                ) == [.markdown]
                && AIOutputPolicy.allowedFormats(
                    for: .translate,
                    selectedText: plainSource
                ) == [.plainText]
                && AIOutputPolicy.allowedFormats(
                    for: .format,
                    parameter: "concise email with bullets"
                ) == [.markdown]
                && AIOutputPolicy.allowedFormats(
                    for: .format,
                    parameter: "fix typos"
                ) == [.plainText]
                && AIOutputPolicy.allowedFormats(for: .explain) == [.plainText, .markdown]
                && AIOutputPolicy.allowedFormats(for: .calculate) == [.plainText, .markdown],
            "Action output format policy did not match the guarded matrix."
        )

        let ocr = PromptBuilder.make(action: .ocr)
        let refine = PromptBuilder.make(action: .refine, selectedText: markdownSource)
        let format = PromptBuilder.make(
            action: .format,
            selectedText: "Hello",
            parameter: "email with bullets"
        )
        let explain = PromptBuilder.make(action: .explain, parameter: "Explain this")
        try expect(
            ocr.outputSchema == .textDocument
                && ocr.allowedOutputFormats == [.plainText]
                && refine.outputSchema == .textDocument
                && refine.allowedOutputFormats == [.markdown]
                && format.outputSchema == .textDocument
                && format.allowedOutputFormats == [.markdown]
                && explain.outputSchema == .textDocument
                && explain.allowedOutputFormats == [.plainText, .markdown],
            "Prompts did not carry their strict document output contracts."
        )
        let calculated = PromptBuilder.make(action: .calculate)
        try expect(
            explain.instructions.contains("Use format markdown whenever")
                && calculated.instructions.contains("only when no formatting or math delimiters are needed"),
            "Explain and Calculate did not require Markdown for formatted or mathematical answers."
        )
    }

    private static func mathSyntaxChecks() async throws {
        let source = "Cost $5.00 and \\(x^2 + \\frac{1}{2}\\) plus $$\\sqrt{x}$$ and `\\(not math\\)`.\n```\n\\[code\\]\n```"
        let spans = MathSyntax.mathSpans(in: source)
        try expect(
            spans.count == 2
                && spans[0].source == "\\(x^2 + \\frac{1}{2}\\)"
                && !spans[0].isDisplay
                && spans[1].source == "$$\\sqrt{x}$$"
                && spans[1].isDisplay,
            "Math scanning interpreted currency or code content as equations."
        )
        try expect(
            MathSyntax.hasUnclosedMathDelimiter(in: "Broken \\(x^2")
                && MathSyntax.hasUnclosedMathDelimiter(in: "Broken $x^2")
                && !MathSyntax.hasUnclosedMathDelimiter(in: "Price $5.00"),
            "Malformed math delimiters were not distinguished from currency."
        )
        try expect(
            MathSyntax.isSupportedExpression("x^2 + \\frac{1}{2} + \\sqrt{y}")
                && MathSyntax.isSupportedExpression("\\alpha_1 + \\sum x")
                && !MathSyntax.isSupportedExpression("\\begin{matrix}a & b\\end{matrix}"),
            "The common native LaTeX grammar was not enforced."
        )

        let safe = AIOutputDocument(format: .markdown, source: "# Safe\n\n[OpenAI](https://openai.com)")
        try AIOutputDocumentValidator.validate(safe)
        do {
            try AIOutputDocumentValidator.validate(
                AIOutputDocument(format: .markdown, source: "<script>alert(1)</script>")
            )
            throw CheckFailure(description: "Raw HTML was accepted in Markdown output.")
        } catch AIOutputValidationError.rawHTML {
            // Expected.
        }
        do {
            try AIOutputDocumentValidator.validate(
                AIOutputDocument(format: .markdown, source: "![image](https://example.com/a.png)")
            )
            throw CheckFailure(description: "Embedded Markdown images were accepted.")
        } catch AIOutputValidationError.embeddedImage {
            // Expected.
        }
        do {
            try AIOutputDocumentValidator.validate(
                AIOutputDocument(format: .markdown, source: "[unsafe](<javascript:alert(1)>)")
            )
            throw CheckFailure(description: "Angle-bracket unsafe links were accepted.")
        } catch AIOutputValidationError.unsafeLink {
            // Expected.
        }
    }

    private static func structuredOutputChecks() async throws {
        let markdownPayload = Data(
            ##"{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"{\"format\":\"markdown\",\"content\":\"# Result\\n\\n\\\\(x^2\\\\)\"}"}]}]}"##.utf8
        )
        let parsed = try ResponsesAPIClient.parseCompletion(
            from: markdownPayload,
            outputSchema: .textDocument,
            allowedOutputFormats: [.markdown]
        )
        try expect(
            parsed.output == AIOutputDocument(
                format: .markdown,
                source: "# Result\n\n\\(x^2\\)"
            ),
            "Structured Markdown output was not decoded into a typed document."
        )

        let disallowedPayload = Data(
            ##"{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"{\"format\":\"markdown\",\"content\":\"answer\"}"}]}]}"##.utf8
        )
        do {
            _ = try ResponsesAPIClient.parseCompletion(
                from: disallowedPayload,
                outputSchema: .textDocument,
                allowedOutputFormats: [.plainText]
            )
            throw CheckFailure(description: "Disallowed output format was accepted.")
        } catch ResponsesAPIError.invalidOutput {
            // Expected.
        }

        let calculatePayload = Data(
            ##"{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"{\"format\":\"markdown\",\"answer\":\"Total: $12.00\"}"}]}]}"##.utf8
        )
        let calculated = try ResponsesAPIClient.parseCompletion(
            from: calculatePayload,
            outputSchema: .calculateAnswer,
            allowedOutputFormats: [.plainText, .markdown]
        )
        try expect(
            calculated.output == AIOutputDocument(
                format: .markdown,
                source: "Total: $12.00"
            ),
            "Calculate answer output was not isolated from its JSON envelope."
        )

        let literalOCRPayload = Data(
            ##"{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"{\"format\":\"plain_text\",\"content\":\"*literal* \\\\(x\\\\)\"}"}]}]}"##.utf8
        )
        let literalOCR = try ResponsesAPIClient.parseCompletion(
            from: literalOCRPayload,
            outputSchema: .textDocument,
            allowedOutputFormats: [.plainText]
        )
        try expect(
            literalOCR.output.format == .plainText
                && literalOCR.output.source == "*literal* \\(x\\)",
            "OCR plain text was interpreted as rich formatting instead of remaining literal."
        )

        let malformedEnvelopePayload = Data(
            ##"{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"not-json"}]}]}"##.utf8
        )
        do {
            _ = try ResponsesAPIClient.parseCompletion(
                from: malformedEnvelopePayload,
                outputSchema: .textDocument,
                allowedOutputFormats: [.plainText]
            )
            throw CheckFailure(description: "Malformed document JSON was accepted.")
        } catch ResponsesAPIError.invalidOutput {
            // Expected.
        }

        let extraFieldPayload = Data(
            ##"{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"{\"format\":\"plain_text\",\"content\":\"answer\",\"extra\":true}"}]}]}"##.utf8
        )
        do {
            _ = try ResponsesAPIClient.parseCompletion(
                from: extraFieldPayload,
                outputSchema: .textDocument,
                allowedOutputFormats: [.plainText]
            )
            throw CheckFailure(description: "Unknown envelope fields were accepted.")
        } catch ResponsesAPIError.invalidOutput {
            // Expected.
        }

        let incompletePayload = Data(
            ##"{"status":"completed","incomplete_details":{"reason":"max_output_tokens"},"output":[{"type":"message","content":[{"type":"output_text","text":"{\"format\":\"plain_text\",\"content\":\"partial\"}"}]}]}"##.utf8
        )
        do {
            _ = try ResponsesAPIClient.parseCompletion(from: incompletePayload)
            throw CheckFailure(description: "Incomplete responses were accepted.")
        } catch ResponsesAPIError.incomplete("max_output_tokens") {
            // Expected.
        }
    }

    private static func promptAndPolicyChecks() async throws {
        try expect(
            HotKeyDefinition.defaults == [
                .init(action: .ocr, virtualKeyCode: 21),
                .init(action: .refine, virtualKeyCode: 15),
                .init(action: .translate, virtualKeyCode: 17),
                .init(action: .format, virtualKeyCode: 3),
                .init(action: .finderPath, virtualKeyCode: 42),
                .init(action: .explain, virtualKeyCode: 14),
                .init(action: .calculate, virtualKeyCode: 24),
                .init(action: .inputLock, virtualKeyCode: 37),
                .init(action: .clipboardQueue, virtualKeyCode: 8),
                .init(action: .insert, virtualKeyCode: 34),
            ],
            "Global shortcut mappings changed."
        )
        try expect(
            AIShortcutAction.ocr.requiresScreenRecording
                && !AIShortcutAction.ocr.requiresAccessibility,
            "OCR must require Screen Recording but not Accessibility."
        )
        try expect(
            AIShortcutAction.calculate.requiresScreenRecording
                && !AIShortcutAction.calculate.requiresAccessibility,
            "Calculate must require Screen Recording but not Accessibility."
        )
        try expect(
            [
                AIShortcutAction.refine,
                AIShortcutAction.translate,
                AIShortcutAction.format,
                AIShortcutAction.explain,
            ].allSatisfy {
                $0.requiresAccessibility && !$0.requiresScreenRecording
            },
            "Text shortcuts must require Accessibility but not Screen Recording."
        )
        try expect(
            !AIShortcutAction.refine.usesMiniModel
                && !AIShortcutAction.translate.usesMiniModel
                && !AIShortcutAction.ocr.usesMiniModel
                && !AIShortcutAction.format.usesMiniModel
                && !AIShortcutAction.explain.usesMiniModel
                && !AIShortcutAction.calculate.usesMiniModel,
            "No shortcut may route to the mini model."
        )
        try expect(
            !AIShortcutAction.finderPath.requiresAccessibility
                && !AIShortcutAction.finderPath.requiresScreenRecording
                && !AIShortcutAction.finderPath.usesMiniModel
                && !AIShortcutAction.finderPath.requiresOpenAI,
            "Finder Path must not require any macOS permission or the OpenAI API."
        )
        try expect(
            AIShortcutAction.allCases
                .filter {
                    $0 != .finderPath
                        && $0 != .inputLock
                        && $0 != .clipboardQueue
                        && $0 != .insert
                }
                .allSatisfy(\.requiresOpenAI)
                && !AIShortcutAction.finderPath.requiresOpenAI
                && !AIShortcutAction.inputLock.requiresOpenAI
                && !AIShortcutAction.clipboardQueue.requiresOpenAI
                && !AIShortcutAction.insert.requiresOpenAI
                && AIShortcutAction.insert.requiresAccessibility,
            "Local and hybrid shortcuts lost their permission/API contract."
        )

        let refine = PromptBuilder.make(
            action: .refine,
            selectedText: "This are a test."
        )
        try expect(
            refine.inputText == "This are a test."
                && refine.instructions.contains("Preserve the original meaning")
                && refine.instructions.contains("Spanish, English, Chinese, and Japanese")
                && refine.instructions.contains("never translate or switch languages")
                && refine.instructions.contains("Return only the revised text"),
            "Refine prompt lost its preservation/output-only contract."
        )
        let translate = PromptBuilder.make(
            action: .translate,
            selectedText: "Hello",
            parameter: "Japanese, formal"
        )
        let format = PromptBuilder.make(
            action: .format,
            selectedText: "Hello",
            parameter: "email with bullets"
        )
        try expect(
            translate.instructions.contains("Japanese, formal")
                && format.instructions.contains("email with bullets")
                && format.instructions.contains("Spanish, English, Chinese, and Japanese")
                && format.instructions.contains("unless the format instruction explicitly requests translation"),
            "Free-form Translate/Format parameters were not preserved."
        )
        let explain = PromptBuilder.make(
            action: .explain,
            selectedText: "Photosynthesis converts light into chemical energy.",
            parameter: "",
            conversationContext: "Earlier explanation"
        )
        try expect(
            explain.model == AppConstants.fullModel
                && explain.maxOutputTokens == 768
                && explain.inputText.contains("Earlier explanation")
                && explain.inputText.contains("Current hidden selected text")
                && explain.inputText.contains("Explain the hidden selected text")
                && explain.instructions.contains("briefly")
                && explain.instructions.contains("general chat question")
                && explain.reasoningEffort == .low,
            "Explain lost its full-model, hidden-selection, memory, or brevity contract."
        )
        let generalChat = PromptBuilder.make(
            action: .explain,
            selectedText: nil,
            parameter: "Why is the sky blue?"
        )
        try expect(
            generalChat.inputText.contains("Why is the sky blue?")
                && !generalChat.inputText.contains("Current hidden selected text"),
            "Explain did not support general chat without a selection."
        )

        let calculated = PromptBuilder.make(action: .calculate)
        let customCalculation = PromptBuilder.make(
            action: .calculate,
            parameter: "Only list each item's extended price."
        )
        try expect(
            calculated.instructions.contains("full visible context")
                && calculated.inputText.contains("No custom instruction")
                && calculated.instructions.contains("shopping list or receipt")
                && calculated.instructions.contains("time-zone conversions")
                && calculated.instructions.contains("currency conversions")
                && calculated.instructions.contains("only the converted time ranges")
                && calculated.instructions.contains("never copy")
                && calculated.instructions.contains("truncated fragments")
                && calculated.reasoningEffort == .high
                && calculated.outputSchema == .calculateAnswer
                && customCalculation.inputText.contains("Only list each item's extended price."),
            "Calculate did not preserve automatic and custom screenshot instructions."
        )
        try expect(
            calculated.maxOutputTokens >= 25_000,
            "High-reasoning Calculate needs enough output space for reasoning and the final answer."
        )

        try expect(
            SelectionReplacementPolicy.shouldReplace(
                originalText: "original",
                currentText: "original",
                originalProcessIdentifier: 42,
                frontmostProcessIdentifier: 42
            ),
            "Unchanged selection should be replaceable."
        )
        try expect(
            !SelectionReplacementPolicy.shouldReplace(
                originalText: "original",
                currentText: "changed",
                originalProcessIdentifier: 42,
                frontmostProcessIdentifier: 42
            ),
            "Changed selection must not be replaced."
        )
        try expect(
            SelectionReplacementPolicy.shouldReplace(
                originalText: "café\r\n第二行",
                currentText: "cafe\u{301}\n第二行",
                originalProcessIdentifier: 42,
                frontmostProcessIdentifier: 42
            ),
            "Visually identical Unicode and newline forms should be replaceable."
        )
        try expect(
            !SelectionReplacementPolicy.shouldReplace(
                originalText: "original",
                currentText: "original",
                originalProcessIdentifier: 42,
                frontmostProcessIdentifier: 99
            ),
            "A different frontmost process must not receive replacement text."
        )
    }

    private static func statusMenuHeadlineChecks() async throws {
        try expect(
            StatusMenuPresentation.headline(
                busy: true,
                enabled: true,
                currentAction: "Calculate"
            ) == "Working · Calculate",
            "The status menu should identify the active shortcut while it is running."
        )
        try expect(
            StatusMenuPresentation.headline(
                busy: false,
                enabled: true,
                currentAction: nil
            ) == "Ready for shortcuts",
            "The status menu should return to Ready after an operation finishes."
        )
        try expect(
            StatusMenuPresentation.headline(
                busy: false,
                enabled: false,
                currentAction: nil
            ) == "Setup required",
            "The status menu should keep setup guidance when shortcuts are disabled."
        )
    }

    private static func calculateResultPresentationChecks() async throws {
        let jsonResult = #"{"answer": " 12 items\nTotal: $48.00 "}"#
        try expect(
            CalculateResultPresentation.displayText(for: jsonResult)
                == "12 items\nTotal: $48.00",
            "Calculate should unwrap the JSON answer envelope and trim surrounding whitespace."
        )
        try expect(
            CalculateResultPresentation.clipboardText(for: jsonResult)
                == "12 items\nTotal: $48.00",
            "Calculate should copy the unwrapped answer instead of the JSON envelope."
        )
        try expect(
            CalculateResultPresentation.displayText(for: " 12 items\nTotal: $48.00 \n")
                == "12 items\nTotal: $48.00",
            "Calculate should display a plain-text answer without surrounding whitespace."
        )
        try expect(
            CalculateResultPresentation.displayText(for: #"{"reasoning": "summed the rows", "answer": "42"}"#)
                == "42",
            "Calculate must surface only the answer field, never reasoning."
        )
        try expect(
            CalculateResultPresentation.displayText(for: #"{"answer": "  "}"#) == nil,
            "Calculate should not display a blank JSON answer."
        )
        try expect(
            CalculateResultPresentation.displayText(for: " \n\t") == nil,
            "Calculate should not display an empty answer."
        )
    }

    private static func calculateResultDismissalChecks() async throws {
        try expect(
            !CalculateResultDismissalPolicy.shouldDismiss(
                initialMouseX: 150,
                initialMouseY: 150,
                currentMouseX: 150,
                currentMouseY: 150,
                panelMinX: 0,
                panelMinY: 0,
                panelWidth: 100,
                panelHeight: 100
            ),
            "Calculate result should remain visible while the cursor is stationary."
        )
        try expect(
            !CalculateResultDismissalPolicy.shouldDismiss(
                initialMouseX: 150,
                initialMouseY: 150,
                currentMouseX: 50,
                currentMouseY: 50,
                panelMinX: 0,
                panelMinY: 0,
                panelWidth: 100,
                panelHeight: 100
            ),
            "Calculate result should remain visible while the cursor is over the popup."
        )
        try expect(
            CalculateResultDismissalPolicy.shouldDismiss(
                initialMouseX: 150,
                initialMouseY: 150,
                currentMouseX: 250,
                currentMouseY: 150,
                panelMinX: 0,
                panelMinY: 0,
                panelWidth: 100,
                panelHeight: 100
            ),
            "Calculate result should dismiss after the cursor moves outside the popup."
        )
    }

    private static func explanationMemoryChecks() async throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var memory = ExplanationConversationMemory(
            idleTimeout: 3_600,
            maximumExchanges: 2,
            maximumUTF8Bytes: 10_000
        )
        try expect(memory.context(now: start) == nil, "New explanation memory was not empty.")

        memory.record(
            highlightedText: "First source",
            request: "",
            explanation: "First explanation",
            now: start
        )
        let active = memory.context(now: start.addingTimeInterval(3_599))
        try expect(
            active?.contains("First explanation") == true
                && active?.contains("Request:\n(none)") == true,
            "Active explanation memory did not preserve the prior exchange."
        )
        try expect(
            memory.activeExchanges(now: start.addingTimeInterval(3_599)).count == 1,
            "Active explanation exchanges were unavailable to the chat UI."
        )

        memory.record(
            highlightedText: "Second source",
            request: "Use an analogy",
            explanation: "Second explanation",
            now: start.addingTimeInterval(3_599)
        )
        memory.record(
            highlightedText: "Third source",
            request: "",
            explanation: "Third explanation",
            now: start.addingTimeInterval(3_600)
        )
        let bounded = memory.context(now: start.addingTimeInterval(3_600))
        try expect(
            bounded?.contains("First explanation") == false
                && bounded?.contains("Second explanation") == true
                && bounded?.contains("Third explanation") == true,
            "Explanation memory did not retain only its newest bounded exchanges."
        )

        try expect(
            memory.context(now: start.addingTimeInterval(7_200)) == nil
                && memory.exchanges.isEmpty,
            "Explanation memory did not reset after one idle hour."
        )
    }

    private static func tokenBudgetChecks() async throws {
        try expect(
            AppConstants.fullDailyBudgetLimit == 1_000_000,
            "The full-model daily guard must match this account's allowance."
        )
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        var ledger = DailyBudgetLedger(limit: 100, state: nil, now: date)
        _ = ledger.reserve(70, now: date)
        try expect(
            ledger.reserve(31, now: date)
                == .refused(remaining: 30, requested: 31),
            "Budget did not refuse a request that crosses the cap."
        )

        let beforeMidnight = ISO8601DateFormatter().date(
            from: "2026-07-27T23:59:59Z"
        )!
        let afterMidnight = ISO8601DateFormatter().date(
            from: "2026-07-28T00:00:01Z"
        )!
        var resetLedger = DailyBudgetLedger(
            limit: 100,
            state: DailyBudgetState(
                utcDay: DailyBudgetLedger.utcDay(for: beforeMidnight),
                reservedTokens: 90
            ),
            now: beforeMidnight
        )
        resetLedger.normalize(now: afterMidnight)
        try expect(
            resetLedger.remaining == 100
                && resetLedger.state.utcDay == "2026-07-28",
            "Budget did not reset at the UTC date boundary."
        )

        let text = PromptBuilder.make(action: .refine, selectedText: "abc")
        try expect(
            TokenEstimator.textReservation(for: text)
                >= text.maxOutputTokens + AppConstants.budgetSafetyMargin,
            "Text reservation omitted output or safety margin."
        )
        let image = PromptBuilder.make(action: .ocr)
        try expect(
            TokenEstimator.imageReservation(
                for: image,
                pixelWidth: 64,
                pixelHeight: 96
            ) >= image.maxOutputTokens + AppConstants.budgetSafetyMargin + 6,
            "Image reservation omitted patch, output, or safety costs."
        )
    }

    private static func sequentialClipboardChecks() async throws {
        var queue = FIFOQueue<String>()
        queue.enqueue("Daniel")
        queue.enqueue("NTU")
        queue.enqueue("Computer Engineering")
        try expect(
            queue.dequeue() == "Daniel"
                && queue.dequeue() == "NTU"
                && queue.dequeue() == "Computer Engineering"
                && queue.dequeue() == nil,
            "Clipboard entries did not leave in first-in, first-out order."
        )

        queue.enqueue("stale")
        queue.reset()
        queue.enqueue("fresh")
        try expect(
            queue.count == 1 && queue.dequeue() == "fresh",
            "A new clipboard session did not start with a fresh queue."
        )
    }

    private static func sequentialClipboardCaptureChecks() async throws {
        try expect(
            ClipboardQueueCapturePolicy.maximumCaptureWait >= 2.0
                && ClipboardQueueCapturePolicy.maximumCaptureAttempts >= 100,
            "Clipboard capture did not allow enough time for a window switch and delayed copy."
        )
    }

    private static func sequentialClipboardSinglePressChecks() async throws {
        var tracker = ClipboardQueueCopyPressTracker()
        try expect(tracker.beginKeyDown(), "The first copy key-down was not accepted.")
        try expect(!tracker.beginKeyDown(), "A held copy key generated a duplicate capture.")
        try expect(tracker.endKeyUp(), "The copy key-up did not finish the press.")
        try expect(!tracker.endKeyUp(), "A repeated copy key-up generated a duplicate capture.")
    }

    private static func insertMatchingChecks() async throws {
        let entries = [
            InsertEntry(key: "Primary Email", value: "daniel@example.com"),
            InsertEntry(key: "University", value: "NTU"),
            InsertEntry(key: "Work Email", value: "work@example.com"),
        ]
        try expect(
            InsertEntryMatcher.exactMatch(for: "primary e-mail", in: entries)?.value
                == "daniel@example.com",
            "Insert exact matching did not normalize case or punctuation."
        )
        try expect(
            InsertEntryMatcher.uniqueContainedMatch(for: "univ", in: entries)?.value == "NTU",
            "Insert did not accept one unambiguous contained key."
        )
        try expect(
            InsertEntryMatcher.uniqueContainedMatch(for: "email", in: entries) == nil,
            "Insert guessed when multiple local keys matched."
        )
        try expect(
            InsertEntryMatcher.filtered(by: "NTU", entries: entries).map(\.key)
                == ["University"],
            "Insert management search did not include values."
        )

        let prompt = PromptBuilder.makeInsertLookup(
            query: "my school",
            candidateKeys: entries.map(\.key)
        )
        try expect(
            prompt.reasoningEffort == .low
                && prompt.maxOutputTokens == 32
                && prompt.inputText.contains("University")
                && !prompt.inputText.contains("daniel@example.com")
                && !prompt.inputText.contains("work@example.com")
                && prompt.instructions.contains("Return only the candidate's integer index"),
            "Insert smart matching exposed stored values or lost its constrained-index contract."
        )

        let fixedDate = Date(timeIntervalSince1970: 1_786_320_000)
        let builtIns = InsertBuiltIns.entries(
            now: fixedDate,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        try expect(
            builtIns.count == 2
                && builtIns.allSatisfy(\.builtIn)
                && builtIns.map(\.key) == ["Date", "Time"]
                && InsertEntryMatcher.exactMatch(for: "date", in: builtIns)?.key
                    == "Date"
                && InsertEntryMatcher.exactMatch(for: "time", in: builtIns)?.key
                    == "Time"
                && InsertEntryMatcher.exactMatch(for: "timestamp", in: builtIns) == nil
                && InsertEntryMatcher.exactMatch(for: "epoch", in: builtIns) == nil,
            "Insert should expose only Date and Time dynamic defaults."
        )
        try expect(
            InsertBuiltIns.conflicts(with: "Date")
                && InsertBuiltIns.conflicts(with: "time")
                && !InsertBuiltIns.conflicts(with: "current-date")
                && !InsertBuiltIns.conflicts(with: "ISO Timestamp")
                && !InsertBuiltIns.conflicts(with: "Primary Email"),
            "Only Date and Time should be reserved from custom entries."
        )
        try expect(
            builtIns.first(where: { $0.key == "Date" })?.value == "2026-08-10"
                && builtIns.first(where: { $0.key == "Time" })?.value == "00:00:00",
            "Date and Time values were not generated from the invocation time."
        )
    }

    private static func requestContractCheck() async throws {
        let client = ResponsesAPIClient(transport: MockTransport { _ in
            throw URLError(.badServerResponse)
        })
        let request = try client.makeRequest(
            prompt: PromptBuilder.make(action: .ocr),
            imagePNGs: [
                Data([0x89, 0x50, 0x4E, 0x47]),
                Data([0x89, 0x50, 0x4E, 0x47]),
            ],
            apiKey: "not-a-real-key",
            safetyIdentifier: "test-safety-id"
        )
        let body = try require(request.httpBody, "Request body was missing.")
        let json = try require(
            try JSONSerialization.jsonObject(with: body) as? [String: Any],
            "Request body was not a JSON object."
        )
        try expect(
            json["model"] as? String == "gpt-5.4-2026-03-05",
            "Request did not use the complimentary-eligible GPT-5.4 snapshot."
        )
        try expect(json["store"] as? Bool == false, "store was not false.")
        try expect(
            (json["reasoning"] as? [String: Any])?["effort"] as? String
                == "none",
            "OCR reasoning effort was not none."
        )
        let input = try require(
            json["input"] as? [[String: Any]],
            "Input array was missing."
        )
        let content = try require(
            input.first?["content"] as? [[String: Any]],
            "Content array was missing."
        )
        let image = try require(
            content.first(where: { $0["type"] as? String == "input_image" }),
            "Image input was missing."
        )
        try expect(
            image["detail"] as? String == "original",
            "OCR image detail was not original."
        )
        try expect(
            content.filter { $0["type"] as? String == "input_image" }.count == 2,
            "Multiple image inputs were not preserved."
        )

        let translationRequest = try client.makeRequest(
            prompt: PromptBuilder.make(
                action: .translate,
                selectedText: "Hola",
                parameter: "English"
            ),
            imagePNGs: [],
            apiKey: "not-a-real-key",
            safetyIdentifier: "test-safety-id"
        )
        let translationBody = try require(
            translationRequest.httpBody,
            "Translation request body was missing."
        )
        let translationJSON = try require(
            try JSONSerialization.jsonObject(with: translationBody) as? [String: Any],
            "Translation request body was not a JSON object."
        )
        try expect(
            translationJSON["model"] as? String
                == "gpt-5.4-2026-03-05",
            "Translate did not route to the full GPT-5.4 snapshot."
        )
        try expect(
            (translationJSON["reasoning"] as? [String: Any])?["effort"] as? String
                == "none",
            "Translate should keep non-reasoning latency."
        )

        let calculateRequest = try client.makeRequest(
            prompt: PromptBuilder.make(action: .calculate),
            imagePNGs: [Data([0x89, 0x50, 0x4E, 0x47])],
            apiKey: "not-a-real-key",
            safetyIdentifier: "test-safety-id"
        )
        let calculateBody = try require(
            calculateRequest.httpBody,
            "Calculate request body was missing."
        )
        let calculateJSON = try require(
            try JSONSerialization.jsonObject(with: calculateBody) as? [String: Any],
            "Calculate request body was not a JSON object."
        )
        try expect(
            (calculateJSON["reasoning"] as? [String: Any])?["effort"] as? String
                == "high",
            "Calculate should use high reasoning."
        )
        let calculateText = try require(
            calculateJSON["text"] as? [String: Any],
            "Calculate text options were missing."
        )
        let calculateFormat = try require(
            calculateText["format"] as? [String: Any],
            "Calculate JSON schema format was missing."
        )
        let calculateSchema = try require(
            calculateFormat["schema"] as? [String: Any],
            "Calculate schema body was missing."
        )
        let schemaProperties = try require(
            calculateSchema["properties"] as? [String: Any],
            "Calculate schema properties were missing."
        )
        try expect(
            calculateFormat["type"] as? String == "json_schema"
                && calculateFormat["strict"] as? Bool == true
                && (calculateSchema["required"] as? [String]) == ["format", "answer"]
                && schemaProperties["format"] != nil
                && schemaProperties["answer"] != nil,
            "Calculate must enforce a strict JSON answer schema."
        )
        let plainText = try require(
            translationJSON["text"] as? [String: Any],
            "Translation text options were missing."
        )
        try expect(
            (plainText["format"] as? [String: Any])?["type"] as? String == "json_schema",
            "Normal AI shortcuts must send a strict JSON document schema."
        )
    }

    private static func mockedSuccessCheck() async throws {
        let payload = #"""
        {
          "status": "completed",
          "model": "gpt-5.4-2026-03-05",
          "output": [
            {"type": "reasoning", "id": "reasoning-test"},
            {
              "type": "message",
              "content": [{"type": "output_text", "text": "{\"format\":\"plain_text\",\"content\":\"Corrected text.\"}"}]
            }
          ],
          "usage": {"input_tokens": 10, "output_tokens": 3, "total_tokens": 13}
        }
        """#.data(using: .utf8)!
        let client = ResponsesAPIClient(
            transport: MockTransport { request in
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/2",
                    headerFields: nil
                )!
                return (payload, response)
            }
        )
        let completion = try await client.complete(
            prompt: PromptBuilder.make(action: .refine, selectedText: "Text"),
            apiKey: "not-a-real-key",
            safetyIdentifier: "test"
        )
        try expect(
            completion.text == "Corrected text."
                && completion.totalTokens == 13,
            "Successful mock response was parsed incorrectly."
        )
    }

    private static func mockedErrorChecks() async throws {
        try expect(
            NetworkRetryPolicy.shouldRetry(URLError(.networkConnectionLost))
                && !NetworkRetryPolicy.shouldRetry(
                    URLError(.notConnectedToInternet)
                ),
            "Network retry policy did not isolate transient connection loss."
        )

        let retryCounter = AttemptCounter()
        let recoveredPayload = Data(
            #"""
            {
              "status": "completed",
              "model": "gpt-5.4-2026-03-05",
              "output": [
                {
                  "type": "message",
                  "content": [{"type": "output_text", "text": "{\"format\":\"plain_text\",\"content\":\"Recovered.\"}"}]
                }
              ]
            }
            """#.utf8
        )
        let retryingClient = ResponsesAPIClient(
            transport: MockTransport { request in
                let attempt = await retryCounter.increment()
                if attempt == 1 {
                    throw URLError(.networkConnectionLost)
                }
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/2",
                    headerFields: nil
                )!
                return (recoveredPayload, response)
            }
        )
        let recovered = try await retryingClient.complete(
            prompt: PromptBuilder.make(
                action: .explain,
                selectedText: "Context",
                parameter: "Explain"
            ),
            apiKey: "not-a-real-key",
            safetyIdentifier: "test"
        )
        let retryAttempts = await retryCounter.value
        try expect(
            recovered.text == "Recovered." && retryAttempts == 2,
            "A single transient connection loss was not recovered exactly once."
        )

        let payload = #"{"error":{"message":"Unauthorized"}}"#.data(using: .utf8)!
        let client = ResponsesAPIClient(
            transport: MockTransport { request in
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 401,
                    httpVersion: "HTTP/2",
                    headerFields: nil
                )!
                return (payload, response)
            }
        )
        do {
            _ = try await client.complete(
                prompt: PromptBuilder.make(
                    action: .refine,
                    selectedText: "Text"
                ),
                apiKey: "not-a-real-key",
                safetyIdentifier: "test"
            )
            throw CheckFailure(description: "HTTP 401 did not fail.")
        } catch let error as ResponsesAPIError {
            try expect(
                error == .httpStatus(401, "Unauthorized"),
                "HTTP error was parsed incorrectly."
            )
        }

        do {
            _ = try ResponsesAPIClient.parseCompletion(from: Data("{}".utf8))
            throw CheckFailure(description: "Malformed response did not fail.")
        } catch ResponsesAPIError.malformedResponse {
            // Expected.
        }

        let empty = Data(
            #"{"status":"completed","model":"gpt-5.4-2026-03-05","output":[]}"#.utf8
        )
        do {
            _ = try ResponsesAPIClient.parseCompletion(from: empty)
            throw CheckFailure(description: "Empty response did not fail.")
        } catch ResponsesAPIError.missingOutput {
            // Expected.
        }
    }
}

private actor AttemptCounter {
    private(set) var value = 0

    func increment() -> Int {
        value += 1
        return value
    }
}

private struct MockTransport: HTTPTransport {
    let handler: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    init(
        handler: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)
    ) {
        self.handler = handler
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await handler(request)
    }
}
