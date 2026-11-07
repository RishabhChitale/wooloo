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

    // MARK: Background

    private func manifestJSON(extra: String) -> Data {
        Data("""
        {"version":1,"size":[64,64],"moods":{"idle":[{"dir":"idle/0","frames":1,"fps":1,"loop":true}]},
         "lines":{"idle":["hi"]}\(extra)}
        """.utf8)
    }

    func testBackgroundAndSpriteRectDecode() throws {
        let manifest = try XCTUnwrap(CompanionManifest.decode(manifestJSON(extra:
            #","background":{"default":"bg/day.png","night":"bg/night.png"},"sprite_rect":[10,20,300,200]"#)))
        XCTAssertEqual(manifest.background, CompanionBackground(defaultPath: "bg/day.png", night: "bg/night.png"))
        XCTAssertEqual(manifest.spriteRect, [10, 20, 300, 200])
        let plain = try XCTUnwrap(CompanionManifest.decode(manifestJSON(extra: "")))
        XCTAssertNil(plain.background)
        XCTAssertNil(plain.spriteRect)
    }

    func testBackgroundNeedsASafePathAndARect() throws {
        let escaping = try XCTUnwrap(CompanionManifest.decode(manifestJSON(extra:
            #","background":{"default":"../x.png"},"sprite_rect":[0,0,10,10]"#)))
        XCTAssertNil(escaping.background)
        XCTAssertNil(escaping.spriteRect)
        let noRect = try XCTUnwrap(CompanionManifest.decode(manifestJSON(extra: #","background":{"default":"bg/x.png"}"#)))
        XCTAssertNil(noRect.background)
        let badRect = try XCTUnwrap(CompanionManifest.decode(manifestJSON(extra:
            #","background":{"default":"bg/x.png"},"sprite_rect":[0,0,0,10]"#)))
        XCTAssertNil(badRect.background)
    }

    func testNightBackgroundBetweenEightAndSix() throws {
        for hour in [20, 23, 0, 5] { XCTAssertTrue(CompanionBackground.isNight(hour: hour), "\(hour)") }
        for hour in [6, 12, 19] { XCTAssertFalse(CompanionBackground.isNight(hour: hour), "\(hour)") }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day = Date(timeIntervalSince1970: 1_700_000_000 - 1_700_000_000 % 86_400 + 12 * 3600)
        let night = day.addingTimeInterval(9 * 3600)
        let both = try XCTUnwrap(CompanionManifest.decode(manifestJSON(extra:
            #","background":{"default":"d.png","night":"n.png"},"sprite_rect":[0,0,1,1]"#)))
        XCTAssertEqual(both.backgroundPath(at: day, calendar: calendar), "d.png")
        XCTAssertEqual(both.backgroundPath(at: night, calendar: calendar), "n.png")
        let dayOnly = try XCTUnwrap(CompanionManifest.decode(manifestJSON(extra:
            #","background":{"default":"d.png"},"sprite_rect":[0,0,1,1]"#)))
        XCTAssertEqual(dayOnly.backgroundPath(at: night, calendar: calendar), "d.png", "no night variant")
    }

    // MARK: Dialogue

    func testMarkdownIsStripped() {
        let markdown = """
        ## Plan

        - **Fix** the `build` first
        1. See [the docs](https://example.com/a) now
        > quoted *text*

        ```swift
        let secret = 1
        ```
        Done   with   spaces.
        """
        XCTAssertEqual(CompanionDialogue.stripMarkdown(markdown),
                       "Plan\nFix the build first\nSee the docs now\nquoted text\nDone with spaces.")
    }

    func testSentencesSplitOnPunctuationAndLines() {
        XCTAssertEqual(CompanionDialogue.sentences(fromMarkdown: "Hello there. It is 3.5 now! Ready?"),
                       ["Hello there.", "It is 3.5 now!", "Ready?"])
        XCTAssertEqual(CompanionDialogue.sentences(fromMarkdown: "- one\n- two"), ["one", "two"])
        XCTAssertEqual(CompanionDialogue.sentences(fromMarkdown: ""), [])
    }

    func testSentencePicksFollowTheMood() {
        let sentences = ["First thing.", "Should I go on?", "Last thing."]
        XCTAssertEqual(CompanionDialogue.pick(mood: .working, sentences: sentences), "Last thing.")
        XCTAssertEqual(CompanionDialogue.pick(mood: .waiting, sentences: sentences), "Should I go on?")
        XCTAssertEqual(CompanionDialogue.pick(mood: .waiting, sentences: ["A.", "B."]), "B.")
        XCTAssertEqual(CompanionDialogue.pick(mood: .done, sentences: sentences), "First thing.")
        XCTAssertEqual(CompanionDialogue.pick(mood: .idle, sentences: sentences), "First thing.")
        XCTAssertNil(CompanionDialogue.pick(mood: .idle, sentences: []))
    }

    func testLongSentencesAreCappedWithAnEllipsis() throws {
        let long = String(repeating: "word ", count: 60)
        let picked = try XCTUnwrap(CompanionDialogue.pick(mood: .idle, sentences: [long]))
        XCTAssertLessThanOrEqual(picked.count, CompanionDialogue.maximumLength)
        XCTAssertTrue(picked.hasSuffix("…"))
        XCTAssertEqual(CompanionDialogue.pick(mood: .idle, sentences: ["Short."]), "Short.")
    }

    private func record(_ type: String, _ parts: [[String: Any]]) -> String {
        let object: [String: Any] = ["type": type, "message": ["content": parts]]
        return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    func testTailParsingTakesTheNewestAssistantText() throws {
        let lines = [
            record("assistant", [["type": "text", "text": "Old reply."]]),
            record("assistant", [["type": "text", "text": "Newest reply."], ["type": "tool_use", "name": "Bash"]]),
            record("assistant", [["type": "tool_use", "name": "Bash"]]),
            record("user", [["type": "text", "text": "User words."]]),
            "{\"type\":\"summary\"}",
            "not json at all",
        ]
        let data = Data(lines.joined(separator: "\n").utf8)
        XCTAssertEqual(CompanionDialogue.latestAssistantText(inTail: data, startsMidFile: false), "Newest reply.")
    }

    func testTailParsingDropsTheFirstPartialLine() {
        let partial = "tial\",\"type\":\"assistant\"}"
        let data = Data((partial + "\n" + record("assistant", [["type": "text", "text": "Whole."]])).utf8)
        XCTAssertEqual(CompanionDialogue.latestAssistantText(inTail: data, startsMidFile: true), "Whole.")
        let onlyPartial = Data("\"type\":\"assistant\"}".utf8)
        XCTAssertNil(CompanionDialogue.latestAssistantText(inTail: onlyPartial, startsMidFile: true))
        XCTAssertNil(CompanionDialogue.latestAssistantText(inTail: Data(), startsMidFile: false))
    }

    func testBubbleFallsBackToTitleAndThenToLines() throws {
        let manifest = try manifest()
        var player = CompanionPlayer()
        player.advance(now: Date(), mood: .working, manifest: manifest, pick: { _ in 0 })
        XCTAssertEqual(player.bubbleText(dialogue: "Real words.", title: "fixing tests"), "Real words.")
        XCTAssertEqual(player.bubbleText(dialogue: nil, title: "fixing tests"), "fixing tests")
        XCTAssertEqual(player.bubbleText(dialogue: "", title: nil), "busy")
    }

    func testAgentSessionIDDecodesOnlyIDKinds() throws {
        let withID = #"{"pane_id":"p","agent_session":{"agent":"claude","kind":"id","value":"abc-123"}}"#
        let other = #"{"pane_id":"p","agent_session":{"agent":"claude","kind":"path","value":"/x"}}"#
        let none = #"{"pane_id":"p"}"#
        XCTAssertEqual(try JSONDecoder().decode(HerdrAgent.self, from: Data(withID.utf8)).agentSessionID, "abc-123")
        XCTAssertNil(try JSONDecoder().decode(HerdrAgent.self, from: Data(other.utf8)).agentSessionID)
        XCTAssertNil(try JSONDecoder().decode(HerdrAgent.self, from: Data(none.utf8)).agentSessionID)
    }

    func testReaderFindsTheTranscriptAndRejectsOddIDs() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/wooloo-tests/companion-\(UUID().uuidString)")
        let project = root.appendingPathComponent("-some-project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = record("assistant", [["type": "text", "text": "Hello from the file."]]) + "\n"
        try transcript.write(to: project.appendingPathComponent("abc-123.jsonl"), atomically: true, encoding: .utf8)

        let reader = CompanionTranscriptReader(projects: root)
        let now = Date()
        let text = await reader.latestText(sessionID: "abc-123", now: now)
        XCTAssertEqual(text, "Hello from the file.")
        let missing = await reader.latestText(sessionID: "nope-1", now: now)
        XCTAssertNil(missing)
        let escaping = await reader.latestText(sessionID: "../abc-123", now: now)
        XCTAssertNil(escaping)
        XCTAssertTrue(CompanionTranscriptReader.isSessionID("dd3aa0e6-9434-4efa-b41a-609228983b0d"))
        XCTAssertFalse(CompanionTranscriptReader.isSessionID("a/b"))
        XCTAssertFalse(CompanionTranscriptReader.isSessionID(""))
    }
}
