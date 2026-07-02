# BonsAI roadmap

This roadmap collects user feedback into product-sized work. It is intentionally
ordered by dependency: first keep the current board trustworthy, then widen
capture/import, then add more agent destinations, then sync across Apple
surfaces.

## Near term

### Agent and LLM support

- Keep Claude Code as the full streaming chat-agent path.
- Keep Codex/GPT on the one-shot Refine and Compile path, and expand it only
  where the CLI can run non-interactively.
- Add OpenCode as the next CLI engine for one-shot Refine and Compile.
- Investigate whether OpenCode is enough to cover OpenAI-compatible,
  Anthropic-compatible, OpenRouter, and local endpoints such as `llama.cpp`.
- Add clearer engine status in Settings: installed, enabled, missing, or not
  supported for a given surface.

The important product rule: a new engine can land first for Refine/Compile.
Joining the in-canvas chat agent is a larger adapter because it needs streaming
events, session resume, and canvas tools.

### Canvas drawing polish

- Hold Shift while drawing an ellipse to create a perfect circle.
- Hold Shift while drawing a rectangle to create a square.
- Hold Shift while drawing a diamond to keep it uniform.
- Keep the behavior local to active drawing/resizing so normal freeform sketching
  remains fast.

### Appearance controls

- Add tint/color customization for the app or canvas UI.
- Treat tint as a restrained accent choice, not a full theme system.
- Preserve the separate board, dock, and toolbar window composition.

### Local storage visibility

- Add a visible "where is my data saved?" readout in Settings or About.
- Explain that boards are local and attachments live under
  `~/Library/Application Support/Composer/Attachments`.
- Make cloud sync status explicit: local-only today, sync later.

## Next

### Import and attachments

- Add drag-and-drop images onto the canvas.
- Add drag-and-drop files as references to their original paths.
- Make the difference between a board attachment and an agent grounding folder
  visible in the UI.
- Add screenshot import from local capture sources and iCloud-backed locations.

### Export

- Export board as PNG for sharing.
- Export board as `.canvas` or another portable structured board format.
- Export board as self-contained HTML for archive/review.

Export should keep enough structure for future re-import where possible. PNG is
for presentation; `.canvas` and HTML are for portability.

## Later

### Apple ecosystem integrations

- Apple Notes integration.
- iCloud Drive import/sync for files and screenshots.
- Cloud sync for boards, with explicit conflict handling before it ships.

### macOS compatibility

- Audit Tahoe-only APIs and make them optional where possible.
- Lower the minimum macOS version only if the core board works without degraded
  or misleading behavior.
- Keep Apple Intelligence-dependent features clearly gated when unavailable.

## Technical investigations

### Nuke for image-heavy boards

BonsAI currently has a custom asynchronous thumbnail cache for canvas image
cards in `BoardCardView`. It already does the basics that matter for local
boards: off-main-thread decode, thumbnail downsampling, request coalescing, and
an `NSCache` cost limit.

Nuke is worth considering if image cards become a heavier feature:

- large boards with many screenshots or photos
- remote image URLs
- progressive image loading
- reusable processing pipelines
- memory-pressure tuning beyond the current thumbnail cache

It is probably not worth adding immediately for plain local-file image cards.
The current cache is small, dependency-free, and tailored to canvas thumbnails.
A good adoption point would be the first feature that adds remote image loading,
image grids, or a richer media browser.

### Why the UI does not fully read as native Liquid Glass

The app uses real AppKit vibrancy and, on macOS 26+, SwiftUI `glassEffect` for
some floating controls. It can still read less native than system Liquid Glass
for a few reasons:

- The main canvas card uses a custom `NSVisualEffectView` plus black scrim and
  gradient sheen, which gives BonsAI its own slab look instead of pure system
  glass.
- Several floating surfaces add custom fills, shadows, and clipping around
  glass. That improves legibility, but it also reduces the automatic refraction
  and grouping that make native Liquid Glass feel alive.
- The board, dock, and toolbar are separate `NSPanel` windows. That composition
  is intentional, but it means glass grouping cannot always behave like one
  continuous SwiftUI hierarchy.
- Some controls are bespoke SwiftUI/AppKit controls rather than standard toolbar,
  sidebar, and inspector controls, so they do not inherit every system glass
  behavior automatically.

The roadmap path is to keep the separate-window composition, then reduce custom
scrims where legibility allows, group nearby custom glass controls with shared
glass containers, use interactive glass for tool surfaces, and prefer standard
macOS controls where they do not weaken the board experience.
