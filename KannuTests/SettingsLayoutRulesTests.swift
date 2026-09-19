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

import XCTest

/// The Settings construction rules, pinned against the sources the way
/// `SettingsHighlightInventoryTests` and `ModalPresentationRulesTests` pin theirs. The rules
/// themselves are written down in `docs/SETTINGS.md`; this file is what keeps them true:
///
/// 1. A `Section` header uses `SettingsSectionHeader`, never a raw `Text` — headers are
///    explanatory text and must be selectable.
/// 2. A `Section` footer uses `SettingsFooter` for the plain-text case, same reason.
/// 3. Secondary/caption informational text carries `.textSelection(.enabled)` or goes through
///    `settingsDescriptionStyle()`. The survivors that deliberately stay unselectable — badges,
///    labels inside tappable cards and control labels, and text covered by a container-level
///    `.textSelection` — are pinned per file below, so a new one is a deliberate edit here, not
///    a row that quietly lost copyability.
/// 4. The shared components themselves keep their `.textSelection`, so a refactor cannot strip
///    selectability from every user at once.
/// 5. The content standard, pinned the same way: no ad-hoc font on row text, no hand-built
///    `Slider`, no padding on a row. Each is a per-file count with a reason, so the survivors are
///    a deliberate list (cards, chips, previews, popovers) and a new one is an edit here.
final class SettingsLayoutRulesTests: XCTestCase {

    // MARK: - Rule 1: headers

    func testNoSectionHeaderIsARawText() {
        for (path, text) in Self.settingsSources() {
            for offender in Self.rawHeaderOffenders(in: text) {
                XCTFail("\(path):\(offender): a Section header is a raw Text — use SettingsSectionHeader so it can be selected and copied")
            }
        }
    }

    // MARK: - Rule 2: footers

    func testNoSectionFooterIsARawText() {
        for (path, text) in Self.settingsSources() {
            for offender in Self.rawFooterOffenders(in: text) {
                XCTFail("\(path):\(offender): a Section footer is a raw Text — use SettingsFooter so it can be selected and copied")
            }
        }
    }

    // MARK: - Rule 3: informational text is selectable, survivors are pinned

    /// Raw `Text` chains styled as secondary/caption information that carry no selection. Every
    /// entry is deliberate: a badge chip, a label inside a tappable card or a control label
    /// (a selectable Text there swallows the control's click), or text already covered by a
    /// container-level `.textSelection`. Adding a new one means either giving it
    /// `.textSelection(.enabled)` / `settingsDescriptionStyle()` or updating this table with the
    /// reason it cannot have one.
    private static let pinnedUnselectableCounts: [String: Int] = [
        "ExtensionsSettings.swift": 1,              // footer legend heading — container-selectable
        "IdleAnimationsSettingsSection.swift": 2,   // "Add" / "Add New" — labels of a tappable card
        "MusicSlotConfigurationView.swift": 1,      // palette item label — draggable/tappable chip
        "SecurityFindingRow.swift": 1,              // severity badge chip, accessibility-hidden
        "SettingsView.swift": 6,                    // badges and tappable style cards: a
                                                    // selectable label swallows the card's click
    ]

    func testEveryInformationalTextIsSelectableOrPinned() {
        var counts: [String: Int] = [:]
        for (path, text) in Self.settingsSources() {
            let found = Self.unselectableInformationalChains(in: text)
            if !found.isEmpty { counts[path] = found.count }
            let allowed = Self.pinnedUnselectableCounts[path] ?? 0
            if found.count > allowed {
                XCTFail("""
                \(path): \(found.count) raw secondary/caption Text chains without .textSelection \
                (pinned: \(allowed)). New informational text must be selectable — add \
                .textSelection(.enabled) or settingsDescriptionStyle(), or pin it here with a \
                reason. First lines: \(found.prefix(6).joined(separator: " | "))
                """)
            }
        }
        // The pin shrinks with the code: a stale entry hides a future offender behind its slot.
        for (path, allowed) in Self.pinnedUnselectableCounts {
            let found = counts[path] ?? 0
            XCTAssertGreaterThanOrEqual(
                allowed, found,
                "\(path): pinned count is stale")
            XCTAssertEqual(
                allowed, found,
                "\(path): fewer raw chains (\(found)) than pinned (\(allowed)) — lower the pin so it keeps meaning something")
        }
    }

