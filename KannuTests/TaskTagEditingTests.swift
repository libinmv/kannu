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

/// The Tags sheet (Add Tags on a task), one tag at a time: what it offers under the field, and
/// what a pick does. Every tag goes through `TaskItem.cleanedTags`, so the sheet never holds a tag
/// the task would not keep.
final class TaskTagEditingTests: XCTestCase {
    typealias Editing = TaskTagEditing

    private let existing = ["review", "writing", "rework", "work", "urgent"]

    // MARK: - Use or create

    /// Tags in use come first, as "#name"; "Create" follows only when the text is a new tag.
    func testExistingTagsAreUsedAndANewOneIsCreated() {
        XCTAssertEqual(Editing.suggestions(for: "urg", existing: existing, current: []),
                       [.use("urgent"), .create("urg")])
        XCTAssertEqual(Editing.suggestions(for: "urgent", existing: existing, current: []),
                       [.use("urgent")], "an existing tag is never created again")
        XCTAssertEqual(Editing.suggestions(for: "design", existing: existing, current: []),
                       [.create("design")])
        XCTAssertEqual(Editing.Suggestion.use("a").tag, "a")
        XCTAssertEqual(Editing.Suggestion.create("b").tag, "b")
    }

    /// Tags that start with the text first, then those that contain it, each in the given order.
    func testTagsStartingWithTheTextRankFirst() {
        XCTAssertEqual(Editing.suggestions(for: "wo", existing: existing, current: []),
                       [.use("work"), .use("rework"), .create("wo")])
        XCTAssertEqual(Editing.suggestions(for: "re", existing: existing, current: []),
                       [.use("review"), .use("rework"), .create("re")])
    }

    func testTagsAlreadyOnTheTaskAreNeverOffered() {
        XCTAssertEqual(Editing.suggestions(for: "wo", existing: existing, current: ["work"]),
                       [.use("rework"), .create("wo")])
        // Text that is already on the task offers nothing, so Return cannot add "rework" for "work".
        XCTAssertEqual(Editing.suggestions(for: "Work", existing: existing, current: ["work"]), [],
                       "a tag the task has is neither used nor created again")
        XCTAssertEqual(Editing.suggestions(for: "", existing: existing, current: ["review", "writing"]),
                       [.use("rework"), .use("work"), .use("urgent")])
    }

    func testCaseNeverMakesASecondTag() {
        XCTAssertEqual(Editing.suggestions(for: "URGENT", existing: existing, current: []),
                       [.use("urgent")], "the spelling in use wins")
        XCTAssertEqual(Editing.suggestions(for: "", existing: ["Work", "work", "WORK"], current: []),
                       [.use("Work")], "the first spelling, once")
        XCTAssertEqual(Editing.adding("WORK", to: ["work"]), ["work"])
    }

    func testALeadingHashIsDropped() {
        XCTAssertEqual(Editing.suggestions(for: "#urg", existing: existing, current: []),
                       [.use("urgent"), .create("urg")])
        XCTAssertEqual(Editing.suggestions(for: "##design", existing: [], current: []), [.create("design")])
        XCTAssertEqual(Editing.adding("#design", to: ["a"]), ["a", "design"])
        XCTAssertNil(Editing.cleaned("#"), "nothing is left of a lone #")
    }

    // MARK: - Limits

    func testTenTagsIsTheMost() {
        let ten = (1...10).map { "t\($0)" }
        XCTAssertEqual(TaskItem.maxTags, 10)
        XCTAssertEqual(Editing.suggestions(for: "new", existing: existing, current: ten), [], "a full task offers nothing")
        XCTAssertEqual(Editing.suggestions(for: "", existing: existing, current: ten), [])
        XCTAssertEqual(Editing.adding("new", to: ten), ten, "an eleventh tag is never added")
        XCTAssertEqual(Editing.adding("t10", to: Array(ten.prefix(9))), ten)
    }

    func testALongTagIsCutAt24Characters() {
        let long = String(repeating: "x", count: 30)
        let cut = String(repeating: "x", count: 24)
        XCTAssertEqual(TaskItem.maxTagLength, 24)
        XCTAssertEqual(Editing.suggestions(for: long, existing: [], current: []), [.create(cut)])
        XCTAssertEqual(Editing.adding(long, to: []), [cut])
        XCTAssertEqual(Editing.suggestions(for: long, existing: [cut], current: []), [.use(cut)],
                       "the cut text is the tag in use")
    }

    // MARK: - Nothing typed

