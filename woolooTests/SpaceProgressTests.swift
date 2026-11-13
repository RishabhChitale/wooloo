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

final class SpaceCategoryTests: XCTestCase {
    private func space(_ id: String, _ label: String) -> HerdrWorkspace {
        HerdrWorkspace(workspaceID: id, label: label, agentStatus: nil, activeTabID: nil, worktree: nil)
    }

    func testAutomaticCategoriesForCurrentSpaces() {
        let expected: [String: SpaceCategory] = [
            "Rishabh": .claude, "Claude Skill Testing": .claude,
            "Playbox-server": .creative, "SuperIntellegence": .creative, "BPM Checker app": .creative,
            "Upscayl Fork": .creative, "Smart Video Library": .creative,
            "options-trading": .finance, "Finance deep dive": .finance, "Budgeting": .finance, "Investing": .finance,
            "Learn Canto": .misc,
            "Study Central": .school, "ECN104 Midterm 2": .school, "MTH131": .school,
        ]
        for (label, category) in expected {
            XCTAssertEqual(SpaceCategory.automatic(for: label), category, label)
        }
    }

    func testKeywordsMatchWordStartsOnly() {
        XCTAssertEqual(SpaceCategory.automatic(for: "Restart scripts"), .misc)   // "art" inside a word does not count
        XCTAssertEqual(SpaceCategory.automatic(for: "art board"), .creative)
    }

    func testGroupsInOrderAndKeepSpaceOrder() {
        let spaces = [space("w1", "Learn Canto"), space("w2", "options-trading"), space("w3", "Playbox-server"),
                      space("w4", "Rishabh"), space("w5", "Upscayl Fork"), space("w6", "Claude Skill Testing")]
        let groups = SpaceCategory.grouped(spaces, overrides: [:])
        XCTAssertEqual(groups.map(\.category), [.claude, .creative, .finance, .misc])
        XCTAssertEqual(groups[0].spaces.map(\.workspaceID), ["w4", "w6"])
        XCTAssertEqual(groups[1].spaces.map(\.workspaceID), ["w3", "w5"])
    }

    func testOverridesPinAndClear() {
        var raw = SpaceCategory.setting(.finance, for: "Learn Canto", in: "")
        XCTAssertEqual(SpaceCategory.category(for: "learn canto", overrides: SpaceCategory.decodeOverrides(raw)), .finance)
        raw = SpaceCategory.setting(.misc, for: "Learn Canto", in: raw)      // same as automatic: pin removed
        XCTAssertEqual(raw, "")
        raw = SpaceCategory.setting(.creative, for: "Learn Canto", in: raw)
        raw = SpaceCategory.setting(nil, for: "Learn Canto", in: raw)
        XCTAssertEqual(SpaceCategory.decodeOverrides(raw), [:])
        XCTAssertEqual(SpaceCategory.decodeOverrides("not json"), [:])
    }

    func testCollapsedToggle() {
        var raw = SpaceCategory.toggling(.finance, in: "")
        raw = SpaceCategory.toggling(.claude, in: raw)
        XCTAssertEqual(raw, "claude,finance")
        XCTAssertEqual(SpaceCategory.decodeCollapsed(raw), [.claude, .finance])
        XCTAssertEqual(SpaceCategory.toggling(.claude, in: raw), "finance")
        XCTAssertEqual(SpaceCategory.decodeCollapsed("bogus,misc"), [.misc])
    }

    func testCategoryColorsSetClearAndIgnoreJunk() {
        var raw = SpaceCategoryColor.setting(.green, for: .finance, in: "")
        raw = SpaceCategoryColor.setting(.blue, for: .claude, in: raw)
        XCTAssertEqual(raw, "claude=blue,finance=green")
        XCTAssertEqual(SpaceCategoryColor.decode(raw), [.claude: .blue, .finance: .green])
        raw = SpaceCategoryColor.setting(nil, for: .claude, in: raw)
        XCTAssertEqual(raw, "finance=green")
        XCTAssertEqual(SpaceCategoryColor.decode("misc=chartreuse,bogus=red,creative=pink"), [.creative: .pink])
    }
}
