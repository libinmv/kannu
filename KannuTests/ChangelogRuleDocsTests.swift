//
//  ChangelogRuleDocsTests.swift
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

/// The CHANGELOG entry shape is documented in several files and parsed by exactly one.
///
/// `.githooks/pre-commit` is the parser and therefore the only source of truth. Every file that tells
/// a human or an agent what an entry looks like is a copy, and this repo has already paid for an
/// unpinned copy twice: `.agents/skills/kannu-senior-contributor/SKILL.md` documented a shape the hook
/// rejects, so every agent following it wrote a commit that could not land (CHANGELOG, 2026-09-13), and
/// `.cursor/rules/feature-changelog.mdc` — `alwaysApply: true`, injected into every Cursor request —
/// had the same defect at the same time and survived the first fix because nobody knew it was there.
///
/// The instinct is to delete the copies and leave one pointer. That is not what this repo's evidence
/// supports. Pointers rot here at the same rate: `CLAUDE.md`'s "CI runs on `main` only" was a
/// pointer-shaped claim that went stale, and `docs/REGRESSIONS.md`'s "read this before touching
/// `Kannu/managers/AgentStatus/`" was a pointer *narrower than the rule it pointed at*, which cost two
/// re-breaks in a file it failed to name. `docs/REGRESSIONS.md` states the actual doctrine: "Prefer a
/// guard to a paragraph. Every invariant below that broke *after* being written down proves prose alone
/// does not hold."
///
/// So the copies stay, and this pins them. A copy checked against the parser is worth more than a
/// pointer checked against nothing.
final class ChangelogRuleDocsTests: XCTestCase {
    // MARK: - Reading the tree

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // KannuTests/
        .deletingLastPathComponent()   // repo root