    // MARK: - Rule 5: the content standard

    /// Lines carrying a caption-sized or pixel-sized font. Every survivor is a badge or chip, a
    /// glyph, or text inside a card, popover or preview that has its own compact scale — never a
    /// row's title or description, which use the Form's type and `settingsDescriptionStyle()`.
    private static let pinnedAdHocFontCounts: [String: Int] = [
        "AnimationEditorView.swift": 11,     // the animation editor sheet: its own dense scale
        "ExtensionsSettings.swift": 1,       // the empty state's 48-pt glyph
        "IdleAnimationsSettingsSection.swift": 9,  // animation cards, their chips, the URL sheet
        "MusicSlotConfigurationView.swift": 7,     // the slot canvas and its draggable chips
        "SecurityFindingRow.swift": 2,       // the severity badge chips
        "SettingsView.swift": 33,            // sidebar chrome and search results, style and HUD
                                             // cards, previews, the colour popover, the
                                             // timer-preset editor, badge capsules
        "SpotifyAuthSettingsSection.swift": 6,     // the sign-in card
        "SpotifyLoginSheet.swift": 1,        // a sheet, not a Form
    ]

    func testRowTextUsesTheFormsTypeOrTheSharedStyle() {
        assertPinnedCounts(Self.pinnedAdHocFontCounts, scanner: Self.adHocFontLines,
                           rule: "a caption-sized or pixel-sized font",
                           cure: "row text uses the Form's own type, and every secondary line goes through settingsDescriptionStyle()")
    }

    /// Lines building a `Slider` by hand. `SettingsSliderRow` is the only shape a Settings *row*
    /// may use, so these are the ones that are not rows.
    private static let pinnedInlineSliderCounts: [String: Int] = [
        "AnimationEditorView.swift": 3,      // the animation editor sheet
        "SettingsComponents.swift": 2,       // SettingsSliderRow itself, stepped and unstepped
        "SettingsView.swift": 1,             // the OSD preview card's own level slider
    ]

    func testNoSliderIsBuiltByHandInARow() {
        assertPinnedCounts(Self.pinnedInlineSliderCounts, scanner: Self.inlineSliderLines,
                           rule: "a hand-built Slider",
                           cure: "a slider row is SettingsSliderRow — one width, one readout column")
    }

    /// Lines adding padding. A grouped `Form` pads its own rows, so padding here belongs to a
    /// card, a chip, a popover, a preview or an empty state — never to a row, which would make
    /// that one row taller than its neighbours.
    private static let pinnedRowPaddingCounts: [String: Int] = [
        "AnimationEditorView.swift": 8,      // the editor sheet
        "EditPanelView.swift": 1,            // a panel, not a Form
        "ExtensionsSettings.swift": 5,       // the empty state and the expanded detail card
        "IdleAnimationsSettingsSection.swift": 8,  // animation cards, chips, the URL sheet
        "MusicSlotConfigurationView.swift": 5,     // the slot canvas
        "PolicyRulesEditor.swift": 1,        // the Edit rules sheet: a sheet pads its own content
        "SecurityFindingRow.swift": 3,       // the finding card and its badge
        "SettingsView.swift": 42,            // sidebar chrome, badge capsules, style and HUD
                                             // cards, previews, the colour popover
        "SpotifyAuthSettingsSection.swift": 1,     // the sign-in card
        "SpotifyLoginSheet.swift": 1,        // a sheet, not a Form
    ]

    func testNoRowPadsItself() {
        assertPinnedCounts(Self.pinnedRowPaddingCounts, scanner: Self.paddingLines,
                           rule: "a padding",
                           cure: "a row in a grouped Form adds none — the Form pads it")
    }

