# Guarded Markdown and LaTeX Output

## Status

Approved architecture. Implementation is isolated on `codex/rich-output-rendering`.
The pre-existing worktree is protected by checkpoint commit `176f3fa`.

## Goals

- Give every AI result a typed, validated presentation format.
- Render Markdown and common LaTeX natively in Explain and Calculate.
- Preserve exact source text for plain-text destinations and unsupported math.
- Keep OCR literal, keep local/UI controls plain, and avoid WebKit or runtime web assets.

## Output contract

Normal AI responses use a strict JSON object:

```json
{"format":"plain_text|markdown","content":"..."}
```

Calculate uses the same format field and keeps the answer isolated from hidden reasoning:

```json
{"format":"plain_text|markdown","answer":"..."}
```

The app maps either object to `AIOutputDocument`, validates the format against an
action policy, normalizes line endings and outer whitespace, and rejects malformed
or disallowed responses before publishing them. Insert lookup remains integer-only.

The action policy is:

| Action | Allowed output |
| --- | --- |
| OCR | `plain_text` only |
| Refine / Translate | detected source mode only |
| Format | Markdown when the instruction requests structured formatting, otherwise plain text |
| Explain / Calculate | plain text or Markdown |
| Insert lookup | integer only |

The model is instructed to emit `\\(...\\)` and `\\[...\\]` for math. The parser
also accepts `$...$` and `$$...$$`, outside code spans and fenced code blocks.

## Native renderer

The renderer is an AppKit/TextKit component shared by Explain and Calculate. It
supports headings, paragraphs, emphasis, lists, block quotes, inline/fenced code,
tables, and selectable non-navigating links. Raw HTML, scripts, embedded images,
and automatic navigation are not executed or loaded; unsafe constructs are shown
as escaped source.

Math is parsed into a small native layout tree and displayed as TextKit attachments.
The supported grammar covers grouped expressions, fractions, square roots,
superscripts, subscripts, Greek letters, and common operators. Unsupported or
malformed expressions remain visible as styled, selectable LaTeX source.

The renderer produces:

- an attributed TextKit representation for native views;
- HTML and RTF/RTFD data with generated equation attachments;
- the normalized original Markdown/LaTeX as the plain-text representation.

## UI and clipboard integration

- Explain keeps user prompts and hidden selection plain, while assistant exchanges
  render from their stored `AIOutputDocument`.
- Calculate becomes a selectable, scrollable result popup and keeps cursor-away
  dismissal.
- Compact success, busy, and error HUDs remain plain labels.
- OCR publishes only literal plain text. Refine and Format use direct Accessibility
  replacement when available, and rich paste fallback after selection validation.
- Clipboard-only results publish plain, HTML, and RTF/RTFD flavors.

## Failure and privacy behavior

Malformed JSON, invalid format values, policy violations, unsafe content, refusals,
and incomplete responses fail closed with a retryable user-facing error. Raw model
responses remain in memory only and are not logged. Conversation memory stores the
typed source document and serializes its source text when building the next prompt.

## Verification

Core checks cover contracts, policies, strict parsing, format detection, and math
parsing. AppKit checks cover Markdown blocks, tables, links, code fences, equations,
currency symbols, unsafe HTML, unsupported math fallback, and clipboard export.
Release builds, installer smoke tests, and manual Explain/Calculate/replacement
checks are required before completion.