    private static func read(_ relativePath: String) -> String? {
        try? String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func require(_ relativePath: String) throws -> String {
        try XCTUnwrap(
            Self.read(relativePath),
            "\(relativePath) is missing or unreadable. If it was renamed, update this test — a guard "
                + "that quietly stops finding its subject passes vacuously forever."
        )
    }

    /// Files that document the entry shape and must therefore carry it literally.
    ///
    /// Adding a file here is deliberate. `testNoOtherFileDescribesTheChangelogEntryUnpinned` is what
    /// stops a new copy being born outside this list.
    private static let documenters = [
        "CONTRIBUTING.md",
        "AGENTS.md",
        ".agents/skills/kannu-senior-contributor/SKILL.md",
        ".cursor/rules/feature-changelog.mdc",
    ]

    /// Files that legitimately *discuss* the rule without prescribing it, and so carry no template.
    ///
    /// The distinction is between telling somebody what to write and recording what happened. The
    /// ledger explains why this guard exists; `CHANGELOG.md` is the data the rule describes. Neither is
    /// something an agent would copy a shape out of. Kept deliberately short — the whole point of
    /// `testNoOtherFileDescribesTheChangelogEntryUnpinned` is that a new *instruction* cannot appear
    /// unpinned, so an entry added here should be as suspicious as one added to `documenters`.
    private static let discussers = [
        "CHANGELOG.md",
        "docs/REGRESSIONS.md",
    ]

    // MARK: - A. The parser is the source of truth

    /// Scrapes the keys the hook actually greps for, rather than trusting its own error message.
    private func requiredKeysFromHook(_ hook: String) -> [String] {
        // Matches: grep -q '^- \*\*Developer label:\*\*'
        let pattern = #"grep -q '\^- \\\*\\\*([^:]+):\\\*\\\*'"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(hook.startIndex..<hook.endIndex, in: hook)
        return regex.matches(in: hook, range: range).compactMap { match in
            guard let r = Range(match.range(at: 1), in: hook) else { return nil }
            return "- **\(hook[r]):**"
        }
    }

    func testTheHookStillParsesWhatWeThinkItDoes() throws {
        let hook = try require(".githooks/pre-commit")

        // Anti-vacuous: prove we read the hook and not an empty string or the wrong file.
        XCTAssertGreaterThan(
            hook.count, 5_000,
            "The pre-commit hook scan found almost nothing — check the path, not the rule."
        )
        XCTAssertTrue(hook.contains("has_change_bullet"), "This is not the hook we think it is.")

        // Order and count are pinned on purpose. A fourth required key added to the hook fails here,
        // which is the signal to update every documenting file in the same commit.
        XCTAssertEqual(
            requiredKeysFromHook(hook),
            ["- **Developer label:**", "- **Agent label:**", "- **Changes:**"],
            "The hook's required keys changed. Update `documenters` to match, in this commit."
        )

        // The rest of the shape the hook enforces.
        XCTAssertTrue(hook.contains(#"/^### /"#), "The hook no longer scans for a `### ` heading.")
        XCTAssertTrue(hook.contains(#"^  - "#), "The hook no longer requires an indented change bullet.")

        // The hook's own error heredoc is itself a copy. Pin it to the greps 40 lines below it.
        for key in requiredKeysFromHook(hook) {
            XCTAssertTrue(
                hook.contains(key),
                "The hook greps for \(key) but its error message does not mention it."
            )
        }
    }

    // MARK: - B. Every documenting file carries the literal shape

    /// The fenced blocks of a Markdown file, de-indented by each block's own common leading whitespace.
    ///
    /// De-indenting matters: `CONTRIBUTING.md` and the skill file both nest the template inside a
    /// numbered list, so the keys do not start at column 0 in the raw text.
    private func fencedBlocks(of text: String) -> [String] {
        var blocks: [String] = []
        var current: [String]?
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if let open = current {
                    blocks.append(deindent(open))
                    current = nil
                } else {
                    current = []
                }
                continue
            }
            current?.append(line)
        }
        return blocks
    }

    private func deindent(_ lines: [String]) -> String {
        let indents = lines
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.prefix { $0 == " " || $0 == "\t" }.count }
        let common = indents.min() ?? 0
        return lines.map { String($0.dropFirst(min(common, $0.count))) }.joined(separator: "\n")
    }

    func testEveryDocumentingFileCarriesTheLiteralShape() throws {
        let keys = requiredKeysFromHook(try require(".githooks/pre-commit"))
        XCTAssertEqual(keys.count, 3, "Key extraction failed; the rest of this test would be vacuous.")
        XCTAssertEqual(Self.documenters.count, 4, "The documenter list changed — was that deliberate?")

        for path in Self.documenters {
            let text = try require(path)
            XCTAssertGreaterThan(text.count, 300, "\(path) is suspiciously short.")

            // The keys must start a line *inside a fenced template*, not merely appear in prose.
            let template = fencedBlocks(of: text).first { block in
                keys.allSatisfy { key in
                    block.components(separatedBy: "\n").contains { $0.hasPrefix(key) }
                }
            }

            XCTAssertNotNil(
                template,
                """
                \(path) documents the CHANGELOG entry but no fenced block in it starts lines with all \
                of \(keys.joined(separator: ", ")). `.githooks/pre-commit` greps for those literals, so \
                an agent following this file writes a commit the hook rejects — that has already \
                happened twice. Carry the literal shape, or delete the file and point at AGENTS.md.
                """
            )

            guard let template else { continue }
            let lines = template.components(separatedBy: "\n")
            XCTAssertTrue(
                lines.contains { $0.hasPrefix("### ") },
                "\(path)'s template is missing the `### ` heading line the hook scans for."
            )
            XCTAssertTrue(
                lines.contains { $0.hasPrefix("  - ") },
                "\(path)'s template is missing the indented change bullet the hook requires."
            )
        }
    }

    // MARK: - C. No unpinned copy may be born

    func testNoOtherFileDescribesTheChangelogEntryUnpinned() throws {
        let keys = requiredKeysFromHook(try require(".githooks/pre-commit"))
        XCTAssertEqual(keys.count, 3)

        let fm = FileManager.default
        var scanned: [String] = []
        var offenders: [String] = []

        let enumerator = fm.enumerator(
            at: Self.repoRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        var candidates: [String] = []
        while let url = enumerator?.nextObject() as? URL {
            let path = url.path.replacingOccurrences(of: Self.repoRoot.path + "/", with: "")
            // Skip build products and vendored trees; they are not instructions to anybody.
            if path.hasPrefix(".build") || path.contains("/SourcePackages/") || path.hasPrefix("marketing/") {
                continue
            }
            guard ["md", "mdc"].contains(url.pathExtension) else { continue }
            candidates.append(path)
        }
        // Hidden directories are skipped above, so add the agent namespaces explicitly.
        for hidden in [".agents", ".cursor", ".claude", ".github", ".githooks"] {
            let base = Self.repoRoot.appendingPathComponent(hidden)
            guard let walker = fm.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            while let url = walker.nextObject() as? URL {
                guard ["md", "mdc"].contains(url.pathExtension) else { continue }
                candidates.append(url.path.replacingOccurrences(of: Self.repoRoot.path + "/", with: ""))
            }
        }

        for path in Set(candidates).sorted() {
            if Self.discussers.contains(path) { continue }
            guard let text = Self.read(path) else { continue }
            scanned.append(path)

            // The tell stays deliberately loose — "Developer label" in any form. Narrowing it to the
            // literal key would stop catching the exact defect this exists for: a file that names the
            // three keys in the *wrong* formatting, which is what both broken copies did.
            let describesTheRule = text.contains("Developer label") || text.contains("Agent label")
            guard describesTheRule, !Self.documenters.contains(path) else { continue }
            offenders.append(path)
        }

        XCTAssertGreaterThan(
            scanned.count, 10,
            "The doc scan found almost nothing — check the path, not the rule."
        )
        XCTAssertEqual(
            Self.discussers.count, 2,
            "A file was excused from this guard. That should be as deliberate as adding a documenter."
        )
        for path in Self.discussers {
            XCTAssertNotNil(Self.read(path), "\(path) is excused from this guard but does not exist.")
        }
        XCTAssertTrue(
            offenders.isEmpty,
            """
            These files describe the CHANGELOG entry but are not pinned to the parser: \
            \(offenders.joined(separator: ", ")). Either carry the literal shape and add them to \
            `documenters`, or stop describing the shape and point at AGENTS.md instead. An unpinned \
            copy is how an agent ends up writing commits the hook rejects.
            """
        )
    }

    // MARK: - D. The import that makes AGENTS.md reach Claude Code

    func testClaudeMdImportsAgentsMdAsItsLastLine() throws {
        let claude = try require("CLAUDE.md")
        _ = try require("AGENTS.md")

        let lines = claude.components(separatedBy: "\n")
        let nonEmpty = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        XCTAssertEqual(
            nonEmpty.last, "@AGENTS.md",
            """
            `@AGENTS.md` must be the last non-empty line of CLAUDE.md. Claude Code reads CLAUDE.md and \
            not AGENTS.md, so this import is the only thing that puts the engineering standards in \
            context — and keeping it last is what leaves the ART framework first, where its "before the \
            first tool call" contract needs to be.
            """
        )

        // The split actually happened, and nothing re-duplicated it.
        XCTAssertFalse(
            claude.contains("## Architecture principles"),
            "CLAUDE.md still carries vendor-neutral content that belongs in AGENTS.md."
        )
        let agents = try require("AGENTS.md")
        XCTAssertTrue(agents.contains("## Architecture principles"), "AGENTS.md lost the shared content.")
    }

    // MARK: - E. No phantom imports

    /// `@token` outside backticks and fences is an import to Claude Code, not prose.
    ///
    /// This is a live hazard, not a theoretical one: AGENTS.md carries `@MainActor` twice, inherited
    /// from CLAUDE.md's architecture principles and house conventions. Unbacktick one and Claude Code
    /// tries to import a file named `MainActor`; if a stray token ever resolves outside the working
    /// directory it becomes an approval dialog at startup instead of a silent miss.
    func bareAtTokens(in text: String) -> [String] {
        var stripped: [String] = []
        var inFence = false
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inFence.toggle()
                continue
            }
            if inFence { continue }
            // Drop inline code spans before looking for imports.
            stripped.append(line.replacingOccurrences(
                of: "`[^`]*`", with: "", options: .regularExpression
            ))
        }
        let body = stripped.joined(separator: "\n")
        // A leading boundary that is not a word character keeps email addresses out.
        let pattern = #"(?:^|[\s(\[])@([A-Za-z0-9_./~-]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else {
            return []
        }
        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        return regex.matches(in: body, range: range).compactMap { match in
            Range(match.range(at: 1), in: body).map { String(body[$0]) }
        }
    }

