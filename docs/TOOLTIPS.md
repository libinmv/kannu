# Tooltips in the notch

**`.help(...)` does not work anywhere in the notch. Use `.hoverTooltip(...)`.**

## Why the native one cannot work

SwiftUI's `.help(...)` compiles to `NSView.toolTip`, and AppKit's `NSToolTipManager` only displays
tooltips for the **active** application. Kannu is `LSUIElement = true` with
`NSApp.setActivationPolicy(.accessory)` (`KannuApp.swift`), and the notch is a
`[.borderless, .nonactivatingPanel]` `NSPanel` shown with `orderFrontRegardless()`. It is never
frontmost, by design — that is the whole point of an ambient status display.

Measured while hovering the notch:

```
frontmost application : Claude   (never Kannu)
tooltip log events    : 0
mouseMoved events     : 0
```

`acceptsMouseMovedEvents = true` does not help: the blocker is app **activation**, not mouse
tracking. That was tried and reverted.

Eight `.help(...)` call sites shipped in notch views and none had ever rendered.

## What to use instead

`HoverTooltip.swift` draws the bubble itself, triggered by `.onHover` — which *does* fire in the
notch (hover-reveal already depends on it).

```swift
Button { … } label: { Image(systemName: "arrow.clockwise") }
    .buttonStyle(.plain)
    .hoverTooltip("Reload usage", edge: .below, pointingHandCursor: true)
```

## Three rules, each learned from a shipped bug

### 1. `.fixedSize()` on both axes is load-bearing
The bubble is an `.overlay`, so its proposed width comes from the **parent** — usually a ~14pt icon
button. Relaxing the horizontal axis makes it adopt that width and render invisibly:

```swift
.fixedSize()                                    // correct
.fixedSize(horizontal: false, vertical: true)   // breaks EVERY tooltip in the app
```

Long labels are handled by **shortening the text**, not by wrapping. One line, ~50 characters.
Guarded by `.githooks/pre-commit`.

### 2. `edge` must match the container, because overlays get clipped
A `ScrollView` (or any `.clipped()`) swallows whatever falls outside its content bounds.
`caffeinateRow` is the first child of a `ScrollView`, so a bubble opening upward landed in the
clipped region and was never visible.

- control near the **top** of its container → `edge: .below`
- control near the **bottom** → `edge: .above` (the default)

Pick by layout, not by aesthetics.

### 3. One hover source per control
Two `.onHover` handlers on the same control fight, and the tooltip loses. If a control needs the
pointing-hand cursor, ask the tooltip for it rather than adding a second handler:

```swift
.hoverTooltip("Keep the Mac awake", edge: .below, pointingHandCursor: true)   // correct
.hoverTooltip("…").onHover { … NSCursor.pointingHand.set() … }                // tooltip stops showing
```

## Every icon-only control has a tooltip

A glyph alone does not say what it does. Every notch control whose label is only an icon shows a
tooltip after the pointer rests on it, and that tooltip text is also its accessibility label —
otherwise VoiceOver reads the SF Symbol name (`quote.bubble`) instead of the action (`Lyrics`).
This is a design rule, not a per-feature choice: a new icon button ships with its tooltip.

**Wording.** 1–3 words, title case, naming the action: `Lyrics`, `Clear History`, `New Note`,
`Remove Favorite`. When the action flips with state, the text flips too (`Pin Note` /
`Unpin Note`, `Mute` / `Unmute`). Use `String(localized:)`.

**The delay stays at 0.4 s.** Long enough that brushing past a row of icons flashes nothing,
short enough that a deliberate hover is answered.

**Plain `Button`s** get both modifiers, with the same string:

```swift
Button(action: onCreate) { Image(systemName: "plus") }
    .buttonStyle(PlainButtonStyle())
    .hoverTooltip(String(localized: "New Note"), edge: .below)
    .accessibilityLabel(String(localized: "New Note"))
```

