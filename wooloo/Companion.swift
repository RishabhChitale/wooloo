import AppKit
import CoreText
import ImageIO
import SwiftUI

// A small animated companion above the Spaces list in the right sidebar. Its frames are not part
// of wooloo: they are read from a local folder (see `CompanionManifest.directory`) and the
// companion is hidden when that folder or its manifest is missing.

/// What the companion is doing, taken from the status of the Space's commander agent.
enum CompanionMood: String, CaseIterable, Sendable {
    case working, idle, done, waiting

    /// Herdr's agent statuses; anything unknown, or no commander at all, is idle.
    init(agentStatus: String?) {
        switch agentStatus?.lowercased() {
        case "working": self = .working
        case "blocked", "needs-input", "needs_input", "request", "waiting": self = .waiting
        case "done": self = .done
        default: self = .idle
        }
    }

    /// The agent named "commander" or "commander-…" in the Space.
    /// The side-chat agent named "ame", in any Space.
    static func ame(in agents: [HerdrAgent]) -> HerdrAgent? {
        agents.first { ($0.name ?? $0.displayAgent)?.lowercased() == "ame" }
    }

    static func commander(in agents: [HerdrAgent], workspaceID: String?) -> HerdrAgent? {
        agents.first { agent in
            guard agent.workspaceID == workspaceID, let name = (agent.name ?? agent.displayAgent)?.lowercased()
            else { return false }
            return name == "commander" || name.hasPrefix("commander-")
        }
    }
}

struct CompanionSequence: Decodable, Equatable, Sendable {
    let dir: String
    let frames: Int
    let fps: Double
    let loop: Bool

    /// Frame files are `<dir>/0.png`…; a folder outside the companion's own is never read.
    var isValid: Bool {
        frames > 0 && frames <= 600 && fps > 0 && fps <= 60 && !dir.isEmpty && !dir.hasPrefix("/")
            && !dir.split(separator: "/").contains("..")
    }

    var duration: Double { Double(frames) / fps }
}

struct CompanionActivity: Decodable, Equatable, Sendable, Identifiable {
    let id: String
    let label: String
    let icon: String
    let mood: String?
}

struct CompanionSkin: Decodable, Equatable, Sendable {
    let label: String
    let moods: [String: [CompanionSequence]]
}

struct CompanionSkinChoice: Equatable, Sendable {
    let id: String
    let label: String
}

struct CompanionSticker: Decodable, Equatable, Sendable, Identifiable {
    let id: String
    let label: String
    let image: String
}

/// One array element that fails to decode is skipped instead of failing the whole manifest.
private struct Lossy<Element: Decodable>: Decodable {
    let value: Element?
    init(from decoder: Decoder) throws { value = try? Element(from: decoder) }
}

extension CompanionManifest {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        size = try values.decode([Int].self, forKey: .size)
        moods = try values.decode([String: [CompanionSequence]].self, forKey: .moods)
        lines = try values.decodeIfPresent([String: [String]].self, forKey: .lines) ?? [:]
        background = try? values.decodeIfPresent(CompanionBackground.self, forKey: .background)
        spriteRect = try? values.decodeIfPresent([Double].self, forKey: .spriteRect)
        activities = ((try? values.decodeIfPresent([Lossy<CompanionActivity>].self, forKey: .activities)) ?? nil)?
            .compactMap(\.value) ?? []
        stickers = ((try? values.decodeIfPresent([Lossy<CompanionSticker>].self, forKey: .stickers)) ?? nil)?
            .compactMap(\.value) ?? []
        font = try? values.decodeIfPresent(String.self, forKey: .font)
        skins = ((try? values.decodeIfPresent([String: Lossy<CompanionSkin>].self, forKey: .skins)) ?? nil)?
            .compactMapValues(\.value) ?? [:]
    }
}

struct CompanionBackground: Decodable, Equatable, Sendable {
    let defaultPath: String
    let night: String?

    enum CodingKeys: String, CodingKey {
        case defaultPath = "default"
        case night
    }

    static func isNight(hour: Int) -> Bool { hour >= 20 || hour < 6 }

    /// Paths stay inside the companion folder, like frame folders.
    var isValid: Bool { [defaultPath, night].compactMap { $0 }.allSatisfy(Self.isSafe) }

    static func isSafe(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.split(separator: "/").contains("..")
    }
}

struct CompanionManifest: Decodable, Equatable, Sendable {
    let version: Int
    let size: [Int]
    let moods: [String: [CompanionSequence]]
    let lines: [String: [String]]
    /// A scene she stands in, with the rectangle (x, y, width, height in background pixels) her
    /// sprite is fitted into. Optional: without both, only the sprite is drawn.
    let background: CompanionBackground?
    let spriteRect: [Double]?
    /// What she does in her free time, one of which the user picks; a nil mood is not available yet.
    let activities: [CompanionActivity]
    let stickers: [CompanionSticker]
    /// A pixel font file in the companion folder, used by the boxes under her.
    let font: String?
    /// Other looks for the webcam, by id ("streamer", "dark_angel"…); the top-level `moods` are Ame's.
    let skins: [String: CompanionSkin]

    enum CodingKeys: String, CodingKey {
        case version, size, moods, lines, background, activities, stickers, font, skins
        case spriteRect = "sprite_rect"
    }

    /// `WOOLOO_COMPANION_DIR`, else `~/.local/share/wooloo-companion/ame`.
    static var directory: URL {
        if let path = ProcessInfo.processInfo.environment["WOOLOO_COMPANION_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/wooloo-companion/ame", isDirectory: true)
    }