    func testAgentsMdHasNoPhantomImportTokens() throws {
        XCTAssertEqual(
            bareAtTokens(in: try require("AGENTS.md")), [],
            """
            AGENTS.md contains a bare `@token` outside backticks. Claude Code parses that as an import. \
            Wrap property wrappers and attributes in backticks — `@MainActor`, not @MainActor.
            """
        )
    }

    func testClaudeMdImportsOnlyAgentsMd() throws {
        XCTAssertEqual(bareAtTokens(in: try require("CLAUDE.md")), ["AGENTS.md"])
    }

    // MARK: - Self-tests for the scanner

    func testTheScannerIgnoresBacktickedAndFencedTokens() {
        XCTAssertEqual(bareAtTokens(in: "use `@MainActor` here"), [])
        XCTAssertEqual(bareAtTokens(in: "```\n@MainActor\n```"), [])
        XCTAssertEqual(bareAtTokens(in: "```swift\nfunc f() { }\n@Published var x = 1\n```"), [])
    }

    func testTheScannerCatchesAnUnbacktickedToken() {
        XCTAssertEqual(bareAtTokens(in: "use @MainActor here"), ["MainActor"])
        XCTAssertEqual(bareAtTokens(in: "see @docs/REGRESSIONS.md"), ["docs/REGRESSIONS.md"])
        XCTAssertEqual(bareAtTokens(in: "@AGENTS.md"), ["AGENTS.md"])
    }

    func testTheScannerIsNotFooledByEmailAddresses() {
        XCTAssertEqual(bareAtTokens(in: "mail david@example.com"), [])
        XCTAssertEqual(bareAtTokens(in: "a.b@c.d reported it"), [])
    }

    func testTheFenceExtractorDeindentsNestedTemplates() {
        let nested = """
        1. Do this:

           ```markdown
           ### YYYY-MM-DD - title
           - **Developer label:** x
           ```
        """
        let block = fencedBlocks(of: nested).first
        XCTAssertNotNil(block)
        XCTAssertTrue(block?.components(separatedBy: "\n").contains { $0.hasPrefix("- **Developer label:**") } == true)
    }
}
