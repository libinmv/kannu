//
//  SettingsHighlightInventoryTests.swift
//  KannuTests
//
//  Copyright (C) 2026 Kannu contributors
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <https://www.gnu.org/licenses/>.
//

import XCTest

/// Settings search lands on a row through its highlight id: the search entry names an id, and the
/// row registers the same id with `.settingsHighlight(id:)`. A mismatch fails silently — the result
/// scrolls nowhere — and two entries had drifted that way unnoticed. The Settings views are not
/// compiled into the logic target, so the pairing is read from the source.
///
/// The counts are pinned on purpose: reworking a tab's layout must keep every registration, so a
/// changed number has to be a deliberate edit here, not a row that lost its modifier.
final class SettingsHighlightInventoryTests: XCTestCase {
    private struct HighlightID: Hashable, CustomStringConvertible {
        /// nil when the registering view receives its id builder from a parent (a closure).
        let tab: String?
        let title: String
        var description: String { "\(tab ?? "?")-\(title)" }
    }

    private struct Entry {
        let tab: String
        let title: String
        let highlight: HighlightID?
    }

    private struct Inventory {
        var entries: [Entry] = []
        var registrations: [HighlightID: Int] = [:]
        var deepLinks: [String: HighlightID] = [:]
    }

    private static let settingsDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // KannuTests/
        .deletingLastPathComponent()   // repo root
        .appendingPathComponent("Kannu/components/Settings", isDirectory: true)

    private static let indexStart = "    private var settingsSearchIndex: [SettingsSearchEntry] {"

    // MARK: - Pinned

    func testCountsArePinned() throws {
        let inventory = try Self.inventory()
        // 2026-10-06: Brain › Tasks' Add a task, Task order and Done and hidden rows moved into the
        // Task list sub-page and gave up their ids; the one visible "Task list" row registers
        // instead, and four new entries (Task list, its filters, tags, schedule) land on it.
        // Then the Task list's back row registered `tasksListOpenID`, the deep link that opens the
        // sub-page itself ("Show all in Brain", a reminder's click); no search entry uses it.
        // 2026-10-07: the Sources switches only connect now, so the "Local tasks" row, its id and
        // its search entry are gone (one fewer of each).
        // 2026-10-15: fullscreen hiding became findable. The "Hide DynamicIsland Options" picker
        // registered an id, and two new entries land on it — "Hide in fullscreen", and
        // "Accessibility access", whose own row exists only while the grant is missing, so its
        // entry targets the always-visible picker. The conditional row also registers its id for
        // the highlight when it is built. Two more entries, registrations and ids.
        // 2026-10-10: task colours. The Sources section gained three colour rows (Local tasks colour,
        // Jira colour, GitLab colour), each with its own id and entry (three more of each); the Task
        // list's "Tag colours" section is a sub-page row, so it registers nothing and its new entry
        // lands on the "Task list" row (four entries in all).
        // 2026-10-17: the archive. "Done and hidden tasks" became "Recently closed tasks", and a
        // new "Archived tasks" entry lands on the same visible "Task list" row (one more entry).
        // 2026-10-18: Brain › Tasks became a tree. The nine connection and colour rows moved onto
        // their source's page and gave up their ids (nine fewer of each); the overview's new
        // "Local tasks" row registers one; "Task list" became "All tasks"; two new entries, "Local
        // tasks" and "Find a task", land on overview rows.
        // 2026-10-19: every source shares one row shape. "Sources" now lands on the always-present
        // Local tasks row (its own "Local tasks" id is gone); Jira's row has its own "Jira Cloud" id
        // (one out, one in). GitHub, Linear, Todoist and Apple Reminders rows and the new "Add a
        // source" row register five more ids; "Add a source" is one more entry. Each new source's
        // own entry lands on its row: Apple Reminders, GitHub, Linear, Todoist.
        // 2026-10-22: General gains Permissions (one entry, one row): what onboarding's
        // Permissions step put off is allowed there.
        // 2026-10-23: Notes gains its first two entries ("Sync with Apple Notes", and "Notes to sync",
        // which lands on the sync switch because its own row shows only while sync is on) and the
        // "Notes to sync" row. The same day All tasks lost its Task order row (David: "no drag and
        // order tasks or numbering"): the "Task order" entry is gone and its other words moved onto
        // "All tasks", one entry fewer with registrations and ids unchanged.
        XCTAssertEqual(inventory.entries.count, 244, "search entries")
        XCTAssertEqual(inventory.registrations.values.reduce(0, +), 275, "row registrations")
        XCTAssertEqual(inventory.registrations.count, 269, "distinct registered ids")
    }