**Shared icon buttons take `tooltip:`** — `HoverButton`, `MinimalisticSquircircleButton` (and
`controlButton(...)`), `playbackButton(...)`, `TabButton`, `TimerControlButton`. Each one
already has an `.onHover` for its highlight, so it drives the bubble from that same hover state
(`.iconButtonTooltip(tooltip, edge:, isHovering:)`), which also applies the accessibility label.
Pass `tooltipEdge:` when the button sits near the top of its container.

### One hover source, two placements

A control that already tracks hover for its own highlight must not also get the self-hovering
`.hoverTooltip(_:edge:)` — that is a second handler (rule 3). Use the hover-driven variant:

```swift
.onHover { isHovered = $0 }
.hoverTooltip(tooltip, edge: .below, isHovering: isHovered)
```

The two variants draw the same bubble but place it differently:

- **`.hoverTooltip(_:edge:)` (self-hovering)** puts the bubble a fixed 22 pt from the control's
  anchoring edge. That clears a ~14 pt glyph, and it stays because callers depend on it:
  `clickableSession` wraps a whole session row, and its bubble only stays out of the
  `ScrollView` clip because it renders inside that row.
- **`.hoverTooltip(_:edge:isHovering:)` (hover-driven)** puts the bubble 8 pt clear of the
  control's own edge, whatever its size. The shared buttons are 30–54 pt; a fixed 22 pt would
  sit the bubble on top of the play glyph.

### `alignment:`

Both variants take `alignment: HorizontalAlignment = .trailing`. Trailing grows the bubble
leftwards from the control's trailing edge. A control at the **left** edge of its window — the
clipboard panel's close button, the mute button at the top-left of the output popover — passes
`.leading`, or its bubble runs off the window and is clipped.

### Horizontal `ScrollView`s clip too

A `ScrollView` clips on both axes, so a bubble opening above a swatch row inside a horizontal
`ScrollView` is swallowed. The note-colour rows use `.scrollClipDisabled()` (macOS 14 is the
floor). Note z-order as well: a bubble drawn over an *earlier* sibling shows, one opening onto a
*later* sibling is drawn underneath it.

### The fitted-panel exception

`MusicControlOverlay` (`FloatingMediaButton`) and `TimerControlOverlay` (`ControlButton`) live in
their own panels, which `MusicControlWindowManager` / `TimerControlWindowManager` size to
`fittingSize` — the height of the button row. A bubble above or below the row falls outside the
window and is never seen. Those two take `accessibilityLabel:` instead, and nothing else.

### The guard

`KannuTests/NotchTooltipCoverageRulesTests` scans the eight notch view folders (`Notch`,
`AgentStatus`, `Music`, `Timer`, `Clipboard`, `Tabs`, `Shelf`, `Stats`) with comments stripped
and string contents blanked, and fails when:

- a shared icon button is called without `tooltip:` (or `accessibilityLabel:` for the two
  fitted-panel buttons);
- a `Button` whose label is only an `Image(systemName:)` has no `.hoverTooltip(` in its modifier
  chain — unless its file is on the allowlist, each entry with its reason;
- any `.help(` remains outside a comment or string.

It is a heuristic: a `Button` whose label comes from a helper (`iconView()`) is not classified
as icon-only, so a new shared button must be added to the test's list of shared buttons.

## Checklist for a new tooltip

1. Use `.hoverTooltip(...)`, never `.help(...)`.
2. Keep the text to one short line.
3. Choose `edge` from where the control sits in its container.
4. If it needs a cursor change, pass `pointingHandCursor: true` — do not add `.onHover`.
5. If the control already has an `.onHover`, use `.hoverTooltip(_:edge:isHovering:)` with its
   hover state, not a second handler.
6. Icon-only? Add `.accessibilityLabel` with the same text, or pass `tooltip:` to a shared button.
7. Hover it in a real build. Placement is not unit-testable; the pre-commit guard and
   `NotchTooltipCoverageRulesTests` only catch the mechanical mistakes.
