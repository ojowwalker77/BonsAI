# BonsAI implementation guardrails

## Architecture: one standard window, floating chrome

BonsAI is a single standard macOS window (`FloatingPanel`, titled/resizable/full-size content)
whose canvas fills it edge to edge. ALL chrome floats over the canvas as Liquid Glass pills:

- Top-left: `+` pill and the hover board picker (after the repositioned traffic lights).
- Top-right: AI actions (Describe Board · Copy Board · agent toggle).
- Bottom-center: ONE command bar — zoom · the nine tools (select, text, shapes, lines, freehand,
  equation) · Settings. (Grounding lives in the agent chat and the ⌘K palette, not the bar.)
- Agent and Settings are SwiftUI glass overlays inside the canvas (`dockOverlay`), NOT separate
  windows. There are no auxiliary panels.

The old floating-panel mode (chromeless glass panel + sibling dock windows) was removed
deliberately in July 2026. Do not reintroduce it.

## CRITICAL: the design system

- **`WindowChrome` (Theme.swift) is law** for floating controls: controlHeight 34, padH 6, padV 5,
  radius 14, edgeInset 16, trafficLightInset 82, iconFont (17 medium), labelFont (13 medium),
  labelPadH 10, itemSpacing 4. No inline sizes, paddings, fonts, or corner radii in chrome views.
- **Every pill/bar is built with `.chromePill()`** (the one wrapper: padding + glass) around
  `SidebarButton` / `SidebarAgentButton` / `CanvasToolbar` controls. Never hand-assemble a pill
  with raw `.padding(...)` + `.composerPopupSurface()` — that is how sizes drifted apart before.
- **Traffic lights are repositioned** onto the control row's centerline
  (`FloatingPanel.layoutWindowChromeButtons`), re-applied by `PanelController` on
  resize/move/key-state changes. Don't remove those delegate hooks — AppKit resets the buttons.
- **Colors are ThemeFlavors** (`Support/ThemeFlavor.swift`): four named themes — Bonsai Dark,
  Bonsai Light, Catppuccin Mocha, Catppuccin Latte (palette data in `Support/Catppuccin.swift`).
  Every `Theme.Palette` token maps a semantic role onto the active flavor's slots (text/subtext/
  overlay/surface/base); views consume ONLY tokens. Never hard-code a hex or
  `Color.white`/`Color.black` in a view — every literal has broken one theme. The accent is
  `Theme.Palette.accent`, never `Color.accentColor`. Theme switching REBUILDS the canvas
  (PanelController.applyTheme) because tokens are plain flavor lookups; the agent is a singleton
  (`CanvasAgent.shared`) so its conversation survives. Settings shows flavor-painted preview
  cards (`ThemePreviewCard`) — new themes are a `ThemeFlavor` + enum case, nothing else.
- **The canvas is solid by default** (`windowCanvas` = the flavor's `base`) painted over a
  behind-window blur; the Settings ▸ Appearance ▸ Canvas slider (`canvasTransparencyKey`,
  default 0) recedes it toward desktop glass. The window itself is non-opaque with a clear
  backing so the blur can sample — don't flip it back to opaque.
- **Glass is `floatingGlass` / `composerPopupSurface` / `dockPanelSurface`** — one recipe. No
  custom frosts, no white-fill "frosted" variants (tried, rejected as generic gray).
- Theming is `ComposerTheme` (System/Light/Dark) applied as the window's `NSAppearance`;
  `composerThemeChanged` re-applies it live.

If this area is edited, run `./script/build_and_run.sh --verify` and visually confirm: solid
canvas, one bottom command bar, aligned top pills on the traffic-light centerline, and both
themes clean (no black ink in light mode).
