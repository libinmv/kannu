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

/// What the Task list filters on, worked out from a task alone: project, status, tags, and the
/// filter match; plus the tags and schedule a task now carries, and the fields a sync adds.
final class TaskFacetsTests: XCTestCase {
    typealias Facets = TaskFacets

    private func remote(_ key: String, category: String? = nil, kind: GitLabKind? = nil,
                        projectID: Int? = nil, labels: [String]? = nil) -> RemoteTaskInfo {
        RemoteTaskInfo(remoteID: key, key: key, hostScope: "h", status: "", isDoneRemotely: false,
                       gitlabProjectID: projectID, lastSeenAt: Date(timeIntervalSince1970: 0),
                       gitlabKind: kind, statusCategory: category, labels: labels)
    }

    private func jira(_ key: String, category: String? = nil, tags: [String] = []) -> TaskItem {
        TaskItem(source: .jira, title: key, remote: remote(key, category: category), tags: tags)
    }

    private func gitlab(_ key: String, kind: GitLabKind = .issue, category: String? = nil, projectID: Int? = 8) -> TaskItem {
        TaskItem(source: .gitlab, title: key, remote: remote(key, category: category, kind: kind, projectID: projectID))
    }

    private func local(_ title: String, timed: Bool = false, tags: [String] = []) -> TaskItem {
        let segments = timed ? [WorkSegment(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 60), origin: .timer)] : []
        return TaskItem(title: title, segments: segments, tags: tags)
    }

    // MARK: - Project

    func testTheProjectComesFromTheKey() {
        XCTAssertEqual(Facets.project(for: jira("PROJ-123")), "PROJ")
        XCTAssertEqual(Facets.project(for: jira("AB2-7")), "AB2")
        XCTAssertEqual(Facets.project(for: gitlab("group/app#45")), "group/app")
        XCTAssertEqual(Facets.project(for: gitlab("group/sub/app!12", kind: .mergeRequest)), "group/sub/app")
        XCTAssertEqual(Facets.project(for: gitlab("#3", projectID: 9)), "#project:9", "an old server: the project id, as a key")
        XCTAssertEqual(Facets.projectName("#project:9"), String(localized: "Project \(9)"), "shown as a name")
        XCTAssertEqual(Facets.projectName("group/app"), "group/app")
        XCTAssertEqual(Facets.projectName("#project:x"), "#project:x")
        XCTAssertNil(Facets.project(for: gitlab("#3", projectID: nil)))
        XCTAssertNil(Facets.project(for: local("Write")), "a local task has no project")
        XCTAssertNil(Facets.project(for: jira("NODASH")))
    }

    // MARK: - Status

    /// A row caption reads GitLab's lower-case states as words ("Open", not "opened"); Jira's own
    /// status names stay as Jira sent them.
    func testTheStatusReadsAsAWord() {
        func task(_ source: TaskSource, status: String) -> TaskItem {
            let info = RemoteTaskInfo(remoteID: "1", key: "K-1", hostScope: "h", status: status, isDoneRemotely: false,
                                      lastSeenAt: Date(timeIntervalSince1970: 0))
            return TaskItem(source: source, title: "t", remote: info)
        }
        XCTAssertEqual(Facets.statusName(for: task(.gitlab, status: "opened")), String(localized: "Open"))
        XCTAssertEqual(Facets.statusName(for: task(.gitlab, status: "merged")), String(localized: "Merged"))
        XCTAssertEqual(Facets.statusName(for: task(.gitlab, status: "review requested")), "Review requested")
        XCTAssertEqual(Facets.statusName(for: task(.jira, status: "in review")), "in review", "Jira's names are verbatim")
        XCTAssertNil(Facets.statusName(for: task(.gitlab, status: "")))
        XCTAssertNil(Facets.statusName(for: local("Write")))
    }

    func testTheStatusComesFromTheCategory() {
        XCTAssertEqual(Facets.status(for: jira("A-1", category: "new")), .toDo)
        XCTAssertEqual(Facets.status(for: jira("A-1", category: "indeterminate")), .inProgress)
        XCTAssertEqual(Facets.status(for: jira("A-1")), .toDo, "a file written before categories")
        XCTAssertEqual(Facets.status(for: gitlab("g/a!1", kind: .mergeRequest)), .inProgress, "an old merge request")
        XCTAssertEqual(Facets.status(for: gitlab("g/a#1")), .toDo)
        XCTAssertEqual(Facets.status(for: local("Write")), .toDo)
        XCTAssertEqual(Facets.status(for: local("Write", timed: true)), .inProgress, "a local task with recorded time")
    }

    func testAGitLabItemsCategory() {
        XCTAssertEqual(Facets.gitlabCategory(kind: .mergeRequest, labels: []), "indeterminate")
        XCTAssertEqual(Facets.gitlabCategory(kind: .issue, labels: ["bug"]), "new")
        for label in ["In progress", "in-progress", "Doing", "WIP", "workflow::in_progress", "status::doing"] {
            XCTAssertEqual(Facets.gitlabCategory(kind: .issue, labels: ["bug", label]), "indeterminate", label)
        }
        for label in ["progress", "doing-later", "wipe", "in progress soon"] {
            XCTAssertFalse(Facets.isInProgressLabel(label), label)
        }
    }

    func testKeptLabelsAreBounded() {
        let many = (1...30).map { "label \($0)" }
        XCTAssertEqual(Facets.keptLabels(many).count, 20)
        XCTAssertEqual(Facets.keptLabels([String(repeating: "x", count: 80), "  ", "a\nb"]),
                       [String(repeating: "x", count: 50), "a b"])
    }

    // MARK: - Matching

    func testEachFilterNarrows() {
        let tasks = [
            jira("PROJ-1", category: "new", tags: ["Urgent"]),
            jira("PROJ-2", category: "indeterminate"),
            jira("OPS-3", category: "new"),
            gitlab("group/app#4"),
            gitlab("group/app!5", kind: .mergeRequest, category: "indeterminate"),
            local("Write", tags: ["writing"]),
            local("Review", timed: true, tags: ["urgent"]),
        ]
        func titles(_ filter: TaskFilter) -> [String] {
            tasks.filter { Facets.matches($0, filter: filter) }.map(\.title)
        }
        XCTAssertEqual(titles(.all).count, tasks.count)
        XCTAssertEqual(titles(TaskFilter(source: .jira)), ["PROJ-1", "PROJ-2", "OPS-3"])
        XCTAssertEqual(titles(TaskFilter(source: .gitlab)), ["group/app#4", "group/app!5"])
        XCTAssertEqual(titles(TaskFilter(source: .local)), ["Write", "Review"])
        XCTAssertEqual(titles(TaskFilter(project: "PROJ")), ["PROJ-1", "PROJ-2"])
        XCTAssertEqual(titles(TaskFilter(project: Facets.noProject)), ["Write", "Review"])
        XCTAssertEqual(titles(TaskFilter(status: .inProgress)), ["PROJ-2", "group/app!5", "Review"])
        XCTAssertEqual(titles(TaskFilter(status: .toDo)), ["PROJ-1", "OPS-3", "group/app#4", "Write"])
        XCTAssertEqual(titles(TaskFilter(tag: "urgent")), ["PROJ-1", "Review"], "tags match ignoring case")
        XCTAssertEqual(titles(TaskFilter(source: .jira, status: .toDo, tag: "URGENT")), ["PROJ-1"], "filters combine")
        XCTAssertEqual(titles(TaskFilter(project: "Gone")), [])
        XCTAssertFalse(TaskFilter.all.isNarrowing)
        XCTAssertTrue(TaskFilter(tag: "x").isNarrowing)
    }

    func testAProjectFilterSavedAsALabelStillWorks() {
        let tasks = [gitlab("#3", projectID: 9), gitlab("#4", projectID: 10), jira("PROJ-1")]
        let stored = Facets.normalizedProjectFilter("Project 9")
        XCTAssertEqual(stored, "#project:9")
        XCTAssertEqual(tasks.filter { Facets.matches($0, filter: TaskFilter(project: stored)) }.map(\.title), ["#3"])
        for unchanged in [Facets.anyProject, Facets.noProject, "PROJ", "group/app", "#project:9", "Project", "Project x", "Project -1"] {
            XCTAssertEqual(Facets.normalizedProjectFilter(unchanged), unchanged, unchanged)
        }
    }

    func testWhatTheFiltersOffer() {
        let tasks = [jira("proj-1"), jira("OPS-2"), gitlab("group/app#4"), local("Write", tags: ["writing", "Urgent"]),
                     local("Review", tags: ["urgent", "alpha"])]
        XCTAssertEqual(Facets.projects(in: tasks), ["group/app", "OPS", "proj"], "sorted ignoring case")
        XCTAssertTrue(Facets.hasTaskWithoutProject(in: tasks))
        XCTAssertFalse(Facets.hasTaskWithoutProject(in: [jira("A-1")]))
        XCTAssertEqual(Facets.tags(in: tasks), ["alpha", "Urgent", "writing"], "first spelling, sorted, once each")
        let counts = Facets.counts([jira("A-1", category: "indeterminate"), local("x"), local("y", timed: true)])
        XCTAssertEqual(counts.toDo, 1)
        XCTAssertEqual(counts.inProgress, 2)
    }

    func testAFilteredMoveCountsTheRowsShown() {
        // On screen with Source Jira and Status To Do: A-1, C-3. B-2 is in progress, w is local.
        let list = [jira("A-1", category: "new"), local("w"), jira("B-2", category: "indeterminate"), jira("C-3", category: "new")]
        let listed = Facets.listed({ _ in true }, filter: TaskFilter(source: .jira, status: .toDo))
        let id = { (title: String) in list.first { $0.title == title }!.id }
        XCTAssertEqual(TaskOrdering.movingUp(id("C-3"), in: list, listed: listed).map(\.title), ["C-3", "A-1", "w", "B-2"])
        XCTAssertEqual(TaskOrdering.move(id: id("A-1"), onto: id("C-3"), in: list, listed: listed).map(\.title),
                       ["w", "B-2", "C-3", "A-1"], "dropped down: after the target, the hidden rows keep their order")
        XCTAssertEqual(TaskOrdering.move(id: id("A-1"), onto: id("B-2"), in: list, listed: listed).map(\.title),
                       list.map(\.title), "a row the filter hides is no drop target")
        XCTAssertEqual(TaskOrdering.active(list, listed: listed).map(\.title), ["A-1", "C-3"])
    }

    // MARK: - Tags

    func testTagsAreCleaned() {
        XCTAssertEqual(TaskItem.cleanedTags(["  #writing ", "Writing", "urgent", "", "##", "two  words"]),
                       ["writing", "urgent", "two words"], "trimmed, no #, first spelling only, empties dropped")
        XCTAssertEqual(TaskItem.cleanedTags([String(repeating: "a", count: 40)]), [String(repeating: "a", count: 24)])
        XCTAssertEqual(TaskItem.cleanedTags((1...15).map { "t\($0)" }).count, TaskItem.maxTags)
        XCTAssertEqual(TaskItem.parsedTags("writing, #urgent,,Writing"), ["writing", "urgent"])
    }

    // MARK: - Coding

    func testTagsScheduleAndCategoriesReadBack() throws {
        let due = Date(timeIntervalSince1970: 1_800_000_000)
        let file = TasksFile(tasks: [
            TaskItem(title: "Write", createdAt: Date(timeIntervalSince1970: 0), tags: ["writing"], scheduledAt: due),
            TaskItem(source: .gitlab, title: "Fix", remote: remote("g/a#1", category: "indeterminate", kind: .issue,
                                                                  projectID: 8, labels: ["doing"]),
                     createdAt: Date(timeIntervalSince1970: 0), tags: ["urgent"]),
        ], drafts: [])
        let data = try TasksFile.makeEncoder().encode(file)
        XCTAssertEqual(try TasksFile.makeDecoder().decode(TasksFile.self, from: data), file)
    }

    func testAFileWrittenBeforeTagsStillReads() throws {
        let json = """
        {"version": 1, "drafts": [], "tasks": [
          {"id": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "title": "Old", "source": "jira",
           "remote": {"remoteID": "1", "key": "A-1", "hostScope": "h", "status": "To Do", "isDoneRemotely": false,
                      "lastSeenAt": "2026-01-01T00:00:00Z"}}
        ]}
        """
        let task = try XCTUnwrap(try TasksFile.makeDecoder().decode(TasksFile.self, from: Data(json.utf8)).tasks.first)
        XCTAssertEqual(task.tags, [])
        XCTAssertNil(task.scheduledAt)
        XCTAssertNil(task.remote?.statusCategory)
        XCTAssertNil(task.remote?.labels)
    }

    func testOddTagsAndLabelsNeverCostTheFile() throws {
        let json = """
        {"version": 1, "drafts": [], "tasks": [
          {"id": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "title": "Odd", "tags": "not a list", "scheduledAt": 7,
           "remote": {"remoteID": "1", "key": "g/a#1", "hostScope": "h", "status": "", "isDoneRemotely": false,
                      "lastSeenAt": "2026-01-01T00:00:00Z", "labels": [1, 2], "statusCategory": {"key": "new"}}},
          {"id": "7F9619FF-8B86-D011-B42D-00C04FC964FF", "title": "Many tags",
           "tags": ["a", "A", " #b ", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l"]}
        ]}
        """
        let tasks = try TasksFile.makeDecoder().decode(TasksFile.self, from: Data(json.utf8)).tasks
        XCTAssertEqual(tasks.count, 2)
        XCTAssertEqual(tasks[0].tags, [])
        XCTAssertNil(tasks[0].scheduledAt)
        XCTAssertNil(tasks[0].remote?.labels)
        XCTAssertNil(tasks[0].remote?.statusCategory)
        XCTAssertEqual(tasks[1].tags, ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j"], "cleaned on read too")
    }

    // MARK: - Sources

    func testASyncCarriesTheCategoryAndLabels() throws {
        let jiraIssue = try JSONDecoder().decode(JiraIssue.self, from: Data("""
            {"id": "10", "key": "PROJ-1", "fields": {"summary": "S", "status": {"name": "In Review", "statusCategory": {"key": "indeterminate"}}}}
            """.utf8))
        XCTAssertEqual(JiraAPI.remoteIssue(from: jiraIssue).statusCategory, "indeterminate")

        let items = try XCTUnwrap(GitLabAPI.decodeItems(Data("""
            [{"id": 1, "iid": 1, "project_id": 8, "state": "opened", "labels": ["bug", "workflow::doing"]},
             {"id": 2, "iid": 2, "project_id": 8, "state": "opened", "labels": [{"name": "detailed"}]},
             {"id": 3, "iid": 3, "project_id": 8, "state": "opened"}]
            """.utf8)))
        XCTAssertEqual(items.count, 3, "an unexpected labels shape never costs the item")
        let doing = GitLabAPI.remoteIssue(from: items[0], kind: .issue, base: "https://gitlab.com", reviewRequested: false)
        XCTAssertEqual(doing.labels, ["bug", "workflow::doing"])
        XCTAssertEqual(doing.statusCategory, "indeterminate")
        let odd = GitLabAPI.remoteIssue(from: items[1], kind: .issue, base: "https://gitlab.com", reviewRequested: false)
        XCTAssertEqual(odd.labels, [])
        XCTAssertEqual(odd.statusCategory, "new")
        let mr = GitLabAPI.remoteIssue(from: items[2], kind: .mergeRequest, base: "https://gitlab.com", reviewRequested: true)
        XCTAssertEqual(mr.statusCategory, "indeterminate")

        var issue = RemoteIssue(remoteID: "10", key: "PROJ-1", title: "S", status: "In Review", isDoneRemotely: false)
        issue.statusCategory = "new"
        let first = TaskMerge.apply(.fetched(RemoteFetch(issues: [issue], complete: true)), source: .jira, hostScope: "h",
                                    to: [], now: Date(), keepingActive: [])
        XCTAssertEqual(first.tasks.first?.remote?.statusCategory, "new")
        var tagged = first.tasks
        tagged[0].tags = ["mine"]
        issue.statusCategory = "indeterminate"
        let second = TaskMerge.apply(.fetched(RemoteFetch(issues: [issue], complete: true)), source: .jira, hostScope: "h",
                                     to: tagged, now: Date(), keepingActive: [])
        XCTAssertEqual(second.tasks.first?.remote?.statusCategory, "indeterminate", "a sync refreshes the category")
        XCTAssertEqual(second.tasks.first?.tags, ["mine"], "and keeps the user's tags")
        XCTAssertEqual(second.updated, 1)
    }
}
