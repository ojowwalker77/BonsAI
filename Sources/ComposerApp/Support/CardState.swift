import CoreGraphics
import Foundation

enum CanvasElementKind: String, Codable, Equatable, CaseIterable {
  case text
  case rectangle
  case ellipse
  case diamond
  case line
  case arrow
  case freehand
  case image
  case equation
  case graph

  /// Box shapes constrain to a square while Shift is held (draw + resize) — rectangle→square,
  /// ellipse→circle, diamond→uniform. Lines and arrows instead snap to an axis (`constrainsToAxis`);
  /// freehand stays freeform.
  var constrainsToSquare: Bool {
    switch self {
    case .rectangle, .ellipse, .diamond: true
    default: false
    }
  }

  /// Lines and arrows snap perfectly horizontal or vertical while Shift is held (whichever the drag
  /// is nearer to). Box shapes square instead; freehand stays freeform.
  var constrainsToAxis: Bool {
    switch self {
    case .line, .arrow: true
    default: false
    }
  }
}

/// One colored span of a text card's ink, measured in UTF-16 offsets of the SERIALIZED plain
/// text (`composerPlainText`). `slot` indexes the active theme's `ThemeFlavor.tints`, so ranges
/// re-resolve per theme exactly like element tints.
struct InkRun: Codable, Equatable {
  var loc: Int
  var len: Int
  var slot: Int
}

struct CanvasPoint: Codable, Equatable {
  var x: Double
  var y: Double

  var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

/// One text card on a board: its content (plain `@token` text — the source of truth, same
/// as the single-note era) plus its board-space frame and z-order. The whole board is a
/// `[CardState]` serialized as JSON into `Dump.cardsData`. Chips stay a within-session
/// cosmetic layer; only this plain text persists.
struct CardState: Codable, Identifiable, Equatable {
  var id: UUID
  /// Missing on legacy boards; nil means `.text`.
  var kind: CanvasElementKind?
  var text: String
  var x: Double
  var y: Double
  var w: Double
  var h: Double
  var z: Int
  /// Freehand points are normalized into the element's local 0...1 frame.
  var points: [CanvasPoint]?
  /// Reserved for arrow/line binding. Kept optional so the first shape slice stays
  /// backward-compatible while the model can already persist bindings.
  var startBindingID: UUID?
  var endBindingID: UUID?
  /// WHERE on the bound card this arrow attaches, normalized into that card's frame (0…1 per
  /// axis). Captured from the drawn stroke, so the arrow lands where it was aimed and keeps that
  /// attachment as the card moves — instead of re-routing through the card's center ("aim-assist",
  /// pulled after 1.4.5 feedback). nil (legacy boards, agent connects) = center-ray routing.
  var startBindingAnchor: CanvasPoint?
  var endBindingAnchor: CanvasPoint?
  var groupID: UUID?
  var isLocked: Bool?
  var imagePath: String?
  /// For `.equation` cards: raw LaTeX math-mode source, without surrounding `$` delimiters.
  var latex: String?
  /// For `.image` cards: the on-device, agent-ready text read out of the screenshot (OCR + a short
  /// classification, e.g. "Terminal error: …"). This is what an image card contributes to the
  /// compiled prompt and to `CanvasBridge.snapshot()` — without it a screenshot is invisible to a
  /// coding agent. Nil while still being read (or when nothing legible was found).
  var imageUnderstanding: String?
  /// A superseded idea — kept on the board for lineage but visually faded (provenance).
  var archived: Bool?
  /// Who last authored this card: 1 = human, 2 = agent. Nil on legacy cards (treated as unknown).
  /// Lets an agent reading the board tell its own work from what the human wrote or changed.
  var whoWrote: Int?
  /// Element tint as a SLOT INDEX into the active theme's `ThemeFlavor.tints` (nil = default
  /// ink). Semantic, not a color value — the same element re-resolves per theme.
  var tint: Int?
  /// Per-range text ink (text cards): colored spans over the serialized plain text.
  var ink: [InkRun]?
  /// Per-card font multiplier for `.text` cards — dragging a text card's corner handles scales its
  /// font (Apple Freeform behavior) instead of reflowing a fixed box (issue #77). nil means 1.0, so
  /// legacy boards decode unchanged; meaningful only for text cards.
  var fontScale: Double?

