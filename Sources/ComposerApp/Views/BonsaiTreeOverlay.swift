import SwiftUI

/// A cultivated bonsai form (kai). The user picks one in Settings ▸ Appearance; it selects the
/// WOODY-stage design (trunk movement, canopy composition, pot proportion) only — the early
/// sprout stage is shared by all styles (a seedling has no style yet).
enum BonsaiStyle: String, CaseIterable, Identifiable {
  case moyogi, chokkan, mikan, murasaki

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .moyogi: "Moyogi"
    case .chokkan: "Chokkan"
    case .mikan: "Mikan"
    case .murasaki: "Murasaki"
    }
  }

  var subtitle: String {
    switch self {
    case .moyogi: "Informal upright"
    case .chokkan: "Formal upright"
    case .mikan: "Fruiting"
    case .murasaki: "Purple-leaf"
    }
  }
}

/// The ambient bonsai in the canvas's bottom-left corner. It observes the shared growth clock and
/// re-draws whenever `grownSeconds` publishes (~every 30s) or the theme rebuilds — there is NO
/// continuous animation, so it costs nothing at rest. Hovering fades in a small age label.
///
/// This view owns only placement + the hover affordance; `BonsaiTreeView` is the pure, deterministic
/// drawing driven by a single `progress` value.
struct BonsaiTreeOverlay: View {
  @ObservedObject private var growth = BonsaiGrowth.shared
  @State private var hovering = false
  /// The user's chosen cultivated form. AppStorage re-renders the corner tree live when Settings
  /// writes this key, so switching styles morphs the tree in place.
  @AppStorage(ComposerPreferences.bonsaiStyleKey) private var styleRaw = BonsaiStyle.moyogi.rawValue

  /// The tree's fixed footprint. Everything anchors to the pot at bottom-center of this box.
  /// Sized with headroom: every style's extent math (documented at its design constants) keeps
  /// drawn pixels ≥4pt inside these bounds at p=1 — the Canvas clips at its edges.
  private static let footprint = CGSize(width: 128, height: 140)

  var body: some View {
    VStack(spacing: 6) {
      if hovering {
        Text(label)
          .font(WindowChrome.labelFont)
          .foregroundStyle(Theme.Palette.body)
          .fixedSize()
          .padding(.horizontal, 10)
          .padding(.vertical, 5)
          .composerPopupSurface(radius: 10)
          .transition(.opacity)
      }

      BonsaiTreeView(progress: growth.progress, style: BonsaiStyle(rawValue: styleRaw) ?? .moyogi)
        .frame(width: Self.footprint.width, height: Self.footprint.height)
        // Hover only lives on the tree's own bounds so the overlay never swallows the canvas beneath.
        .contentShape(Rectangle())
        .onHover { over in
          withAnimation(.easeOut(duration: 0.15)) { hovering = over }
        }
    }
    // No click handlers anywhere — decoration must stay transparent to board interaction.
    .allowsHitTesting(true)
  }

  /// "Bonsai · 12.4h" — one decimal below 10h, whole hours above. In DEBUG, a non-1× dev speed is
  /// appended so the scrub state is legible while testing.
  private var label: String {
    let hours = growth.grownSeconds / 3600
    let hoursText = hours < 10
      ? String(format: "%.1fh", hours)
      : String(format: "%.0fh", hours)
    var text = "Bonsai · \(hoursText)"
    #if DEBUG
    let speed = growth.devSpeedMultiplier
    if speed != 1 {
      text += " · \(Int(speed))×"
    }
    #endif
    return text
  }
}

/// The tree itself: a fully procedural, deterministic SwiftUI `Canvas`.
///
/// Design language: "illustrated botanical" — stylized, not cartoonish. What sells it:
/// - a DARK bark trunk with nebari (root flare), real movement, and strong taper — the trunk is
///   the hero, as in real bonsai;
/// - canopies built from many small overlapping leaf lobes in three values (shadow underside,
///   mid body, sunlit top) forming irregular cloud silhouettes with air between clumps;
/// - visible structure: forked branch wood entering each cloud, bare twig tips peeking past the
///   canopy edge, moss on the soil;
/// - per-style composition, down to the pot (cascades grow from tall pots).
///
/// Every shape is a continuous function of `progress` (0…1); new clumps fade/scale in over short
/// smoothstep windows so nothing pops. Organic irregularity comes from a seeded PRNG with
/// hard-coded per-clump seeds — the tree is byte-identical every frame and every launch.
struct BonsaiTreeView: View {
  let progress: Double
  let style: BonsaiStyle

