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

import SwiftUI

/// The notch header's Tasks button, the last of the trailing row's items that come and go, directly
/// left of the clipboard button (the order is pinned by `HeaderOrderRulesTests`): it opens
/// `TasksPopover`, and carries a yellow dot while a Time to log entry waits for an answer — yellow
/// is Kannu's "needs your input".
///
/// `KannuHeader` shows it only with the notch open and the minimalistic UI off, and then as
/// `TasksHeaderVisibility` says: with tasks on, on the timer tab, or on every tab when there is no
/// timer tab. It is a view of its own so `TasksManager` is created only then: with tasks off,
/// nothing here runs and the task file is never read.
///
/// While the popover is open it sets `vm.isTasksPopoverActive`, which
/// `ContentView.hasAnyActivePopovers()` reads, so the notch does not close under it. Leaving the
/// view clears it too (the notch closing, a switch away from the timer tab, tasks or the
/// minimalistic UI switched): a popover that vanishes with its button never reports closing, and a
/// flag left set would hold the notch open.
///
/// Its tooltip is `.hoverTooltip`; `.help` never renders in the notch (docs/REGRESSIONS.md entry 9).
struct TasksHeaderButton: View {
    @EnvironmentObject private var vm: KannuViewModel
    @ObservedObject private var manager = TasksManager.shared
    @State private var showsPopover = false

    var body: some View {
        let waiting = WorklogDrafts.waitingCount(manager.drafts)
        Button(action: {
            withAnimation(.smooth) {
                showsPopover.toggle()
            }
        }) {
            Capsule()
                .fill(.black)
                .frame(width: 30, height: 30)
                .overlay {
                    Image(systemName: "checklist")
                        .foregroundColor(.white)
                        .padding()
                        .imageScale(.medium)
                }
                .overlay(alignment: .topTrailing) {
                    if waiting > 0 {
                        Circle()
                            .fill(Color.yellow)
                            .frame(width: 7, height: 7)
                            .padding(5)
                            .accessibilityHidden(true)
                    }
                }
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel(Self.accessibilityLabel(waiting: waiting))
        .hoverTooltip(String(localized: "Tasks"), edge: .below)
        .popover(isPresented: $showsPopover, arrowEdge: .bottom) {
            TasksPopover(close: { showsPopover = false })
        }
        .onChange(of: showsPopover) { _, isActive in
            vm.isTasksPopoverActive = isActive
            if !isActive {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    vm.shouldRecheckHover.toggle()
                }
            }
        }
        .onDisappear {
            showsPopover = false
            vm.isTasksPopoverActive = false
        }
    }

    /// "Tasks", or "Tasks, 2 entries waiting to be logged": the dot, for VoiceOver.
    static func accessibilityLabel(waiting: Int) -> String {
        switch waiting {
        case ..<1:
            return String(localized: "Tasks")
        case 1:
            return String(localized: "Tasks, 1 entry waiting to be logged")
        default:
            return String(localized: "Tasks, \(waiting) entries waiting to be logged")
        }
    }
}