  struct GraphPoint: Codable, Equatable, Hashable {
    var x: Double
    var y: Double
    var label: String = ""
    /// Per-point ink slot (status colors on a timeline); nil inherits the series color.
    var tint: Int? = nil

    init(x: Double, y: Double, label: String = "", tint: Int? = nil) {
      self.x = x
      self.y = y
      self.label = label
      self.tint = tint
    }

    private enum CodingKeys: String, CodingKey {
      case x
      case y
      case label
      case tint
    }

    init(from decoder: Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      x = try values.decodeIfPresent(Double.self, forKey: .x) ?? 0
      y = try values.decodeIfPresent(Double.self, forKey: .y) ?? 0
      label = try values.decodeIfPresent(String.self, forKey: .label) ?? ""
      tint = try values.decodeIfPresent(Int.self, forKey: .tint)
    }
  }

  struct GraphSeries: Codable, Equatable, Hashable, Identifiable {
    var id: UUID = UUID()
    var expression: String? = nil
    var points: [GraphPoint]? = nil
    var label: String = ""
    var tint: Int? = nil

    init(id: UUID = UUID(),
         expression: String? = nil,
         points: [GraphPoint]? = nil,
         label: String = "",
         tint: Int? = nil) {
      self.id = id
      self.expression = expression
      self.points = points
      self.label = label
      self.tint = tint
    }

    private enum CodingKeys: String, CodingKey {
      case id
      case expression
      case points
      case label
      case tint
    }

    init(from decoder: Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
      expression = try values.decodeIfPresent(String.self, forKey: .expression)
      points = try values.decodeIfPresent([GraphPoint].self, forKey: .points)
      label = try values.decodeIfPresent(String.self, forKey: .label) ?? ""
      tint = try values.decodeIfPresent(Int.self, forKey: .tint)
    }
  }

  struct GraphSpec: Codable, Equatable, Hashable {
    var xLabel: String = ""
    var xUnit: String = ""
    var yLabel: String = ""
    var yUnit: String = ""
    var xMin: Double = 0
    var xMax: Double = 10
    var yMin: Double = 0
    var yMax: Double = 10
    var showGrid: Bool = true
    var series: [GraphSeries] = []

    init(xLabel: String = "",
         xUnit: String = "",
         yLabel: String = "",
         yUnit: String = "",
         xMin: Double = 0,
         xMax: Double = 10,
         yMin: Double = 0,
         yMax: Double = 10,
         showGrid: Bool = true,
         series: [GraphSeries] = []) {
      self.xLabel = xLabel
      self.xUnit = xUnit
      self.yLabel = yLabel
      self.yUnit = yUnit
      self.xMin = xMin
      self.xMax = xMax
      self.yMin = yMin
      self.yMax = yMax
      self.showGrid = showGrid
      self.series = series
    }

    private enum CodingKeys: String, CodingKey {
      case xLabel
      case xUnit
      case yLabel
      case yUnit
      case xMin
      case xMax
      case yMin
      case yMax
      case showGrid
      case series
    }

    init(from decoder: Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      xLabel = try values.decodeIfPresent(String.self, forKey: .xLabel) ?? ""
      xUnit = try values.decodeIfPresent(String.self, forKey: .xUnit) ?? ""
      yLabel = try values.decodeIfPresent(String.self, forKey: .yLabel) ?? ""
      yUnit = try values.decodeIfPresent(String.self, forKey: .yUnit) ?? ""
      xMin = try values.decodeIfPresent(Double.self, forKey: .xMin) ?? 0
      xMax = try values.decodeIfPresent(Double.self, forKey: .xMax) ?? 10
      yMin = try values.decodeIfPresent(Double.self, forKey: .yMin) ?? 0
      yMax = try values.decodeIfPresent(Double.self, forKey: .yMax) ?? 10
      showGrid = try values.decodeIfPresent(Bool.self, forKey: .showGrid) ?? true
      series = try values.decodeIfPresent([GraphSeries].self, forKey: .series) ?? []
    }
  }
  /// For `.graph` cards: axis labels, units, ranges, and grid preference.
  var graph: GraphSpec?