  var body: some View {
    Canvas { context, size in
      draw(in: &context, size: size)
    }
    // Redraw is driven purely by `progress` changing (growth publish / theme rebuild). No animation.
    .drawingGroup()
  }

  // MARK: Palette — every color derives from theme tokens. The only manipulations are opacity,
  // token-to-token blends, and HSB shading OF a token (no literal color ever enters).

  private var greenBase: Color { Color(shade(Theme.flavor.tints[3], sat: 1.05, bri: 0.85)) }
  private var greenShadow: Color { Color(shade(Theme.flavor.tints[3], sat: 1.22, bri: 0.6)) }
  private var greenLight: Color { Color(shade(Theme.flavor.tints[3], sat: 0.8, bri: 1.2)) }
  /// Murasaki foliage: the same three-value recipe applied to the purple tint slot.
  private var purpleBase: Color { Color(shade(Theme.flavor.tints[5], sat: 1.05, bri: 0.85)) }
  private var purpleShadow: Color { Color(shade(Theme.flavor.tints[5], sat: 1.22, bri: 0.6)) }
  private var purpleLight: Color { Color(shade(Theme.flavor.tints[5], sat: 0.8, bri: 1.2)) }
  /// Mikan fruit: the yellow tint slot, with a sunlit spot.
  private var fruitBase: Color { Color(shade(Theme.flavor.tints[2], sat: 1.1, bri: 0.98)) }
  private var fruitLight: Color { Color(shade(Theme.flavor.tints[2], sat: 0.7, bri: 1.25)) }
  /// Dark bark in every theme: shading the warm tint down (instead of blending toward text ink,
  /// which LIGHTENS in dark themes) is what keeps the trunk reading as wood, not caramel.
  private var barkBase: Color { Color(shade(Theme.flavor.tints[1], sat: 0.62, bri: 0.5)) }
  private var barkRidge: Color { Color(shade(Theme.flavor.tints[1], sat: 0.5, bri: 0.82)) }
  private var soilColor: Color { Color(shade(Theme.flavor.tints[1], sat: 0.72, bri: 0.4)) }

  // MARK: Top-level draw

  private func draw(in context: inout GraphicsContext, size: CGSize) {
    let base = CGPoint(x: size.width / 2, y: size.height - 8)
    let p = max(0, min(1, progress))
    let pot = potMetrics
    let soil = base.y - CGFloat(pot.bodyH + pot.lipH) + 2

    drawPot(in: &context, base: base, m: pot)

    // Sprout (fresh install) crossfades out as the woody trunk crossfades in around p≈0.30.
    let sproutAlpha = 1 - smoothstep(0.26, 0.34, p)
    let woodyAlpha = smoothstep(0.26, 0.34, p)

    if sproutAlpha > 0.001 {
      drawSprout(in: &context, base: base, soil: soil, p: p, alpha: sproutAlpha)
    }
    if woodyAlpha > 0.001 {
      drawTree(in: &context, base: base, soil: soil, p: p, alpha: woodyAlpha)
    }
  }

  // MARK: Pot

  private struct PotMetrics {
    var lipW: CGFloat
    var bodyW: CGFloat
    var bodyH: CGFloat
    var lipH: CGFloat
    var footDX: CGFloat
  }

  /// All current forms take the classic shallow tray. (Kept as a per-style hook — a cascade
  /// style would need a tall pot.)
  private var potMetrics: PotMetrics {
    PotMetrics(lipW: 60, bodyW: 54, bodyH: 20, lipH: 6, footDX: 14)
  }