    func testOnlyTheKnownRowsTakeTheirIdBuilderFromAParent() throws {
        let unattributed = try Self.inventory().registrations.keys.filter { $0.tab == nil }.map(\.title)
        XCTAssertEqual(Set(unattributed), ["Accent colour", "Device Picker Style"])
    }

    func testQuitIsFindableBySearch() throws {
        // Searching "quit" or "exit" found nothing while the only Quit was a toolbar button, which
        // search cannot land on. The entry must carry both words; the pairing tests below prove it
        // lands on a registered row.
        let settingsView = try XCTUnwrap(try Self.sources()["SettingsView.swift"])
        let entry = try XCTUnwrap(settingsView.components(separatedBy: "\n").first {
            $0.contains("SettingsSearchEntry(") && $0.contains("highlightID(for: \"Quit Kannu\")")
        }, "no search entry lands on the Quit Kannu row")
        for word in ["\"quit\"", "\"exit\""] {
            XCTAssertTrue(entry.contains(word), "searching \(word) must find Quit Kannu")
        }
        XCTAssertTrue(settingsView.contains(".settingsHighlight(id: highlightID(\"Quit Kannu\"))"), "the Quit row lost its highlight id")
    }

    // MARK: - Pairing

    func testEverySearchEntryLandsOnARegisteredRow() throws {
        let inventory = try Self.inventory()
        let missing = inventory.entries.compactMap { entry -> String? in
            guard let id = entry.highlight else { return nil }
            let registered = inventory.registrations[id] != nil
                || inventory.registrations[HighlightID(tab: nil, title: id.title)] != nil
            return registered ? nil : "\(entry.tab): \"\(entry.title)\" → \(id)"
        }
        XCTAssertEqual(missing, [], "search entries whose highlight id no row registers")
    }

    func testEverySearchEntryNamesItsOwnTab() throws {
        let wrong = try Self.inventory().entries.compactMap { entry -> String? in
            guard let tab = entry.highlight?.tab, tab != entry.tab else { return nil }
            return "\(entry.tab): \"\(entry.title)\" → \(tab)"
        }
        XCTAssertEqual(wrong, [], "the id's tab prefix must match the tab the search opens")
    }

    func testEveryDeepLinkIsRegistered() throws {
        let inventory = try Self.inventory()
        XCTAssertFalse(inventory.deepLinks.isEmpty)
        for (name, id) in inventory.deepLinks {
            XCTAssertNotNil(inventory.registrations[id], "SettingsDeepLink.\(name) → \(id) is registered by no row")
        }
    }

    func testTheParserSeesEveryEntryAndRegistration() throws {
        // Guards the regexes themselves: a missed form would quietly shrink both sides.
        let sources = try Self.sources()
        let entryCalls = sources.values.map { $0.components(separatedBy: "SettingsSearchEntry(tab:").count - 1 }.reduce(0, +)
        let inventory = try Self.inventory()
        XCTAssertEqual(inventory.entries.count, entryCalls)
    }

    func testEverySearchEntryNamesARow() throws {
        // An entry without an id opens its tab and scrolls nowhere (the three Battery test entries did).
        let withoutRow = try Self.inventory().entries.filter { $0.highlight == nil }.map { "\($0.tab): \($0.title)" }
        XCTAssertEqual(withoutRow, [])
    }

