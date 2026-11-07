import XCTest
@testable import wooloo

final class CompanionTests: XCTestCase {
    private let manifestJSON = """
    {"version":1,"size":[64,64],
     "moods":{"working":[{"dir":"working/0","frames":4,"fps":8,"loop":true},
                         {"dir":"working/1","frames":2,"fps":4,"loop":true}],
              "idle":[{"dir":"idle/0","frames":3,"fps":6,"loop":false},
                      {"dir":"../escape","frames":3,"fps":6,"loop":false},
                      {"dir":"idle/zero","frames":0,"fps":6,"loop":false}],
              "done":[{"dir":"done/0","frames":2,"fps":2,"loop":false}],
              "waiting":[]},
     "lines":{"working":["busy"],"idle":["hi","yo"],"done":["yay"],"waiting":[""]}}
    """

    private func manifest() throws -> CompanionManifest {
        try XCTUnwrap(CompanionManifest.decode(Data(manifestJSON.utf8)))
    }

    private func agent(_ name: String?, status: String?, workspace: String? = "w1") -> HerdrAgent {
        let json = """
        {"pane_id":"p-\(name ?? "none")","workspace_id":\(workspace.map { "\"\($0)\"" } ?? "null"),
         "name":\(name.map { "\"\($0)\"" } ?? "null"),"agent_status":\(status.map { "\"\($0)\"" } ?? "null")}
        """
        return try! JSONDecoder().decode(HerdrAgent.self, from: Data(json.utf8))
    }

    func testStatusMapsToMood() {
        XCTAssertEqual(CompanionMood(agentStatus: "working"), .working)
        for status in ["blocked", "needs-input", "needs_input", "request"] {
            XCTAssertEqual(CompanionMood(agentStatus: status), .waiting, status)
        }
        XCTAssertEqual(CompanionMood(agentStatus: "done"), .done)
        for status in ["idle", "unknown", "", nil] { XCTAssertEqual(CompanionMood(agentStatus: status), .idle) }
    }

    func testCommanderIsFoundByNameInTheSelectedSpace() {
        let agents = [agent("claude", status: "working"), agent("commander-2", status: "done", workspace: "w2"),
                      agent("Commander", status: "blocked"), agent(nil, status: "idle")]
        XCTAssertEqual(CompanionMood.commander(in: agents, workspaceID: "w1")?.name, "Commander")
        XCTAssertEqual(CompanionMood.commander(in: agents, workspaceID: "w2")?.name, "commander-2")
        XCTAssertNil(CompanionMood.commander(in: agents, workspaceID: "w3"))
        XCTAssertNil(CompanionMood.commander(in: [agent("commandeer", status: "idle")], workspaceID: "w1"))
    }

    func testManifestDecodingDropsUnusableSequences() throws {
        let manifest = try manifest()
        XCTAssertEqual(manifest.size, [64, 64])
        XCTAssertEqual(manifest.sequences(for: .working).map(\.dir), ["working/0", "working/1"])
        XCTAssertEqual(manifest.sequences(for: .idle).map(\.dir), ["idle/0"], "no parent folders, no empty sequences")
        XCTAssertEqual(manifest.sequences(for: .waiting), [])
        XCTAssertEqual(manifest.lines(for: .waiting), [], "empty lines are ignored")
        XCTAssertNil(CompanionManifest.decode(Data("{}".utf8)))
        XCTAssertNil(CompanionManifest.decode(Data(manifestJSON.replacingOccurrences(of: "\"version\":1", with: "\"version\":2").utf8)))
    }

    func testMissingFolderGivesNoManifest() {
        XCTAssertNil(CompanionManifest.load(from: URL(fileURLWithPath: "/private/tmp/wooloo-no-companion")))
    }

