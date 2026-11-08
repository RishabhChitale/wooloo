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
        let noon: Int = 1_700_000_000 - 1_700_000_000 % 86_400 + 12 * 3600
        let day = Date(timeIntervalSince1970: TimeInterval(noon))
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

    // MARK: Activities

    private func activityManifest() throws -> CompanionManifest {
        let json = """
        {"version":1,"size":[64,64],
         "moods":{"idle":[{"dir":"idle/0","frames":2,"fps":2,"loop":true}],
                  "working":[{"dir":"working/0","frames":2,"fps":2,"loop":true}],
                  "game":[{"dir":"game/0","frames":2,"fps":2,"loop":true}]},
         "lines":{},
         "activities":[{"id":"idle","label":"Idle","icon":"activities/idle.png","mood":"idle"},
                       {"id":"game","label":"Game","icon":"activities/game.png","mood":"game"},
                       {"id":"stream","label":"Stream","icon":"activities/stream.png","mood":"stream_watch"},
                       {"id":"soon","label":"Soon","icon":"activities/soon.png","mood":null},
                       {"id":"bad","label":"Bad","icon":"../x.png","mood":"game"},
                       {"label":"No id"}],
         "stickers":[{"id":"ok","label":"OK","image":"stickers/ok.png"},{"id":"broken"}],
         "font":"font/pixel.ttf"}
        """
        return try XCTUnwrap(CompanionManifest.decode(Data(json.utf8)))
    }

    func testActivitiesAndStickersDecodeLeniently() throws {
        let manifest = try activityManifest()
        XCTAssertEqual(manifest.activities.map(\.id), ["idle", "game", "stream", "soon"], "broken and unsafe ones are skipped")
        XCTAssertNil(manifest.activity(id: "soon")?.mood)
        XCTAssertEqual(manifest.stickers.map(\.label), ["OK"])
        XCTAssertEqual(manifest.font, "font/pixel.ttf")
        let plain = try XCTUnwrap(CompanionManifest.decode(manifestJSON(extra: "")))
        XCTAssertEqual(plain.activities, [])
        XCTAssertEqual(plain.stickers, [])
        XCTAssertNil(plain.font)
    }

    func testChosenActivityPlaysOnlyWhenTheCommanderIsIdleOrDone() throws {
        let manifest = try activityManifest()
        XCTAssertEqual(manifest.sequenceKey(mood: .working, activityID: "game"), "working", "work wins")
        XCTAssertEqual(manifest.sequenceKey(mood: .waiting, activityID: "game"), "waiting")
        XCTAssertEqual(manifest.sequenceKey(mood: .idle, activityID: "game"), "game")
        XCTAssertEqual(manifest.sequenceKey(mood: .done, activityID: "game"), "game")
        XCTAssertEqual(manifest.sequenceKey(mood: .idle, activityID: "idle"), "idle")
        XCTAssertEqual(manifest.sequenceKey(mood: .idle, activityID: "soon"), "idle", "not available yet")
        XCTAssertEqual(manifest.sequenceKey(mood: .idle, activityID: "stream"), "idle", "no sequences for its mood")
        XCTAssertEqual(manifest.sequenceKey(mood: .idle, activityID: "nope"), "idle")
        XCTAssertEqual(manifest.sequenceKey(mood: .idle, activityID: nil), "idle")
    }

    func testPlayerSwitchesSequencesWhenTheActivityChanges() throws {
        let manifest = try activityManifest()
        var player = CompanionPlayer()
        let start = Date(timeIntervalSince1970: 1000)
        player.advance(now: start, mood: .idle, manifest: manifest, sequenceKey: "idle", pick: { _ in 0 })
        XCTAssertEqual(player.sequence?.dir, "idle/0")
        XCTAssertTrue(player.advance(now: start.addingTimeInterval(1), mood: .idle, manifest: manifest,
                                     sequenceKey: "game", pick: { _ in 0 }))
        XCTAssertEqual(player.sequence?.dir, "game/0")
        player.advance(now: start.addingTimeInterval(2), mood: .working, manifest: manifest,
                       sequenceKey: manifest.sequenceKey(mood: .working, activityID: "game"), pick: { _ in 0 })
        XCTAssertEqual(player.sequence?.dir, "working/0")
    }

    func testChoicesPersistInUserDefaults() throws {
        let suite = "wooloo.companion.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(CompanionPreferences.activityID(defaults: defaults), "idle")
        XCTAssertFalse(CompanionPreferences.isCollapsed(CompanionPreferences.activitiesCollapsedKey, defaults: defaults))
        CompanionPreferences.setActivityID("game", defaults: defaults)
        CompanionPreferences.setCollapsed(true, key: CompanionPreferences.activitiesCollapsedKey, defaults: defaults)
        XCTAssertEqual(CompanionPreferences.activityID(defaults: defaults), "game")
        XCTAssertTrue(CompanionPreferences.isCollapsed(CompanionPreferences.activitiesCollapsedKey, defaults: defaults))
        XCTAssertFalse(CompanionPreferences.isCollapsed(CompanionPreferences.jineCollapsedKey, defaults: defaults))
        XCTAssertEqual(defaults.string(forKey: "companionActivity"), "game", "the key the view reads")
    }

    // MARK: JINE

    private func rawRecord(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    func testMessagesKeepTypedUserTextAndAssistantText() {
        let lines = [
            rawRecord(["type": "user", "timestamp": "2026-11-07T10:00:00.000Z",
                       "message": ["content": "first typed"]]),
            rawRecord(["type": "assistant", "timestamp": "2026-11-07T10:00:05.500Z",
                       "message": ["content": [["type": "text", "text": "**Sure.** On it."], ["type": "tool_use", "name": "Bash"]]]]),
            rawRecord(["type": "user", "message": ["content": [["type": "tool_result", "content": "output"]]]]),
            rawRecord(["type": "user", "isMeta": true, "message": ["content": "meta text"]]),
            rawRecord(["type": "user", "message": ["content": "<system-reminder>hidden</system-reminder>"]]),
            rawRecord(["type": "user", "isSidechain": true, "message": ["content": "sub-agent prompt"]]),
            rawRecord(["type": "system", "message": ["content": "system text"]]),
            rawRecord(["type": "assistant", "message": ["content": [["type": "tool_use", "name": "Read"]]]]),
            rawRecord(["type": "user", "message": ["content": [["type": "text", "text": "second typed"]]]]),
            "garbage",
        ]
        let messages = CompanionDialogue.messages(inTail: Data(lines.joined(separator: "\n").utf8), startsMidFile: false)
        XCTAssertEqual(messages.map(\.role), [.user, .assistant, .user])
        XCTAssertEqual(messages.map(\.text), ["first typed", "**Sure.** On it.", "second typed"])
        XCTAssertEqual(messages[1].displayText, "Sure. On it.")
        XCTAssertNotNil(messages[0].time)
        XCTAssertEqual(try XCTUnwrap(messages[1].time).timeIntervalSince(try XCTUnwrap(messages[0].time)), 5.5, accuracy: 0.01)
        XCTAssertNil(messages[2].time)
    }

    func testOnlyTheLastFourMessagesAndNoPartialFirstLine() {
        var lines = ["{\"partial\":"]
        for index in 1...6 { lines.append(rawRecord(["type": "user", "message": ["content": "m\(index)"]])) }
        let data = Data(lines.joined(separator: "\n").utf8)
        XCTAssertEqual(CompanionDialogue.messages(inTail: data, startsMidFile: true).map(\.text), ["m3", "m4", "m5", "m6"])
        XCTAssertEqual(CompanionDialogue.messages(inTail: data, startsMidFile: true, limit: 2).map(\.text), ["m5", "m6"])
        XCTAssertEqual(CompanionDialogue.messages(inTail: Data("no newline".utf8), startsMidFile: true), [])
    }

    func testMessageBubblesAreCapped() {
        let long = CompanionMessage(role: .assistant, text: String(repeating: "x", count: 3000), time: nil)
        XCTAssertEqual(long.displayText.count, CompanionMessage.maximumDisplayLength)
        let reply = CompanionMessage(role: .assistant, text: String(repeating: "word ", count: 120), time: nil)
        XCTAssertFalse(reply.displayText.hasSuffix("…"), "a normal long reply is shown whole")
        XCTAssertTrue(long.displayText.hasSuffix("…"))
    }

    func testLastSentLabel() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertEqual(CompanionMessage.lastSent(now.addingTimeInterval(-5), now: now), "last sent 5s ago")
        XCTAssertEqual(CompanionMessage.lastSent(now.addingTimeInterval(-125), now: now), "last sent 2m ago")
        XCTAssertEqual(CompanionMessage.lastSent(now.addingTimeInterval(-7300), now: now), "last sent 2h ago")
        XCTAssertEqual(CompanionMessage.lastSent(now.addingTimeInterval(-90_000), now: now), "last sent 1d ago")
        XCTAssertEqual(CompanionMessage.lastSent(now.addingTimeInterval(5), now: now), "last sent 0s ago")
        XCTAssertNil(CompanionMessage.lastSent(nil, now: now))
    }

    func testPromptPayloadForTextAndStickers() throws {
        XCTAssertEqual(CompanionMessage.promptParams(paneID: "w1:p1", text: "  hello there \n"),
                       ["target": "w1:p1", "text": "hello there"])
        XCTAssertEqual(CompanionMessage.promptParams(paneID: "w1:p1", text: try activityManifest().stickers[0].label),
                       ["target": "w1:p1", "text": "OK"], "a sticker sends its label")
        XCTAssertNil(CompanionMessage.promptParams(paneID: "w1:p1", text: "  \n "))
        XCTAssertNil(CompanionMessage.promptParams(paneID: "", text: "hi"))
        let huge = CompanionMessage.promptParams(paneID: "p", text: String(repeating: "a", count: 9000))
        XCTAssertEqual(huge?["text"]?.count, CompanionMessage.maximumSendLength)
    }

    func testReaderSnapshotHasTheMessages() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/wooloo-tests/companion-\(UUID().uuidString)")
        let project = root.appendingPathComponent("-p")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let text = rawRecord(["type": "user", "message": ["content": "hi"]]) + "\n"
            + rawRecord(["type": "assistant", "message": ["content": [["type": "text", "text": "Hello."]]]]) + "\n"
        try text.write(to: project.appendingPathComponent("s-1.jsonl"), atomically: true, encoding: .utf8)
        let snapshot = await CompanionTranscriptReader(projects: root).snapshot(sessionID: "s-1")
        XCTAssertEqual(snapshot.text, "Hello.")
        XCTAssertEqual(snapshot.messages.map(\.text), ["hi", "Hello."])
    }

    // MARK: Skins

    private func skinManifest() throws -> CompanionManifest {
        let json = """
        {"version":1,"size":[64,64],
         "moods":{"idle":[{"dir":"ame/idle","frames":2,"fps":2,"loop":true}],
                  "working":[{"dir":"ame/working","frames":2,"fps":2,"loop":true}],
                  "done":[{"dir":"ame/done","frames":2,"fps":2,"loop":false}]},
         "lines":{},
         "skins":{"streamer":{"label":"Streamer","moods":{"idle":[{"dir":"st/idle","frames":2,"fps":2,"loop":true}],
                                                           "working":[{"dir":"st/working","frames":2,"fps":2,"loop":true}]}},
                  "dark_angel":{"label":"Dark Angel","moods":{"working":[{"dir":"da/working","frames":2,"fps":2,"loop":true}]}},
                  "broken":{"label":"Broken"},
                  "empty":{"label":"Empty","moods":{"idle":[]}}}}
        """
        return try XCTUnwrap(CompanionManifest.decode(Data(json.utf8)))
    }

    func testSkinsDecodeAndAreOrdered() throws {
        let manifest = try skinManifest()
        XCTAssertEqual(manifest.skinChoices, [CompanionSkinChoice(id: "ame", label: "Ame"),
                                              CompanionSkinChoice(id: "streamer", label: "Streamer"),
                                              CompanionSkinChoice(id: "dark_angel", label: "Dark Angel")],
                       "unusable skins are dropped; Ame comes first")
        XCTAssertEqual(try XCTUnwrap(CompanionManifest.decode(manifestJSON(extra: ""))).skins.count, 0, "no skins: no gear")
        XCTAssertEqual(manifest.previewPath(skin: "streamer"), "st/idle/0.png")
    }

    func testSkinSequencesFallBackToItsIdleThenToTheTopLevel() throws {
        let manifest = try skinManifest()
        XCTAssertEqual(manifest.sequences(forKey: "working", skin: "streamer").map(\.dir), ["st/working"])
        XCTAssertEqual(manifest.sequences(forKey: "done", skin: "streamer").map(\.dir), ["st/idle"], "its own idle")
        XCTAssertEqual(manifest.sequences(forKey: "done", skin: "dark_angel").map(\.dir), ["ame/done"],
                       "no idle of its own: the top-level mood")
        XCTAssertEqual(manifest.sequences(forKey: "idle", skin: "dark_angel").map(\.dir), ["ame/idle"])
        XCTAssertEqual(manifest.sequences(forKey: "working", skin: "ame").map(\.dir), ["ame/working"])
        XCTAssertEqual(manifest.sequences(forKey: "working", skin: nil).map(\.dir), ["ame/working"])
        XCTAssertEqual(manifest.sequences(forKey: "working", skin: "unknown").map(\.dir), ["ame/working"])
    }

    func testUnknownSkinResolvesToAme() throws {
        let manifest = try skinManifest()
        XCTAssertEqual(manifest.resolvedSkin("streamer"), "streamer")
        XCTAssertEqual(manifest.resolvedSkin("gone"), "ame")
        XCTAssertEqual(manifest.resolvedSkin(nil), "ame")
    }

    func testSwitchingSkinSwapsSequencesImmediately() throws {
        let manifest = try skinManifest()
        var player = CompanionPlayer()
        let start = Date(timeIntervalSince1970: 1000)
        player.advance(now: start, mood: .working, manifest: manifest, skin: "ame", pick: { _ in 0 })
        XCTAssertEqual(player.sequence?.dir, "ame/working")
        XCTAssertTrue(player.advance(now: start.addingTimeInterval(0.1), mood: .working, manifest: manifest,
                                     skin: "streamer", pick: { _ in 0 }))
        XCTAssertEqual(player.sequence?.dir, "st/working")
        XCTAssertFalse(player.advance(now: start.addingTimeInterval(0.2), mood: .working, manifest: manifest,
                                      skin: "streamer", pick: { _ in 0 }))
    }

    func testSkinChoicePersists() throws {
        let suite = "wooloo.companion.skin.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(CompanionPreferences.skinID(defaults: defaults), "ame")
        CompanionPreferences.setSkinID("dark_angel", defaults: defaults)
        XCTAssertEqual(CompanionPreferences.skinID(defaults: defaults), "dark_angel")
        XCTAssertEqual(defaults.string(forKey: "companionSkin"), "dark_angel", "the key the view reads")
    }

    // MARK: Emotions

    private let now = Date(timeIntervalSince1970: 2_000_000)

    private func emotion(_ mood: CompanionMood, text: String? = nil, age: TimeInterval? = 60,
                         elapsed: TimeInterval = 0) -> CompanionEmotion? {
        CompanionEmotionRules.resolve(mood: mood, signals: CompanionTextSignals(text: text),
                                      textTime: age.map { now.addingTimeInterval(-$0) },
                                      statusElapsed: elapsed, now: now)
    }

    func testSignalsMatchWholeWordsIgnoringCase() {
        XCTAssertTrue(CompanionTextSignals(text: "I will PUBLISH it, then tag.").scary)
        XCTAssertTrue(CompanionTextSignals(text: "It is production-ready").scary, "hyphens separate words")
        XCTAssertFalse(CompanionTextSignals(text: "tagged tagline releases").scary, "only whole words")
        XCTAssertTrue(CompanionTextSignals(text: "It crashed.").failure)
        XCTAssertTrue(CompanionTextSignals(text: "I couldn’t do that").failure, "curly apostrophe")
        XCTAssertTrue(CompanionTextSignals(text: "I can't").failure)
        XCTAssertFalse(CompanionTextSignals(text: "errors everywhere").failure)
        XCTAssertTrue(CompanionTextSignals(text: "Sorry about that").sorry)
        XCTAssertEqual(CompanionTextSignals(text: nil), CompanionTextSignals())
    }

    func testScaredNeedsWorkingAndAScaryWord() {
        XCTAssertEqual(emotion(.working, text: "Now I delete the branch."), .scared)
        XCTAssertEqual(emotion(.working, text: "Pushing to production", age: 99_999), .scared, "any age")
        XCTAssertNil(emotion(.idle, text: "I will force push"))
        XCTAssertNil(emotion(.waiting, text: "May I publish?"))
    }

    func testCryingNeedsAFailureWordAndSorryWithinTenMinutes() {
        XCTAssertEqual(emotion(.idle, text: "Sorry, the build failed."), .crying)
        XCTAssertEqual(emotion(.done, text: "I'm sorry, it broke.", age: 599), .crying)
        XCTAssertEqual(emotion(.working, text: "Sorry, it crashed."), .crying, "any status")
        XCTAssertEqual(emotion(.idle, text: "Sorry, it failed.", age: 601), nil, "too old")
        XCTAssertNil(emotion(.idle, text: "Sorry about the wait."), "no failure word")
    }

    func testSadNeedsAFailureWordWithinTenMinutes() {
        XCTAssertEqual(emotion(.idle, text: "The deploy was denied."), .sad)
        XCTAssertEqual(emotion(.done, text: "Access is blocked.", age: 600), .sad, "the limit is inclusive")
        XCTAssertNil(emotion(.idle, text: "Access is blocked.", age: 601))
        XCTAssertNil(emotion(.idle, text: "All good."))
        XCTAssertNil(emotion(.idle, text: "It failed.", age: nil), "no timestamp: too old")
    }

    func testAngryAndStressedWaitForTheirTimers() {
        XCTAssertNil(emotion(.waiting, elapsed: 600))
        XCTAssertEqual(emotion(.waiting, elapsed: 601), .angry)
        XCTAssertNil(emotion(.working, elapsed: 900))
        XCTAssertEqual(emotion(.working, elapsed: 901), .stressed)
        XCTAssertNil(emotion(.idle, elapsed: 5000))
        XCTAssertNil(emotion(.done, elapsed: 5000))
    }

    func testPriorityOrder() {
        // scared > crying > sad > angry > stressed
        XCTAssertEqual(emotion(.working, text: "Sorry, I will delete it but the tests failed.", elapsed: 5000), .scared)
        XCTAssertEqual(emotion(.waiting, text: "Sorry, it failed.", elapsed: 5000), .crying)
        XCTAssertEqual(emotion(.waiting, text: "It failed.", elapsed: 5000), .sad)
        XCTAssertEqual(emotion(.waiting, text: "All fine.", elapsed: 5000), .angry)
        XCTAssertEqual(emotion(.working, text: "It failed.", elapsed: 5000), .sad, "sad beats stressed")
        XCTAssertEqual(emotion(.working, text: "All fine.", elapsed: 5000), .stressed)
        XCTAssertNil(emotion(.working, text: "All fine.", elapsed: 10))
    }

    func testStatusTimerRestartsWhenTheStatusChanges() {
        var timer = CompanionStatusTimer()
        XCTAssertEqual(timer.elapsed(now: now), 0)
        timer.observe("working", now: now)
        timer.observe("working", now: now.addingTimeInterval(500))
        XCTAssertEqual(timer.elapsed(now: now.addingTimeInterval(900)), 900, "same status keeps counting")
        timer.observe("blocked", now: now.addingTimeInterval(1000))
        XCTAssertEqual(timer.elapsed(now: now.addingTimeInterval(1010)), 10, "a new status restarts")
        timer.observe("working", now: now.addingTimeInterval(1100))
        XCTAssertEqual(timer.elapsed(now: now.addingTimeInterval(1101)), 1)
    }

    func testEmotionBubblePicks() {
        let sentences = ["First.", "Middle.", "Last."]
        XCTAssertEqual(CompanionDialogue.pick(mood: .working, emotion: .sad, sentences: sentences), "First.")
        XCTAssertEqual(CompanionDialogue.pick(mood: .idle, emotion: .crying, sentences: sentences), "First.")
        XCTAssertEqual(CompanionDialogue.pick(mood: .working, emotion: .scared, sentences: sentences), "Last.")
        XCTAssertEqual(CompanionDialogue.pick(mood: .idle, emotion: .stressed, sentences: sentences), "Last.")
        XCTAssertEqual(CompanionDialogue.pick(mood: .waiting, emotion: .angry, sentences: ["A.", "Why?", "B."]), "Why?")
        XCTAssertEqual(CompanionDialogue.pick(mood: .idle, emotion: nil, sentences: sentences), "First.")
    }

    func testMissingEmotionMoodFallsBackToTheBaseMood() throws {
        let json = """
        {"version":1,"size":[1,1],
         "moods":{"idle":[{"dir":"i","frames":1,"fps":1,"loop":true}],"sad":[{"dir":"s","frames":1,"fps":1,"loop":true}]},
         "skins":{"streamer":{"label":"S","moods":{"idle":[{"dir":"si","frames":1,"fps":1,"loop":true}]}},
                  "dark_angel":{"label":"D","moods":{"idle":[{"dir":"di","frames":1,"fps":1,"loop":true}],
                                                     "scared":[{"dir":"ds","frames":1,"fps":1,"loop":true}]}}}}
        """
        let manifest = try XCTUnwrap(CompanionManifest.decode(Data(json.utf8)))
        XCTAssertTrue(manifest.hasOwnSequences(forKey: "sad", skin: "ame"))
        XCTAssertTrue(manifest.hasOwnSequences(forKey: "sad", skin: nil))
        XCTAssertFalse(manifest.hasOwnSequences(forKey: "crying", skin: "ame"))
        XCTAssertFalse(manifest.hasOwnSequences(forKey: "sad", skin: "streamer"), "the skin has no sad of its own")
        XCTAssertTrue(manifest.hasOwnSequences(forKey: "scared", skin: "dark_angel"))
        XCTAssertFalse(manifest.hasOwnSequences(forKey: "scared", skin: "streamer"))
    }

    func testTranscriptTailCarriesTheNewestAssistantTime() throws {
        let data = Data((record("assistant", [["type": "text", "text": "Old."]]) + "\n"
            + rawRecord(["type": "assistant", "timestamp": "2026-11-07T10:00:05Z",
                         "message": ["content": [["type": "text", "text": "Newest."]]]])).utf8)
        let latest = try XCTUnwrap(CompanionDialogue.latestAssistant(inTail: data, startsMidFile: false))
        XCTAssertEqual(latest.text, "Newest.")
        XCTAssertNotNil(latest.time)
    }

    // MARK: Love

    func testAffectionSignals() {
        for text in ["I love this", "so CUTE", "Thank you!", "thanks", "good job", "Good girl", "ily", "xoxo <3",
                     "nice ♥", "great ❤️", "wow 💖", "💜", "send LOVE"] {
            XCTAssertTrue(CompanionAffection.matches(text), text)
        }
        for text in ["glove box", "acute pain", "thankful", "good morning", "ilya", "💔", "", "run the tests"] {
            XCTAssertFalse(CompanionAffection.matches(text), text)
        }
        XCTAssertFalse(CompanionAffection.matches(nil))
        XCTAssertTrue(CompanionAffection.matches("Aww, Daisuki!", extra: ["DAISUKI"]), "the sticker label")
        XCTAssertFalse(CompanionAffection.matches("Aww", extra: ["Daisuki"]))
    }

    private func loveEmotion(_ mood: CompanionMood, text: String? = nil, loveAge: TimeInterval? = 30,
                             elapsed: TimeInterval = 0) -> CompanionEmotion? {
        CompanionEmotionRules.resolve(mood: mood, signals: CompanionTextSignals(text: text),
                                      textTime: now.addingTimeInterval(-60), statusElapsed: elapsed, now: now,
                                      loveTime: loveAge.map { now.addingTimeInterval(-$0) })
    }

    func testLoveLastsFiveMinutesFromTheMessage() {
        XCTAssertEqual(loveEmotion(.idle), .love)
        XCTAssertEqual(loveEmotion(.working), .love)
        XCTAssertEqual(loveEmotion(.waiting, loveAge: 300), .love, "the limit is inclusive")
        XCTAssertNil(loveEmotion(.idle, loveAge: 301))
        XCTAssertNil(loveEmotion(.idle, loveAge: nil), "no affectionate message")
    }

    func testLovePriority() {
        XCTAssertEqual(loveEmotion(.working, text: "Now I delete it."), .scared, "scared beats love")
        XCTAssertEqual(loveEmotion(.idle, text: "Now I delete it."), .love, "scared needs working")
        XCTAssertEqual(loveEmotion(.idle, text: "Sorry, it failed."), .love, "love beats crying")
        XCTAssertEqual(loveEmotion(.idle, text: "It failed."), .love, "love beats sad")
        XCTAssertEqual(loveEmotion(.waiting, elapsed: 5000), .love, "love beats angry")
        XCTAssertEqual(loveEmotion(.working, elapsed: 5000), .love, "love beats stressed")
        XCTAssertEqual(loveEmotion(.idle, text: "Sorry, it failed.", loveAge: 400), .crying, "after the window")
    }

    func testLoveBubbleAndLines() throws {
        XCTAssertEqual(CompanionDialogue.pick(mood: .working, emotion: .love, sentences: ["First.", "Last."]), "First.")
        let json = """
        {"version":1,"size":[1,1],"moods":{"idle":[{"dir":"i","frames":1,"fps":1,"loop":true}]},
         "lines":{"idle":["calm"],"love":["kyaa"]}}
        """
        let manifest = try XCTUnwrap(CompanionManifest.decode(Data(json.utf8)))
        var player = CompanionPlayer()
        player.advance(now: now, mood: .idle, manifest: manifest, pick: { _ in 0 })
        XCTAssertEqual(player.bubbleText(title: nil), "calm")
        player.advance(now: now.addingTimeInterval(1), mood: .idle, manifest: manifest, sequenceKey: "idle",
                       lineKey: "love", pick: { _ in 0 })
        XCTAssertEqual(player.bubbleText(title: nil), "kyaa", "a love line without a new mood")
        XCTAssertFalse(manifest.hasOwnSequences(forKey: "love", skin: nil), "no love mood: the base mood plays")
    }

    func testNewestTypedUserMessageIsFoundForTheAffectionRule() {
        let lines = [
            rawRecord(["type": "user", "timestamp": "2026-11-07T10:00:00Z", "message": ["content": "you are so cute"]]),
            rawRecord(["type": "assistant", "message": ["content": [["type": "text", "text": "Thanks."]]]]),
            rawRecord(["type": "user", "message": ["content": [["type": "tool_result", "content": "love"]]]]),
            rawRecord(["type": "user", "message": ["content": "<command-name>/love</command-name>"]]),
        ]
        let user = CompanionDialogue.messages(inTail: Data(lines.joined(separator: "\n").utf8), startsMidFile: false,
                                              limit: Int.max).last(where: { $0.role == .user })
        XCTAssertEqual(user?.text, "you are so cute")
        XCTAssertNotNil(user?.time)
    }

    // MARK: Webcam size and zoom

    func testHeightFactorAndZoomAreClamped() {
        XCTAssertEqual(CompanionPreferences.clampedHeightFactor(0.1), 0.5)
        XCTAssertEqual(CompanionPreferences.clampedHeightFactor(9), 1.8)
        XCTAssertEqual(CompanionPreferences.clampedHeightFactor(1.1), 1.1)
        XCTAssertEqual(CompanionPreferences.clampedHeightFactor(.nan), 1.0)
        XCTAssertEqual(CompanionPreferences.clampedZoom(0.2), 1.0)
        XCTAssertEqual(CompanionPreferences.clampedZoom(7), 2.5)
        XCTAssertEqual(CompanionPreferences.clampedZoom(1.3), 1.3)
        XCTAssertEqual(CompanionPreferences.clampedZoom(.infinity), 2.0)
    }

    func testHeightFactorAndZoomPersistAndDefault() throws {
        let suite = "CompanionSizeTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(CompanionPreferences.heightFactor(defaults: defaults), 1.0, "unset uses the default")
        XCTAssertEqual(CompanionPreferences.zoom(defaults: defaults), 2.0)
        defaults.set(1.25, forKey: CompanionPreferences.heightFactorKey)
        defaults.set(2.0, forKey: CompanionPreferences.zoomKey)
        XCTAssertEqual(CompanionPreferences.heightFactor(defaults: defaults), 1.25)
        XCTAssertEqual(CompanionPreferences.zoom(defaults: defaults), 2.0)
        defaults.set(40.0, forKey: CompanionPreferences.heightFactorKey)
        defaults.set(0.0, forKey: CompanionPreferences.zoomKey)
        XCTAssertEqual(CompanionPreferences.heightFactor(defaults: defaults), 1.8, "stored values are clamped on read")
        XCTAssertEqual(CompanionPreferences.zoom(defaults: defaults), 1.0)
    }

    func testZoomAnchorIsTheSpriteCenter() {
        let size = CGSize(width: 200, height: 100)
        let anchor = CompanionScene.zoomAnchor(spriteRect: [100, 20, 40, 60], backgroundSize: size)
        XCTAssertEqual(anchor.x, 0.6, accuracy: 0.0001)
        XCTAssertEqual(anchor.y, 0.5, accuracy: 0.0001)
        XCTAssertEqual(CompanionScene.zoomAnchor(spriteRect: nil, backgroundSize: size), .center)
        XCTAssertEqual(CompanionScene.zoomAnchor(spriteRect: [1, 2, 3], backgroundSize: size), .center)
        XCTAssertEqual(CompanionScene.zoomAnchor(spriteRect: [500, 500, 50, 50], backgroundSize: size).x, 1,
                       "a rectangle outside the background stays inside the unit square")
    }

    func testVisibleBoundsFindsTheOpaquePixels() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 10, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        // Context origin is bottom-left: this is the top-right 2x2 block of the image.
        context.fill(CGRect(x: 6, y: 6, width: 2, height: 2))
        let image = try XCTUnwrap(context.makeImage())
        let bounds = try XCTUnwrap(CompanionSprite.visibleBounds(of: image))
        XCTAssertEqual(bounds.minX, 0.6, accuracy: 0.001)
        XCTAssertEqual(bounds.minY, 0, accuracy: 0.001)
        XCTAssertEqual(bounds.width, 0.2, accuracy: 0.001)
        XCTAssertEqual(bounds.height, 0.25, accuracy: 0.001)

        let empty = try XCTUnwrap(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        XCTAssertNil(CompanionSprite.visibleBounds(of: empty))
    }

    func testZoomAnchorFollowsVisibleBounds() {
        let visible = CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)
        // Image 100x100 fitted into a 100x200 rect at (50, 0): shown 100x100, vertically centered at y 50.
        let anchor = CompanionScene.zoomAnchor(spriteRect: [50, 0, 100, 200], backgroundSize: CGSize(width: 200, height: 400),
                                               imageSize: CGSize(width: 100, height: 100), visible: visible)
        XCTAssertEqual(anchor.x, (50 + 75) / 200, accuracy: 0.0001)
        XCTAssertEqual(anchor.y, (50 + 25) / 400, accuracy: 0.0001)
        let plain = CompanionScene.zoomAnchor(visible: visible, imageSize: CGSize(width: 10, height: 10),
                                              area: CGSize(width: 100, height: 100))
        XCTAssertEqual(plain.x, 0.75, accuracy: 0.0001)
        XCTAssertEqual(plain.y, 0.25, accuracy: 0.0001)
        XCTAssertEqual(CompanionScene.zoomAnchor(spriteRect: [0, 0, 50, 50], backgroundSize: CGSize(width: 100, height: 100),
                                                 imageSize: .zero, visible: nil).x, 0.25, accuracy: 0.0001,
                       "no visible bounds: the sprite_rect center")
    }

    // MARK: Side chat with Ame

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ hour: Int, _ minute: Int = 0, day: Int = 3) -> Date {
        utc.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    private func isolatedDefaults() throws -> (UserDefaults, () -> Void) {
        let suite = "CompanionNudgeTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (defaults, { defaults.removePersistentDomain(forName: suite) })
    }

    func testNudgeTextAndHints() {
        // 2026-11-03 is a Tuesday.
        XCTAssertEqual(CompanionNudge.text(now: date(15, 5), hint: "everything is quiet", calendar: utc),
                       "[nudge] it's Tuesday 3:05 PM; everything is quiet")
        XCTAssertEqual(CompanionNudge.hint(commanderWorking: true, runningTasks: 0), "the commander is working")
        XCTAssertEqual(CompanionNudge.hint(commanderWorking: false, runningTasks: 0), "everything is quiet")
        XCTAssertEqual(CompanionNudge.hint(commanderWorking: true, runningTasks: 3), "3 tasks running")
        XCTAssertEqual(CompanionNudge.hint(commanderWorking: false, runningTasks: 1), "1 task running")
    }

    func testNudgeQuietHours() {
        XCTAssertFalse(CompanionNudge.isQuiet(date(0, 59), calendar: utc))
        XCTAssertTrue(CompanionNudge.isQuiet(date(1), calendar: utc))
        XCTAssertTrue(CompanionNudge.isQuiet(date(8, 59), calendar: utc))
        XCTAssertFalse(CompanionNudge.isQuiet(date(9), calendar: utc))
    }

    func testSchedulerWaitsARandomDelayThenSendsOnceWhenIdle() throws {
        let (defaults, cleanup) = try isolatedDefaults()
        defer { cleanup() }
        var scheduler = CompanionNudgeScheduler()
        let delay: (ClosedRange<TimeInterval>) -> TimeInterval = { $0.lowerBound }
        XCTAssertFalse(scheduler.due(now: date(10), ameIsIdle: true, calendar: utc, defaults: defaults, random: delay),
                       "the first look only schedules")
        XCTAssertEqual(scheduler.nextFire, date(10).addingTimeInterval(45 * 60))
        XCTAssertFalse(scheduler.due(now: date(10, 44), ameIsIdle: true, calendar: utc, defaults: defaults, random: delay))
        XCTAssertFalse(scheduler.due(now: date(10, 46), ameIsIdle: false, calendar: utc, defaults: defaults, random: delay),
                       "a busy Ame waits")
        XCTAssertEqual(scheduler.nextFire, date(10).addingTimeInterval(45 * 60), "and the time stays due")
        XCTAssertTrue(scheduler.due(now: date(10, 50), ameIsIdle: true, calendar: utc, defaults: defaults, random: delay))
        XCTAssertFalse(scheduler.due(now: date(10, 51), ameIsIdle: true, calendar: utc, defaults: defaults, random: delay))
        XCTAssertEqual(scheduler.nextFire, date(10, 50).addingTimeInterval(45 * 60))
        XCTAssertEqual(defaults.integer(forKey: CompanionNudgeScheduler.countKey), 1)
    }

    func testSchedulerSkipsQuietHoursAndStopsAtTheDailyLimit() throws {
        let (defaults, cleanup) = try isolatedDefaults()
        defer { cleanup() }
        let delay: (ClosedRange<TimeInterval>) -> TimeInterval = { $0.upperBound }
        var scheduler = CompanionNudgeScheduler()
        _ = scheduler.due(now: date(0, 30), ameIsIdle: true, calendar: utc, defaults: defaults, random: delay)
        XCTAssertFalse(scheduler.due(now: date(3), ameIsIdle: true, calendar: utc, defaults: defaults, random: delay),
                       "03:00 is quiet")
        XCTAssertEqual(defaults.integer(forKey: CompanionNudgeScheduler.countKey), 0)
        XCTAssertEqual(scheduler.nextFire, date(3).addingTimeInterval(150 * 60), "moved on instead")

        defaults.set(CompanionNudge.dayKey(date(12), calendar: utc), forKey: CompanionNudgeScheduler.dayKey)
        defaults.set(CompanionNudge.maximumPerDay, forKey: CompanionNudgeScheduler.countKey)
        scheduler = CompanionNudgeScheduler()
        _ = scheduler.due(now: date(11), ameIsIdle: true, calendar: utc, defaults: defaults, random: { $0.lowerBound })
        XCTAssertFalse(scheduler.due(now: date(12), ameIsIdle: true, calendar: utc, defaults: defaults, random: { $0.lowerBound }),
                       "8 a day at most")
        // The next local day starts again at zero.
        scheduler = CompanionNudgeScheduler()
        _ = scheduler.due(now: date(11, day: 4), ameIsIdle: true, calendar: utc, defaults: defaults, random: { $0.lowerBound })
        XCTAssertTrue(scheduler.due(now: date(12, day: 4), ameIsIdle: true, calendar: utc, defaults: defaults, random: { $0.lowerBound }))
        XCTAssertEqual(defaults.integer(forKey: CompanionNudgeScheduler.countKey), 1)
    }

    func testNudgesAreHiddenFromTheChat() {
        let messages = [
            CompanionMessage(role: .user, text: "[nudge] it's Tuesday 3:05 PM; everything is quiet", time: date(15)),
            CompanionMessage(role: .assistant, text: "hi!", time: date(15, 1)),
            CompanionMessage(role: .user, text: "  [nudge] padded", time: date(16)),
            CompanionMessage(role: .user, text: "what is a [nudge]?", time: date(17)),
            CompanionMessage(role: .assistant, text: "[nudge] from her stays", time: date(17, 1)),
        ]
        XCTAssertEqual(CompanionNudge.visible(messages).map(\.text), ["hi!", "what is a [nudge]?", "[nudge] from her stays"])
    }

    func testUnreadCountsOnlyWhileOutOfSightAndClearsWhenSeen() {
        var unread = CompanionUnread()
        unread.update(assistantTimes: [date(9), date(10)], visible: false)
        XCTAssertEqual(unread.count, 0, "what is there at first counts as read")
        unread.update(assistantTimes: [date(9), date(10), date(11)], visible: false)
        XCTAssertEqual(unread.count, 1)
        unread.update(assistantTimes: [date(9), date(10), date(11), date(12)], visible: false)
        XCTAssertEqual(unread.count, 2)
        unread.update(assistantTimes: [date(9), date(10), date(11), date(12)], visible: true)
        XCTAssertEqual(unread.count, 0, "expanded in the key window")
        unread.update(assistantTimes: [date(9), date(10), date(11), date(12)], visible: false)
        XCTAssertEqual(unread.count, 0, "nothing new")
        unread.update(assistantTimes: [date(12), date(13)], visible: false)
        XCTAssertEqual(unread.count, 1)

        var empty = CompanionUnread()
        empty.update(assistantTimes: [], visible: false)
        empty.update(assistantTimes: [date(8)], visible: false)
        XCTAssertEqual(empty.count, 1, "the first text after an empty chat is unread")
    }

    func testLoveFromTheUserMessagesToAme() {
        let messages = [
            CompanionMessage(role: .user, text: "hello", time: date(10)),
            CompanionMessage(role: .user, text: "LOVE", time: date(11)),
            CompanionMessage(role: .assistant, text: "love you too", time: date(11, 1)),
            CompanionMessage(role: .user, text: "ok", time: date(12)),
        ]
        XCTAssertEqual(CompanionAffection.newestLove(in: messages, extra: ["LOVE"]), date(11),
                       "her own reply and later plain messages do not count")
        XCTAssertNil(CompanionAffection.newestLove(in: [messages[0], messages[2]]))
        XCTAssertEqual(CompanionAffection.later(date(10), date(11)), date(11))
        XCTAssertEqual(CompanionAffection.later(nil, date(11)), date(11))
        XCTAssertNil(CompanionAffection.later(nil, nil))
        let signals = CompanionTextSignals()
        XCTAssertEqual(CompanionEmotionRules.resolve(mood: .idle, signals: signals, textTime: nil, statusElapsed: 0,
                                                      now: date(11, 3), loveTime: date(11)), .love)
    }

    func testAmeIsFoundByNameInAnySpace() throws {
        let json = #"{"pane_id":"w2:p9","workspace_id":"w2","agent":"claude","name":"Ame","agent_status":"idle"}"#
        let ame = try JSONDecoder().decode(HerdrAgent.self, from: Data(json.utf8))
        let other = try JSONDecoder().decode(HerdrAgent.self, from: Data(json.replacingOccurrences(of: "Ame", with: "amelia").utf8))
        XCTAssertEqual(CompanionMood.ame(in: [other, ame])?.paneID, "w2:p9")
        XCTAssertNil(CompanionMood.ame(in: [other]))
    }

    // MARK: Stickers, sizing, Ame alerts

    func testStickerMarkerRoundTripsAndRejectsOtherText() {
        XCTAssertEqual(CompanionMessage.stickerMarker("LOVE"), "[sticker: LOVE]")
        XCTAssertEqual(CompanionMessage.stickerLabel(in: "[sticker: LOVE]"), "LOVE")
        XCTAssertEqual(CompanionMessage.stickerLabel(in: "  [sticker: Good job] \n"), "Good job")
        XCTAssertNil(CompanionMessage.stickerLabel(in: "hi [sticker: LOVE]"))
        XCTAssertNil(CompanionMessage.stickerLabel(in: "[sticker: ]"))
        XCTAssertNil(CompanionMessage.stickerLabel(in: "[sticker: a] b]"))
        XCTAssertNil(CompanionMessage.stickerLabel(in: "[sticker: a]\nmore"))
        XCTAssertNil(CompanionMessage.stickerLabel(in: "LOVE"))
    }

    func testLoveStillFiresForTheStickerMarker() {
        XCTAssertTrue(CompanionAffection.matches("[sticker: LOVE]", extra: ["LOVE"]))
        XCTAssertTrue(CompanionAffection.matches("[sticker: Big hug]", extra: ["big hug"]))
        XCTAssertFalse(CompanionAffection.matches("[sticker: WAVE]", extra: ["LOVE"]))
    }

    func testRoomHeightIsWidthTimesTheClampedFactor() {
        XCTAssertEqual(CompanionPreferences.roomHeight(width: 200, factor: 1.0), 200)
        XCTAssertEqual(CompanionPreferences.roomHeight(width: 200, factor: 9), 360)
        XCTAssertEqual(CompanionPreferences.roomHeight(width: 200, factor: 0), 100)
        XCTAssertEqual(CompanionPreferences.roomHeight(width: -5, factor: 1), 0)
    }

    func testAmeAlertsAreSkippedUnlessEnabled() {
        XCTAssertTrue(HerdrNotifier.suppresses(agentName: "ame", notifiesAme: false))
        XCTAssertTrue(HerdrNotifier.suppresses(agentName: "Ame", notifiesAme: false))
        XCTAssertFalse(HerdrNotifier.suppresses(agentName: "ame", notifiesAme: true))
        XCTAssertFalse(HerdrNotifier.suppresses(agentName: "commander", notifiesAme: false))
        XCTAssertFalse(HerdrNotifier.suppresses(agentName: nil, notifiesAme: false))
    }

    func testBackgroundFillsTheRoomAtEverySize() {
        let background = CGSize(width: 320, height: 180)
        for factor in [0.5, 1.0, 1.54, 1.8] {
            for width in [200.0, 244.0, 400.0] {
                let area = CGSize(width: width, height: CompanionPreferences.roomHeight(width: width, factor: factor))
                let scale = CompanionScene.fillScale(content: background, in: area)
                XCTAssertGreaterThanOrEqual(background.width * scale, area.width - 0.0001, "w \(width) f \(factor)")
                XCTAssertGreaterThanOrEqual(background.height * scale, area.height - 0.0001, "w \(width) f \(factor)")
                // One axis fits exactly: nothing is scaled more than needed.
                XCTAssertTrue(abs(background.width * scale - area.width) < 0.0001
                              || abs(background.height * scale - area.height) < 0.0001)
            }
        }
        XCTAssertEqual(CompanionScene.fillScale(content: .zero, in: CGSize(width: 10, height: 10)), 1)
    }

    // MARK: Skin change cutscenes

    private func manifestJSON(transitions: String) -> Data {
        let sequence = #"{"dir":"idle","frames":2,"fps":4,"loop":true}"#
        return Data(("""
        {"version":1,"size":[10,10],"moods":{"idle":[\(sequence)]},"transitions":\(transitions)}
        """).utf8)
    }

    func testTransitionLookupPrefersExactThenWildcardThenNothing() throws {
        let manifest = try XCTUnwrap(CompanionManifest.decode(manifestJSON(transitions: """
        [{"from":"*","to":"kangel","dir":"t/any","frames":4,"fps":12},
         {"from":"ame","to":"kangel","dir":"t/exact","frames":4,"fps":12},
         {"from":"*","to":"streamer","dir":"t/stream","frames":2,"fps":12,"reverse":true}]
        """)))
        XCTAssertEqual(manifest.transition(from: "ame", to: "kangel")?.dir, "t/exact")
        XCTAssertEqual(manifest.transition(from: "streamer", to: "kangel")?.dir, "t/any")
        XCTAssertEqual(manifest.transition(from: "ame", to: "streamer")?.dir, "t/stream")
        XCTAssertNil(manifest.transition(from: "ame", to: "dark_angel"))
        XCTAssertNil(manifest.transition(from: "kangel", to: "kangel"), "no change, no cutscene")
    }

    func testTransitionFramesPlayBackwardsWhenReversed() throws {
        let forward = CompanionTransition(from: "a", to: "b", dir: "t", frames: 4, fps: 2)
        let backward = CompanionTransition(from: "a", to: "b", dir: "t", frames: 4, fps: 2, reverse: true)
        XCTAssertEqual(forward.order, [0, 1, 2, 3])
        XCTAssertEqual(backward.order, [3, 2, 1, 0])
        XCTAssertEqual(forward.position(elapsed: 0), 0)
        XCTAssertEqual(forward.position(elapsed: 0.6), 1)
        XCTAssertEqual(forward.position(elapsed: 1.99), 3)
        XCTAssertNil(forward.position(elapsed: 2), "over after the last frame; it never loops")
        XCTAssertEqual(forward.duration, 2)
    }

    func testDecodeSkipsBadTransitions() throws {
        let manifest = try XCTUnwrap(CompanionManifest.decode(manifestJSON(transitions: """
        [{"from":"ame","to":"a","dir":"t/ok","frames":3,"fps":12},
         {"from":"ame","to":"b","dir":"../escape","frames":3,"fps":12},
         {"from":"ame","to":"c","dir":"/abs","frames":3,"fps":12},
         {"from":"ame","to":"d","dir":"t/zero","frames":0,"fps":12},
         {"from":"ame","to":"e","dir":"t/fast","frames":3,"fps":999},
         {"from":"ame","to":"*","dir":"t/star","frames":3,"fps":12},
         {"from":"ame","dir":"t/missing-to","frames":3,"fps":12},
         "junk"]
        """)))
        XCTAssertEqual(manifest.transitions.map(\.dir), ["t/ok"])
        let none = try XCTUnwrap(CompanionManifest.decode(manifestJSON(transitions: "42")))
        XCTAssertEqual(none.transitions, [], "a malformed list is just no cutscenes")
    }

    func testMissingTransitionFoldersAreDropped() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wooloo-trans-\(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("t/here"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = try XCTUnwrap(CompanionManifest.decode(manifestJSON(transitions: """
        [{"from":"ame","to":"a","dir":"t/here","frames":3,"fps":12},
         {"from":"ame","to":"b","dir":"t/gone","frames":3,"fps":12}]
        """)))
        XCTAssertEqual(manifest.droppingMissingTransitions(in: root).transitions.map(\.dir), ["t/here"])
    }

    func testTransitionPreferenceDefaultsOn() throws {
        let suite = "CompanionTransitionPrefTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(CompanionPreferences.playsTransitions(defaults: defaults))
        defaults.set(false, forKey: CompanionPreferences.transitionsKey)
        XCTAssertFalse(CompanionPreferences.playsTransitions(defaults: defaults))
    }

    // MARK: Background job transcripts and the mood file

    private let now0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func file(_ id: String, minutesAgo: Double, cwd: String? = "/work") -> CompanionSessionFile {
        CompanionSessionFile(id: id, modified: now0.addingTimeInterval(-minutesAgo * 60), cwd: cwd)
    }

    private func choose(_ listing: [CompanionSessionFile], registeredAgo: Double = 120, registeredIDs: Set<String> = ["reg"],
                        cwd: String? = "/work", previous: String? = nil) -> String {
        CompanionSessionChoice.choose(registeredID: "reg", registeredModified: now0.addingTimeInterval(-registeredAgo * 60),
                                      listing: listing, registeredIDs: registeredIDs, now: now0,
                                      commanderCwd: cwd, previous: previous)
    }

    func testSessionChoicePicksANewerUnregisteredFile() {
        XCTAssertEqual(choose([file("job", minutesAgo: 1)]), "job")
        XCTAssertEqual(choose([file("old", minutesAgo: 5), file("job", minutesAgo: 1)]), "job", "the newest wins")
        XCTAssertEqual(choose([]), "reg")
    }

    func testSessionChoiceNeverTakesARegisteredSession() {
        XCTAssertEqual(choose([file("pawn", minutesAgo: 1)], registeredIDs: ["reg", "pawn"]), "reg")
        XCTAssertEqual(choose([file("pawn", minutesAgo: 1), file("job", minutesAgo: 3)], registeredIDs: ["reg", "pawn"]), "job")
    }

    func testSessionChoiceIgnoresStaleAndOlderFiles() {
        XCTAssertEqual(choose([file("stale", minutesAgo: 11)]), "reg", "quiet for over 10 minutes")
        XCTAssertEqual(choose([file("older", minutesAgo: 30)], registeredAgo: 20), "reg", "older than the registered file")
        XCTAssertEqual(choose([file("job", minutesAgo: 9.9)]), "job")
    }

    func testSessionChoiceChecksTheWorkingDirectory() {
        XCTAssertEqual(choose([file("elsewhere", minutesAgo: 1, cwd: "/other")]), "reg")
        XCTAssertEqual(choose([file("nocwd", minutesAgo: 1, cwd: nil)]), "reg")
        XCTAssertEqual(choose([file("job", minutesAgo: 1, cwd: "/work/")]), "job", "a trailing slash does not matter")
        XCTAssertEqual(choose([file("anywhere", minutesAgo: 1, cwd: "/other")], cwd: nil), "anywhere",
                       "no pane directory known: not required")
    }

    func testSessionChoiceKeepsTheOrphanInUseAndFallsBack() {
        // B is a little newer than A: no flip-flop. Much newer: switch.
        XCTAssertEqual(choose([file("a", minutesAgo: 2), file("b", minutesAgo: 1.7)], previous: "a"), "a")
        XCTAssertEqual(choose([file("a", minutesAgo: 5), file("b", minutesAgo: 1)], previous: "a"), "b")
        // The orphan went quiet for 10 minutes: back to the registered session.
        XCTAssertEqual(choose([file("a", minutesAgo: 10.5)], previous: "a"), "reg")
        // The orphan became registered: never kept.
        XCTAssertEqual(choose([file("a", minutesAgo: 1)], registeredIDs: ["reg", "a"], previous: "a"), "reg")
    }

    func testReaderFollowsAnUnregisteredNewerFileInTheSameFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wooloo-sess-\(UUID())")
        let folder = root.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        func write(_ id: String, cwd: String, age: TimeInterval) throws {
            let url = folder.appendingPathComponent("\(id).jsonl")
            try "{\"cwd\":\"\(cwd)\",\"type\":\"user\"}\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
        }
        try write("reg-1", cwd: "/work", age: 3600)
        try write("job-1", cwd: "/work", age: 30)
        try write("pawn-1", cwd: "/work", age: 10)
        try write("far-1", cwd: "/other", age: 5)
        let reader = CompanionTranscriptReader(projects: root)
        let chosen = await reader.effectiveSessionID(registered: "reg-1", registeredIDs: ["reg-1", "pawn-1"],
                                                     commanderCwd: "/work", now: now)
        XCTAssertEqual(chosen, "job-1")
        let alone = await CompanionTranscriptReader(projects: root).effectiveSessionID(
            registered: "reg-1", registeredIDs: ["reg-1", "pawn-1", "job-1", "far-1"], commanderCwd: "/work", now: now)
        XCTAssertEqual(alone, "reg-1")
    }

    func testMoodFilePayloadHasOnlyMoodSkinAndTime() throws {
        let data = CompanionMoodState.payload(mood: "game", skin: "streamer", time: Date(timeIntervalSince1970: 1_800_000_000))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["mood", "skin", "t"])
        XCTAssertEqual(object["mood"] as? String, "game")
        XCTAssertEqual(object["skin"] as? String, "streamer")
        XCTAssertEqual(object["t"] as? Int, 1_800_000_000)
        XCTAssertEqual(CompanionMoodState.fileURL(companionDirectory: URL(fileURLWithPath: "/h/wooloo-companion/ame")).path,
                       "/h/wooloo-companion/state/mood.json")
    }

    func testMoodFileIsWrittenOnChangeAndEveryThirtySeconds() {
        let t = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(CompanionMoodState.isDue(key: "idle", lastKey: nil, lastWrite: nil, now: t))
        XCTAssertFalse(CompanionMoodState.isDue(key: "idle", lastKey: "idle", lastWrite: t, now: t.addingTimeInterval(29)))
        XCTAssertTrue(CompanionMoodState.isDue(key: "idle", lastKey: "idle", lastWrite: t, now: t.addingTimeInterval(30)))
        XCTAssertTrue(CompanionMoodState.isDue(key: "working", lastKey: "idle", lastWrite: t, now: t.addingTimeInterval(1)))
    }

    // MARK: Animation polish

    private func timeline(_ style: CompanionClipStyle, frames: Int = 4, fps: Double = 4, seed: UInt64 = 7) -> CompanionClipTimeline {
        CompanionClipTimeline(style: style, frames: frames, fps: fps, seed: seed)
    }

    func testBlinkHoldsFrameZeroForTwoAndAHalfToSixSeconds() {
        for seed in UInt64(1)...20 {
            let line = timeline(.blink, seed: seed)
            var start = 0.0
            for index in 0..<30 {
                let cycle = line.cycle(index, start: start)
                XCTAssertTrue(CompanionClipTimeline.blinkHold.contains(cycle.hold), "hold \(cycle.hold)")
                XCTAssertEqual(line.frame(at: cycle.start + cycle.hold * 0.5), 0)
                start = cycle.end
            }
        }
    }

    func testBlinkIsSlowAndNeverFlipsFasterThanTwelveFramesPerSecond() {
        let line = timeline(.blink, frames: 3, seed: 11)
        var changes: [TimeInterval] = []
        var last = line.frame(at: 0)
        var t = 0.0
        while t < 120 {
            t += 0.01
            let frame = line.frame(at: t)
            if frame != last { changes.append(t); last = frame }
        }
        for (a, b) in zip(changes, changes.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b - a, 1 / 12 - 0.0205, "frames \(a) -> \(b)")
        }
        // About one blink (two to three changes of frame) per 2.5 s at the very most.
        XCTAssertLessThanOrEqual(Double(changes.count) / 3 * 2.5, 120 * 1.0 + 2.5 * 3)
        let blinks = changes.filter { line.frame(at: $0) == 0 }.count
        XCTAssertLessThanOrEqual(Double(blinks) * 2.5, 120 + 2.5 * 2.0 * 2, "no more than ~1 blink per 2.5 s")
    }

    func testBlinkReturnsToFrameZeroAndSometimesDoubles() {
        let line = timeline(.blink, frames: 3, seed: 5)
        var doubles = 0
        var start = 0.0
        for index in 0..<200 {
            let cycle = line.cycle(index, start: start)
            if cycle.isDouble { doubles += 1 }
            XCTAssertEqual(line.frame(at: cycle.end - 0.001) == 0 || cycle.play > 0, true)
            XCTAssertEqual(line.frame(at: cycle.end + 0.001), 0, "the next cycle starts on frame 0")
            start = cycle.end
        }
        XCTAssertTrue((15...70).contains(doubles), "about 20% of cycles: \(doubles)")
    }

    func testGestureHoldsThenPlaysAllFramesOnceAtItsOwnFPS() {
        let line = timeline(.gesture, frames: 4, fps: 2, seed: 3)
        let cycle = line.cycle(at: 0)
        XCTAssertTrue(CompanionClipTimeline.gestureHold.contains(cycle.hold))
        XCTAssertEqual(line.frame(at: cycle.hold - 0.01), 0)
        XCTAssertEqual(cycle.play, 2, accuracy: 0.0001)
        XCTAssertEqual(line.frame(at: cycle.hold + 0.01), 0)
        XCTAssertEqual(line.frame(at: cycle.hold + 0.6), 1)
        XCTAssertEqual(line.frame(at: cycle.hold + 1.9), 3)
        XCTAssertEqual(line.frame(at: cycle.end + 0.01), 0, "then it rests again")
    }

    func testOneFrameClipsJustHold() {
        for style in [CompanionClipStyle.blink, .gesture] {
            let line = timeline(style, frames: 1)
            XCTAssertTrue(stride(from: 0.0, to: 60, by: 0.37).allSatisfy { line.frame(at: $0) == 0 })
            XCTAssertTrue(line.isResting(at: 30))
        }
    }

    func testTimelineIsTheSameForTheSameSeedAndDiffersBetweenSeeds() {
        XCTAssertEqual(timeline(.blink, seed: 9).cycle(at: 50), timeline(.blink, seed: 9).cycle(at: 50))
        XCTAssertNotEqual(timeline(.blink, seed: 9).cycle(0, start: 0).hold, timeline(.blink, seed: 10).cycle(0, start: 0).hold)
    }

    func testRotationWaitsForAStyledClipToRest() throws {
        let json = #"{"version":1,"size":[1,1],"moods":{"idle":["#
            + #"{"dir":"a","frames":3,"fps":4,"loop":true,"style":"blink"},"#
            + #"{"dir":"b","frames":3,"fps":4,"loop":true,"style":"blink"}]}}"#
        let manifest = try XCTUnwrap(CompanionManifest.decode(Data(json.utf8)))
        var player = CompanionPlayer()
        let start = Date(timeIntervalSince1970: 5000)
        player.advance(now: start, mood: .idle, manifest: manifest, pick: { _ in 0 })
        let first = try XCTUnwrap(player.sequence)
        let line = CompanionClipTimeline(sequence: first, seed: player.seed)
        // Find a moment after 15 s when the clip is mid-blink, and one when it rests.
        var busy: TimeInterval?
        var resting: TimeInterval?
        var t = 15.0
        while t < 60, busy == nil || resting == nil {
            if line.isResting(at: t) { resting = resting ?? t } else { busy = busy ?? t }
            t += 0.05
        }
        let mid = try XCTUnwrap(busy)
        XCTAssertFalse(player.advance(now: start.addingTimeInterval(mid), mood: .idle, manifest: manifest, pick: { _ in 0 }),
                       "not in the middle of a blink")
        XCTAssertEqual(player.sequence, first)
    }

    func testRotationWaitsUntilTheNextVariantIsLoaded() throws {
        let json = #"{"version":1,"size":[1,1],"moods":{"idle":["#
            + #"{"dir":"a","frames":2,"fps":4,"loop":true},{"dir":"b","frames":2,"fps":4,"loop":true}]}}"#
        let manifest = try XCTUnwrap(CompanionManifest.decode(Data(json.utf8)))
        var player = CompanionPlayer()
        let start = Date(timeIntervalSince1970: 5000)
        player.advance(now: start, mood: .idle, manifest: manifest, pick: { _ in 0 })
        player.advance(now: start.addingTimeInterval(13), mood: .idle, manifest: manifest, pick: { _ in 0 })
        XCTAssertEqual(player.upcoming?.dir, "b", "chosen ahead of the switch")
        XCTAssertFalse(player.advance(now: start.addingTimeInterval(16), mood: .idle, manifest: manifest,
                                      pick: { _ in 0 }, isLoaded: { _ in false }))
        XCTAssertEqual(player.sequence?.dir, "a", "still on the old one while b loads")
        XCTAssertTrue(player.advance(now: start.addingTimeInterval(17), mood: .idle, manifest: manifest,
                                     pick: { _ in 0 }, isLoaded: { _ in true }))
        XCTAssertEqual(player.sequence?.dir, "b")
    }

    func testVisibleBoundsUnionAndAConstantAnchorWithinASequence() {
        let union = CompanionSprite.union([CGRect(x: 0.2, y: 0.2, width: 0.2, height: 0.2), nil,
                                           CGRect(x: 0.5, y: 0.1, width: 0.3, height: 0.2)])
        let box = try? XCTUnwrap(union)
        XCTAssertEqual(box?.minX ?? -1, 0.2, accuracy: 0.0001)
        XCTAssertEqual(box?.minY ?? -1, 0.1, accuracy: 0.0001)
        XCTAssertEqual(box?.width ?? -1, 0.6, accuracy: 0.0001)
        XCTAssertEqual(box?.height ?? -1, 0.3, accuracy: 0.0001)
        XCTAssertNil(CompanionSprite.union([nil, nil]))
        let size = CGSize(width: 100, height: 100)
        let anchors = (0..<5).map { _ in
            CompanionScene.zoomAnchor(spriteRect: [10, 10, 80, 80], backgroundSize: CGSize(width: 200, height: 200),
                                      imageSize: size, visible: union)
        }
        XCTAssertEqual(Set(anchors.map { "\($0.x),\($0.y)" }).count, 1, "the same for every frame of a sequence")
    }

    func testSettingsTilesWrapIntoRowsWithinTheWidth() {
        XCTAssertEqual(CompanionSettingsLayout.columnCount(contentWidth: 250 - CompanionSettingsLayout.chrome), 4)
        XCTAssertEqual(CompanionSettingsLayout.columnCount(contentWidth: 10), 1)
        XCTAssertEqual(Int((15.0 / 4.0).rounded(.up)), 4, "15 activities take four rows")
        XCTAssertEqual(CompanionSettingsLayout.maximumHeight(screenHeight: 2000), 560)
        XCTAssertEqual(CompanionSettingsLayout.maximumHeight(screenHeight: 600), 420)
    }
}