    /// A source's row exists only while it is connected, so its entries land on Add a source until
    /// then: the redirect is wired, and every source with a row has its id in the map it reads.
    func testASourceNotConnectedLandsOnAddASource() throws {
        let settingsView = try XCTUnwrap(try Self.sources()["SettingsView.swift"])
        XCTAssertTrue(settingsView.contains(".map(landingOnABuiltRow)"), "search no longer redirects them")
        XCTAssertTrue(settingsView.contains("landed.highlightID = SettingsDeepLink.tasksAddSourceHighlightID"))
        for link in ["tasksJiraSourceHighlightID", "tasksGitLabSourceHighlightID", "tasksGitHubSourceHighlightID",
                     "tasksLinearSourceHighlightID", "tasksTodoistSourceHighlightID", "tasksAppleRemindersSourceHighlightID"] {
            XCTAssertTrue(settingsView.contains(": \(link)"), "\(link) is not in taskSourceRows")
        }
    }

    /// Brain › Tasks' pages below the overview exist only while open, so nothing on them may carry
    /// a highlight id: a search landing there would scroll to nothing (docs/SETTINGS.md). All tasks'
    /// own deep link is on its back row, which the overview's file builds.
    func testTheRowsBelowTheTasksOverviewRegisterNothing() throws {
        let sources = try Self.sources()
        for name in ["TaskSourcePages.swift", "TaskRowList.swift", "AllTasksPage.swift", "TaskDetailPage.swift", "NewTaskSheet.swift"] {
            let page = try XCTUnwrap(sources[name], name)
            XCTAssertFalse(page.contains("settingsHighlight("), "\(name) registers a highlight id on a row search cannot reach")
            XCTAssertFalse(page.contains("highlightID("), "\(name) names a highlight id")
        }
    }

    /// A source page's rows land on that source's row on the overview, which opens the page; the
    /// overview's All tasks row takes the entries for All tasks and a task's page.
    func testTasksPageEntriesLandOnTheRowThatOpensThem() throws {
        let inventory = try Self.inventory()
        let landing = Dictionary(inventory.entries.filter { $0.tab == "tasks" }.map { ($0.title, $0.highlight) },
                                 uniquingKeysWith: { first, _ in first })
        let rows: [String: [String]] = [
            "tasksSourcesHighlightID": ["Sources", "Local tasks", "Local tasks colour"],
            "tasksJiraSourceHighlightID": ["Jira Cloud", "Sync Jira", "Jira colour", "Refresh Jira issues", "Issue filter (JQL)"],
            "tasksAddSourceHighlightID": ["Add a source"],
            "tasksGitLabSourceHighlightID": ["GitLab", "Sync GitLab", "GitLab colour", "Include merge requests", "Refresh GitLab items"],
            "tasksListHighlightID": ["All tasks", "Find a task", "Add a task", "Tag colours", "Archived tasks"],
        ]
        for (link, titles) in rows {
            let id = try XCTUnwrap(inventory.deepLinks[link], link)
            for title in titles {
                XCTAssertEqual(landing[title] ?? nil, id, "\"\(title)\" must land on the row \(link) names")
            }
        }
    }

    // MARK: - Parsing