    /// nil when the file is missing, not a version 1 manifest, or has no usable sequence.
    static func load(from directory: URL) -> CompanionManifest? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")) else { return nil }
        return decode(data)
    }

    static func decode(_ data: Data) -> CompanionManifest? {
        guard let manifest = try? JSONDecoder().decode(CompanionManifest.self, from: data),
              manifest.version == 1, manifest.size.count == 2 else { return nil }
        let usable = manifest.moods.mapValues { $0.filter(\.isValid) }
        guard usable.values.contains(where: { !$0.isEmpty }) else { return nil }
        let scene = manifest.background.flatMap { $0.isValid ? $0 : nil }
        let rect = manifest.spriteRect.flatMap { rect in
            rect.count == 4 && rect.allSatisfy(\.isFinite) && rect[0] >= 0 && rect[1] >= 0 && rect[2] > 0 && rect[3] > 0
                ? rect : nil
        }
        return CompanionManifest(version: 1, size: manifest.size, moods: usable, lines: manifest.lines,
                                 background: scene != nil && rect != nil ? scene : nil,
                                 spriteRect: scene != nil ? rect : nil,
                                 activities: manifest.activities.filter { CompanionBackground.isSafe($0.icon) },
                                 stickers: manifest.stickers.filter { CompanionBackground.isSafe($0.image) },
                                 font: manifest.font.flatMap { CompanionBackground.isSafe($0) ? $0 : nil },
                                 skins: manifest.skins.compactMapValues { skin in
                                     let usable = skin.moods.mapValues { $0.filter(\.isValid) }
                                     return usable.values.contains(where: { !$0.isEmpty })
                                         ? CompanionSkin(label: skin.label, moods: usable) : nil
                                 })
    }

    static let defaultSkin = "ame"

    /// The skins to choose from: Ame first, then the manifest's others in a fixed order.
    var skinChoices: [CompanionSkinChoice] {
        let order = ["streamer", "dark_angel"]
        let others = skins.keys.filter { $0 != Self.defaultSkin }.sorted { lhs, rhs in
            let (l, r) = (order.firstIndex(of: lhs) ?? order.count, order.firstIndex(of: rhs) ?? order.count)
            return l == r ? lhs < rhs : l < r
        }
        return ([Self.defaultSkin] + others).map {
            CompanionSkinChoice(id: $0, label: skins[$0]?.label ?? ($0 == Self.defaultSkin ? "Ame" : $0))
        }
    }

    /// `id` if it is a skin of this manifest, else Ame.
    func resolvedSkin(_ id: String?) -> String {
        id.flatMap { id in skinChoices.contains { $0.id == id } ? id : nil } ?? Self.defaultSkin
    }

    /// A skin's sequences for a mood; when it lacks the mood, its idle ones, then the top-level
    /// (Ame's) for that mood.
    func sequences(forKey key: String, skin: String?) -> [CompanionSequence] {
        guard let skin, let moods = skins[skin]?.moods else { return sequences(forKey: key) }
        if let own = moods[key], !own.isEmpty { return own }
        if let idle = moods["idle"], !idle.isEmpty { return idle }
        return sequences(forKey: key)
    }

    /// Whether the skin itself (Ame's top-level moods for Ame) has sequences for a mood, without
    /// the fallbacks of `sequences(forKey:skin:)`: an emotion it lacks is not shown.
    func hasOwnSequences(forKey key: String, skin: String?) -> Bool {
        if let skin, let moods = skins[skin]?.moods { return !(moods[key] ?? []).isEmpty }
        return !sequences(forKey: key).isEmpty
    }

    /// A still frame of the skin's idle sequence, for its tile in the settings.
    func previewPath(skin: String) -> String? {
        sequences(forKey: "idle", skin: skin).first.map { $0.dir + "/0.png" }
    }

    /// The sequences of a mood or of an activity's mood ("game", "stream_watch"…).
    func sequences(forKey key: String) -> [CompanionSequence] { moods[key] ?? [] }

    func activity(id: String?) -> CompanionActivity? { activities.first { $0.id == id } }

    /// Which sequences play: the commander's mood wins while it works or waits; when idle or done
    /// she plays the chosen activity's, if it is available and has sequences.
    func sequenceKey(mood: CompanionMood, activityID: String?, skin: String? = nil) -> String {
        guard mood == .idle || mood == .done, let key = activity(id: activityID)?.mood,
              !sequences(forKey: key, skin: skin).isEmpty else { return mood.rawValue }
        return key
    }

    /// The background file for `date`: the night one from 20:00 to 06:00 when there is one.
    func backgroundPath(at date: Date, calendar: Calendar = .current) -> String? {
        guard let background else { return nil }
        let night = CompanionBackground.isNight(hour: calendar.component(.hour, from: date))
        return night ? background.night ?? background.defaultPath : background.defaultPath
    }

    func sequences(for mood: CompanionMood) -> [CompanionSequence] { sequences(forKey: mood.rawValue) }
    func lines(for mood: CompanionMood) -> [String] { lines(forKey: mood.rawValue) }
    func lines(forKey key: String) -> [String] { (lines[key] ?? []).filter { !$0.isEmpty } }
}

/// Which sequence and speech line show now. Pure, so rotation is testable: `pick` returns an index
/// below its argument.
struct CompanionPlayer {
    static let loopRotation: TimeInterval = 15
    static let lineRotation: TimeInterval = 20

    private(set) var mood: CompanionMood?
    private(set) var playingKey: String?
    private(set) var sequence: CompanionSequence?
    private(set) var sequenceStart = Date.distantPast
    private(set) var line: String?
    private var playingLineKey: String?
    private var lineStart = Date.distantPast

    /// Moves to a new sequence or line when the mood changed, a one-shot sequence ended, a loop
    /// has played long enough, or a line has been up long enough. Returns whether anything changed.
    @discardableResult
    mutating func advance(now: Date, mood newMood: CompanionMood, manifest: CompanionManifest,
                          sequenceKey: String? = nil, skin: String? = nil, lineKey: String? = nil,
                          pick: (Int) -> Int = { Int.random(in: 0..<$0) }) -> Bool {
        var changed = false
        let moodChanged = mood != newMood
        let key = sequenceKey ?? newMood.rawValue
        let identity = (skin ?? "") + "|" + key
        let keyChanged = playingKey != identity
        let elapsed = now.timeIntervalSince(sequenceStart)
        if moodChanged || keyChanged || sequence == nil
            || (sequence.map { $0.loop ? elapsed >= Self.loopRotation : elapsed >= $0.duration } ?? true) {
            let choices = manifest.sequences(forKey: key, skin: skin)
            // Not the same sequence twice in a row when there is another one.
            let others = choices.filter { $0 != sequence }
            let pool = others.isEmpty || moodChanged || keyChanged ? choices : others
            let next = pool.isEmpty ? nil : pool[pick(pool.count)]
            changed = true
            sequence = next
            sequenceStart = now
        }
        let linesKey = lineKey ?? newMood.rawValue
        // A missing line is not retried every tick: a mood without lines simply has none.
        if moodChanged || playingLineKey != linesKey || lineStart == .distantPast
            || now.timeIntervalSince(lineStart) >= Self.lineRotation {
            playingLineKey = linesKey
            let lines = manifest.lines(forKey: linesKey)
            let others = lines.filter { $0 != line }
            let pool = others.isEmpty ? lines : others
            let next = pool.isEmpty ? nil : pool[pick(pool.count)]
            if next != line { changed = true }
            line = next
            lineStart = now
        }
        mood = newMood
        playingKey = identity
        return changed
    }

    /// The frame to show at `now`: a loop wraps, a one-shot holds its last frame.
    func frameIndex(at now: Date) -> Int {
        guard let sequence else { return 0 }
        let step = Int(max(0, now.timeIntervalSince(sequenceStart)) * sequence.fps)
        return sequence.loop ? step % sequence.frames : min(step, sequence.frames - 1)
    }

    /// What the commander said, if its transcript gave anything; else, while working, its terminal
    /// title; else a line of the mood.
    func bubbleText(dialogue: String? = nil, title: String?) -> String? {
        if let dialogue, !dialogue.isEmpty { return dialogue }
        if mood == .working, let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        return line
    }
}