    /// The tokens exist and something reads each of them, so a number cannot drift back into a
    /// row and a token cannot linger after its last user is gone.
    func testEveryMetricTokenIsDeclaredAndUsed() throws {
        let sources = Self.settingsSources()
        let components = try XCTUnwrap(sources["SettingsComponents.swift"],
                                       "SettingsComponents.swift not found")
        for token in ["labelStack", "rowContent", "footerStack", "sliderWidth", "valueColumn",
                      "statusDot", "cardPadding"] {
            XCTAssertTrue(components.contains("static let \(token)"),
                          "SettingsMetrics.\(token) is gone — update docs/SETTINGS.md with it")
            XCTAssertTrue(sources.values.contains { $0.contains("SettingsMetrics.\(token)") },
                          "SettingsMetrics.\(token) is declared but nothing reads it")
        }
    }

    // MARK: - Rule 4: the components stay selectable

    func testTheSharedComponentsKeepTheirTextSelection() throws {
        let text = try XCTUnwrap(Self.settingsSources()["SettingsComponents.swift"],
                                 "SettingsComponents.swift not found")
        for component in ["SettingsSectionHeader", "SettingsFooter", "SettingsValueText"] {
            let region = Self.region(of: component, in: text)
            XCTAssertNotNil(region, "\(component) is gone — update this test and docs/SETTINGS.md")
            if let region {
                XCTAssertTrue(region.contains(".textSelection(.enabled)"),
                              "\(component) lost its .textSelection — every caller loses copyability at once")
            }
        }
        // These select through settingsDescriptionStyle, which carries the .textSelection — and,
        // for the tinted ones, keeps them the same size as every other secondary line.
        for component in ["SettingsStatusText", "SettingsRowLabel", "SettingsErrorText"] {
            let region = Self.region(of: component, in: text)
            XCTAssertNotNil(region, "\(component) is gone — update this test and docs/SETTINGS.md")
            if let region {
                XCTAssertTrue(region.contains("settingsDescriptionStyle("),
                              "\(component) stopped going through settingsDescriptionStyle — it loses selectability and drifts off the type scale")
            }
        }
        let style = Self.region(of: "View", in: text) ?? text
        XCTAssertTrue(style.contains(".textSelection(.enabled)"),
                      "settingsDescriptionStyle() lost its .textSelection")
    }

    // MARK: - The scanners must actually catch things

    func testTheHeaderScannerCatchesAPlantedOffender() {
        let planted = """
        Section {
            row
        } header: {
            Text("Planted")
        }
        """
        XCTAssertEqual(Self.rawHeaderOffenders(in: planted).count, 1)
        XCTAssertEqual(Self.rawHeaderOffenders(in: planted.replacingOccurrences(
            of: "Text(", with: "SettingsSectionHeader(")).count, 0)
        XCTAssertEqual(Self.rawHeaderOffenders(in: "} header: { Text(\"X\") }").count, 1)
        // A comment explaining the rule is not an offender.
        XCTAssertEqual(Self.rawHeaderOffenders(in: "// } header: { Text(\"X\") }").count, 0)
    }

    func testTheFooterScannerCatchesAPlantedOffender() {
        let planted = """
        } footer: {
            Text("Planted")
        }
        """
        XCTAssertEqual(Self.rawFooterOffenders(in: planted).count, 1)
        XCTAssertEqual(Self.rawFooterOffenders(in: planted.replacingOccurrences(
            of: "Text(", with: "SettingsFooter(")).count, 0)
    }

    func testTheChainScannerCatchesAPlantedOffenderAndPassesTheCures() {
        let planted = """
        Text("info")
            .font(.caption)
            .foregroundStyle(.secondary)
        """
        XCTAssertEqual(Self.unselectableInformationalChains(in: planted).count, 1)
        XCTAssertEqual(Self.unselectableInformationalChains(
            in: planted + "\n    .textSelection(.enabled)").count, 0)
        XCTAssertEqual(Self.unselectableInformationalChains(in: """
        Text("info")
            .settingsDescriptionStyle()
        """).count, 0)
        // The older spelling counts too.
        XCTAssertEqual(Self.unselectableInformationalChains(in: """
        Text("Inactive")
            .foregroundColor(.secondary)
        """).count, 1)
        // Primary text is not the rule's business.
        XCTAssertEqual(Self.unselectableInformationalChains(in: "Text(\"title\")").count, 0)
    }

