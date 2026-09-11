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
        failures += await run("Responses request contract", requestContractCheck)
        failures += await run("configurable provider requests", configurableProviderRequestCheck)
        failures += await run("transport residency lifecycle", transportLifecycleCheck)
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
        let separatedDocument = AIOutputDocument(
            format: .markdown,
            source: "First\u{2028}Second\u{2029}Third"
        )
        try expect(
            separatedDocument.source == "First\nSecond\nThird",
            "AI output documents did not normalize Unicode line separators."
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
                && explain.outputSchema == .explanationResponse
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
                && MathSyntax.isSupportedExpression("\\rho \\mathbf{u}")
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
        do {
            try AIOutputDocumentValidator.validate(
                AIOutputDocument(format: .plainText, source: "Result: <script>evil()</script>")
            )
            throw CheckFailure(description: "Dangerous HTML tags were accepted in plain_text output.")
        } catch AIOutputValidationError.rawHTML {
            // Expected.
        }
        do {
            try AIOutputDocumentValidator.validate(
                AIOutputDocument(format: .plainText, source: "javascript:doEvil()")
            )
            throw CheckFailure(description: "Executable URI schemes were accepted in plain_text output.")
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

        let trailingGlitchPayload = Data(
            ##"{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"{\"format\":\"plain_text\",\"content\":\"I'm not sure what you mean by \\\"ehaiefa\\\".\"}'}## assistant to=final spam"}]}]}"##.utf8
        )
        let glitchParsed = try ResponsesAPIClient.parseCompletion(
            from: trailingGlitchPayload,
            outputSchema: .textDocument,
            allowedOutputFormats: [.plainText]
        )
        try expect(
            glitchParsed.output.format == .plainText
                && glitchParsed.output.source.contains("I'm not sure what you mean")
                && !glitchParsed.output.source.contains("assistant to=final")
                && !glitchParsed.output.source.contains("spam"),
            "Trailing glitch envelope was not cleanly parsed and sanitized."
        )

        let calculateFencedGlitchPayload = Data(
            ##"{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"```json\n{\"format\":\"plain_text\",\"answer\":\"$42.50\"}\n```\n## assistant\nextra"}]}]}"##.utf8
        )
        let calculateFencedParsed = try ResponsesAPIClient.parseCompletion(
            from: calculateFencedGlitchPayload,
            outputSchema: .calculateAnswer,
            allowedOutputFormats: [.plainText, .markdown]
        )
        try expect(
            calculateFencedParsed.output == AIOutputDocument(
                format: .plainText,
                source: "$42.50"
            ),
            "Fenced calculate answer with trailing glitch tokens was not extracted and sanitized."
        )

        let explainPayload = Data(
            ##"{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"{\"format\":\"markdown\",\"explanation\":\"**Photosynthesis** converts light into chemical energy.\"}"}]}]}"##.utf8
        )
        let explainParsed = try ResponsesAPIClient.parseCompletion(
            from: explainPayload,
            outputSchema: .explanationResponse,
            allowedOutputFormats: [.plainText, .markdown]
        )
        try expect(
            explainParsed.output == AIOutputDocument(
                format: .markdown,
                source: "**Photosynthesis** converts light into chemical energy."
            ),
            "Explain AI output was not parsed under explanationResponse contract."
        )

        let explainGlitchPayload = Data(
            ##"{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"```json\n{\"format\":\"plain_text\",\"explanation\":\"Gravitational force diminishes with distance.\"}## assistant to=final\n```"}]}]}"##.utf8
        )
        let explainGlitchParsed = try ResponsesAPIClient.parseCompletion(
            from: explainGlitchPayload,
            outputSchema: .explanationResponse,
            allowedOutputFormats: [.plainText, .markdown]
        )
        try expect(
            explainGlitchParsed.output == AIOutputDocument(
                format: .plainText,
                source: "Gravitational force diminishes with distance."
            ),
            "Explain AI answer with glitch tokens and code fences was not cleanly extracted."
        )
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
                && refine.reasoningEffort == .medium
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
            translate.reasoningEffort == .medium
                && format.reasoningEffort == .medium
                && translate.instructions.contains("Japanese, formal")
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
                && explain.maxOutputTokens == AppConstants.maximumOutputTokens
                && explain.inputText.contains("Earlier explanation")
                && explain.inputText.contains("Current hidden selected text")
                && explain.inputText.contains("Explain the hidden selected text")
                && explain.instructions.contains("briefly")
                && explain.instructions.contains("general chat question")
                && explain.reasoningEffort == .high,
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

        // Test paste session FIFO sequence ensuring first copy is never skipped:
        var pasteSourceQueue = FIFOQueue<String>()
        pasteSourceQueue.enqueue("First Item")
        pasteSourceQueue.enqueue("Second Item")
        pasteSourceQueue.enqueue("Third Item")

        var session = ClipboardQueuePasteSession(queue: &pasteSourceQueue)
        try expect(session.count == 3, "Initial paste session count should be 3.")
        try expect(session.current == "First Item", "First paste must be the first copied item.")
        try expect(!session.isComplete, "Session should not be complete before pasting.")

        // After first paste is consumed, advance to second item:
        let second = session.advance()
        try expect(second == "Second Item", "After first paste, session must advance to second item.")
        try expect(session.current == "Second Item", "Current payload must be Second Item.")
        try expect(session.count == 2, "Remaining paste count should be 2.")

        // After second paste is consumed, advance to third item:
        let third = session.advance()
        try expect(third == "Third Item", "After second paste, session must advance to third item.")
        try expect(session.current == "Third Item", "Current payload must be Third Item.")
        try expect(session.count == 1, "Remaining paste count should be 1.")

        // After third paste is consumed, advance to completion:
        let end = session.advance()
        try expect(end == nil, "After final paste, advance must return nil.")
        try expect(session.current == nil, "Current payload must be nil when complete.")
        try expect(session.count == 0, "Remaining paste count should be 0.")
        try expect(session.isComplete, "Session must report complete when all items are pasted.")
    }

    private static func sequentialClipboardCaptureChecks() async throws {
        try expect(
            ClipboardQueueCapturePolicy.maximumCaptureWait >= 2.0
                && ClipboardQueueCapturePolicy.maximumCaptureAttempts >= 100,
            "Clipboard capture did not allow enough time for a window switch and delayed copy."
        )
        try expect(
            ClipboardQueuePastePolicy.advanceDelay >= 0.2,
            "Clipboard payloads are not held long enough for asynchronous paste consumers."
        )

        let expected = ["quick", "cleanup,", "since", "this"]
        var captured: [String] = []
        var tracker = ClipboardQueueCaptureTracker(initialChangeCount: 40)
        var changeCount = 40
        for word in expected {
            tracker.synchronizeIfIdle(to: changeCount)
            tracker.registerCopyPress()
            changeCount += 1
            guard tracker.canConsume(changeCount: changeCount),
                  tracker.consume(changeCount: changeCount)
            else {
                throw CheckFailure(description: "A sequential clipboard change was not captured.")
            }
            captured.append(word)
        }
        try expect(
            captured == expected && !tracker.hasPendingCopies,
            "Sequential clipboard changes were duplicated, reordered, or left pending."
        )

        // Several delayed observers previously consumed the same final state,
        // producing results such as `quick this this this`. One change count
        // must now satisfy at most one physical Copy press.
        var delayed = ClipboardQueueCaptureTracker(initialChangeCount: 100)
        for _ in expected {
            delayed.registerCopyPress()
        }
        try expect(
            delayed.consume(changeCount: 104)
                && !delayed.consume(changeCount: 104)
                && delayed.pendingCopyCount == 3,
            "One clipboard update was incorrectly consumed by multiple Copy presses."
        )
        delayed.discardPendingCopies(observedChangeCount: 104)
        try expect(
            !delayed.hasPendingCopies,
            "Expired clipboard presses were not discarded."
        )
    }

    private static func sequentialClipboardSinglePressChecks() async throws {
        var tracker = ClipboardQueueCopyPressTracker()
        try expect(tracker.beginKeyDown(), "The first copy key-down was not accepted.")
        try expect(!tracker.beginKeyDown(), "A held copy key generated a duplicate capture.")
        try expect(tracker.endKeyUp(), "The copy key-up did not finish the press.")
        try expect(!tracker.endKeyUp(), "A repeated copy key-up generated a duplicate capture.")

        // Window switch recovery check: if keyUp was missed during a window switch,
        // reset() clears the press state so the next window can immediately capture.
        try expect(tracker.beginKeyDown(), "Key-down before window switch was not accepted.")
        tracker.reset()
        try expect(tracker.beginKeyDown(), "Key-down after window switch reset was rejected.")
        try expect(tracker.endKeyUp(), "Key-up after window switch was not accepted.")
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
            prompt.reasoningEffort == .medium
                && prompt.maxOutputTokens == 1_024
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
            "Request did not use the pinned GPT-5.4 snapshot."
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
                == "medium",
            "Translate should use medium reasoning for fast, nuanced responses."
        )

        let explainRequest = try client.makeRequest(
            prompt: PromptBuilder.make(action: .explain, parameter: "Explain gravity"),
            imagePNGs: [],
            apiKey: "not-a-real-key",
            safetyIdentifier: "test-safety-id"
        )
        let explainBody = try require(
            explainRequest.httpBody,
            "Explain request body was missing."
        )
        let explainJSON = try require(
            try JSONSerialization.jsonObject(with: explainBody) as? [String: Any],
            "Explain request body was not a JSON object."
        )
        try expect(
            (explainJSON["reasoning"] as? [String: Any])?["effort"] as? String
                == "high",
            "Explain should use high reasoning for deep answers."
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

    private static func configurableProviderRequestCheck() async throws {
        let openAIConfiguration = AIProviderConfiguration(
            provider: .openAICompatible,
            endpoint: URL(string: "https://example.test/v1/chat/completions")!,
            model: "custom-openai-model"
        )
        let anthropicConfiguration = AIProviderConfiguration(
            provider: .anthropic,
            endpoint: URL(string: "https://example.test/v1/messages")!,
            model: "custom-anthropic-model"
        )
        try expect(
            openAIConfiguration.validationMessage == nil
                && anthropicConfiguration.validationMessage == nil
                && AIProviderConfiguration(
                    provider: .anthropic,
                    endpoint: URL(string: "file:///tmp/messages")!,
                    model: "model"
                ).validationMessage != nil,
            "Provider configuration validation accepted an invalid endpoint."
        )
        try expect(
            AIProviderConfiguration.defaultConfiguration(for: .openAICompatible).model
                == AppConstants.fullModel
                && AIProviderConfiguration.defaultConfiguration(for: .anthropic).model
                == AppConstants.anthropicModel,
            "Provider defaults did not match the configured first-party models."
        )

        let requestClient = AIProviderClient(transport: MockTransport { _ in
            throw URLError(.badServerResponse)
        })
        let openAIRequest = try requestClient.makeRequest(
            prompt: PromptBuilder.make(action: .ocr),
            imagePNGs: [Data([0x89, 0x50, 0x4E, 0x47])],
            apiKey: "test-secret-key-not-real",
            safetyIdentifier: "test-safety-id",
            configuration: openAIConfiguration
        )
        try expect(
            openAIRequest.url == openAIConfiguration.endpoint
                && openAIRequest.value(forHTTPHeaderField: "Authorization")
                    == "Bearer test-secret-key-not-real",
            "OpenAI-compatible request did not use the selected endpoint or auth scheme."
        )
        let openAIBody = try require(
            try JSONSerialization.jsonObject(
                with: require(openAIRequest.httpBody, "OpenAI-compatible body was missing.")
            ) as? [String: Any],
            "OpenAI-compatible body was not a JSON object."
        )
        let openAIMessages = try require(
            openAIBody["messages"] as? [[String: Any]],
            "OpenAI-compatible messages were missing."
        )
        let openAIUserContent = try require(
            openAIMessages.last?["content"] as? [[String: Any]],
            "OpenAI-compatible user content was missing."
        )
        let openAIResponseFormat = try require(
            openAIBody["response_format"] as? [String: Any],
            "OpenAI-compatible JSON response format was missing."
        )
        let openAIJSONSchema = try require(
            openAIResponseFormat["json_schema"] as? [String: Any],
            "OpenAI-compatible JSON schema wrapper was missing."
        )
        try expect(
            openAIBody["model"] as? String == "custom-openai-model"
                && openAIBody["max_completion_tokens"] as? Int == AppConstants.maximumOutputTokens
                && openAIMessages.first?["role"] as? String == "system"
                && openAIUserContent.contains(where: { $0["type"] as? String == "image_url" })
                && openAIResponseFormat["type"] as? String == "json_schema"
                && openAIJSONSchema["strict"] as? Bool == true,
            "OpenAI-compatible request did not preserve the app's model and output contract."
        )

        let anthropicRequest = try requestClient.makeRequest(
            prompt: PromptBuilder.make(action: .ocr),
            imagePNGs: [Data([0x89, 0x50, 0x4E, 0x47])],
            apiKey: "test-secret-key-not-real",
            safetyIdentifier: "test-safety-id",
            configuration: anthropicConfiguration
        )
        try expect(
            anthropicRequest.url == anthropicConfiguration.endpoint
                && anthropicRequest.value(forHTTPHeaderField: "x-api-key")
                    == "test-secret-key-not-real"
                && anthropicRequest.value(forHTTPHeaderField: "anthropic-version")
                    == "2023-06-01",
            "Anthropic request did not use the selected endpoint or required headers."
        )
        let anthropicBody = try require(
            try JSONSerialization.jsonObject(
                with: require(anthropicRequest.httpBody, "Anthropic body was missing.")
            ) as? [String: Any],
            "Anthropic body was not a JSON object."
        )
        let anthropicMessages = try require(
            anthropicBody["messages"] as? [[String: Any]],
            "Anthropic messages were missing."
        )
        let anthropicUserContent = try require(
            anthropicMessages.first?["content"] as? [[String: Any]],
            "Anthropic user content was missing."
        )
        let anthropicOutputConfig = try require(
            anthropicBody["output_config"] as? [String: Any],
            "Anthropic output configuration was missing."
        )
        try expect(
            anthropicBody["model"] as? String == "custom-anthropic-model"
                && anthropicBody["max_tokens"] as? Int == AppConstants.maximumOutputTokens
                && anthropicBody["system"] as? String == PromptBuilder.make(action: .ocr).instructions
                && anthropicMessages.first?["role"] as? String == "user"
                && anthropicUserContent.contains(where: { $0["type"] as? String == "image" })
                && (anthropicOutputConfig["format"] as? [String: Any])?["type"] as? String
                    == "json_schema",
            "Anthropic request did not preserve the app's model and output contract."
        )

        let openAIPayload = Data(
            #"""
            {
              "choices": [{
                "message": {
                  "role": "assistant",
                  "content": "{\"format\":\"plain_text\",\"content\":\"Configured.\"}"
                },
                "finish_reason": "stop"
              }],
              "model": "custom-openai-model",
              "usage": {"prompt_tokens": 4, "completion_tokens": 2, "total_tokens": 6}
            }
            """#.utf8
        )
        let openAICompletionClient = AIProviderClient(transport: MockTransport { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/2",
                headerFields: nil
            )!
            return (openAIPayload, response)
        })
        let openAICompletion = try await openAICompletionClient.complete(
            prompt: PromptBuilder.make(action: .refine, selectedText: "Text"),
            apiKey: "test-secret-key-not-real",
            safetyIdentifier: "test-safety-id",
            configuration: openAIConfiguration
        )
        try expect(
            openAICompletion.text == "Configured."
                && openAICompletion.model == "custom-openai-model"
                && openAICompletion.totalTokens == 6,
            "OpenAI-compatible completion was not parsed through the shared output contract."
        )

        let anthropicPayload = Data(
            #"""
            {
              "content": [{
                "type": "text",
                "text": "{\"format\":\"plain_text\",\"explanation\":\"Anthropic.\"}"
              }],
              "model": "custom-anthropic-model",
              "stop_reason": "end_turn",
              "usage": {"input_tokens": 4, "output_tokens": 2}
            }
            """#.utf8
        )
        let anthropicCompletionClient = AIProviderClient(transport: MockTransport { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/2",
                headerFields: nil
            )!
            return (anthropicPayload, response)
        })
        let anthropicCompletion = try await anthropicCompletionClient.complete(
            prompt: PromptBuilder.make(action: .explain, parameter: "Explain this"),
            apiKey: "test-secret-key-not-real",
            safetyIdentifier: "test-safety-id",
            configuration: anthropicConfiguration
        )
        try expect(
            anthropicCompletion.text == "Anthropic."
                && anthropicCompletion.model == "custom-anthropic-model"
                && anthropicCompletion.totalTokens == 6,
            "Anthropic completion was not parsed through the shared output contract."
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

    private static func transportLifecycleCheck() async throws {
        let transport = LifecycleTransport()
        let client = AIProviderClient(transport: transport)
        let endpoint = URL(string: "https://example.com/v1/chat/completions")!

        client.prepareConnection()
        await client.preconnect(to: endpoint)
        client.suspendConnection()

        let snapshot = transport.snapshot
        try expect(
            snapshot.prepareCount == 1
                && snapshot.preconnectEndpoints == [endpoint]
                && snapshot.suspendCount == 1,
            "The provider client did not forward prepare, preconnect, and suspend lifecycle events."
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

private final class LifecycleTransport: HTTPTransport, @unchecked Sendable {
    struct Snapshot {
        let prepareCount: Int
        let preconnectEndpoints: [URL]
        let suspendCount: Int
    }

    private let lock = NSLock()
    private var prepareCount = 0
    private var preconnectEndpoints: [URL] = []
    private var suspendCount = 0

    var snapshot: Snapshot {
        lock.withLock {
            Snapshot(
                prepareCount: prepareCount,
                preconnectEndpoints: preconnectEndpoints,
                suspendCount: suspendCount
            )
        }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        throw URLError(.unsupportedURL)
    }

    func prepare() {
        lock.withLock {
            prepareCount += 1
        }
    }

    func preconnect(to endpoint: URL) async {
        lock.withLock {
            preconnectEndpoints.append(endpoint)
        }
    }

    func suspend() {
        lock.withLock {
            suspendCount += 1
        }
    }
}
