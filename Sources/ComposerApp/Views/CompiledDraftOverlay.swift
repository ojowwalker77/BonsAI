import SwiftUI

/// The result of "Compile to draft" — a full-card frosted sheet showing the merged prompt,
/// with Copy and Close.
struct CompiledDraftOverlay: View {
  let text: String
  var onCopy: () -> Void
  var onClose: () -> Void

  var body: some View {
    ZStack(alignment: .topLeading) {
      ZStack {
        VisualEffectBackground(material: .hudWindow, blending: .behindWindow, state: .active)
        Color.black.opacity(0.9)
      }
      .contentShape(Rectangle())

      VStack(spacing: 0) {
        header
        ScrollView {
          Text(text)
            .font(.body)
            .textSelection(.enabled)
            .foregroundStyle(Theme.Palette.body)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.bottom, 26)
        }
        .scrollIndicators(.never)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
  }

  private var header: some View {
    HStack(spacing: 10) {
      Image(systemName: "wand.and.rays").foregroundStyle(Theme.Palette.accent)
      Text("Compiled draft")
        .font(.title2.weight(.semibold))
        .foregroundStyle(Theme.Palette.body)
      Spacer()
      Button(action: onCopy) {
        HStack(spacing: 6) {
          Image(systemName: "doc.on.doc")
          Text("Copy")
        }
        .font(.body.weight(.medium))
        .foregroundStyle(Theme.Palette.accent)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.Palette.accentFill))
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Copy to clipboard")
      Button(action: onClose) {
        Image(systemName: "xmark")
          .font(.body.weight(.semibold))
          .foregroundStyle(Theme.Palette.title)
          .frame(width: 32, height: 32)
          .background(Circle().fill(Color.white.opacity(0.06)))
          .contentShape(Circle())
      }
      .buttonStyle(.plain)
      .help("Close  Esc")
    }
    .padding(.horizontal, 28)
    .padding(.top, 24)
    .padding(.bottom, 14)
  }
}