/// Feelings that override the base mood, strongest first: scared, love, crying, sad, angry, stressed.
enum CompanionEmotion: String, CaseIterable, Sendable {
    case scared, love, crying, sad, angry, stressed
}

/// Which emotion words the commander's newest text holds. Words match whole, in lower case.
struct CompanionTextSignals: Equatable, Sendable {
    var scary = false
    var failure = false
    var sorry = false

    static let scaryWords: Set<String> = ["release", "publish", "tag", "delete", "force", "irreversible", "production"]
    static let failureWords: Set<String> = ["failed", "failure", "error", "broke", "broken", "couldn't", "can't",
                                            "denied", "blocked", "crashed"]

    init() {}

    init(text: String?) {
        guard let text else { return }
        let normalized = text.lowercased().replacingOccurrences(of: "’", with: "'")
        let words = Set(normalized.split(whereSeparator: { !($0.isLetter || $0 == "'") }).map(String.init))
        scary = !words.isDisjoint(with: Self.scaryWords)
        failure = !words.isDisjoint(with: Self.failureWords)
        sorry = words.contains("sorry")
    }
}

/// Signs of affection in what the user typed: love, cute, thanks, hearts…
enum CompanionAffection {
    static let words: Set<String> = ["love", "cute", "thanks", "ily"]
    static let phrases = ["thank you", "good job", "good girl"]
    static let duration: TimeInterval = 5 * 60

    /// `extra` are more phrases, such as the label of the LOVE sticker. Words and phrases match whole.
    static func matches(_ text: String?, extra: [String] = []) -> Bool {
        guard let text else { return false }
        let lowered = (CompanionMessage.stickerLabel(in: text) ?? text).lowercased().replacingOccurrences(of: "’", with: "'")
        if lowered.contains("<3") || lowered.unicodeScalars.contains(where: isHeart) { return true }
        let tokens = lowered.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'") }).map(String.init)
        if !words.isDisjoint(with: tokens) { return true }
        let padded = " " + tokens.joined(separator: " ") + " "
        return (phrases + extra.map { $0.lowercased() }).contains { phrase in
            let parts = phrase.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'") })
            return !parts.isEmpty && padded.contains(" " + parts.joined(separator: " ") + " ")
        }
    }

    /// When the newest affectionate message of the user was sent, among `messages`.
    static func newestLove(in messages: [CompanionMessage], extra: [String] = []) -> Date? {
        messages.filter { $0.role == .user && matches($0.text, extra: extra) }.compactMap(\.time).max()
    }

    /// The later of two love times.
    static func later(_ a: Date?, _ b: Date?) -> Date? {
        switch (a, b) {
        case let (a?, b?): return max(a, b)
        default: return a ?? b
        }
    }

    /// ♥ ♡ ❤ ❣ and the heart emoji (not the broken heart).
    private static func isHeart(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x2665, 0x2661, 0x2763, 0x2764, 0x1F493, 0x1F495...0x1F49F, 0x1F5A4, 0x1F90D, 0x1F90E, 0x1F9E1,
             0x1FA75...0x1FA77:
            return true
        default:
            return false
        }
    }
}
/// How long the commander has had the same status, restarted whenever the status changes.
struct CompanionStatusTimer: Equatable, Sendable {
    private(set) var status: String?
    private(set) var since: Date?

    mutating func observe(_ newStatus: String?, now: Date) {
        guard since == nil || newStatus != status else { return }
        status = newStatus
        since = now
    }

    func elapsed(now: Date) -> TimeInterval { since.map { max(0, now.timeIntervalSince($0)) } ?? 0 }
}

enum CompanionEmotionRules {
    static let messageWindow: TimeInterval = 10 * 60
    static let angryAfter: TimeInterval = 10 * 60
    static let stressedAfter: TimeInterval = 15 * 60

    /// The strongest emotion that applies, or nil for the base mood. `textTime` is when the newest
    /// assistant text was written; without it a text counts as too old for the failure rules.
    static func resolve(mood: CompanionMood, signals: CompanionTextSignals, textTime: Date?,
                        statusElapsed: TimeInterval, now: Date, loveTime: Date? = nil) -> CompanionEmotion? {
        let fresh = textTime.map { now.timeIntervalSince($0) <= messageWindow } ?? false
        if mood == .working, signals.scary { return .scared }
        if let loveTime, now.timeIntervalSince(loveTime) <= CompanionAffection.duration { return .love }
        if signals.failure, signals.sorry, fresh { return .crying }
        if signals.failure, fresh { return .sad }
        if mood == .waiting, statusElapsed > angryAfter { return .angry }
        if mood == .working, statusElapsed > stressedAfter { return .stressed }
        return nil
    }
}
/// One turn of the commander's conversation, as the JINE box shows it.
struct CompanionMessage: Equatable, Sendable {
    enum Role: Equatable, Sendable { case user, assistant }
    let role: Role
    let text: String
    let time: Date?

    static let maximumDisplayLength = 200
    static let maximumSendLength = 4000

