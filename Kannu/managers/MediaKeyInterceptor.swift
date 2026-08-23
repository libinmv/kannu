/*
 * Kannu (കണ്ണ്)
 * Copyright (C) 2024-2026 Kannu Contributors
 *
 * Originally from boring.notch project
 * Modified and adapted for Kannu (കണ്ണ്)
 * See NOTICE for details.
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

import Foundation
import AppKit
import CoreGraphics
#if canImport(ApplicationServices)
import ApplicationServices
#endif

private let NX_SYSDEFINED_EVENT_TYPE: UInt32 = 14
private let NX_KEYTYPE_SOUND_UP: Int32 = 0
private let NX_KEYTYPE_SOUND_DOWN: Int32 = 1
private let NX_KEYTYPE_BRIGHTNESS_UP: Int32 = 2
private let NX_KEYTYPE_BRIGHTNESS_DOWN: Int32 = 3
private let NX_KEYTYPE_MUTE: Int32 = 7

enum MediaKeyDirection {
    case up
    case down
}

enum MediaKeyStep {
    case standard
    case fine
}

struct MediaKeyConfiguration {
    var interceptVolume: Bool
    var interceptBrightness: Bool
    var interceptCommandModifiedBrightness: Bool
    /// Listen for brightness keys without swallowing them (macOS applies the change).
    var observeBrightnessKeys: Bool

    static let disabled = MediaKeyConfiguration(
        interceptVolume: false,
        interceptBrightness: false,
        interceptCommandModifiedBrightness: false,
        observeBrightnessKeys: false
    )
}

protocol MediaKeyInterceptorDelegate: AnyObject {
    func mediaKeyInterceptor(
        _ interceptor: MediaKeyInterceptor,
        didReceiveVolumeCommand direction: MediaKeyDirection,
        step: MediaKeyStep,
        isRepeat: Bool,
        modifiers: NSEvent.ModifierFlags
    )
    func mediaKeyInterceptor(
        _ interceptor: MediaKeyInterceptor,
        didReceiveBrightnessCommand direction: MediaKeyDirection,
        step: MediaKeyStep,
        isRepeat: Bool,
        modifiers: NSEvent.ModifierFlags
    )
    func mediaKeyInterceptorDidObserveBrightnessKey(_ interceptor: MediaKeyInterceptor)
    func mediaKeyInterceptorDidToggleMute(_ interceptor: MediaKeyInterceptor)
}

final class MediaKeyInterceptor {
    static let shared = MediaKeyInterceptor()

    weak var delegate: MediaKeyInterceptorDelegate?
    var configuration: MediaKeyConfiguration = .disabled {
        didSet {
            updateTapState()
        }
    }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isTapEnabled = false
    /// Set the first time the tap actually delivers a media key. A non-nil tap is not
    /// a healthy tap: a re-signed binary launched through Launch Services can hold a
    /// tap that reports enabled yet never fires, and macOS raises no callback for it.
    /// Only a delivered key proves interception is really happening.
    private(set) var hasObservedMediaKey = false
    private var lastKnownTrust = false
    private var healthTimer: Timer?
#if canImport(ApplicationServices)
    private var didRequestAccessibilityPrompt = false
#endif
    private let systemDefinedEventType = CGEventType(rawValue: NX_SYSDEFINED_EVENT_TYPE)
    private let eventTapLocations: [CGEventTapLocation] = [.cghidEventTap, .cgSessionEventTap]

    private var currentTrust: Bool {
#if canImport(ApplicationServices)
        AXIsProcessTrusted()
#else
        true
#endif
    }

    /// Permission granted, tap created and tap enabled. Necessary, not sufficient.
    var isInterceptionAvailable: Bool {
        guard let tap = eventTap, currentTrust else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    /// True only when volume keys are provably being swallowed before macOS sees them.
    /// When this is false macOS handles the keys itself and draws its own HUD, so Kannu
    /// must not draw a second one on top.
    var isVolumeInterceptionEffective: Bool {
        configuration.interceptVolume && hasObservedMediaKey && isInterceptionAvailable
    }

    /// Brightness equivalent. Only meaningful when brightness interception is intended —
    /// observe-only and DDC modes pass the key through to macOS by design.
    var isBrightnessInterceptionEffective: Bool {
        configuration.interceptBrightness && hasObservedMediaKey && isInterceptionAvailable
    }

    private init() {}

    @discardableResult
    func start() -> Bool {
        if let tap = eventTap {
            // A tap that exists but is dead (permission revoked, binary re-signed)
            // must be rebuilt — re-enabling a dead tap does nothing.
            if !configurationWantsTap || CGEvent.tapIsEnabled(tap: tap) {
                updateTapState()
                return true
            }
            NSLog("⚠️ Media key tap exists but is not enabled — rebuilding")
            teardownTap()
        }

#if canImport(ApplicationServices)
        requestAccessibilityPermissionIfNeeded()
#endif

        guard let systemDefinedType = systemDefinedEventType else {
            NSLog("❌ Unable to resolve system-defined event type")
            return false
        }
        let mask = CGEventMask(1) << systemDefinedType.rawValue
        let callback: CGEventTapCallBack = { _, type, cgEvent, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(cgEvent) }
            let interceptor = Unmanaged<MediaKeyInterceptor>.fromOpaque(userInfo).takeUnretainedValue()
            return interceptor.handleEvent(cgEvent: cgEvent, type: type)
        }

        var createdTap: CFMachPort?
        for location in eventTapLocations {
            if let tap = CGEvent.tapCreate(
                tap: location,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: callback,
                userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
            ) {
                createdTap = tap
                break
            }
        }

        guard let tap = createdTap else {
#if canImport(ApplicationServices)
            if !AXIsProcessTrusted() {
                NSLog("⚠️ Accessibility permission missing; grant access in System Settings › Privacy & Security › Accessibility")
            }
#endif
            NSLog("❌ Failed to create media key event tap")
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        isTapEnabled = true
        lastKnownTrust = currentTrust
        startHealthMonitor()
        NSLog("✅ Media key event tap installed (HID)")
        return true
    }

    func stop() {
        stopHealthMonitor()
        teardownTap()
    }

    private func teardownTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        isTapEnabled = false
    }

    private func startHealthMonitor() {
        guard healthTimer == nil else { return }
        // Cheap local checks. This is what makes granting Accessibility while Kannu is
        // running take effect: previously the tap was created once and never retried,
        // so a grant only applied after a restart.
        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            self?.verifyTapHealth()
        }
        RunLoop.main.add(timer, forMode: .common)
        healthTimer = timer
    }

    private func stopHealthMonitor() {
        healthTimer?.invalidate()
        healthTimer = nil
    }

    private func verifyTapHealth() {
        guard configurationWantsTap else { return }
        let trusted = currentTrust
        if trusted != lastKnownTrust {
            lastKnownTrust = trusted
            NSLog("ℹ️ Accessibility %@ — rebuilding media key tap", trusted ? "granted" : "revoked")
            teardownTap()
            hasObservedMediaKey = false
            _ = start()
            return
        }
        guard trusted, let tap = eventTap else { return }
        if !CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
            isTapEnabled = true
        }
    }

    private var configurationWantsTap: Bool {
        configuration.interceptVolume
            || configuration.interceptBrightness
            || configuration.interceptCommandModifiedBrightness
            || configuration.observeBrightnessKeys
    }

    private func updateTapState() {
        guard let tap = eventTap else { return }
        // Compare against the tap's real state, not our flag — macOS can disable the
        // tap behind our back (timeout), leaving isTapEnabled stale.
        let shouldEnable = configurationWantsTap
        if CGEvent.tapIsEnabled(tap: tap) != shouldEnable {
            CGEvent.tapEnable(tap: tap, enable: shouldEnable)
        }
        isTapEnabled = shouldEnable
    }

    private func handleEvent(cgEvent: CGEvent, type: CGEventType) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap, configurationWantsTap {
                CGEvent.tapEnable(tap: tap, enable: true)
                isTapEnabled = true
                NSLog("⚠️ Media key tap disabled by %@ — re-enabled",
                      type == .tapDisabledByTimeout ? "timeout" : "user input")
            }
            return Unmanaged.passUnretained(cgEvent)
        }

        guard let systemDefinedType = systemDefinedEventType,
              type == systemDefinedType,
              let nsEvent = NSEvent(cgEvent: cgEvent),
              nsEvent.subtype.rawValue == 8 else {
            return Unmanaged.passUnretained(cgEvent)
        }

        let data1 = nsEvent.data1
        let keyCode = (data1 & 0xFFFF0000) >> 16
        let keyFlags = data1 & 0x0000FFFF
        let keyState = ((keyFlags & 0xFF00) >> 8) == 0xA // 0xA = keyDown, 0xB = keyUp
        let isRepeat = (keyFlags & 0x0001) == 1
        let step = step(for: nsEvent)
        let modifiers = nsEvent.modifierFlags

        // Proof of life: the tap is genuinely delivering media keys. Until this is set
        // we must assume macOS is still handling them (and drawing its own HUD).
        switch Int32(keyCode) {
        case NX_KEYTYPE_SOUND_UP, NX_KEYTYPE_SOUND_DOWN, NX_KEYTYPE_MUTE,
             NX_KEYTYPE_BRIGHTNESS_UP, NX_KEYTYPE_BRIGHTNESS_DOWN:
            if !hasObservedMediaKey {
                hasObservedMediaKey = true
                NSLog("✅ Media key interception confirmed live")
            }
        default:
            break
        }

        guard keyState else {
            // Swallow key-up events only when intercepting, otherwise let them pass through
            if shouldHandle(keyCode: Int32(keyCode), modifiers: modifiers) {
                return nil
            }
            return Unmanaged.passUnretained(cgEvent)
        }

        switch Int32(keyCode) {
        case NX_KEYTYPE_SOUND_UP:
            guard configuration.interceptVolume else { return Unmanaged.passUnretained(cgEvent) }
            delegate?.mediaKeyInterceptor(self, didReceiveVolumeCommand: .up, step: step, isRepeat: isRepeat, modifiers: modifiers)
            return nil
        case NX_KEYTYPE_SOUND_DOWN:
            guard configuration.interceptVolume else { return Unmanaged.passUnretained(cgEvent) }
            delegate?.mediaKeyInterceptor(self, didReceiveVolumeCommand: .down, step: step, isRepeat: isRepeat, modifiers: modifiers)
            return nil
        case NX_KEYTYPE_MUTE:
            guard configuration.interceptVolume else { return Unmanaged.passUnretained(cgEvent) }
            delegate?.mediaKeyInterceptorDidToggleMute(self)
            return nil
        case NX_KEYTYPE_BRIGHTNESS_UP:
            if shouldInterceptBrightness(modifiers: modifiers) {
                delegate?.mediaKeyInterceptor(self, didReceiveBrightnessCommand: .up, step: step, isRepeat: isRepeat, modifiers: modifiers)
                return nil
            }
            if configuration.observeBrightnessKeys && shouldObserveBrightness(modifiers: modifiers) {
                delegate?.mediaKeyInterceptorDidObserveBrightnessKey(self)
            }
            return Unmanaged.passUnretained(cgEvent)
        case NX_KEYTYPE_BRIGHTNESS_DOWN:
            if shouldInterceptBrightness(modifiers: modifiers) {
                delegate?.mediaKeyInterceptor(self, didReceiveBrightnessCommand: .down, step: step, isRepeat: isRepeat, modifiers: modifiers)
                return nil
            }
            if configuration.observeBrightnessKeys && shouldObserveBrightness(modifiers: modifiers) {
                delegate?.mediaKeyInterceptorDidObserveBrightnessKey(self)
            }
            return Unmanaged.passUnretained(cgEvent)
        default:
            return Unmanaged.passUnretained(cgEvent)
        }
    }

    private func shouldHandle(keyCode: Int32, modifiers: NSEvent.ModifierFlags) -> Bool {
        switch keyCode {
        case NX_KEYTYPE_SOUND_UP, NX_KEYTYPE_SOUND_DOWN, NX_KEYTYPE_MUTE:
            return configuration.interceptVolume
        case NX_KEYTYPE_BRIGHTNESS_UP, NX_KEYTYPE_BRIGHTNESS_DOWN:
            return configuration.interceptBrightness || (configuration.interceptCommandModifiedBrightness && modifiers.contains(.command))
        default:
            return false
        }
    }

    private func shouldInterceptBrightness(modifiers: NSEvent.ModifierFlags) -> Bool {
        if configuration.interceptBrightness {
            return true
        }
        return configuration.interceptCommandModifiedBrightness && modifiers.contains(.command)
    }

    private func shouldObserveBrightness(modifiers: NSEvent.ModifierFlags) -> Bool {
        !modifiers.contains(.command)
    }

    private func shouldHandleBrightness(modifiers: NSEvent.ModifierFlags) -> Bool {
        shouldInterceptBrightness(modifiers: modifiers)
    }

    private func step(for event: NSEvent) -> MediaKeyStep {
        let modifiers = event.modifierFlags
        if modifiers.contains(.option) && modifiers.contains(.shift) {
            return .fine
        }
        return .standard
    }
}

#if canImport(ApplicationServices)
extension MediaKeyInterceptor {
    private func requestAccessibilityPermissionIfNeeded() {
        guard !AXIsProcessTrusted(), !didRequestAccessibilityPrompt else { return }
        if AppRuntimeEnvironment.isUITesting { return }
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options: CFDictionary = [promptKey: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        didRequestAccessibilityPrompt = true
    }
}
#endif