  private func drawPot(in context: inout GraphicsContext, base: CGPoint, m: PotMetrics) {
    let lipTop = base.y - m.bodyH - m.lipH

    // Trapezoid body (wider at the lip, narrowing to the foot).
    var body = Path()
    body.move(to: CGPoint(x: base.x - m.bodyW / 2, y: lipTop + m.lipH))
    body.addLine(to: CGPoint(x: base.x + m.bodyW / 2, y: lipTop + m.lipH))
    body.addLine(to: CGPoint(x: base.x + m.bodyW / 2 - 7, y: base.y))
    body.addLine(to: CGPoint(x: base.x - m.bodyW / 2 + 7, y: base.y))
    body.closeSubpath()

    let lip = Path(roundedRect: CGRect(x: base.x - m.lipW / 2, y: lipTop, width: m.lipW, height: m.lipH),
                   cornerRadius: 2)

    context.fill(body, with: .color(Theme.Palette.keycapFill))
    context.fill(lip, with: .color(Theme.Palette.keycapFill))
    context.stroke(body, with: .color(Theme.Palette.panelHairline), lineWidth: 1)
    context.stroke(lip, with: .color(Theme.Palette.panelHairline), lineWidth: 1)

    // Two tiny feet.
    for dx in [-m.footDX, m.footDX] {
      let foot = Path(roundedRect: CGRect(x: base.x + dx - 4, y: base.y - 1, width: 8, height: 4),
                      cornerRadius: 1.5)
      context.fill(foot, with: .color(Theme.Palette.keycapFill))
      context.stroke(foot, with: .color(Theme.Palette.panelHairline), lineWidth: 1)
    }

    // Soil: a low dark mound inside the lip, with a few moss bumps — small detail, big believability.
    let soilTop = lipTop + 1
    var soil = Path()
    soil.move(to: CGPoint(x: base.x - m.lipW / 2 + 5, y: soilTop + 3))
    soil.addQuadCurve(to: CGPoint(x: base.x + m.lipW / 2 - 5, y: soilTop + 3),
                      control: CGPoint(x: base.x, y: soilTop - 3))
    soil.addLine(to: CGPoint(x: base.x + m.lipW / 2 - 5, y: soilTop + m.lipH))
    soil.addLine(to: CGPoint(x: base.x - m.lipW / 2 + 5, y: soilTop + m.lipH))
    soil.closeSubpath()
    context.fill(soil, with: .color(soilColor.opacity(0.85)))

    let mossSpread = m.lipW / 2 - 8
    for (fx, r) in [(-0.55, 2.6), (0.05, 2.0), (0.6, 3.0)] as [(CGFloat, CGFloat)] {
      let c = CGPoint(x: base.x + fx * mossSpread, y: soilTop + 1.5)
      context.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r * 0.6, width: r * 2, height: r * 1.2)),
                   with: .color(greenShadow.opacity(0.55)))
    }
  }

  // MARK: Sprout stage (p < ~0.30, shared by all styles)

  private func drawSprout(in context: inout GraphicsContext, base: CGPoint, soil: CGFloat, p: Double, alpha: Double) {
    let height = lerp(6, 22, p / 0.30)
    let top = CGPoint(x: base.x + 2, y: soil - height)

    var stem = Path()
    stem.move(to: CGPoint(x: base.x - 1, y: soil))
    stem.addQuadCurve(to: top, control: CGPoint(x: base.x - 5, y: soil - height * 0.55))
    context.stroke(stem, with: .color(greenBase.opacity(alpha)),
                   style: StrokeStyle(lineWidth: 2, lineCap: .round))

    // 2–3 small leaves, two-tone, appearing progressively with the stem's growth.
    let leaves: [(dx: CGFloat, dy: CGFloat, rx: CGFloat, ry: CGFloat, threshold: Double, lit: Bool)] = [
      (-4, 2, 5, 3, 0.05, false),
      (5, 6, 5.5, 3.2, 0.12, false),
      (0, -2, 4.5, 3, 0.20, true),
    ]
    for leaf in leaves {
      let a = alpha * smoothstep(leaf.threshold, leaf.threshold + 0.06, p)
      guard a > 0.001 else { continue }
      let rect = CGRect(x: top.x + leaf.dx - leaf.rx, y: top.y + leaf.dy - leaf.ry,
                        width: leaf.rx * 2, height: leaf.ry * 2)
      context.fill(Path(ellipseIn: rect), with: .color((leaf.lit ? greenLight : greenBase).opacity(a)))
    }
  }

  // MARK: The tree — per-style designs

  /// One foliage cloud. `attach` is the trunk-spine fraction its branch wood grows from
  /// (<0 = detached). `twigs` = bare tips peeking past the canopy. `fruits` = how many fruit
  /// hang from this cloud's lower silhouette once the tree is mature.
  private struct Clump {
    var enter: Double
    var center: CGPoint
    var r: CGFloat
    var aspect: CGFloat
    var attach: CGFloat
    var seed: UInt64
    var twigs: Int = 0
    var fruits: Int = 0
  }

  private struct Design {
    var spine: [CGPoint]
    var trunkWidth: CGFloat
    var clumps: [Clump]
    /// Bare wood with no foliage: (spine fraction, end point, width).
    var bareTwigs: [(t: CGFloat, end: CGPoint, width: CGFloat)] = []
    var purpleFoliage = false
  }

  /// All coordinates are the FINAL (p=1) layout in absolute canvas space (base=(64,132)); growth
  /// scales every point about the soil anchor. Extent math per style lives on its constants.
  private func design(base: CGPoint, soil: CGFloat) -> Design {
    let x = base.x
    switch style {
    case .moyogi:
      // Informal upright: strong S-movement, big asymmetric triangle of clouds.
      // EXTENTS p=1: left clump (43,72) r14 asp1.35 → reach rx·0.9+0.6r≈25.4+shadow → x≥15 ✓.
      // Apex (70,40) r16: top y ≈ 40−(ry·0.9+0.6r)≈20 ✓. Right clump (90,63) r12.5 → x≤112 ✓.
      return Design(
        spine: [CGPoint(x: x, y: soil + 2), CGPoint(x: x - 7, y: soil - 12),
                CGPoint(x: x + 5, y: soil - 30), CGPoint(x: x - 4, y: soil - 48),
                CGPoint(x: x + 8, y: soil - 62)],
        trunkWidth: 9,
        clumps: [
          Clump(enter: 0.0, center: CGPoint(x: x + 6, y: soil - 68), r: 16, aspect: 1.5, attach: 1.0, seed: 11, twigs: 2),
          Clump(enter: 0.34, center: CGPoint(x: x - 21, y: soil - 36), r: 14, aspect: 1.35, attach: 0.30, seed: 12, twigs: 1),
          Clump(enter: 0.52, center: CGPoint(x: x + 26, y: soil - 45), r: 12.5, aspect: 1.3, attach: 0.56, seed: 13, twigs: 1),
          Clump(enter: 0.70, center: CGPoint(x: x - 12, y: soil - 56), r: 9, aspect: 1.2, attach: 0.80, seed: 14),
        ])
    case .chokkan:
      // Formal upright: dead-straight taper, pagoda tiers alternating and shrinking upward.
      // EXTENTS p=1: widest tier (45,86) r10.5 asp1.85 → reach ≈23.8 → x≥21 ✓. Apex top ≈21 ✓.
      return Design(
        spine: [CGPoint(x: x, y: soil + 2), CGPoint(x: x, y: soil - 20),
                CGPoint(x: x, y: soil - 44), CGPoint(x: x, y: soil - 70)],
        trunkWidth: 10,
        clumps: [
          Clump(enter: 0.0, center: CGPoint(x: x, y: soil - 74), r: 12, aspect: 1.5, attach: 1.0, seed: 21, twigs: 2),
          Clump(enter: 0.34, center: CGPoint(x: x - 19, y: soil - 22), r: 10.5, aspect: 1.85, attach: 0.28, seed: 22),
          Clump(enter: 0.42, center: CGPoint(x: x + 20, y: soil - 20), r: 9.5, aspect: 1.75, attach: 0.30, seed: 23),
          Clump(enter: 0.56, center: CGPoint(x: x - 14, y: soil - 44), r: 8.5, aspect: 1.7, attach: 0.58, seed: 24),
          Clump(enter: 0.70, center: CGPoint(x: x + 15, y: soil - 46), r: 8, aspect: 1.6, attach: 0.62, seed: 25),
        ])
    case .mikan:
      // Fruiting citrus: a sturdy, gently curved trunk under a broad rounded dome — orchard
      // proportions — with yellow fruit hanging from the clouds' lower edges once mature.
      // EXTENTS p=1: left (44,68) r12 asp1.4 → x ≥ 21.7 ✓; right (86,64) r12.5 → x ≤ 109 ✓;
      // apex (64,52) r15 top ≈ 33 ✓; lowest fruit ≈ y78+3 ✓. All ≥4pt inside.
      return Design(
        spine: [CGPoint(x: x, y: soil + 2), CGPoint(x: x - 5, y: soil - 12),
                CGPoint(x: x + 4, y: soil - 28), CGPoint(x: x - 1, y: soil - 42)],
        trunkWidth: 9.5,
        clumps: [
          Clump(enter: 0.0, center: CGPoint(x: x, y: soil - 56), r: 15, aspect: 1.6, attach: 1.0, seed: 31, twigs: 2, fruits: 3),
          Clump(enter: 0.34, center: CGPoint(x: x - 20, y: soil - 40), r: 12, aspect: 1.4, attach: 0.35, seed: 32, fruits: 2),
          Clump(enter: 0.52, center: CGPoint(x: x + 22, y: soil - 44), r: 12.5, aspect: 1.4, attach: 0.60, seed: 33, twigs: 1, fruits: 2),
        ])
    case .murasaki:
      // Purple-leaf (ornamental plum / maple mood): a slender trunk drifting LEFT — mirroring
      // moyogi so the pair reads distinct — under a full three-value purple canopy.
      // EXTENTS p=1: apex (58,42) r15.5 → top ≈ 22.7, left ≈ 27 ✓; right (86,66) r13 → x ≤ 110 ✓;
      // left-mid (40,70) r12 → x ≥ 18.8 ✓. All ≥4pt inside.
      return Design(
        spine: [CGPoint(x: x, y: soil + 2), CGPoint(x: x + 6, y: soil - 12),
                CGPoint(x: x - 6, y: soil - 30), CGPoint(x: x + 2, y: soil - 46),
                CGPoint(x: x - 8, y: soil - 60)],
        trunkWidth: 8.5,
        clumps: [
          Clump(enter: 0.0, center: CGPoint(x: x - 6, y: soil - 66), r: 15.5, aspect: 1.55, attach: 1.0, seed: 41, twigs: 2),
          Clump(enter: 0.34, center: CGPoint(x: x + 22, y: soil - 42), r: 13, aspect: 1.35, attach: 0.32, seed: 42, twigs: 1),
          Clump(enter: 0.52, center: CGPoint(x: x - 24, y: soil - 38), r: 12, aspect: 1.3, attach: 0.58, seed: 43),
          Clump(enter: 0.70, center: CGPoint(x: x + 10, y: soil - 56), r: 8.5, aspect: 1.2, attach: 0.82, seed: 44),
        ],
        purpleFoliage: true)
    }
  }

  private func drawTree(in context: inout GraphicsContext, base: CGPoint, soil: CGFloat, p: Double, alpha: Double) {
    let d = design(base: base, soil: soil)
    let anchor = CGPoint(x: base.x, y: soil)
    let growF = lerp(0.42, 1, p)                      // young trees are small versions of the design
    let scaled = { (pt: CGPoint) -> CGPoint in
      CGPoint(x: anchor.x + (pt.x - anchor.x) * growF, y: anchor.y + (pt.y - anchor.y) * growF)
    }

    // Trunk: sampled smooth spine, rendered as a filled taper with a nebari flare at the base.
    let samples = catmullRom(d.spine.map(scaled), samples: 28)
    let w0 = d.trunkWidth * lerp(0.45, 1, p)
    let (trunkPath, leftEdge) = taperedSpine(samples, startWidth: w0, endWidth: max(1.2, w0 * 0.16), nebari: true)
    context.fill(trunkPath, with: .color(barkBase.opacity(alpha)))

    // Branch wood BEFORE canopy, so clouds sit on their branches.
    for clump in d.clumps where clump.attach >= 0 && clump.attach < 0.95 {
      let g = smoothstep(clump.enter, clump.enter + 0.07, p)
      guard g > 0.001 else { continue }
      let from = samples[min(samples.count - 1, Int(CGFloat(samples.count - 1) * clump.attach))]
      let center = scaled(clump.center)
      let end = CGPoint(x: center.x + (from.x - center.x) * 0.3, y: center.y + (from.y - center.y) * 0.3)
      let mid = CGPoint(x: (from.x + end.x) / 2, y: (from.y + end.y) / 2 + 3)   // cultivated dip
      let bSamples = catmullRom([from, mid, end], samples: 10)
      let bw = 3.4 * lerp(0.5, 1, p) * CGFloat(g)
      let (bPath, _) = taperedSpine(bSamples, startWidth: bw, endWidth: max(0.8, bw * 0.3), nebari: false)
      context.fill(bPath, with: .color(barkBase.opacity(alpha * g)))
    }

    // Bare windward stubs (no foliage).
    for stub in d.bareTwigs {
      let g = smoothstep(0.45, 0.55, p)
      guard g > 0.001 else { continue }
      let from = samples[min(samples.count - 1, Int(CGFloat(samples.count - 1) * stub.t))]
      let end = scaled(stub.end)
      let mid = CGPoint(x: (from.x + end.x) / 2, y: (from.y + end.y) / 2 + 2)
      let (path, _) = taperedSpine(catmullRom([from, mid, end], samples: 8),
                                   startWidth: stub.width, endWidth: 0.8, nebari: false)
      context.fill(path, with: .color(barkBase.opacity(alpha * g)))
    }

    // Bark ridge highlight along one flank gives the trunk its form (skip the nebari zone).
    if leftEdge.count > 8 {
      var ridge = Path()
      let slice = leftEdge[3..<Int(Double(leftEdge.count) * 0.78)]
      ridge.move(to: slice.first!)
      for pt in slice.dropFirst() { ridge.addLine(to: pt) }
      context.stroke(ridge, with: .color(barkRidge.opacity(0.5 * alpha)),
                     style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
    }

    // Canopy: clouds last, each a lobed three-value clump; then bare twig tips peeking past,
    // then fruit hanging from the lower silhouette (mature trees only).
    let foliage: (shadow: Color, base: Color, light: Color) = d.purpleFoliage
      ? (purpleShadow, purpleBase, purpleLight)
      : (greenShadow, greenBase, greenLight)
    for clump in d.clumps {
      let g = smoothstep(clump.enter, clump.enter + 0.07, p)
      guard g > 0.001 else { continue }
      let center = scaled(clump.center)
      let r = clump.r * lerp(0.5, 1, p) * CGFloat(0.6 + 0.4 * g)
      drawClump(in: &context, center: center, r: r, aspect: clump.aspect,
                seed: clump.seed, alpha: alpha * g, colors: foliage)
      if clump.twigs > 0 && p > 0.5 {
        drawPeekTwigs(in: &context, center: center, r: r, aspect: clump.aspect,
                      count: clump.twigs, seed: clump.seed &+ 99, alpha: alpha * g)
      }
      if clump.fruits > 0 {
        drawFruits(in: &context, center: center, r: r, aspect: clump.aspect,
                   count: clump.fruits, seed: clump.seed &+ 7, p: p, alpha: alpha)
      }
    }
  }

  // MARK: Canopy clumps

  /// One foliage cloud: a fixed central lobe plus seeded satellite lobes, drawn in three value
  /// layers (shadow underside offset down-right → mid body → sunlit upper-left lobes). The lobed
  /// silhouette is what kills the "flat ellipse blob" look.
  /// Reach bound (used by every style's extent check): lobe distance ≤0.9·rx and lobe radius
  /// ≤0.6·r, so max horizontal reach ≈ rx·0.9 + 0.6r (+~3 for the shadow offset).
  private func drawClump(in context: inout GraphicsContext, center: CGPoint, r: CGFloat,
                         aspect: CGFloat, seed: UInt64, alpha: Double,
                         colors: (shadow: Color, base: Color, light: Color)) {
    var rng = SeededRandom(seed: seed)
    let rx = r * aspect
    let ry = r * 0.72
    var lobes: [(c: CGPoint, r: CGFloat)] = [(center, r * 0.62)]
    let count = max(6, Int(r) / 2 + 5)
    for i in 0..<count {
      let angle = (Double(i) + rng.next() * 0.7) / Double(count) * 2 * .pi
      let dist = 0.35 + 0.55 * rng.next()
      let c = CGPoint(x: center.x + CGFloat(cos(angle)) * rx * CGFloat(dist),
                      y: center.y + CGFloat(sin(angle)) * ry * CGFloat(dist))
      lobes.append((c, r * (0.32 + 0.28 * CGFloat(rng.next()))))
    }

    for lobe in lobes {   // shadow underside
      let lr = lobe.r * 1.08
      context.fill(Path(ellipseIn: CGRect(x: lobe.c.x - lr + 1.5, y: lobe.c.y - lr * 0.8 + 2.5,
                                          width: lr * 2, height: lr * 1.6)),
                   with: .color(colors.shadow.opacity(0.6 * alpha)))
    }
    for lobe in lobes {   // mid body
      context.fill(Path(ellipseIn: CGRect(x: lobe.c.x - lobe.r, y: lobe.c.y - lobe.r * 0.8,
                                          width: lobe.r * 2, height: lobe.r * 1.6)),
                   with: .color(colors.base.opacity(0.95 * alpha)))
    }
    for lobe in lobes where lobe.c.y <= center.y && lobe.c.x <= center.x + rx * 0.3 {   // sunlit top
      let lr = lobe.r * 0.62
      context.fill(Path(ellipseIn: CGRect(x: lobe.c.x - lr - 1.5, y: lobe.c.y - lr * 0.8 - 2,
                                          width: lr * 2, height: lr * 1.6)),
                   with: .color(colors.light.opacity(0.75 * alpha)))
    }
  }

  /// Yellow fruit hanging along a cloud's lower silhouette. Fruit is the maturity reward: each
  /// piece ripens in (fades + swells) on its own late threshold, staggered per fruit.
  private func drawFruits(in context: inout GraphicsContext, center: CGPoint, r: CGFloat,
                          aspect: CGFloat, count: Int, seed: UInt64, p: Double, alpha: Double) {
    var rng = SeededRandom(seed: seed)
    let rx = r * aspect
    let ry = r * 0.72
    for i in 0..<count {
      let enter = 0.58 + Double(i) * 0.08 + rng.next() * 0.04
      let angle = Double.pi * (0.15 + 0.7 * rng.next())          // lower arc (y grows downward)
      let fr = (2.3 + CGFloat(rng.next()) * 0.7)
      let g = smoothstep(enter, enter + 0.06, p)
      guard g > 0.001 else { continue }
      let c = CGPoint(x: center.x + CGFloat(cos(angle)) * rx * 0.78,
                      y: center.y + CGFloat(sin(angle)) * ry * 0.95 + 1.5)
      let radius = fr * CGFloat(0.5 + 0.5 * g)
      context.fill(Path(ellipseIn: CGRect(x: c.x - radius, y: c.y - radius,
                                          width: radius * 2, height: radius * 2)),
                   with: .color(fruitBase.opacity(alpha * g)))
      let hl = radius * 0.42
      context.fill(Path(ellipseIn: CGRect(x: c.x - hl - radius * 0.25, y: c.y - hl - radius * 0.3,
                                          width: hl * 2, height: hl * 2)),
                   with: .color(fruitLight.opacity(0.8 * alpha * g)))
    }
  }

  /// Bare twig tips poking a few points past the canopy silhouette — the aged-tree signal.
  private func drawPeekTwigs(in context: inout GraphicsContext, center: CGPoint, r: CGFloat,
                             aspect: CGFloat, count: Int, seed: UInt64, alpha: Double) {
    var rng = SeededRandom(seed: seed)
    let rx = r * aspect
    for i in 0..<count {
      let angle = (-100.0 + Double(i) * 55 + rng.next() * 20) * .pi / 180
      let reach = rx * 0.95 + 4 + CGFloat(rng.next()) * 3
      let end = CGPoint(x: center.x + CGFloat(cos(angle)) * reach,
                        y: center.y + CGFloat(sin(angle)) * reach * 0.72)
      var twig = Path()
      twig.move(to: CGPoint(x: center.x + (end.x - center.x) * 0.4,
                            y: center.y + (end.y - center.y) * 0.4))
      twig.addLine(to: end)
      context.stroke(twig, with: .color(barkBase.opacity(0.8 * alpha)),
                     style: StrokeStyle(lineWidth: 1, lineCap: .round))
    }
  }

  // MARK: Geometry helpers

  /// A filled taper along a sampled polyline spine: offsets each sample by half the local width
  /// along the normal and joins the two edges. `nebari` boosts the width near t=0 into a root
  /// flare (~2.1× at the very base). Returns the path plus the left-edge samples for the ridge.
  private func taperedSpine(_ samples: [CGPoint], startWidth: CGFloat, endWidth: CGFloat,
                            nebari: Bool) -> (path: Path, leftEdge: [CGPoint]) {
    guard samples.count >= 2 else { return (Path(), []) }
    var left: [CGPoint] = []
    var right: [CGPoint] = []
    for i in 0..<samples.count {
      let t = CGFloat(i) / CGFloat(samples.count - 1)
      let point = samples[i]
      let reference = i == 0 ? samples[1] : samples[i - 1]
      let tangent = i == 0 ? CGPoint(x: reference.x - point.x, y: reference.y - point.y)
                           : CGPoint(x: point.x - reference.x, y: point.y - reference.y)
      let len = max(0.0001, hypot(tangent.x, tangent.y))
      let normal = CGPoint(x: -tangent.y / len, y: tangent.x / len)
      var halfWidth = (startWidth + (endWidth - startWidth) * t) / 2
      if nebari && t < 0.12 { halfWidth *= 1 + 1.1 * (1 - t / 0.12) }
      left.append(CGPoint(x: point.x + normal.x * halfWidth, y: point.y + normal.y * halfWidth))
      right.append(CGPoint(x: point.x - normal.x * halfWidth, y: point.y - normal.y * halfWidth))
    }
    var path = Path()
    path.move(to: left[0])
    for pt in left.dropFirst() { path.addLine(to: pt) }
    for pt in right.reversed() { path.addLine(to: pt) }
    path.closeSubpath()
    return (path, left)
  }

  /// Centripetal-ish Catmull-Rom through the control points — the smooth trunk movement.
  private func catmullRom(_ points: [CGPoint], samples: Int) -> [CGPoint] {
    guard points.count >= 3 else { return points }
    let padded = [points[0]] + points + [points[points.count - 1]]
    var out: [CGPoint] = []
    let segments = points.count - 1
    let perSegment = max(2, samples / segments)
    for i in 0..<segments {
      let p0 = padded[i], p1 = padded[i + 1], p2 = padded[i + 2], p3 = padded[i + 3]
      for j in 0..<perSegment {
        let t = CGFloat(j) / CGFloat(perSegment)
        let t2 = t * t, t3 = t2 * t
        out.append(CGPoint(
          x: 0.5 * (2 * p1.x + (-p0.x + p2.x) * t + (2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x) * t2
                    + (-p0.x + 3 * p1.x - 3 * p2.x + p3.x) * t3),
          y: 0.5 * (2 * p1.y + (-p0.y + p2.y) * t + (2 * p0.y - 5 * p1.y + 4 * p2.y - p3.y) * t2
                    + (-p0.y + 3 * p1.y - 3 * p2.y + p3.y) * t3)))
      }
    }
    out.append(points[points.count - 1])
    return out
  }

  private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat {
    a + (b - a) * CGFloat(max(0, min(1, t)))
  }

  /// Hermite smoothstep — 0 below `edge0`, 1 above `edge1`, eased between.
  private func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
    guard edge1 > edge0 else { return x < edge0 ? 0 : 1 }
    let t = max(0, min(1, (x - edge0) / (edge1 - edge0)))
    return t * t * (3 - 2 * t)
  }

  /// HSB shading of a theme token (sat/bri multipliers, clamped) — how bark and the three foliage
  /// values are derived from the flavor's tint slots without any literal color.
  private func shade(_ color: NSColor, sat: CGFloat, bri: CGFloat) -> NSColor {
    let c = color.usingColorSpace(.sRGB) ?? color
    var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
    return NSColor(hue: h, saturation: min(1, s * sat), brightness: min(1, b * bri), alpha: a)
  }
}

/// SplitMix64 — tiny deterministic PRNG. Hard-coded per-clump seeds give each cloud a stable,
/// organic lobe arrangement that never changes between frames or launches.
private struct SeededRandom {
  private var state: UInt64
  init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
  mutating func next() -> Double {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    z ^= z >> 31
    return Double(z >> 11) * (1.0 / 9_007_199_254_740_992.0)
  }
}