  init(id: UUID = UUID(),
       kind: CanvasElementKind = .text,
       text: String = "",
       x: Double,
       y: Double,
       w: Double = Double(CardState.defaultSize.width),
       h: Double = Double(CardState.defaultSize.height),
       z: Int = 0,
       points: [CanvasPoint]? = nil,
       startBindingID: UUID? = nil,
       endBindingID: UUID? = nil,
       groupID: UUID? = nil,
       isLocked: Bool = false,
       imagePath: String? = nil,
       latex: String? = nil,
       graph: GraphSpec? = nil,
       imageUnderstanding: String? = nil,
       archived: Bool = false,
       whoWrote: Int? = nil,
       tint: Int? = nil,
       ink: [InkRun]? = nil,
       fontScale: Double? = nil) {
    self.id = id
    self.kind = kind == .text ? nil : kind
    self.text = text
    self.x = x
    self.y = y
    self.w = w
    self.h = h
    self.z = z
    self.points = points
    self.startBindingID = startBindingID
    self.endBindingID = endBindingID
    self.groupID = groupID
    self.isLocked = isLocked ? true : nil
    self.imagePath = imagePath
    self.latex = latex
    self.graph = graph
    self.imageUnderstanding = imageUnderstanding
    self.archived = archived ? true : nil
    self.whoWrote = whoWrote
    self.tint = tint
    self.ink = ink
    self.fontScale = fontScale
  }

  var elementKind: CanvasElementKind { kind ?? .text }
  /// The card's font multiplier as a `CGFloat` — 1.0 when unset. Composes with the global text-size
  /// slider and the board zoom.
  var textScale: CGFloat { CGFloat(fontScale ?? 1) }
  var locked: Bool { isLocked ?? false }
  var isArchived: Bool { archived ?? false }
  var resolvedImageURL: URL? { imagePath.flatMap(AssetStore.resolve) }
  /// 1 = human, 2 = agent, 0 = unknown/legacy.
  var author: Int { whoWrote ?? 0 }

  var frame: CGRect {
    get { CGRect(x: x, y: y, width: w, height: h) }
    set { x = newValue.minX; y = newValue.minY; w = newValue.width; h = newValue.height }
  }

  var isBlank: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

  // Board-space geometry (points; the board is effectively infinite).
  static let defaultSize = CGSize(width: 360, height: 220)
  static let minSize = CGSize(width: 180, height: 96)
  /// Text behaves like Excalidraw point text: it starts small at the click and the height
  /// auto-grows to fit what you type, so these are just the seed/minimum, not a fixed box.
  static let textDefaultSize = CGSize(width: 360, height: 56)
  static let textMinSize = CGSize(width: 120, height: 40)
  static let shapeMinSize = CGSize(width: 56, height: 56)
  static let lineMinSize = CGSize(width: 24, height: 24)
  static let shapeSize = CGSize(width: 220, height: 140)
  static let lineSize = CGSize(width: 240, height: 96)
  static let equationSize = CGSize(width: 220, height: 96)
  static let graphSize = CGSize(width: 320, height: 240)

  var minimumSize: CGSize {
    switch elementKind {
    case .text:
      CardState.textMinSize
    case .equation:
      CGSize(width: 100, height: 48)
    case .graph:
      CGSize(width: 180, height: 140)
    case .rectangle, .ellipse, .diamond, .image:
      CardState.shapeMinSize
    case .line, .arrow, .freehand:
      CardState.lineMinSize
    }
  }

  /// The first card of a fresh board, and the shape a migrated single-note dump takes.
  /// Point-text height (auto-grows as you write); a bit wider so the brain-dump hint fits.
  static func firstCard(text: String = "") -> CardState {
    CardState(text: text, x: 48, y: 48, w: 420, h: 56, z: 0)
  }

  static func defaultFreehandPoints() -> [CanvasPoint] {
    [
      CanvasPoint(x: 0.08, y: 0.62),
      CanvasPoint(x: 0.20, y: 0.42),
      CanvasPoint(x: 0.34, y: 0.50),
      CanvasPoint(x: 0.48, y: 0.28),
      CanvasPoint(x: 0.62, y: 0.58),
      CanvasPoint(x: 0.78, y: 0.38),
      CanvasPoint(x: 0.92, y: 0.48),
    ]
  }

  static func defaultLinePoints() -> [CanvasPoint] {
    [
      CanvasPoint(x: 0.06, y: 0.88),
      CanvasPoint(x: 0.94, y: 0.12),
    ]
  }
}