    /// Markdown stripped, lines joined, capped for a bubble.
    var displayText: String {
        let flat = CompanionDialogue.stripMarkdown(text).replacingOccurrences(of: "\n", with: " ")
        guard flat.count > Self.maximumDisplayLength else { return flat }
        return String(flat.prefix(Self.maximumDisplayLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// What the chat sends for a tapped sticker, and the label back out of such a message.
    static func stickerMarker(_ label: String) -> String { "[sticker: \(label)]" }

    static func stickerLabel(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let opening = "[sticker: "
        guard trimmed.hasPrefix(opening), trimmed.hasSuffix("]"), !trimmed.contains("\n") else { return nil }
        let label = trimmed.dropFirst(opening.count).dropLast()
        guard !label.isEmpty, !label.contains("]") else { return nil }
        return String(label)
    }

    /// "last sent 5s ago", "…3m ago", "…2h ago", "…1d ago".
    static func lastSent(_ time: Date?, now: Date) -> String? {
        guard let time else { return nil }
        let seconds = max(0, Int(now.timeIntervalSince(time)))
        switch seconds {
        case ..<60: return "last sent \(seconds)s ago"
        case ..<3600: return "last sent \(seconds / 60)m ago"
        case ..<86_400: return "last sent \(seconds / 3600)h ago"
        default: return "last sent \(seconds / 86_400)d ago"
        }
    }

    /// The parameters of Herdr's `agent.prompt` (what `herdr agent prompt` sends) for a message to
    /// the agent in a pane; nil when there is nothing to send.
    static func promptParams(paneID: String, text: String) -> [String: String]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !paneID.isEmpty else { return nil }
        return ["target": paneID, "text": String(trimmed.prefix(maximumSendLength))]
    }
}

/// What the transcript's tail holds: the newest assistant text, and the last few messages.
struct CompanionTranscriptSnapshot: Equatable, Sendable {
    var text: String?
    var textTime: Date?
    /// The newest user message that was typed, for the affection rule; not kept beyond the model.
    var userText: String?
    var userTime: Date?
    var messages: [CompanionMessage] = []
}
/// What the commander says, taken from the text parts of its newest Claude Code reply. Only those
/// parts are read; the text is never logged or stored.
enum CompanionDialogue {
    static let maximumLength = 140

    /// The text parts of the newest `assistant` record in the tail of a transcript. A tail that
    /// starts in the middle of the file begins with a partial line, which is dropped. Records of
    /// other types, and replies without a text part (tool calls only), are skipped.
    static func latestAssistantText(inTail data: Data, startsMidFile: Bool) -> String? {
        latestAssistant(inTail: data, startsMidFile: startsMidFile)?.text
    }

    /// The same, with the time written on the record.
    static func latestAssistant(inTail data: Data, startsMidFile: Bool) -> (text: String, time: Date?)? {
        var body = data[...]
        if startsMidFile {
            guard let newline = body.firstIndex(of: 0x0A) else { return nil }
            body = body[body.index(after: newline)...]
        }
        for line in body.split(separator: 0x0A, omittingEmptySubsequences: true).reversed() {
            guard let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  record["type"] as? String == "assistant",
                  let message = record["message"] as? [String: Any] else { continue }
            var parts: [String] = []
            if let text = message["content"] as? String {
                parts.append(text)
            } else if let content = message["content"] as? [[String: Any]] {
                for part in content where part["type"] as? String == "text" {
                    if let text = part["text"] as? String { parts.append(text) }
                }
            }
            let text = parts.joined(separator: "\n")
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return (text, (record["timestamp"] as? String).flatMap(parseTime))
            }
        }
        return nil
    }

    /// The last `limit` messages of the conversation in a transcript's tail, oldest first: text the
    /// user typed (not tool results, meta or system records, nor anything starting with "<") and
    /// the text parts of assistant replies. Side-chain records (sub-agents) are left out.
    static func messages(inTail data: Data, startsMidFile: Bool, limit: Int = 4) -> [CompanionMessage] {
        var body = data[...]
        if startsMidFile {
            guard let newline = body.firstIndex(of: 0x0A) else { return [] }
            body = body[body.index(after: newline)...]
        }
        var result: [CompanionMessage] = []
        for line in body.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = record["type"] as? String, type == "user" || type == "assistant",
                  record["isMeta"] as? Bool != true, record["isSidechain"] as? Bool != true,
                  let message = record["message"] as? [String: Any] else { continue }
            var parts: [String] = []
            if let text = message["content"] as? String {
                parts.append(text)
            } else if let content = message["content"] as? [[String: Any]] {
                if type == "user", content.contains(where: { $0["type"] as? String == "tool_result" }) { continue }
                for part in content where part["type"] as? String == "text" {
                    if let text = part["text"] as? String { parts.append(text) }
                }
            }
            let text = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty || (type == "user" && text.hasPrefix("<")) { continue }
            result.append(CompanionMessage(role: type == "user" ? .user : .assistant, text: text,
                                           time: (record["timestamp"] as? String).flatMap(parseTime)))
        }
        return Array(result.suffix(limit))
    }

