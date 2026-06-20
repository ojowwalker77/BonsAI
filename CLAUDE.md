# Composer implementation guardrails

## CRITICAL: preserve the board + dock composition

**BE SUPER AWARE: DO NOT CHANGE THESE LINES OR FUCK UP THIS COMPOSITION BY “CLEANING UP” THE LAYOUT.**

The Agent and Settings are deliberately separate AppKit panels, coordinated with the board window.
They must not be folded into `ComposerCanvas`, rendered as an overlay, or made into an `HStack`
sidebar.

- `PanelController.positionWorkspace()` owns the two-window geometry.
- The dock's `y: y` and `height: workspaceHeight - cardTopInset` are intentional: they align the
  dock with the visible board card, which starts below the toolbar, while keeping their bottoms
  perfectly level.
- `Theme.Size.railGutter(in:) == 9%` is intentional breathing room. The left rail must not crowd
  or overlap the canvas card.
- The top toolbar centers on `WorkspaceLayout.toolbarCenterX` from `PanelController`, which is the
  full board-plus-Agent/Settings composition. Do not center it only within the reduced board card.
- Keep dock width, gap, rail gutter, and toolbar gutter screen-relative. No fixed width/minimum
  should be introduced in this outer layout.

If this area is edited, run `./script/build_and_run.sh --verify` and visually open both Settings
and Agent. Confirm: separate windows, a shrunken board, aligned top/bottom edges, and a generous
rail-to-canvas gap.
