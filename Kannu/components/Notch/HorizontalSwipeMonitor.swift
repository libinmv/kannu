/*
 * Kannu (കണ്ണ്)
 * Copyright (C) 2024-2026 Kannu Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

#if canImport(AppKit)
import AppKit
import SwiftUI

// MARK: - Scroll-wheel monitor

/// A local scroll-wheel monitor scoped to the view it backs. `NSView.scrollWheel` is not delivered
/// when SwiftUI layers sit above the representable, so this watches the app's scroll events and
/// hands `onScroll` each one, once, while the pointer is over this view. `onScroll` returns true to
/// consume the event. The monitor is removed when the view goes away.
///
/// Two users: the ruler (`RulerTimerPicker`) turns sideways trackpad scrolls into minutes, and the
/// timer tab's side column (`HorizontalSwipeMonitor`) turns a two-finger swipe into a page change.
struct ScrollWheelMonitor: NSViewRepresentable {
    let onScroll: (NSEvent) -> Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.installMonitor(on: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onScroll = onScroll
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onScroll: onScroll)
    }

    @MainActor
    final class Coordinator: NSObject {
        var onScroll: (NSEvent) -> Bool
        private var monitor: Any?
        private weak var observedView: NSView?
        private var lastEventTimestamp: TimeInterval = 0

        init(onScroll: @escaping (NSEvent) -> Bool) {
            self.onScroll = onScroll
        }

        func installMonitor(on view: NSView) {
            removeMonitor()
            observedView = view
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self, weak view] event in
                guard let self, let view else { return event }
                guard self.shouldOffer(event, view: view) else { return event }
                return self.onScroll(event) ? nil : event
            }
        }

        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            observedView = nil
            lastEventTimestamp = 0
        }

        private func shouldOffer(_ event: NSEvent, view: NSView) -> Bool {
            guard lastEventTimestamp != event.timestamp else { return false }
            lastEventTimestamp = event.timestamp
            return isCursorOverView(view)
        }

        private func isCursorOverView(_ view: NSView) -> Bool {
            guard let window = view.window else { return false }
            let screenPoint = NSEvent.mouseLocation
            let windowPoint = window.convertPoint(fromScreen: screenPoint)
            let localPoint = view.convert(windowPoint, from: nil)
            return view.bounds.contains(localPoint)
        }
    }
}

extension NSEvent {
    /// A trackpad (or momentum) scroll that moves more sideways than vertically: what the ruler has
    /// always taken. A plain mouse wheel has neither phase and never counts.
    var isHorizontalTrackpadScroll: Bool {
        let deltaX = scrollingDeltaX
        let deltaY = scrollingDeltaY
        guard abs(deltaX) > abs(deltaY), abs(deltaX) > 0.15 else { return false }
        return phase != [] || momentumPhase != []
    }
}

// MARK: - Two-finger page swipe

/// Turns a two-finger swipe over the view into a page change for the timer tab's side column.
///
/// It follows one gesture from `.began` to `.ended` (`TimerSideSwipe`) and ignores momentum, so a
/// flick changes the page once and its coasting changes nothing. It consumes only sideways
/// (horizontal-dominant) events: a vertical scroll still reaches the list under it. A plain mouse
/// wheel has no gesture phase and is left alone.
struct HorizontalSwipeMonitor: View {
    let current: TimerSidePage
    let onSwipe: (TimerSidePage) -> Void

    /// The gesture so far. A class, so counting deltas does not redraw the column on every event.
    @State private var tracker = Tracker()

    var body: some View {
        ScrollWheelMonitor { event in
            if event.momentumPhase == [] {
                if let page = tracker.handle(event, current: current) {
                    onSwipe(page)
                }
            }
            return event.isHorizontalTrackpadScroll
        }
    }

    @MainActor
    final class Tracker {
        private var swipe = TimerSideSwipe()

        func handle(_ event: NSEvent, current: TimerSidePage) -> TimerSidePage? {
            let phase = event.phase
            if phase.contains(.began) {
                swipe.reset()
            }
            if phase.contains(.ended) || phase.contains(.cancelled) {
                swipe.reset()
                return nil
            }
            guard phase.contains(.began) || phase.contains(.changed) else { return nil }
            // TimerSideSwipe counts in the natural-scrolling sense (fingers left is negative), so a
            // swipe follows the fingers whichever way the user's scrolling runs.
            let natural = event.isDirectionInvertedFromDevice ? 1.0 : -1.0
            return swipe.add(
                dx: Double(event.scrollingDeltaX) * natural,
                dy: Double(event.scrollingDeltaY),
                current: current
            )
        }
    }
}
#endif