    private static func parseTime(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    /// Plain text lines: fenced code blocks dropped; headings, quotes, list bullets, emphasis and
    /// code ticks removed; links reduced to their text; whitespace collapsed.
    static func stripMarkdown(_ markdown: String) -> String {
        var kept: [String] = []
        var inFence = false
        for raw in markdown.components(separatedBy: .newlines) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            if inFence { continue }
            var line = trimmed
            line = line.replacingOccurrences(of: #"^(#{1,6}\s+|>+\s*|[-*+]\s+|\d+[.)]\s+)"#, with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: #"!?\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
            for mark in ["**", "__", "~~", "`", "*"] { line = line.replacingOccurrences(of: mark, with: "") }
            if line.allSatisfy({ "|-: ".contains($0) }) { continue }
            line = line.replacingOccurrences(of: "|", with: " ")
            line = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if !line.isEmpty { kept.append(line) }
        }
        return kept.joined(separator: "\n")
    }

    /// Sentences in order; a line break also ends one, so list items stay apart.
    static func sentences(fromMarkdown markdown: String) -> [String] {
        var result: [String] = []
        for line in stripMarkdown(markdown).components(separatedBy: "\n") {
            var current = ""
            let characters = Array(line)
            for (index, character) in characters.enumerated() {
                current.append(character)
                let endsSentence = ".!?…".contains(character)
                    && (index + 1 == characters.count || characters[index + 1].isWhitespace)
                if endsSentence {
                    result.append(current.trimmingCharacters(in: .whitespaces))
                    current = ""
                }
            }
            let rest = current.trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty { result.append(rest) }
        }
        return result
    }

    /// Working: what it is saying now (the last sentence). Waiting: its question, else the last
    /// sentence. Done or idle: how the reply begins.
    static func pick(mood: CompanionMood, emotion: CompanionEmotion? = nil, sentences: [String]) -> String? {
        let sentence: String?
        switch emotion {
        case .sad, .crying, .love: return sentences.first.map(cap)
        case .scared, .stressed: return sentences.last.map(cap)
        case .angry, nil: break
        }
        switch mood {
        case .working: sentence = sentences.last
        case .waiting: sentence = sentences.last(where: { $0.hasSuffix("?") }) ?? sentences.last
        case .done, .idle: sentence = sentences.first
        }
        return sentence.map(cap)
    }

    static func cap(_ sentence: String) -> String {
        guard sentence.count > maximumLength else { return sentence }
        return String(sentence.prefix(maximumLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// Finds `~/.claude/projects/*/<session>.jsonl` and reads only the end of it, at most every 1.5 s
/// and again only when its size or modification date changed.
actor CompanionTranscriptReader {
    static let tailBytes = 64 * 1024
    static let minimumInterval: TimeInterval = 1.5

    private struct Entry {
        var url: URL?
        var checked: Date?
        var size: Int?
        var modified: Date?
        var snapshot = CompanionTranscriptSnapshot()
    }

    private var entries: [String: Entry] = [:]
    private let projects: URL

    init(projects: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")) {
        self.projects = projects
    }

    /// Session ids are UUIDs; anything else never becomes a path.
    static func isSessionID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    func latestText(sessionID: String, now: Date = Date()) -> String? {
        snapshot(sessionID: sessionID, now: now).text
    }

    func snapshot(sessionID: String, now: Date = Date()) -> CompanionTranscriptSnapshot {
        guard Self.isSessionID(sessionID) else { return CompanionTranscriptSnapshot() }
        var entry = entries[sessionID] ?? Entry()
        defer { entries[sessionID] = entry }
        if let checked = entry.checked, now.timeIntervalSince(checked) < Self.minimumInterval { return entry.snapshot }
        entry.checked = now
        if entry.url == nil { entry.url = locate(sessionID) }
        guard let url = entry.url else { return entry.snapshot }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.intValue else {
            entry.url = nil
            entry.snapshot = CompanionTranscriptSnapshot()
            return entry.snapshot
        }
        let modified = attributes[.modificationDate] as? Date
        if size == entry.size, modified == entry.modified { return entry.snapshot }
        entry.size = size
        entry.modified = modified
        entry.snapshot = Self.readTail(of: url, size: size)
        return entry.snapshot
    }

    private func locate(_ sessionID: String) -> URL? {
        guard let folders = try? FileManager.default.contentsOfDirectory(
            at: projects, includingPropertiesForKeys: nil) else { return nil }
        return folders.map { $0.appendingPathComponent("\(sessionID).jsonl") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func readTail(of url: URL, size: Int) -> CompanionTranscriptSnapshot {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return CompanionTranscriptSnapshot() }
        defer { try? handle.close() }
        let offset = max(0, size - tailBytes)
        guard (try? handle.seek(toOffset: UInt64(offset))) != nil,
              let data = try? handle.readToEnd() else { return CompanionTranscriptSnapshot() }
        let latest = CompanionDialogue.latestAssistant(inTail: data, startsMidFile: offset > 0)
        let newestUser = CompanionDialogue.messages(inTail: data, startsMidFile: offset > 0, limit: Int.max)
            .last(where: { $0.role == .user })
        return CompanionTranscriptSnapshot(
            text: latest?.text, textTime: latest?.time,
            userText: newestUser?.text, userTime: newestUser?.time,
            messages: CompanionDialogue.messages(inTail: data, startsMidFile: offset > 0, limit: 24))
    }
}
/// Decoded frames, which `CompanionModel` keeps for the sequences it has played.
struct CompanionFrames: @unchecked Sendable {
    let images: [CGImage]
}

@MainActor
final class CompanionModel: ObservableObject {
    @Published private(set) var manifest: CompanionManifest?
    @Published private(set) var player = CompanionPlayer()
    @Published private(set) var loaded: [String: CompanionFrames] = [:]
    @Published private(set) var sentences: [String] = []
    @Published private(set) var messages: [CompanionMessage] = []
    @Published private(set) var sendError: String?
    /// The emotion she shows: the strongest rule that applies and that the manifest has sequences for.
    @Published private(set) var emotion: CompanionEmotion?
    private var signals = CompanionTextSignals()
    private var textTime: Date?
    private var commanderLoveTime: Date?
    private var ameLoveTime: Date?
    /// The newest affectionate message of the user to the commander or to Ame.
    private var loveTime: Date? { CompanionAffection.later(commanderLoveTime, ameLoveTime) }
    private let ameReader = CompanionTranscriptReader()
    private var ameSession: String?
    private var ameRequested = Date.distantPast
    private var ameInFlight = false
    private var unread = CompanionUnread()
    private var jineVisible = false
    private var nudges = CompanionNudgeScheduler()
    /// How many texts of Ame arrived while the JINE box was out of sight.
    @Published private(set) var unreadCount = 0
    private var statusTimer = CompanionStatusTimer()
    /// Single images of the companion folder (scene, activity icons, stickers), by relative path.
    @Published private(set) var images: [String: CGImage] = [:]
    /// The registered skin font, if the manifest has one.
    @Published private(set) var fontName: String?
    private var loading: Set<String> = []
    private var started = false
    private let reader = CompanionTranscriptReader()
    private var dialogueSession: String?
    private var dialogueRequested = Date.distantPast
    private var dialogueInFlight = false
    private var directory = CompanionManifest.directory
    private var currentSkin: String?

    /// Loading starts at creation: the view shows nothing until the manifest is in, so an
    /// `onAppear` on that empty content would never fire.
    init() { start() }

    func start() {
        guard !started else { return }
        started = true
        let directory = directory
        Task {
            let result = await Task.detached(priority: .utility) { () -> (CompanionManifest?, String?) in
                let manifest = CompanionManifest.load(from: directory)
                let font = manifest?.font.flatMap { CompanionFontLoader.register(at: directory.appendingPathComponent($0)) }
                return (manifest, font)
            }.value
            self.fontName = result.1
            self.manifest = result.0
            if let manifest = result.0 {
                let previews = manifest.skinChoices.compactMap { manifest.previewPath(skin: $0.id) }
                for path in manifest.activities.map(\.icon) + manifest.stickers.map(\.image) + previews {
                    self.ensureImage(path)
                }
            }
        }
    }

    /// Called as time passes and when the commander's mood or the chosen activity changes.
    func advance(now: Date, mood: CompanionMood, activityID: String? = nil, skin: String? = nil,
                 status: String? = nil) {
        guard let manifest else { return }
        var next = player
        let skin = manifest.skins.isEmpty ? nil : manifest.resolvedSkin(skin)
        if skin != currentSkin {
            // Another skin: the old one's frames are not needed any more.
            currentSkin = skin
            loaded = [:]
            loading = loading.filter { $0.hasPrefix("image:") }
        }
        statusTimer.observe(status ?? mood.rawValue, now: now)
        let candidate = CompanionEmotionRules.resolve(mood: mood, signals: signals, textTime: textTime,
                                                      statusElapsed: statusTimer.elapsed(now: now), now: now,
                                                      loveTime: loveTime)
        let applied = candidate.flatMap { manifest.hasOwnSequences(forKey: $0.rawValue, skin: skin) ? $0 : nil }
        if applied != emotion { emotion = applied }
        let lineKey = applied == .love && !manifest.lines(forKey: "love").isEmpty ? "love" : nil
        let key = applied?.rawValue ?? manifest.sequenceKey(mood: mood, activityID: activityID, skin: skin)
        if next.advance(now: now, mood: mood, manifest: manifest, sequenceKey: key, skin: skin,
                        lineKey: lineKey) { player = next }
        if let sequence = next.sequence { ensureLoaded(sequence) }
        if let path = manifest.backgroundPath(at: now) { ensureImage(path) }
    }

    /// The commander's words for the current mood, from its newest reply.
    var dialogue: String? {
        player.mood.flatMap { CompanionDialogue.pick(mood: $0, emotion: emotion, sentences: sentences) }
    }

    /// Re-reads the commander's transcript, off the main thread and at most every 1.5 s.
    func refreshDialogue(sessionID: String?, now: Date = Date()) {
        if sessionID != dialogueSession {
            dialogueSession = sessionID
            dialogueRequested = .distantPast
            if !sentences.isEmpty { sentences = [] }
            signals = CompanionTextSignals()
            textTime = nil
            commanderLoveTime = nil
        }
        guard let sessionID, !dialogueInFlight,
              now.timeIntervalSince(dialogueRequested) >= CompanionTranscriptReader.minimumInterval else { return }
        dialogueRequested = now
        dialogueInFlight = true
        let reader = reader
        Task {
            let snapshot = await reader.snapshot(sessionID: sessionID)
            self.dialogueInFlight = false
            guard self.dialogueSession == sessionID else { return }
            let next = snapshot.text.map { CompanionDialogue.sentences(fromMarkdown: $0) } ?? []
            if next != self.sentences { self.sentences = next }
            self.signals = CompanionTextSignals(text: snapshot.text)
            self.textTime = snapshot.textTime
            let loveLabels = (self.manifest?.stickers ?? []).filter { $0.id == "love" }.map(\.label)
            self.commanderLoveTime = CompanionAffection.matches(snapshot.userText, extra: loveLabels) ? snapshot.userTime : nil
        }
    }

    /// Reads Ame's transcript for the JINE box: her texts and the user's messages, without nudges.
    func refreshAme(sessionID: String?, now: Date = Date()) {
        if sessionID != ameSession {
            ameSession = sessionID
            ameRequested = .distantPast
            if !messages.isEmpty { messages = [] }
            ameLoveTime = nil
            unread = CompanionUnread()
            if unreadCount != 0 { unreadCount = 0 }
        }
        guard let sessionID, !ameInFlight,
              now.timeIntervalSince(ameRequested) >= CompanionTranscriptReader.minimumInterval else { return }
        ameRequested = now
        ameInFlight = true
        let reader = ameReader
        Task {
            let snapshot = await reader.snapshot(sessionID: sessionID)
            self.ameInFlight = false
            guard self.ameSession == sessionID else { return }
            let shown = CompanionNudge.visible(snapshot.messages)
            let next = Array(shown.suffix(4))
            if next != self.messages { self.messages = next }
            let loveLabels = (self.manifest?.stickers ?? []).filter { $0.id == "love" }.map(\.label)
            self.ameLoveTime = CompanionAffection.newestLove(in: shown, extra: loveLabels)
            self.updateUnread()
        }
    }

    /// Whether the JINE box is expanded in the key window; reading clears the unread count.
    func setJineVisible(_ visible: Bool) {
        jineVisible = visible
        updateUnread()
    }

    private func updateUnread() {
        unread.update(assistantTimes: messages.filter { $0.role == .assistant }.compactMap(\.time), visible: jineVisible)
        if unread.count != unreadCount { unreadCount = unread.count }
    }

    /// Called often: sends a nudge to Ame when one is due. Never logs or keeps the text.
    func tickNudge(now: Date, ame: HerdrAgent?, commanderStatus: String?, store: HerdrStore) {
        guard manifest != nil, let ame, store.isConnected else { return }
        let idle = CompanionMood(agentStatus: ame.agentStatus) == .idle
        guard nudges.due(now: now, ameIsIdle: idle) else { return }
        let hint = CompanionNudge.hint(commanderWorking: CompanionMood(agentStatus: commanderStatus) == .working,
                                       runningTasks: 0)
        guard let params = CompanionMessage.promptParams(paneID: ame.paneID, text: CompanionNudge.text(now: now, hint: hint))
        else { return }
        Task { try? await store.sendAgentPrompt(params) }
    }

    /// Sends a message to the commander through Herdr; false when it cannot be sent. The text is
    /// never logged or kept.
    func send(_ text: String, to commander: HerdrAgent?, via store: HerdrStore) async -> Bool {
        guard let commander, store.isConnected,
              let params = CompanionMessage.promptParams(paneID: commander.paneID, text: text) else { return false }
        do {
            try await store.sendAgentPrompt(params)
            sendError = nil
            return true
        } catch {
            sendError = "Not sent: \(error.localizedDescription)"
            return false
        }
    }

    /// The scene behind her at `now` (the night one in the evening), once loaded.
    func backgroundImage(at now: Date) -> CGImage? {
        manifest?.backgroundPath(at: now).flatMap { images[$0] }
    }

    func image(forPath path: String) -> CGImage? { images[path] }

    private var visibleCache: [ObjectIdentifier: (image: CGImage, bounds: CGRect?)] = [:]

    /// The visible (non-transparent) part of `image` as a rectangle of 0...1 fractions, found
    /// once per frame image and kept.
    func visibleBounds(of image: CGImage) -> CGRect? {
        let key = ObjectIdentifier(image)
        if let cached = visibleCache[key], cached.image === image { return cached.bounds }
        let bounds = CompanionSprite.visibleBounds(of: image)
        if visibleCache.count > 512 { visibleCache.removeAll() }
        visibleCache[key] = (image, bounds)
        return bounds
    }

    func image(at now: Date) -> CGImage? {
        guard let sequence = player.sequence, let frames = loaded[sequence.dir]?.images, !frames.isEmpty else { return nil }
        return frames[min(player.frameIndex(at: now), frames.count - 1)]
    }

    private func ensureImage(_ path: String) {
        guard images[path] == nil, loading.insert("image:" + path).inserted else { return }
        let url = directory.appendingPathComponent(path)
        Task {
            let image = await Task.detached(priority: .utility) { () -> CGImage? in
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                return CGImageSourceCreateImageAtIndex(source, 0, nil)
            }.value
            if let image { self.images[path] = image }
        }
    }

    private func ensureLoaded(_ sequence: CompanionSequence) {
        guard loaded[sequence.dir] == nil, loading.insert(sequence.dir).inserted else { return }
        let folder = directory.appendingPathComponent(sequence.dir, isDirectory: true)
        let count = sequence.frames
        Task {
            let frames = await Task.detached(priority: .utility) { () -> CompanionFrames in
                CompanionFrames(images: (0..<count).compactMap { index in
                    let url = folder.appendingPathComponent("\(index).png")
                    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                    return CGImageSourceCreateImageAtIndex(source, 0, nil)
                })
            }.value
            self.loaded[sequence.dir] = frames
            self.loading.remove(sequence.dir)
        }
    }
}

enum CompanionFontLoader {
    /// Registers a font file for this process and returns its PostScript name.
    nonisolated static func register(at url: URL) -> String? {
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let first = descriptors.first else { return nil }
        return CTFontDescriptorCopyAttribute(first, kCTFontNameAttribute) as? String
    }
}

/// The room: her scene and sprite with the speech bubble under it. The companion panel around it
/// decides whether there is anything to show.
struct CompanionView: View {
    @ObservedObject var model: CompanionModel
    let commander: HerdrAgent?
    /// The "ame" agent whose side chat the JINE box shows; the room itself keeps the commander.
    var ame: HerdrAgent?
    var store: HerdrStore?
    /// The sidebar's width; the room is 1.0 times as tall by default.
    let width: CGFloat
    @AppStorage(CompanionPreferences.activityKey) private var activityID = CompanionPreferences.defaultActivity
    @AppStorage(CompanionPreferences.skinKey) private var skin = CompanionManifest.defaultSkin
    @AppStorage(CompanionPreferences.heightFactorKey) private var heightFactor = CompanionPreferences.defaultHeightFactor
    @AppStorage(CompanionPreferences.zoomKey) private var zoom = CompanionPreferences.defaultZoom
    @State private var showsSettings = false
    @State private var dragStartFactor: Double?

    var body: some View {
        let mood = CompanionMood(agentStatus: commander?.agentStatus)
        TimelineView(.animation(minimumInterval: 1 / (model.player.sequence?.fps ?? 10))) { context in
            VStack(spacing: 6) {
                CompanionScene(background: model.backgroundImage(at: context.date),
                               spriteRect: model.manifest?.spriteRect,
                               sprite: model.image(at: context.date),
                               spriteVisible: model.image(at: context.date).flatMap { model.visibleBounds(of: $0) },
                               zoom: CompanionPreferences.clampedZoom(zoom))
                .frame(height: CompanionPreferences.roomHeight(width: width, factor: heightFactor))
                .overlay(alignment: .bottom) {
                    // A thin grab strip along the bottom edge; dragging down makes the room taller.
                    ResizeHandleArea(
                        vertical: true,
                        tooltip: "Drag to resize the webcam · double-click to reset",
                        onDrag: { translation in
                            guard width > 0 else { return }
                            let start = dragStartFactor ?? CompanionPreferences.clampedHeightFactor(heightFactor)
                            dragStartFactor = start
                            heightFactor = CompanionPreferences.clampedHeightFactor(start + translation / width)
                        },
                        onDragEnd: { dragStartFactor = nil },
                        onReset: { heightFactor = CompanionPreferences.defaultHeightFactor }
                    )
                    .frame(height: 7)
                }
                .overlay(alignment: .topTrailing) {
                    if model.manifest?.skins.isEmpty == false {
                        CompanionGearButton(isPresented: $showsSettings) {
                            CompanionWebcamSettings(model: model, isPresented: $showsSettings)
                        }
                    }
                }
                if let text = model.player.bubbleText(dialogue: model.dialogue,
                                                      title: commander?.terminalTitleStripped) {
                    CompanionBubble(text: text)
                }
            }
            .onChange(of: context.date) { _, date in
                model.advance(now: date, mood: mood, activityID: activityID, skin: skin, status: commander?.agentStatus)
                model.refreshDialogue(sessionID: commander?.agentSessionID, now: date)
                model.refreshAme(sessionID: ame?.agentSessionID, now: date)
                if let store { model.tickNudge(now: date, ame: ame, commanderStatus: commander?.agentStatus, store: store) }
            }
            .onChange(of: mood) { _, mood in model.advance(now: Date(), mood: mood, activityID: activityID, skin: skin, status: commander?.agentStatus) }
            .onChange(of: activityID) { _, id in model.advance(now: Date(), mood: mood, activityID: id, skin: skin, status: commander?.agentStatus) }
            .onChange(of: skin) { _, skin in model.advance(now: Date(), mood: mood, activityID: activityID, skin: skin, status: commander?.agentStatus) }
            .onAppear { model.advance(now: Date(), mood: mood, activityID: activityID, skin: skin, status: commander?.agentStatus) }
        }
        .accessibilityHidden(true)
    }
}

/// Her sprite, alone or in front of a background that fills the area (bottom-centered); the sprite is
/// fitted into `spriteRect`, given in background pixels, at the background's scale.
struct CompanionScene: View {
    let background: CGImage?
    let spriteRect: [Double]?
    let sprite: CGImage?
    /// The part of the sprite image that is not transparent, as 0...1 fractions (top-left origin).
    var spriteVisible: CGRect?
    /// The whole scene is magnified by this much around her sprite's center.
    var zoom: Double = 1

    /// The unit point to zoom around: the center of what is visible of the sprite image, which
    /// is fitted into `spriteRect` (background pixels) or, with `spriteRect` nil, into the whole
    /// area of `size`. Without visible bounds, the center of `spriteRect`, else the middle.
    static func zoomAnchor(spriteRect: [Double]?, backgroundSize size: CGSize,
                           imageSize: CGSize, visible: CGRect?) -> UnitPoint {
        guard let visible, let rect = spriteRect, rect.count == 4, rect.allSatisfy(\.isFinite),
              size.width > 0, size.height > 0, imageSize.width > 0, imageSize.height > 0,
              rect[2] > 0, rect[3] > 0 else {
            return zoomAnchor(spriteRect: spriteRect, backgroundSize: size)
        }
        let fit = min(rect[2] / imageSize.width, rect[3] / imageSize.height)
        let shown = CGSize(width: imageSize.width * fit, height: imageSize.height * fit)
        let x = rect[0] + (rect[2] - shown.width) / 2 + visible.midX * shown.width
        let y = rect[1] + (rect[3] - shown.height) / 2 + visible.midY * shown.height
        return UnitPoint(x: min(max(x / size.width, 0), 1), y: min(max(y / size.height, 0), 1))
    }

    /// Without a background the sprite fills the area, so the anchor is the visible center.
    static func zoomAnchor(visible: CGRect?, imageSize: CGSize, area: CGSize) -> UnitPoint {
        guard let visible, imageSize.width > 0, imageSize.height > 0, area.width > 0, area.height > 0 else { return .center }
        let fit = min(area.width / imageSize.width, area.height / imageSize.height)
        let shown = CGSize(width: imageSize.width * fit, height: imageSize.height * fit)
        let x = (area.width - shown.width) / 2 + visible.midX * shown.width
        let y = (area.height - shown.height) / 2 + visible.midY * shown.height
        return UnitPoint(x: min(max(x / area.width, 0), 1), y: min(max(y / area.height, 0), 1))
    }

    /// Where the sprite's center is within a background of `size`, as a unit point, for the
    /// zoom to scale around. The middle when there is no usable rectangle.
    static func zoomAnchor(spriteRect: [Double]?, backgroundSize size: CGSize) -> UnitPoint {
        guard let rect = spriteRect, rect.count == 4, size.width > 0, size.height > 0,
              rect.allSatisfy(\.isFinite) else { return .center }
        let x = (rect[0] + rect[2] / 2) / size.width
        let y = (rect[1] + rect[3] / 2) / size.height
        return UnitPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }

    /// The scale that fits `content` into `area` without cropping.
    static func fitScale(content: CGSize, in area: CGSize) -> CGFloat {
        guard content.width > 0, content.height > 0 else { return 1 }
        return min(area.width / content.width, area.height / content.height)
    }

    /// The scale that makes `content` cover `area` completely: the larger of the two fits, so
    /// the background is cropped on one axis and never leaves a band.
    static func fillScale(content: CGSize, in area: CGSize) -> CGFloat {
        guard content.width > 0, content.height > 0 else { return 1 }
        return max(area.width / content.width, area.height / content.height)
    }

    var body: some View {
        GeometryReader { area in
            if let background, let rect = spriteRect, rect.count == 4 {
                let size = CGSize(width: background.width, height: background.height)
                let scale = Self.fillScale(content: size, in: area.size)
                ZStack(alignment: .topLeading) {
                    Image(decorative: background, scale: 1)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: size.width * scale, height: size.height * scale)
                    if let sprite {
                        Image(decorative: sprite, scale: 1)
                            .interpolation(.none)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: rect[2] * scale, height: rect[3] * scale)
                            .offset(x: rect[0] * scale, y: rect[1] * scale)
                    }
                }
                .frame(width: size.width * scale, height: size.height * scale)
                .scaleEffect(zoom, anchor: Self.zoomAnchor(
                    spriteRect: rect, backgroundSize: size,
                    imageSize: sprite.map { CGSize(width: $0.width, height: $0.height) } ?? .zero,
                    visible: spriteVisible))
                // Bottom-center: the extra width is cropped evenly left and right, the extra
                // height at the top, so the picture always reaches every edge of the room.
                .frame(width: area.size.width, height: area.size.height, alignment: .bottom)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            } else if let sprite {
                Image(decorative: sprite, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: area.size.width, height: area.size.height)
                    .scaleEffect(zoom, anchor: Self.zoomAnchor(
                        visible: spriteVisible, imageSize: CGSize(width: sprite.width, height: sprite.height),
                        area: area.size))
                    .clipped()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A rounded speech bubble whose tail points up at the companion.
private struct CompanionBubble: View {
    let text: String
    @Environment(\.woolooTypography) private var typography

    var body: some View {
        Text(text)
            .font(.system(size: typography.secondary))
            .foregroundStyle(Color(red: 0.22, green: 0.15, blue: 0.3))
            .lineLimit(4)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Color(red: 0.93, green: 0.85, blue: 0.97), in: RoundedRectangle(cornerRadius: 9))
            .overlay(alignment: .top) {
                Triangle()
                    .fill(Color(red: 0.93, green: 0.85, blue: 0.97))
                    .frame(width: 12, height: 6)
                    .offset(y: -6)
            }
    }

    private struct Triangle: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.closeSubpath()
            return path
        }
    }
}

/// Facts about a sprite frame's pixels.
enum CompanionSprite {
    /// The smallest rectangle, in 0...1 fractions of the image with the origin at the top left,
    /// that holds every pixel with some alpha; nil when the image is fully transparent or empty.
    static func visibleBounds(of image: CGImage) -> CGRect? {
        let width = image.width, height = image.height
        guard width > 0, height > 0, width * height <= 16_000_000 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            let row = y * width * 4
            for x in 0..<width where pixels[row + x * 4 + 3] != 0 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                maxY = y
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: Double(minX) / Double(width), y: Double(minY) / Double(height),
                      width: Double(maxX - minX + 1) / Double(width),
                      height: Double(maxY - minY + 1) / Double(height))
    }
}

// MARK: Side chat with Ame

/// The random texts the app sends to the "ame" agent, and which messages the JINE box hides.
enum CompanionNudge {
    static let prefix = "[nudge]"
    /// Seconds between two nudges, drawn at random.
    static let delayRange: ClosedRange<TimeInterval> = (45 * 60)...(150 * 60)
    /// Local hours in which nothing is sent: 01:00 up to 09:00.
    static let quietHours = 1..<9
    static let maximumPerDay = 8

    static func isNudge(_ text: String) -> Bool {
        text.drop(while: { $0.isWhitespace }).hasPrefix(prefix)
    }

    /// Without the user messages that are nudges.
    static func visible(_ messages: [CompanionMessage]) -> [CompanionMessage] {
        messages.filter { !($0.role == .user && isNudge($0.text)) }
    }

    static func isQuiet(_ date: Date, calendar: Calendar = .current) -> Bool {
        quietHours.contains(calendar.component(.hour, from: date))
    }

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
    }

    static func hint(commanderWorking: Bool, runningTasks: Int) -> String {
        if runningTasks > 0 { return runningTasks == 1 ? "1 task running" : "\(runningTasks) tasks running" }
        return commanderWorking ? "the commander is working" : "everything is quiet"
    }

    /// "[nudge] it's Tuesday 3:05 PM; everything is quiet"
    static func text(now: Date, hint: String, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEEE h:mm a"
        return "\(prefix) it's \(formatter.string(from: now)); \(hint)"
    }
}

/// When the next nudge is due. The count per local day is kept in UserDefaults; the next time
/// lives only while the app runs.
struct CompanionNudgeScheduler {
    static let dayKey = "companionNudgeDay"
    static let countKey = "companionNudgeCount"

    private(set) var nextFire: Date?

    /// True once, when a nudge should go out now; this counts it and picks the next time. Out of
    /// hours or past the daily limit the time is only moved on. A busy Ame waits, without moving it.
    mutating func due(now: Date, ameIsIdle: Bool, calendar: Calendar = .current,
                      defaults: UserDefaults = .standard,
                      random: (ClosedRange<TimeInterval>) -> TimeInterval = { Double.random(in: $0) }) -> Bool {
        guard let fire = nextFire else {
            nextFire = now.addingTimeInterval(random(CompanionNudge.delayRange))
            return false
        }
        guard now >= fire else { return false }
        let today = CompanionNudge.dayKey(now, calendar: calendar)
        let sent = defaults.string(forKey: Self.dayKey) == today ? defaults.integer(forKey: Self.countKey) : 0
        if CompanionNudge.isQuiet(now, calendar: calendar) || sent >= CompanionNudge.maximumPerDay {
            nextFire = now.addingTimeInterval(random(CompanionNudge.delayRange))
            return false
        }
        guard ameIsIdle else { return false }
        defaults.set(today, forKey: Self.dayKey)
        defaults.set(sent + 1, forKey: Self.countKey)
        nextFire = now.addingTimeInterval(random(CompanionNudge.delayRange))
        return true
    }
}

/// How many of Ame's texts arrived while the JINE box was out of sight.
struct CompanionUnread: Equatable {
    private var seen: Date?
    private var primed = false
    private(set) var count = 0

    /// `assistantTimes` are the send times of her texts in the transcript. What is there the first
    /// time is taken as read.
    mutating func update(assistantTimes: [Date], visible: Bool) {
        if visible || !primed {
            count = 0
            seen = assistantTimes.max() ?? seen
            primed = true
            return
        }
        guard let seen else { count = assistantTimes.count; return }
        count = assistantTimes.filter { $0 > seen }.count
    }
}
