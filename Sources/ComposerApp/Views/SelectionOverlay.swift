import SwiftUI

/// The one selection box for the whole board, drawn in viewport space from `SelectionChrome` — the
/// same layout `CanvasSelectGesture` hit-tests, so a handle is grabbable exactly where it is drawn.
/// Everything here is pointer-transparent except the delete button; the canvas input view owns
/// every other press.
struct SelectionOverlay: View {
  let chrome: SelectionChrome
  let onDelete: () -> Void

  var body: some View {
    ZStack(alignment: .topLeading) {
      ForEach(Array(chrome.elementOutlines.enumerated()), id: \.offset) { _, rect in
        RoundedRectangle(cornerRadius: 3, style: .continuous)
          .strokeBorder(Theme.Palette.accent.opacity(0.45), lineWidth: 1)
          .frame(width: max(rect.width, 1), height: max(rect.height, 1))
          .position(x: rect.midX, y: rect.midY)
      }

      if let box = chrome.box {
        RoundedRectangle(cornerRadius: chrome.boxCornerRadius, style: .continuous)
          .strokeBorder(
            Theme.Palette.accent.opacity(chrome.isMultiple ? 0.85 : 0.7),
            style: StrokeStyle(lineWidth: 1, dash: chrome.isMultiple ? [4, 3] : []))
          .frame(width: box.width, height: box.height)
          .position(x: box.midX, y: box.midY)

        ForEach(chrome.handles, id: \.self) { handle in
          let point = handle.point(on: box)
          if handle.isCorner {
            CornerHandle().position(point)
          } else if chrome.sidesAreTextWidth {
            WrapWidthHandle().position(point)
          }
        }
      }

      ForEach(chrome.ports, id: \.direction) { port in
        PortHandle(direction: port.direction).position(port.point)
      }

      ForEach(chrome.endpoints, id: \.endpoint) { endpoint in
        EndpointHandle().position(endpoint.point)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .allowsHitTesting(false)
    .overlay(alignment: .topLeading) {
      if let center = chrome.deleteCenter {
        DeleteSelectionButton(action: onDelete).position(center)
      }
    }
  }
}

private struct CornerHandle: View {
  var body: some View {
    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
      .fill(Theme.Palette.labelChipFill)
      .frame(width: 8, height: 8)
      .overlay(RoundedRectangle(cornerRadius: 2.5, style: .continuous)
        .strokeBorder(Theme.Palette.accent.opacity(0.9), lineWidth: 1))
      .shadow(color: Theme.Palette.elementShadow, radius: 2, y: 1)
  }
}

/// A vertical pill distinguishes a text element's reflow handles from its scale corners.
private struct WrapWidthHandle: View {
  var body: some View {
    Capsule()
      .fill(Theme.Palette.labelChipFill)
      .frame(width: 6, height: 18)
      .overlay(Capsule().strokeBorder(Theme.Palette.accent.opacity(0.9), lineWidth: 1))
      .shadow(color: Theme.Palette.elementShadow, radius: 2, y: 1)
  }
}

/// Round endpoint furniture, deliberately distinct from the square resize corners.
private struct EndpointHandle: View {
  var body: some View {
    Circle()
      .fill(Theme.Palette.labelChipFill)
      .frame(width: 9, height: 9)
      .overlay(Circle().strokeBorder(Theme.Palette.accent, lineWidth: 1.5))
      .shadow(color: Theme.Palette.elementShadow, radius: 2, y: 1)
  }
}

/// Quick-connect: click for a linked shape, drag to connect (⌥ for a plain line).
private struct PortHandle: View {
  let direction: ConnectorDirection

  var body: some View {
    Image(systemName: symbol)
      .font(.system(size: 8, weight: .semibold))
      .foregroundStyle(Theme.Palette.accent)
      .frame(width: 15, height: 15)
      .background(Circle().fill(Theme.Palette.windowCanvas.opacity(0.94)))
      .overlay(Circle().strokeBorder(Theme.Palette.accent.opacity(0.62), lineWidth: 1))
      .shadow(color: Theme.Palette.elementShadow, radius: 2, y: 1)
  }

  private var symbol: String {
    switch direction {
    case .up: "arrow.up"
    case .right: "arrow.right"
    case .down: "arrow.down"
    case .left: "arrow.left"
    }
  }
}

private struct DeleteSelectionButton: View {
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: "xmark")
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(Theme.Palette.chromeGlyphHover)
        .frame(width: 18, height: 18)
        .background(Circle().fill(Theme.Palette.labelChipFill))
        .overlay(Circle().strokeBorder(Theme.Palette.panelHairline, lineWidth: 0.5))
        .shadow(color: Theme.Palette.elementShadow, radius: 2, y: 1)
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .help("Delete card".localizedUI)
  }
}
