import Foundation
import CoreGraphics
import ImageIO
@preconcurrency import Vision
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Turns a captured screenshot into agent-ready text, entirely on-device.
///
/// Two stages, both private and offline:
/// 1. **Vision OCR** (`VNRecognizeTextRequest`) reads the pixels — free, no permission, no model
///    download. This always runs and is the floor: even with Apple Intelligence off, a screenshot
///    still compiles to its transcribed text.
/// 2. **Foundation Models** (when available) cleans that raw OCR into a tidy, labelled block and
///    classifies what the shot *is* (error log / code / UI / table / table / generic), so the
///    coding agent gets "Terminal error: …" rather than a jumble of detected lines. Mirrors
///    `SemanticLintService`'s availability gating; if the model can't run, stage 1's text is used
///    verbatim.
///
/// The result is what an `.image` card stores in `imageUnderstanding` and contributes to the prompt.
enum ImageUnderstanding {
  /// Warm the Foundation Models assets so the first refine doesn't pay cold-start latency. Called
  /// when the capture overlay appears, so the model loads while the user drags out their selection.
  /// Cheap no-op when Apple Intelligence is unavailable.
  static func prewarm() {
    guard isModelAvailable else { return }
    #if canImport(FoundationModels)
    guard #available(macOS 26, *) else { return }
    let session = LanguageModelSession(instructions: instructions)
    session.prewarm()
    warmSession = session
    #endif
  }

  /// Holds one warmed session purely to keep the model assets resident; refines still use a fresh,
  /// stateless session so no transcript accumulates. Untyped because the type is gated behind 26.
  private static var warmSession: AnyObject?

  /// The agent-ready block for a captured image, or nil when nothing legible was found and the model
  /// couldn't describe it either (a pure-graphic shot with no text). Used by disk-path callers; the
  /// live capture flow calls the two stages directly so the card paints OCR before the refine lands.
  static func analyze(cgImage: CGImage) async -> String? {
    let raw = await recognizeText(in: cgImage)
    if let refined = await refine(ocr: raw), !refined.isEmpty { return refined }
    guard !raw.isEmpty else { return nil }
    return "[Screenshot]\n\(raw)"
  }

  /// Convenience for an image already saved to disk.
  static func analyze(imagePath: String) async -> String? {
    guard let cgImage = loadCGImage(path: imagePath) else { return nil }
    return await analyze(cgImage: cgImage)
  }

  private static func loadCGImage(path: String) -> CGImage? {
    guard let url = AssetStore.resolve(path),
          let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
  }

  // MARK: Stage 1 — Vision OCR (the fast floor; always runs)

  /// Recognized text, newline-joined and trimmed. Empty when nothing legible was found.
  static func recognizeText(in cgImage: CGImage) async -> String {
    let lines = (try? await runOCR(cgImage)) ?? []
    return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func runOCR(_ cgImage: CGImage) async throws -> [String] {
    try await withCheckedThrowingContinuation { continuation in
      let request = VNRecognizeTextRequest { request, error in
        if let error {
          continuation.resume(throwing: error)
          return
        }
        let lines = (request.results as? [VNRecognizedTextObservation] ?? [])
          .compactMap { $0.topCandidates(1).first?.string }
        continuation.resume(returning: lines)
      }
      request.recognitionLevel = .accurate
      request.usesLanguageCorrection = true
      let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
      // Vision work off the main thread; the continuation hops back to the caller's context.
      DispatchQueue.global(qos: .userInitiated).async {
        do { try handler.perform([request]) }
        catch { continuation.resume(throwing: error) }
      }
    }
  }

  // MARK: Stage 2 — Foundation Models refinement (optional upgrade)

  private static var isModelAvailable: Bool {
    guard #available(macOS 26, *) else { return false }
    #if canImport(FoundationModels)
    if case .available = SystemLanguageModel.default.availability { return true }
    return false
    #else
    return false
    #endif
  }

  /// Clean + classify the OCR text into one labelled block. Returns nil when the model is
  /// unavailable, the OCR was empty, or generation failed — the caller then keeps the raw OCR.
  static func refine(ocr: String) async -> String? {
    guard isModelAvailable, !ocr.isEmpty else { return nil }
    #if canImport(FoundationModels)
    guard #available(macOS 26, *) else { return nil }
    // Cap the input so a dense screenshot can't overflow the small on-device context.
    let trimmed = ocr.count > 6_000 ? String(ocr.prefix(6_000)) : ocr
    do {
      let session = LanguageModelSession(instructions: instructions)
      let result = try await session.respond(to: prompt(for: trimmed), generating: ImageReadout.self).content
      let label = result.kind.label
      let body = result.content.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !body.isEmpty else { return nil }
      return "[Screenshot — \(label)]\n\(body)"
    } catch {
      return nil
    }
    #else
    return nil
    #endif
  }

  private static let instructions = """
  You convert the raw OCR text of a screenshot into a clean, self-contained block that a coding \
  agent can act on. The OCR may be noisy, out of order, or include UI chrome. Your job:
  - Decide what the screenshot is (error/log, code, UI screen, table, terminal, or other text).
  - Reconstruct the meaningful content faithfully. Preserve code, stack traces, file paths, error \
    messages, and identifiers VERBATIM — do not paraphrase or "fix" them. For a table, format it as \
    Markdown. For a UI, briefly describe the screen and list its visible labels/controls.
  - Drop pure chrome (menu bars, clocks, battery, window controls) that isn't part of the content.
  - Never invent text that isn't supported by the OCR. If little is legible, return what there is.
  Return only the reconstructed content — no preamble, no commentary.
  """

  private static func prompt(for ocr: String) -> String {
    """
    Here is the raw OCR text from a screenshot. Classify it and reconstruct its content.

    ===== OCR =====
    \(ocr)
    """
  }
}

#if canImport(FoundationModels)

@available(macOS 26, *)
@Generable
private struct ImageReadout {
  @Guide(description: "What this screenshot mostly is.")
  let kind: ImageKind
  @Guide(description: "The reconstructed, agent-ready content. Code/errors/paths kept verbatim; a table as Markdown; a UI described with its visible labels.")
  let content: String
}

@available(macOS 26, *)
@Generable
private enum ImageKind {
  case error
  case code
  case ui
  case table
  case terminal
  case text

  var label: String {
    switch self {
    case .error: "Error"
    case .code: "Code"
    case .ui: "UI"
    case .table: "Table"
    case .terminal: "Terminal"
    case .text: "Text"
    }
  }
}

#endif
