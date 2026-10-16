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
/// hands `onScroll` each one delivered to this view's window, once, while the pointer is over this
/// view. `onScroll` returns true to consume the event. The monitor is removed when the view goes
/// away.
///
/// Two users: the ruler (`RulerTimerPicker`) turns sideways trackpad scrolls into minutes, and the
/// timer tab (`HorizontalSwipeMonitor`) turns a two-finger swipe into a side-column page change.
///
/// Both are local monitors, and AppKit runs local monitors in no promised order, so when the two
/// views overlap (the ruler sits on the tab) the one that runs first and consumes decides. The ruler
/// wins by geometry: its monitor `ownsSidewaysScroll`, which registers its view in
/// `sidewaysScrollOwners` for as long as the monitor is installed, and the tab's monitor
/// `yieldsToOwners`, which hands back every event whose pointer is inside an owner's view in the
/// same window. The frame is read live, off the owner's `NSView`, at the moment the event arrives:
/// no hover callback, `@State` or re-render has to have happened first, so the first sideways
/// scroll over a ruler that appeared under a still pointer sets minutes rather than turning the page.
struct ScrollWheelMonitor: NSViewRepresentable {
    /// This view's sideways scroll is its own: monitors that `yieldsToOwners` stand aside over it.
    var ownsSidewaysScroll = false
    /// Hand back any event whose pointer is over an owner's view in this window.
    var yieldsToOwners = false
    let onScroll: (NSEvent) -> Bool

    /// The views whose sideways scroll is their own (the ruler), while their monitor is installed.
    /// Weak, so a view that goes away without `dismantleNSView` is forgotten rather than kept.
    @MainActor static let sidewaysScrollOwners = NSHashTable<NSView>.weakObjects()

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
        Coordinator(ownsSidewaysScroll: ownsSidewaysScroll, yieldsToOwners: yieldsToOwners, onScroll: onScroll)
    }

    @MainActor
    final class Coordinator: NSObject {
        var onScroll: (NSEvent) -> Bool
        private let ownsSidewaysScroll: Bool
        private let yieldsToOwners: Bool
        private var monitor: Any?
        private weak var observedView: NSView?
        private var lastEventTimestamp: TimeInterval = 0

        init(ownsSidewaysScroll: Bool, yieldsToOwners: Bool, onScroll: @escaping (NSEvent) -> Bool) {
            self.ownsSidewaysScroll = ownsSidewaysScroll
            self.yieldsToOwners = yieldsToOwners
            self.onScroll = onScroll
        }

        func installMonitor(on view: NSView) {
            removeMonitor()
            observedView = view
            if ownsSidewaysScroll { ScrollWheelMonitor.sidewaysScrollOwners.add(view) }
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
            if let observedView { ScrollWheelMonitor.sidewaysScrollOwners.remove(observedView) }
            observedView = nil
            lastEventTimestamp = 0
        }

        private func shouldOffer(_ event: NSEvent, view: NSView) -> Bool {
            // Only scrolls delivered to this view's window: a popover over the tab (Tasks,
            // clipboard) is a window of its own, and its scrolls are not this view's to take.
            if let eventWindow = event.window, eventWindow !== view.window { return false }
            guard lastEventTimestamp != event.timestamp else { return false }
            lastEventTimestamp = event.timestamp
            guard let window = view.window else { return false }
            let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
            guard Self.isPoint(windowPoint, over: view) else { return false }
            // By geometry, before anything is offered: over an owner (the ruler) the event is the
            // owner's, whichever monitor AppKit happens to run first.
            if yieldsToOwners && Self.isPoint(windowPoint, overAnOwnerIn: window) { return false }
            return true
        }

        /// Whether `windowPoint` (window coordinates) falls inside `view`.
        static func isPoint(_ windowPoint: NSPoint, over view: NSView) -> Bool {
            guard view.window != nil, !view.isHiddenOrHasHiddenAncestor else { return false }
            return view.bounds.contains(view.convert(windowPoint, from: nil))
        }

        /// Whether `windowPoint` falls inside a registered owner's view that lives in `window`.
        static func isPoint(_ windowPoint: NSPoint, overAnOwnerIn window: NSWindow) -> Bool {
            ScrollWheelMonitor.sidewaysScrollOwners.allObjects.contains { owner in
                owner.window === window && isPoint(windowPoint, over: owner)
            }
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
/// `NotchTimerView` puts it behind the whole tab (composer, divider and column), so a swipe works
/// anywhere on the tab, not only over the column.
///
/// It follows one gesture from `.began` to `.ended` (`TimerSideSwipe`) and ignores momentum, so a
/// flick changes the page once and its coasting changes nothing. It consumes only sideways
/// (horizontal-dominant) events: a vertical scroll still reaches the list, or the notch, under it.
/// A plain mouse wheel has no gesture phase and is left alone.
///
/// A local monitor never sees events taken by a nested event-tracking loop, so a view on the tab
/// that follows a trackpad gesture in a loop of its own (a SwiftUI `List`'s table view) keeps the
/// swipe from it. The side column's pages are `ScrollView`s for that reason (`TimerSideColumn`).
///
/// Over the ruler, whose own sideways scroll sets the minutes, it hands every event back untouched.
/// That is decided by geometry: its `ScrollWheelMonitor` `yieldsToOwners`, so an event whose pointer
/// is inside the ruler's view is never offered here (`ScrollWheelMonitor.sidewaysScrollOwners`).
/// `isSuspended` (the ruler's hover, as `NotchTimerView` tracks it) is a second guard on top, not
/// the first: it reaches this view through `@State` and a re-render, which a scroll can beat.
struct HorizontalSwipeMonitor: View {
    let current: TimerSidePage
    var isSuspended = false
    let onSwipe: (TimerSidePage) -> Void

    /// The gesture so far. A class, so counting deltas does not redraw the tab on every event.
    @State private var tracker = Tracker()

    var body: some View {
        ScrollWheelMonitor(yieldsToOwners: true) { event in
            guard !isSuspended else { return false }
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
