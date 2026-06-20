# Composer agent notes

## CRITICAL: board + dock geometry — do not casually change

**BE SUPER AWARE: DO NOT CHANGE THESE LINES OR FUCK UP THIS COMPOSITION BY “CLEANING UP” THE LAYOUT.**

The board and the Agent/Settings dock are deliberately two real `NSPanel` windows. This is not a
sidebar and must never become an overlay or an `HStack` child of `ComposerCanvas` again.

- `PanelController.positionWorkspace()` gives the board its remaining screen-relative width, then
  positions the dock beside it using the screen-relative `dockWidth` and `dockMargin`.
- The dock must keep `y: y` and `height: workspaceHeight - cardTopInset`. This makes its top and
  bottom exactly align with the visible canvas card (below the floating toolbar), not the invisible
  outer workspace frame.
- `Theme.Size.railGutter(in:)` intentionally uses `0.090`: it includes real breathing room between
  the left rail and the canvas card. Do not reduce it without comparing the composed UI on screen.
- The top toolbar must use `WorkspaceLayout.toolbarCenterX`, supplied by
  `PanelController.positionWorkspace()`. It is the center of the complete board-plus-Agent/Settings
  composition; never recenter it only within the reduced board card or board window.
- All primary workspace measurements are fractions of the current visible screen. Do not replace
  them with point constants, hard minimums, or intrinsic-size-driven stack layout.

Before changing any of this, launch the app and visually verify both Settings and Agent open beside
the shrunken board, share the card's top/bottom edges, and leave clear space between the rail and
canvas.
