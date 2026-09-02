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

## Checklist for a new tooltip

1. Use `.hoverTooltip(...)`, never `.help(...)`.
2. Keep the text to one short line.
3. Choose `edge` from where the control sits in its container.
4. If it needs a cursor change, pass `pointingHandCursor: true` — do not add `.onHover`.
5. Hover it in a real build. None of this is unit-testable; the pre-commit guards only catch the
   mechanical mistakes.
