import XCTest
@testable import wooloo

final class SpaceProgressTests: XCTestCase {
    private func files(_ progress: [String: (Int, Int, TimeInterval)], askers: [String] = [], bg: [String: TimeInterval] = [:]) -> UnitFiles {
        var f = UnitFiles()
        for (name, v) in progress { f.progress[name] = UnitProgressEntry(items: v.0, done: v.1, updatedAt: v.2) }
        f.askers = askers
        f.backgroundPanes = bg
        return f
    }

    func testNonUnitSpaceIsNotUnit() {
        let s = SpacePillSummary.make(agents: [SpaceAgent(name: "claude", paneID: "p1", status: "working")],
                                      files: UnitFiles(), unreadDone: [], now: 1000)
        XCTAssertFalse(s.isUnitSpace)
        XCTAssertFalse(s.hasPills)
    }

    func testWorkingMeanPercentAndStale() {
        let agents = [SpaceAgent(name: "pawn-a-1", paneID: "p1", status: "working"),
                      SpaceAgent(name: "pawn-a-2", paneID: "p2", status: "working"),
                      SpaceAgent(name: "pawn-a-3", paneID: "p3", status: "working")]
        let f = files(["pawn-a-1": (4, 1, 990), "pawn-a-2": (4, 3, 995), "pawn-a-3": (4, 2, 100)])
        let s = SpacePillSummary.make(agents: agents, files: f, unreadDone: [], now: 1000)
        XCTAssertEqual(s.working, 2)
        XCTAssertEqual(s.workingPercent, 50)
        XCTAssertEqual(s.stale, 1)
    }

    func testDoneNeedsUnreadMarkAndAllTicked() {
        let agents = [SpaceAgent(name: "pawn-a-1", paneID: "p1", status: "idle"),
                      SpaceAgent(name: "pawn-a-2", paneID: "p2", status: "done")]
        let f = files(["pawn-a-1": (2, 2, 1), "pawn-a-2": (2, 2, 1)])
        XCTAssertEqual(SpacePillSummary.make(agents: agents, files: f, unreadDone: ["p1"], now: 1000).done, 1)
        XCTAssertEqual(SpacePillSummary.make(agents: agents, files: f, unreadDone: [], now: 1000).done, 0)
    }

    func testUnfinishedAndBackground() {
        let agents = [SpaceAgent(name: "pawn-a-1", paneID: "p1", status: "idle"),
                      SpaceAgent(name: "pawn-a-2", paneID: "p2", status: "idle")]
        let f = files(["pawn-a-1": (6, 5, 1), "pawn-a-2": (6, 5, 1)], bg: ["p2": 990])
        let s = SpacePillSummary.make(agents: agents, files: f, unreadDone: [], now: 1000)
        XCTAssertEqual(s.unfinished, 1)
        XCTAssertEqual(s.working, 1)
        XCTAssertEqual(s.workingPercent, 83)
        let old = files(["pawn-a-2": (6, 5, 1)], bg: ["p2": 900])
        XCTAssertEqual(SpacePillSummary.make(agents: [agents[1]], files: old, unreadDone: [], now: 1000).unfinished, 1)
    }

    func testWaitingCountsAskersInSpaceOnly() {
        let agents = [SpaceAgent(name: "commander-x", paneID: "p1", status: "idle")]
        let f = files([:], askers: ["commander-x", "commander-x", "commander-other"])
        let s = SpacePillSummary.make(agents: agents, files: f, unreadDone: [], now: 1000)
        XCTAssertTrue(s.isUnitSpace)
        XCTAssertEqual(s.waiting, 2)
    }
}
