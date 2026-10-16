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

import Defaults
import SwiftUI

struct KannuHeader: View {
    @EnvironmentObject var vm: KannuViewModel
    @ObservedObject var batteryModel = BatteryStatusViewModel.shared
    @ObservedObject var coordinator = KannuViewCoordinator.shared
    @ObservedObject var clipboardManager = ClipboardManager.shared
    @ObservedObject var shelfState = ShelfStateViewModel.shared
    @ObservedObject var timerManager = TimerManager.shared
    @ObservedObject var doNotDisturbManager = DoNotDisturbManager.shared
    @ObservedObject var llmUsageManager = LLMUsageManager.shared
    @State private var showClipboardPopover = false
    @State private var showColorPickerPopover = false
    @State private var showTimerPopover = false
    @Default(.enableTimerFeature) var enableTimerFeature
    @Default(.timerDisplayMode) var timerDisplayMode
    @Default(.showClipboardIcon) var showClipboardIcon
    @Default(.showColorPickerIcon) var showColorPickerIcon
    @Default(.clipboardDisplayMode) var clipboardDisplayMode
    @Default(.showBatteryIndicator) var showBatteryIndicator
    @Default(.showBatteryPercentInside) var showBatteryPercentInside
    @Default(.showMinimalisticBatteryIndicator) var showMinimalisticBatteryIndicator
    @Default(.enableMinimalisticUI) var enableMinimalisticUI
    @Default(.enableTasks) var enableTasks