    func testAnEmptyFieldOffersAFewQuickPicks() {
        let many = ["a", "b", "c", "d", "e", "f", "g"]
        XCTAssertEqual(Editing.suggestions(for: "", existing: many, current: []),
                       many.prefix(Editing.quickPickCount).map(Editing.Suggestion.use))
        XCTAssertEqual(Editing.quickPickCount, 5)
        XCTAssertEqual(Editing.suggestions(for: "  ", existing: many, current: ["a"]),
                       ["b", "c", "d", "e", "f"].map(Editing.Suggestion.use), "blank is empty; the task's own are skipped")
        XCTAssertEqual(Editing.suggestions(for: "", existing: [], current: []), [], "no tags in use, no picks, no Create")
    }

    // MARK: - Return

    /// Return adds a tag in use only when it starts with the text; otherwise the text as typed.
    func testReturnPicksAPrefixMatchOrCreatesTheText() {
        func pick(_ typed: String, current: [String] = []) -> Editing.Suggestion? {
            Editing.returnPick(for: typed, in: Editing.suggestions(for: typed, existing: existing, current: current))
        }
        XCTAssertEqual(pick("urg"), .use("urgent"))
        XCTAssertEqual(pick("URGENT"), .use("urgent"), "the spelling in use wins")
        XCTAssertEqual(pick("view"), .create("view"), "a tag that only contains the text needs a click")
        XCTAssertEqual(pick("design"), .create("design"))
        XCTAssertNil(pick("work", current: ["work"]), "a tag the task has adds nothing")
        XCTAssertNil(pick(""), "an empty field never adds a quick pick")
        XCTAssertNil(pick("new", current: (1...10).map { "t\($0)" }), "a full task adds nothing")
    }

    // MARK: - One at a time

    func testAddingAppendsOneTagAndRemovingTakesItOut() {
        XCTAssertEqual(Editing.adding("b", to: ["a"]), ["a", "b"])
        XCTAssertEqual(Editing.adding("  ", to: ["a"]), ["a"], "nothing typed adds nothing")
        XCTAssertEqual(Editing.removing("A", from: ["a", "b"]), ["b"])
        XCTAssertEqual(Editing.removing("c", from: ["a", "b"]), ["a", "b"])
    }

    // MARK: - Order (the first tag gives the task its colour)

    /// A dragged tag takes the place of the pill it is dropped on: after it when dropped on a later
    /// pill, before it when dropped on an earlier one. Every other tag keeps its order.
    func testMovingPutsTheTagAtTheIndexAndKeepsTheRestInOrder() {
        let tags = ["a", "b", "c", "d"]
        XCTAssertEqual(Editing.moving("a", to: 2, in: tags), ["b", "c", "a", "d"], "onto a later pill: after it")
        XCTAssertEqual(Editing.moving("d", to: 1, in: tags), ["a", "d", "b", "c"], "onto an earlier pill: before it")
        XCTAssertEqual(Editing.moving("b", to: 1, in: tags), tags, "onto itself: nothing moves")
        XCTAssertEqual(Editing.moving("b", to: 2, in: tags), ["a", "c", "b", "d"], "Move Right")
        XCTAssertEqual(Editing.moving("c", to: 1, in: tags), ["a", "c", "b", "d"], "Move Left")
    }

    func testMovingClampsTheIndex() {
        let tags = ["a", "b", "c"]
        XCTAssertEqual(Editing.moving("b", to: 99, in: tags), ["a", "c", "b"], "past the end is the last place")
        XCTAssertEqual(Editing.moving("b", to: -5, in: tags), ["b", "a", "c"], "before the start is the first place")
        XCTAssertEqual(Editing.moving("c", to: 3, in: tags), tags, "the last tag moved right stays last")
        XCTAssertEqual(Editing.moving("a", to: -1, in: tags), tags, "the first tag moved left stays first")
    }

    func testMovingMatchesIgnoringCaseAndKeepsTheTagsSpelling() {
        XCTAssertEqual(Editing.moving("WORK", to: 0, in: ["urgent", "Work"]), ["Work", "urgent"])
        XCTAssertEqual(Editing.movingToFront("work", in: ["a", "b", "Work"]), ["Work", "a", "b"])
    }

    /// Text dropped from elsewhere, or a tag the task does not carry, moves nothing.
    func testMovingATagTheTaskDoesNotCarryChangesNothing() {
        XCTAssertEqual(Editing.moving("zzz", to: 0, in: ["a", "b"]), ["a", "b"])
        XCTAssertEqual(Editing.moving("a", to: 0, in: []), [])
        XCTAssertEqual(Editing.movingToFront("zzz", in: ["a", "b"]), ["a", "b"])
    }

    func testMovingToFrontMakesTheTagFirst() {
        XCTAssertEqual(Editing.movingToFront("c", in: ["a", "b", "c"]), ["c", "a", "b"])
        XCTAssertEqual(Editing.movingToFront("a", in: ["a", "b", "c"]), ["a", "b", "c"], "already first")
    }
}