    func testTheContentStandardScannersCatchPlantedOffenders() {
        XCTAssertEqual(Self.adHocFontLines(in: "Text(\"x\").font(.caption)").count, 1)
        XCTAssertEqual(Self.adHocFontLines(in: "Text(\"x\").font(.caption2)").count, 1)
        XCTAssertEqual(Self.adHocFontLines(in: "Text(\"x\").font(.system(size: 11))").count, 1)
        XCTAssertEqual(Self.adHocFontLines(in: "Text(\"x\").font(.system(.caption, design: .monospaced))").count, 1)
        XCTAssertEqual(Self.adHocFontLines(in: "// .font(.caption) is banned on row text").count, 0)
        XCTAssertEqual(Self.adHocFontLines(in: "Text(\"x\").settingsDescriptionStyle()").count, 0)
        XCTAssertEqual(Self.adHocFontLines(in: "Text(\"x\").font(.subheadline)").count, 0)

        XCTAssertEqual(Self.inlineSliderLines(in: "Slider(value: $x, in: 0...1)").count, 1)
        XCTAssertEqual(Self.inlineSliderLines(in: "// Slider(value: $x, in: 0...1)").count, 0)
        XCTAssertEqual(Self.inlineSliderLines(in: "SettingsSliderRow(\"T\", value: $x, in: 0...1, valueText: nil)").count, 0)

        XCTAssertEqual(Self.paddingLines(in: ".padding(.vertical, 8)").count, 1)
        XCTAssertEqual(Self.paddingLines(in: "// .padding(12)").count, 0)
        XCTAssertEqual(Self.paddingLines(in: ".frame(width: 220)").count, 0)

        // The same offenders, wrapped the way a long call is usually written. A rule that only
        // reads one physical line at a time is one reformat away from being switched off.
        XCTAssertEqual(Self.inlineSliderLines(in: """
        Slider(
            value: $value,
            in: range
        )
        """).count, 1)
        XCTAssertEqual(Self.adHocFontLines(in: """
        Text("x")
            .font(.system(size: 13,
                          weight: .semibold))
        """).count, 1)
        XCTAssertEqual(Self.paddingLines(in: """
        Text("x")
            .padding(
                .vertical, 8)
        """).count, 1)
        // Joining lines must not join across a comment that sits inside the call.
        XCTAssertEqual(Self.inlineSliderLines(in: """
        Slider(
            // value comes from the binding above
            value: $value, in: range)
        """).count, 1)
    }

    func testTheScanReadTheRealSources() {
        let sources = Self.settingsSources()
        XCTAssertGreaterThan(sources.count, 8, "the Settings directory moved — fix settingsSources()")
        XCTAssertNotNil(sources["SettingsView.swift"])
        XCTAssertNotNil(sources["SettingsComponents.swift"])
    }

    // MARK: - Plumbing

    /// `Kannu/components/Settings/*.swift`, keyed by file name. The views are not compiled into
    /// this target, so the rules read the sources as text — the same route
    /// `SettingsHighlightInventoryTests` takes.
    private static func settingsSources() -> [String: String] {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Kannu/components/Settings")
        var out: [String: String] = [:]
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in files where name.hasSuffix(".swift") {
            out[name] = try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
        }
        return out.compactMapValues { $0 }
    }

    /// The shared shape of every pinned-count rule: no file may exceed its pin, and no pin may
    /// outlive the code it describes — a stale pin hides the next offender behind its slot.
    private func assertPinnedCounts(_ pinned: [String: Int],
                                    scanner: (String) -> [String],
                                    rule: String,
                                    cure: String,
                                    file: StaticString = #filePath,
                                    line: UInt = #line) {
        var counts: [String: Int] = [:]
        for (path, text) in Self.settingsSources() {
            let found = scanner(text)
            if !found.isEmpty { counts[path] = found.count }
            let allowed = pinned[path] ?? 0
            if found.count > allowed {
                XCTFail("""
                \(path): \(found.count) lines with \(rule) (pinned: \(allowed)). \(cure). Fix it, \
                or pin it here with the reason it cannot follow the rule. \
                First lines: \(found.prefix(6).joined(separator: " | "))
                """, file: file, line: line)
            }
        }
        for (path, allowed) in pinned {
            let found = counts[path] ?? 0
            XCTAssertEqual(allowed, found,
                           "\(path): pinned \(allowed) lines with \(rule) but found \(found) — move the pin so it keeps meaning something",
                           file: file, line: line)
        }
    }