    var body: some View {
        HStack(spacing: 0) {
            HStack {
                if !enableMinimalisticUI {
                    let shouldShowTabs = coordinator.alwaysShowTabs || vm.notchState == .open || !shelfState.items.isEmpty
                    if shouldShowTabs {
                        TabSelectionView()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(vm.notchState == .closed ? 0 : 1)
            .blur(radius: vm.notchState == .closed ? 20 : 0)
            .animation(.smooth.delay(0.1), value: vm.notchState)
            .zIndex(2)
            .padding(8)

            if vm.notchState == .open {
                // Layout only — this must not paint. The panel background already covers these
                // bounds with the skin (or the fill colour) and sits strictly behind the header,
                // so filling here only ever duplicated it. Once skins landed, the duplicate
                // became wrong: it stamped a flat notchFillColor patch in NotchShape over the
                // middle of the skin. The mask went with it — masking a clear rect is a no-op.
                Color.clear
                    .frame(
                        width: min(vm.closedNotchSize.width, 300),
                        height: max(24, vm.effectiveClosedNotchHeight)
                    )
            }

            HStack(spacing: 4) {
                if vm.notchState == .open && !enableMinimalisticUI {
                    // Order: what comes and goes first, what is always there last. The row is
                    // trailing-aligned, so an item that appears pushes only what is to its left —
                    // the fixed buttons (clipboard, timer, Brain, battery) never move. Pinned by
                    // HeaderOrderRulesTests.

                    // Screen Recording Indicator
                    if Defaults[.enableScreenRecordingDetection] && Defaults[.showRecordingIndicator] && !shouldSuppressStatusIndicators {
                        RecordingIndicator()
                            .frame(width: 30, height: 30) // Same size as other header elements
                    }

                    if Defaults[.enableDoNotDisturbDetection]
                        && Defaults[.showDoNotDisturbIndicator]
                        && doNotDisturbManager.isDoNotDisturbActive
                        && !shouldSuppressStatusIndicators {
                        FocusIndicator()
                            .frame(width: 30, height: 30)
                            .transition(.opacity)
                    }

                    // Refresh icon for the Usage tab — icon-only, shown only while the Usage tab
                    // is the active view, so it sits with the other comers and goers.
                    if coordinator.currentView == .llmUsage {
                        Button(action: {
                            llmUsageManager.refreshAll(force: true)
                        }) {
                            Capsule()
                                .fill(.black)
                                .frame(width: 30, height: 30)
                                .overlay {
                                    Image(systemName: "arrow.clockwise")
                                        .foregroundColor(.white)
                                        .padding()
                                        .imageScale(.medium)
                                }
                        }
                        .buttonStyle(PlainButtonStyle())
                        .disabled(llmUsageManager.isRefreshing)
                        // Icon-only, so VoiceOver would otherwise announce the SF Symbol name
                        // rather than what the control does.
                        .accessibilityLabel("Refresh usage")
                        .hoverTooltip("Refresh usage", edge: .below)
                        .transition(.opacity)
                    }

                    // Last of the comers and goers, left of the clipboard button. Its own view, so
                    // TasksManager (and the task file) is touched only with tasks on:
                    // showsTasksButton includes that.
                    if showsTasksButton {
                        TasksHeaderButton()
                            .transition(.opacity)
                    }

                    if Defaults[.enableClipboardManager]
                        && showClipboardIcon
                        && clipboardDisplayMode != .separateTab {
                        Button(action: {
                            // Switch behavior based on display mode
                            switch clipboardDisplayMode {
                            case .panel:
                                ClipboardPanelManager.shared.toggleClipboardPanel(trigger: "header-button")
                            case .popover:
                                showClipboardPopover.toggle()
                            case .separateTab:
                                coordinator.currentView = .notes
                            }
                        }) {
                            Capsule()
                                .fill(.black)
                                .frame(width: 30, height: 30)
                                .overlay {
                                    Image(systemName: "doc.on.clipboard")
                                        .foregroundColor(.white)
                                        .padding()
                                        .imageScale(.medium)
                                }
                        }
                        .buttonStyle(PlainButtonStyle())
                        .popover(isPresented: $showClipboardPopover, arrowEdge: .bottom) {
                            ClipboardPopover()
                        }
                        .onChange(of: showClipboardPopover) { _, isActive in
                            vm.isClipboardPopoverActive = isActive
                            
                            // If popover was closed, trigger a hover recheck
                            if !isActive {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    vm.shouldRecheckHover.toggle()
                                }
                            }
                        }
                        .onAppear {
                            if Defaults[.enableClipboardManager] && !clipboardManager.isMonitoring {
                                clipboardManager.startMonitoring()
                            }
                        }
                    }

                    if Defaults[.enableTimerFeature] && timerDisplayMode == .popover {
                        Button(action: {
                            withAnimation(.smooth) {
                                showTimerPopover.toggle()
                            }
                        }) {
                            Capsule()
                                .fill(.black)
                                .frame(width: 30, height: 30)
                                .overlay {
                                    Image(systemName: "timer")
                                        .foregroundColor(.white)
                                        .padding()
                                        .imageScale(.medium)
                                }
                        }
                        .buttonStyle(PlainButtonStyle())
                        .popover(isPresented: $showTimerPopover, arrowEdge: .bottom) {
                            TimerPopover()
                        }
                        .onChange(of: showTimerPopover) { _, isActive in
                            vm.isTimerPopoverActive = isActive
                            if !isActive {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    vm.shouldRecheckHover.toggle()
                                }
                            }
                        }
                    }

                    if Defaults[.settingsIconInNotch] {
                        Button(action: {
                            SettingsWindowController.shared.showWindow()
                        }) {
                            Capsule()
                                .fill(.black)
                                .frame(width: 30, height: 30)
                                .overlay {
                                    Image(systemName: "brain")
                                        .foregroundColor(.white)
                                        .padding()
                                        .imageScale(.medium)
                                }
                        }
                        .buttonStyle(PlainButtonStyle())
                        .accessibilityLabel("Brain")
                        .hoverTooltip(String(localized: "Brain"), edge: .below)
                    }
                }

                if vm.notchState == .open && showBatteryIndicator {
                    if enableMinimalisticUI {
                        // In minimalistic notch mode, show the battery pill only when
                        // showMinimalisticBatteryIndicator is enabled (and not DI mode).
                        if !shouldUseDynamicIslandMode(for: vm.screen) && showMinimalisticBatteryIndicator {
                            MinimalisticBatteryView(
                                levelBattery: batteryModel.levelBattery,
                                isPluggedIn: batteryModel.isPluggedIn,
                                isCharging: batteryModel.isCharging,
                                isInLowPowerMode: batteryModel.isInLowPowerMode,
                                bodyWidth: 28,
                                bodyHeight: 14,
                                isForNotification: false,
                                showPercentInside: showBatteryPercentInside
                            )
                            .padding(.trailing, 4)
                            .transition(.opacity.combined(with: .scale(scale: 0.85)))
                        }
                    } else {
                        KannuBatteryView(
                            batteryWidth: 30,
                            isCharging: batteryModel.isCharging,
                            isInLowPowerMode: batteryModel.isInLowPowerMode,
                            isPluggedIn: batteryModel.isPluggedIn,
                            levelBattery: batteryModel.levelBattery,
                            maxCapacity: batteryModel.maxCapacity,
                            timeToFullCharge: batteryModel.timeToFullCharge,
                            isForNotification: false
                        )
                    }
                }
            }
            .font(.system(.headline, design: .rounded))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .opacity(vm.notchState == .closed ? 0 : 1)
            .blur(radius: vm.notchState == .closed ? 20 : 0)
            .animation(.smooth.delay(0.1), value: vm.notchState)
            // The Tasks and Refresh buttons' show/hide: a plain fade. A tab click changes
            // currentView with no transaction, so without these the fade never runs. Only what is
            // to their left moves (the row is trailing).
            .animation(.easeInOut(duration: 0.15), value: showsTasksButton)
            .animation(.easeInOut(duration: 0.15), value: coordinator.currentView == .llmUsage)
            .zIndex(2)
        }
        .foregroundColor(.gray)
        .environmentObject(vm)
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ToggleClipboardPopover"))) { _ in
            // Handle keyboard shortcut for popover mode
            if Defaults[.enableClipboardManager] && clipboardDisplayMode == .popover {
                showClipboardPopover.toggle()
            }
        }
        .onChange(of: enableTimerFeature) { _, newValue in
            if !newValue {
                showTimerPopover = false
                vm.isTimerPopoverActive = false
            }
        }
        .onChange(of: timerDisplayMode) { _, mode in
            if mode == .tab {
                showTimerPopover = false
                vm.isTimerPopoverActive = false
            }
        }
        .onChange(of: enableTasks) { _, isOn in
            // The button goes with the setting; a popover that vanished with it never says it closed.
            if !isOn {
                vm.isTasksPopoverActive = false
            }
        }
    }
}

private extension KannuHeader {
    /// The Tasks button: with tasks on, on the timer tab, or on every tab when there is no timer
    /// tab (the timer off, or shown as a popover). The timer tab exists exactly as
    /// `TabSelectionView` builds it.
    var showsTasksButton: Bool {
        TasksHeaderVisibility.isShown(
            enableTasks: enableTasks,
            currentViewIsTimer: coordinator.currentView == .timer,
            timerTabExists: enableTimerFeature && timerDisplayMode == .tab
        )
    }

    var shouldSuppressStatusIndicators: Bool {
        Defaults[.settingsIconInNotch]
            && Defaults[.enableClipboardManager]
            && Defaults[.showClipboardIcon]
            && Defaults[.showColorPickerIcon]
            && Defaults[.enableTimerFeature]
    }
}

#Preview {
    KannuHeader()
        .environmentObject(KannuViewModel())
}
