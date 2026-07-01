# BonsAI implementation guardrails

## Architecture: one standard window, floating chrome

BonsAI is a single standard macOS window (`FloatingPanel`, titled/resizable/full-size content)
whose canvas fills it edge to edge. ALL chrome floats over the canvas as Liquid Glass pills:

- Top-left: `+` pill and the hover board picker (after the repositioned traffic lights).
- Top-right: AI actions (Describe Board · Copy Board · agent toggle).
- Bottom-center: ONE command bar — zoom · the eight tools · grounding folder · Settings.
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
- **Light mode never uses black.** All light-mode ink derives from `Theme.lightInk` (#575757).
  Never hard-code `Color.white`/`Color.black` in views — use the adaptive `Theme.Palette` tokens
  (chromeGlyph, hoverWash, elementStroke, …). Every hard-coded literal has broken one theme.
- **The canvas is solid** (`Theme.Palette.windowCanvas`: black dark / paper white light) and the
  window backing (`Theme.nsWindowCanvas`) must stay in sync with it.
- **Glass is `floatingGlass` / `composerPopupSurface` / `dockPanelSurface`** — one recipe. No
  custom frosts, no white-fill "frosted" variants (tried, rejected as generic gray).
- Theming is `ComposerTheme` (System/Light/Dark) applied as the window's `NSAppearance`;
  `composerThemeChanged` re-applies it live.

If this area is edited, run `./script/build_and_run.sh --verify` and visually confirm: solid
canvas, one bottom command bar, aligned top pills on the traffic-light centerline, and both
themes clean (no black ink in light mode).