    func testMoodChangeSwitchesImmediately() throws {
        let manifest = try manifest()
        var player = CompanionPlayer()
        let start = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(player.advance(now: start, mood: .idle, manifest: manifest, pick: { _ in 0 }))
        XCTAssertEqual(player.sequence?.dir, "idle/0")
        XCTAssertTrue(player.advance(now: start.addingTimeInterval(0.1), mood: .done, manifest: manifest, pick: { _ in 0 }))
        XCTAssertEqual(player.sequence?.dir, "done/0")
        XCTAssertEqual(player.line, "yay")
    }

    func testOneShotSequenceRotatesWhenItEndsAndHoldsItsLastFrame() throws {
        let manifest = try manifest()
        var player = CompanionPlayer()
        let start = Date(timeIntervalSince1970: 1000)
        player.advance(now: start, mood: .idle, manifest: manifest, pick: { _ in 0 })
        // 3 frames at 6 fps last 0.5 s.
        XCTAssertEqual(player.frameIndex(at: start.addingTimeInterval(0.2)), 1)
        XCTAssertEqual(player.frameIndex(at: start.addingTimeInterval(0.4)), 2)
        XCTAssertEqual(player.frameIndex(at: start.addingTimeInterval(9)), 2)
        XCTAssertFalse(player.advance(now: start.addingTimeInterval(0.4), mood: .idle, manifest: manifest, pick: { _ in 0 }))
        XCTAssertTrue(player.advance(now: start.addingTimeInterval(0.6), mood: .idle, manifest: manifest, pick: { _ in 0 }))
        XCTAssertEqual(player.frameIndex(at: start.addingTimeInterval(0.6)), 0, "it starts over")
    }

    func testLoopsWrapAndRotateEveryFifteenSeconds() throws {
        let manifest = try manifest()
        var player = CompanionPlayer()
        let start = Date(timeIntervalSince1970: 1000)
        player.advance(now: start, mood: .working, manifest: manifest, pick: { _ in 0 })
        XCTAssertEqual(player.sequence?.dir, "working/0")
        XCTAssertEqual(player.frameIndex(at: start.addingTimeInterval(0.5)), 0, "4 frames at 8 fps wrap after 0.5 s")
        XCTAssertFalse(player.advance(now: start.addingTimeInterval(14), mood: .working, manifest: manifest, pick: { _ in 0 }))
        XCTAssertTrue(player.advance(now: start.addingTimeInterval(15), mood: .working, manifest: manifest, pick: { _ in 0 }))
        XCTAssertEqual(player.sequence?.dir, "working/1", "another sequence when there is one")
    }

    func testLinesRotateEveryTwentySecondsAndWorkingShowsTheTitle() throws {
        let manifest = try manifest()
        var player = CompanionPlayer()
        let start = Date(timeIntervalSince1970: 1000)
        player.advance(now: start, mood: .idle, manifest: manifest, pick: { _ in 0 })
        XCTAssertEqual(player.bubbleText(title: "ignored"), "hi")
        player.advance(now: start.addingTimeInterval(19), mood: .idle, manifest: manifest, pick: { _ in 0 })
        XCTAssertEqual(player.bubbleText(title: nil), "hi")
        player.advance(now: start.addingTimeInterval(20), mood: .idle, manifest: manifest, pick: { _ in 0 })
        XCTAssertEqual(player.bubbleText(title: nil), "yo")

        player.advance(now: start.addingTimeInterval(21), mood: .working, manifest: manifest, pick: { _ in 0 })
        XCTAssertEqual(player.bubbleText(title: "  fixing tests \n"), "fixing tests")
        XCTAssertEqual(player.bubbleText(title: "  "), "busy")
        XCTAssertEqual(player.bubbleText(title: nil), "busy")
    }

    func testMoodWithoutSequencesShowsNothing() throws {
        var player = CompanionPlayer()
        player.advance(now: Date(), mood: .waiting, manifest: try manifest(), pick: { _ in 0 })
        XCTAssertNil(player.sequence)
        XCTAssertNil(player.bubbleText(title: nil))
        XCTAssertEqual(player.frameIndex(at: Date()), 0)
    }
}
