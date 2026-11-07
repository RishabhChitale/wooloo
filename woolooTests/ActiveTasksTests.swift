import XCTest
@testable import wooloo

final class ActiveTasksTests: XCTestCase {
    private func task(_ id: String, pid: Int32 = 100, started: Double = 1000, space: String? = nil) -> TrackedTask {
        TrackedTask(id: id, label: "Job \(id)", pid: pid, started: started, space: space, cwd: "/work", command: "make")
    }

    func testProcessLivenessFollowsESRCH() {
        XCTAssertTrue(ActiveTasks.isAlive(pid: 5, probe: { _ in (0, 0) }))
        XCTAssertFalse(ActiveTasks.isAlive(pid: 5, probe: { _ in (-1, ESRCH) }))
        XCTAssertTrue(ActiveTasks.isAlive(pid: 5, probe: { _ in (-1, EPERM) }), "alive, but not ours to signal")
        XCTAssertFalse(ActiveTasks.isAlive(pid: 0, probe: { _ in (0, 0) }))
        XCTAssertFalse(ActiveTasks.isAlive(pid: -3, probe: { _ in (0, 0) }))
        XCTAssertTrue(ActiveTasks.isAlive(pid: getpid()), "this process")
    }

    func testLoadingDropsDeadAndBrokenFiles() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/wooloo-tests/tasks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func write(_ name: String, _ json: String) throws {
            try json.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try write("a.json", #"{"id":"a","label":"Alive","pid":10,"started":2000,"space":null,"cwd":"/x","command":"go"}"#)
        try write("b.json", #"{"id":"b","label":"Dead","pid":20,"started":1000,"space":"w1","cwd":null,"command":null}"#)
        try write("c.json", "not json")
        try write("d.txt", #"{"id":"d","label":"Ignored","pid":10,"started":1,"space":null}"#)
        let tasks = ActiveTasks.loadTasks(in: directory, probe: { pid in pid == 20 ? (-1, ESRCH) : (0, 0) })
        XCTAssertEqual(tasks.map(\.id), ["a"])
        XCTAssertEqual(ActiveTasks.loadTasks(in: directory.appendingPathComponent("missing")), [])
    }

    func testSpaceFiltering() {
        let tasks = [task("any"), task("mine", space: "w1"), task("theirs", space: "w2"), task("also", space: "w3")]
        let (shown, others) = ActiveTasks.visible(tasks, selectedSpace: "w1")
        XCTAssertEqual(shown.map(\.id), ["any", "mine"])
        XCTAssertEqual(others, 2)
        let none = ActiveTasks.visible(tasks, selectedSpace: nil)
        XCTAssertEqual(none.shown.map(\.id), ["any"], "no selected Space: only unassigned jobs")
        XCTAssertEqual(none.others, 3)
    }

    func testElapsedFormatting() {
        XCTAssertEqual(ActiveTasks.elapsed(-5), "0s")
        XCTAssertEqual(ActiveTasks.elapsed(42), "42s")
        XCTAssertEqual(ActiveTasks.elapsed(60), "1m")
        XCTAssertEqual(ActiveTasks.elapsed(12 * 60 + 59), "12m")
        XCTAssertEqual(ActiveTasks.elapsed(3600), "1h")
        XCTAssertEqual(ActiveTasks.elapsed(3600 + 3 * 60), "1h 3m")
        XCTAssertEqual(ActiveTasks.elapsed(86_400 + 4 * 3600), "1d 4h")
        XCTAssertEqual(ActiveTasks.elapsed(2 * 86_400), "2d")
    }

    func testGhJSONDecoding() throws {
        let json = """
        [{"databaseId":123,"workflowName":"CI","displayTitle":"Fix it","headBranch":"main",
          "createdAt":"2026-11-07T10:00:00Z","url":"https://github.com/o/r/actions/runs/123"},
         {"databaseId":124,"workflowName":null,"displayTitle":"Bare","headBranch":null,"createdAt":null,"url":null}]
        """
        let runs = try JSONDecoder().decode([CIRun].self, from: Data(json.utf8))
        XCTAssertEqual(runs.map(\.databaseId), [123, 124])
        XCTAssertEqual(runs[0].workflowName, "CI")
        XCTAssertNotNil(ActiveTasks.parseTime(runs[0].createdAt))
        XCTAssertNil(ActiveTasks.parseTime(runs[1].createdAt))
        XCTAssertEqual(ActiveTasks.arguments(repository: "o/r", status: "queued"),
                       ["run", "list", "-R", "o/r", "--status", "queued", "--limit", "20",
                        "--json", "databaseId,workflowName,displayTitle,headBranch,createdAt,url"])
    }

    func testRepositoryListParsing() {
        let text = "# repos\nowner/one\n  Owner/One  \n\nbad line\nowner/two.js\n../etc/passwd\na/b/c\n"
        XCTAssertEqual(ActiveTasks.repositories(inList: text), ["owner/one", "owner/two.js"])
        XCTAssertEqual(ActiveTasks.shortName("owner/one"), "one")
    }

    func testRowsCombineTrackedJobsAndRuns() {
        let runs = [("o/wooloo", CIRun(databaseId: 1, workflowName: "CI", displayTitle: "T", headBranch: "main",
                                       createdAt: "2026-11-07T10:00:00Z", url: "https://github.com/o/wooloo/actions/runs/1")),
                    ("o/wooloo", CIRun(databaseId: 1, workflowName: "CI", displayTitle: "T", headBranch: "main",
                                       createdAt: nil, url: nil)),
                    ("o/x", CIRun(databaseId: 2, workflowName: nil, displayTitle: "Deploy", headBranch: nil,
                                  createdAt: nil, url: "http://insecure.example"))]
        let result = ActiveTasks.rows(tracked: [task("mine", space: "w1"), task("theirs", space: "w2")],
                                      ci: runs, selectedSpace: "w1")
        XCTAssertEqual(result.others, 1)
        XCTAssertEqual(result.rows.map(\.label), ["Job mine", "CI · wooloo", "Deploy · x"], "duplicates once")
        XCTAssertEqual(result.rows.map(\.source), [.tracked, .ci, .ci])
        XCTAssertEqual(result.rows[0].detail, "make\nin /work")
        XCTAssertNotNil(result.rows[1].url)
        XCTAssertNil(result.rows[2].url, "only https links open")
    }
}