    /// Non-comment lines carrying a caption-sized or pixel-sized font.
    private static func adHocFontLines(in text: String) -> [String] {
        matchingLines(in: text) {
            $0.contains(".font(.caption") || $0.contains(".font(.system(size:")
                || $0.contains(".font(.system(.caption")
        }
    }

    /// Non-comment lines building a `Slider` directly.
    private static func inlineSliderLines(in text: String) -> [String] {
        matchingLines(in: text) { $0.contains("Slider(value:") }
    }

    /// Non-comment lines adding padding.
    private static func paddingLines(in text: String) -> [String] {
        matchingLines(in: text) { $0.contains(".padding(") }
    }

    private static func matchingLines(in text: String, where predicate: (String) -> Bool) -> [String] {
        joinedStatements(in: text).filter(predicate)
    }

    /// Comment lines dropped, then every line break that sits inside a call — after an opening
    /// paren or a comma — joined up. Without this the rules would only see code as it happens to
    /// be wrapped today: `Slider(value: $x, in: r)` would fail the guard while the same call
    /// split across four lines would sail through it.
    private static func joinedStatements(in text: String) -> [String] {
        let code = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !isComment($0) }
            .joined(separator: "\n")
        let joined = code.replacingOccurrences(of: #"([(,])[ \t]*\n[ \t]*"#, with: "$1",
                                               options: .regularExpression)
        return joined.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func isComment(_ line: Substring) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*")
    }

    /// Line numbers (1-based) where a `header: {` is immediately answered by a raw `Text(`.
    private static func rawHeaderOffenders(in text: String) -> [Int] {
        offenders(in: text, opener: "header: {")
    }

    private static func rawFooterOffenders(in text: String) -> [Int] {
        offenders(in: text, opener: "footer: {")
    }

    private static func offenders(in text: String, opener: String) -> [Int] {
        var out: [Int] = []
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() where !isComment(line) {
            guard let range = line.range(of: opener) else { continue }
            let rest = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            if rest.hasPrefix("Text(") {
                out.append(index + 1)
            } else if rest.isEmpty, index + 1 < lines.count,
                      lines[index + 1].trimmingCharacters(in: .whitespaces).hasPrefix("Text(") {
                out.append(index + 2)
            }
        }
        return out
    }

    /// First lines of `Text(` chains styled secondary/caption/subheadline with no selection and
    /// no `settingsDescriptionStyle()`. Mirrors what a reader sees: the chain is the `Text(` line
    /// plus the `.modifier` lines that follow it.
    private static func unselectableInformationalChains(in text: String) -> [String] {
        var out: [String] = []
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var index = 0
        while index < lines.count {
            let line = lines[index]
            // A bare `Text(` — not the tail of `SettingsValueText(` and friends.
            guard let range = line.range(of: "Text("),
                  range.lowerBound == line.startIndex
                    || !line[line.index(before: range.lowerBound)].isLetter,
                  !isComment(line[...]) else { index += 1; continue }
            var chain = [line]
            var next = index + 1
            while next < lines.count,
                  lines[next].trimmingCharacters(in: .whitespaces).hasPrefix(".") {
                chain.append(lines[next])
                next += 1
            }
            let joined = chain.joined(separator: "\n")
            let informational = joined.contains(".foregroundStyle(.secondary)")
                || joined.contains(".foregroundColor(.secondary)")
                || joined.contains(".font(.caption")
                || joined.contains(".font(.subheadline")
            if informational, !joined.contains(".textSelection"),
               !joined.contains(".settingsDescriptionStyle") {
                out.append(line.trimmingCharacters(in: .whitespaces))
            }
            index = next
        }
        return out
    }

    private static func region(of declaration: String, in text: String) -> String? {
        guard let start = text.range(of: "struct \(declaration)")
            ?? text.range(of: "extension \(declaration)")
            ?? text.range(of: "func \(declaration)") else { return nil }
        let rest = text[start.lowerBound...]
        if let end = rest.range(of: "\nstruct ") ?? rest.range(of: "\nextension ") {
            return String(rest[..<end.lowerBound])
        }
        return String(rest)
    }
}