    private static func sources() throws -> [String: String] {
        let files = try FileManager.default.contentsOfDirectory(at: settingsDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        var out: [String: String] = [:]
        for file in files {
            out[file.lastPathComponent] = try String(contentsOf: file, encoding: .utf8)
        }
        XCTAssertNotNil(out["SettingsView.swift"])
        return out
    }

    private static func inventory() throws -> Inventory {
        var inventory = Inventory()
        var sources = try sources()
        let settingsView = try XCTUnwrap(sources["SettingsView.swift"])

        // The search index registers nothing; parse it on its own and keep it out of the rows.
        let start = try XCTUnwrap(settingsView.range(of: indexStart))
        let end = try XCTUnwrap(settingsView.range(of: "\n    }\n", range: start.upperBound..<settingsView.endIndex))
        let index = String(settingsView[start.lowerBound..<end.lowerBound])
        sources["SettingsView.swift"] = String(settingsView[..<start.lowerBound]) + String(settingsView[end.lowerBound...])

        for match in matches(#"static let (\w+) = SettingsTab\.(\w+)\.highlightID\(for: "([^"]+)"\)"#, in: settingsView) {
            inventory.deepLinks[match[1]] = HighlightID(tab: match[2], title: match[3])
        }

        for match in matches(#"SettingsSearchEntry\(tab: \.(\w+), title: "([^"]*)", keywords: \[[^\]]*\], highlightID: ([^\n]*)\),?[ \t]*$"#,
                             in: index) {
            let expression = match[3]
            let highlight: HighlightID?
            if let id = matches(#"^SettingsTab\.(\w+)\.highlightID\(for: "([^"]+)"\)$"#, in: expression).first {
                highlight = HighlightID(tab: id[1], title: id[2])
            } else if let link = matches(#"^SettingsDeepLink\.(\w+)$"#, in: expression).first {
                highlight = try XCTUnwrap(inventory.deepLinks[link[1]], "unknown deep link \(link[1])")
            } else {
                XCTAssertEqual(expression, "nil", "unparsed highlight id for \"\(match[2])\"")
                highlight = nil
            }
            inventory.entries.append(Entry(tab: match[1], title: match[2], highlight: highlight))
        }

        // Each top-level declaration is a region; a type's own `highlightID(_:)` names its tab, and an
        // extension of that type shares it.
        var regions: [(type: String, body: String)] = []
        for text in sources.values {
            let declarations = matchRanges(#"^(?:private |fileprivate )?(?:final )?(?:struct|extension|class|enum) (\w+)"#,
                                           in: text, options: [.anchorsMatchLines])
            for (offset, declaration) in declarations.enumerated() {
                let bodyEnd = offset + 1 < declarations.count ? declarations[offset + 1].range.lowerBound : text.endIndex
                regions.append((declaration.name, String(text[declaration.range.lowerBound..<bodyEnd])))
            }
        }
        var tabByType: [String: String] = [:]
        let helper = #"func highlightID\(_ title: String\) -> String \{\s*(?:SettingsTab\.(\w+)\.highlightID\(for: title\)|"(\w+)-\\\(title\)")\s*\}"#
        for region in regions {
            if let match = matches(helper, in: region.body).first {
                tabByType[region.type] = match[1].isEmpty ? match[2] : match[1]
            }
        }

        for region in regions {
            let tab = tabByType[region.type]
            var found: [HighlightID] = []
            for match in matches(#"(?<![.\w])highlightID\("([^"]+)"\)"#, in: region.body) {
                found.append(HighlightID(tab: tab, title: match[1]))
            }
            for match in matches(#"highlightTitle: "([^"]+)""#, in: region.body) {
                found.append(HighlightID(tab: tab, title: match[1]))
            }
            for match in matches(#"highlightProvider\("([^"]+)"\)"#, in: region.body) {
                found.append(HighlightID(tab: nil, title: match[1]))
            }
            for match in matches(#"settingsHighlight\(id: SettingsTab\.(\w+)\.highlightID\(for: "([^"]+)"\)\)"#, in: region.body) {
                found.append(HighlightID(tab: match[1], title: match[2]))
            }
            for match in matches(#"settingsHighlight\(id: SettingsDeepLink\.(\w+)\)"#, in: region.body) {
                found.append(try XCTUnwrap(inventory.deepLinks[match[1]], "unknown deep link \(match[1])"))
            }
            for id in found {
                inventory.registrations[id, default: 0] += 1
            }
        }
        return inventory
    }

    /// Capture groups of every match (index 0 is the whole match; a group that did not take part is "").
    private static func matches(_ pattern: String, in text: String, options: NSRegularExpression.Options = [.anchorsMatchLines]) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            XCTFail("bad pattern \(pattern)")
            return []
        }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { result in
            (0..<result.numberOfRanges).map { group in
                Range(result.range(at: group), in: text).map { String(text[$0]) } ?? ""
            }
        }
    }

    private static func matchRanges(_ pattern: String, in text: String,
                                    options: NSRegularExpression.Options) -> [(name: String, range: Range<String.Index>)] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            XCTFail("bad pattern \(pattern)")
            return []
        }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { result in
            guard let whole = Range(result.range, in: text), let name = Range(result.range(at: 1), in: text) else { return nil }
            return (String(text[name]), whole)
        }
    }
}
