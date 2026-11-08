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
    /// "loop" (the default), "blink" or "gesture": how the frames are timed; see `CompanionClipTimeline`.
    var style: String?

    var isStyled: Bool { CompanionClipStyle(style) != .loop }

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

/// A thing she does on her own while idle: a clip key the skin may define (`tweet`, `comics`…),
/// the base moods it suits, how likely it is, and the hearts level it fits. The time of day plays
/// no part. `sleep` is the nap's clip and never an ambient one.
struct CompanionAmbient: Decodable, Equatable, Sendable {
    let key: String
    let moods: [String]
    let weight: Double
    /// It is eligible only while her hearts level is within these (0...100 when not given).
    let minHearts: Double?
    let maxHearts: Double?

    enum CodingKeys: String, CodingKey { case key, moods, weight, minHearts, maxHearts }

    init(key: String, moods: [String], weight: Double = 1, minHearts: Double? = nil, maxHearts: Double? = nil) {
        self.key = key
        self.moods = moods
        self.weight = weight
        self.minHearts = minHearts
        self.maxHearts = maxHearts
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        key = try values.decode(String.self, forKey: .key)
        moods = (try? values.decodeIfPresent([String].self, forKey: .moods)) ?? []
        weight = try values.decode(Double.self, forKey: .weight)
        minHearts = (try? values.decodeIfPresent(Double.self, forKey: .minHearts)) ?? nil
        maxHearts = (try? values.decodeIfPresent(Double.self, forKey: .maxHearts)) ?? nil
    }

    var isValid: Bool {
        !key.isEmpty && key != "sleep" && key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
            && !moods.isEmpty && weight.isFinite && weight > 0
            && (minHearts.map { $0.isFinite } ?? true) && (maxHearts.map { $0.isFinite } ?? true)
    }

    /// Whether the hearts level allows it.
    func fits(hearts: Double) -> Bool {
        hearts >= (minHearts ?? 0) && hearts <= (maxHearts ?? 100)
    }
}

/// A cutscene played when the skin changes: full-scene frames `<dir>/000.png`….
struct CompanionTransition: Decodable, Equatable, Sendable {
    /// A skin id, or "*" for any skin.
    let from: String
    let to: String
    let dir: String
    let frames: Int
    let fps: Double
    let reverse: Bool

    enum CodingKeys: String, CodingKey { case from, to, dir, frames, fps, reverse }

    init(from: String, to: String, dir: String, frames: Int, fps: Double, reverse: Bool = false) {
        self.from = from
        self.to = to
        self.dir = dir
        self.frames = frames
        self.fps = fps
        self.reverse = reverse
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        from = try values.decode(String.self, forKey: .from)
        to = try values.decode(String.self, forKey: .to)
        dir = try values.decode(String.self, forKey: .dir)
        frames = try values.decode(Int.self, forKey: .frames)
        fps = try values.decode(Double.self, forKey: .fps)
        reverse = (try? values.decodeIfPresent(Bool.self, forKey: .reverse)) ?? false
    }

    var isValid: Bool {
        !from.isEmpty && !to.isEmpty && to != "*" && frames > 0 && frames <= 600 && fps > 0 && fps <= 60
            && CompanionBackground.isSafe(dir)
    }

    var duration: Double { Double(frames) / fps }

    /// The frame file numbers in the order they are shown.
    var order: [Int] { reverse ? Array((0..<frames).reversed()) : Array(0..<frames) }

    /// Which frame to show `elapsed` seconds in; nil once the cutscene is over.
    func position(elapsed: TimeInterval) -> Int? {
        guard elapsed >= 0 else { return 0 }
        let position = Int(elapsed * fps)
        return position < frames ? position : nil
    }
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
        transitions = ((try? values.decodeIfPresent([Lossy<CompanionTransition>].self, forKey: .transitions)) ?? nil)?
            .compactMap(\.value) ?? []
        ambient = ((try? values.decodeIfPresent([Lossy<CompanionAmbient>].self, forKey: .ambient)) ?? nil)?
            .compactMap(\.value) ?? []
        headpat = ((try? values.decodeIfPresent(CompanionHeadpat.self, forKey: .headpat)) ?? nil)
        hearts = ((try? values.decodeIfPresent(CompanionHearts.self, forKey: .hearts)) ?? nil)
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
    /// Cutscenes for skin changes.
    var transitions: [CompanionTransition] = []
    /// What she does on her own while idle.
    var ambient: [CompanionAmbient] = []
    /// Headpats and hearts; optional, and the feature is off without them.
    var headpat: CompanionHeadpat?
    var hearts: CompanionHearts?

    enum CodingKeys: String, CodingKey {
        case version, size, moods, lines, background, activities, stickers, font, skins, transitions, ambient
        case headpat, hearts
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
        return decode(data)?.droppingMissingTransitions(in: directory)
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
                                 },
                                 transitions: manifest.transitions.filter(\.isValid),
                                 ambient: manifest.ambient.filter(\.isValid),
                                 headpat: manifest.headpat.flatMap { $0.isUsable ? $0 : nil },
                                 hearts: manifest.hearts.flatMap { $0.isUsable ? $0 : nil })
    }

    /// The cutscene for changing from skin `old` to `new`: an exact match first, then one from
    /// any skin ("*"), else none.
    func transition(from old: String, to new: String) -> CompanionTransition? {
        guard old != new else { return nil }
        return transitions.first { $0.from == old && $0.to == new }
            ?? transitions.first { $0.from == "*" && $0.to == new }
    }

    /// The animations the camera is fitted to, whichever one is playing: the base and emotion
    /// moods the skin has of its own.
    static let cameraKeys = ["working", "idle", "done", "waiting", "angry", "stressed", "sad", "crying", "scared", "love"]

    func cameraSequences(skin: String?) -> [CompanionSequence] {
        var seen: Set<String> = []
        return Self.cameraKeys.filter { hasOwnSequences(forKey: $0, skin: skin) }
            .flatMap { sequences(forKey: $0, skin: skin) }
            .filter { seen.insert($0.dir).inserted }
    }

    /// The same manifest without the cutscenes whose folder is missing in `directory`.
    func droppingMissingTransitions(in directory: URL) -> CompanionManifest {
        var copy = self
        copy.transitions = transitions.filter { transition in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(transition.dir).path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
        return copy
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
enum CompanionClipStyle: String, Sendable {
    case loop, blink, gesture

    init(_ name: String?) { self = name.flatMap { Self(rawValue: $0.lowercased()) } ?? .loop }
}

/// The timing of a "blink" or "gesture" clip, as a pure function of the time since it started.
/// Frame 0 is held for a random while, then the rest plays once; every cycle draws its own
/// numbers from `seed`, so it never settles into a rhythm.
struct CompanionClipTimeline: Sendable {
    static let blinkFPS = 12.0
    static let blinkHold: ClosedRange<Double> = 2.5...6.0
    static let gestureHold: ClosedRange<Double> = 1.5...4.0
    static let doubleBlinkChance = 0.2
    /// The pause between the two blinks of a double blink.
    static let doubleBlinkGap = 0.12

    let style: CompanionClipStyle
    let frames: Int
    let fps: Double
    let seed: UInt64

    init(sequence: CompanionSequence, seed: UInt64) {
        self.init(style: CompanionClipStyle(sequence.style), frames: sequence.frames, fps: sequence.fps, seed: seed)
    }

    init(style: CompanionClipStyle, frames: Int, fps: Double, seed: UInt64) {
        self.style = style
        self.frames = max(1, frames)
        self.fps = fps > 0 ? fps : 1
        self.seed = seed
    }

    struct Cycle: Equatable, Sendable {
        let start: TimeInterval
        let hold: TimeInterval
        /// How long the moving part lasts (0 for a one-frame clip).
        let play: TimeInterval
        let isDouble: Bool
        var end: TimeInterval { start + hold + play }
    }

    /// A number in 0..<1 that depends on the seed, the cycle and what it is for.
    static func unit(seed: UInt64, cycle: Int, salt: UInt64) -> Double {
        var z = seed &+ UInt64(truncatingIfNeeded: cycle) &* 0x9E37_79B9_7F4A_7C15 &+ salt &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }

    private var blinkLength: TimeInterval { Double(frames) / Self.blinkFPS }

    func cycle(_ index: Int, start: TimeInterval) -> Cycle {
        guard frames > 1, style != .loop else { return Cycle(start: start, hold: 3600, play: 0, isDouble: false) }
        let range = style == .blink ? Self.blinkHold : Self.gestureHold
        let hold = range.lowerBound + Self.unit(seed: seed, cycle: index, salt: 1) * (range.upperBound - range.lowerBound)
        switch style {
        case .blink:
            let double = Self.unit(seed: seed, cycle: index, salt: 2) < Self.doubleBlinkChance
            let play = double ? blinkLength * 2 + Self.doubleBlinkGap : blinkLength
            return Cycle(start: start, hold: hold, play: play, isDouble: double)
        default:
            return Cycle(start: start, hold: hold, play: Double(frames) / fps, isDouble: false)
        }
    }

    /// The cycle that `elapsed` seconds in falls into.
    func cycle(at elapsed: TimeInterval) -> Cycle {
        let target = min(max(0, elapsed), 3600)
        var index = 0
        var current = cycle(0, start: 0)
        while target >= current.end, index < 5000 {
            index += 1
            current = cycle(index, start: current.end)
        }
        return current
    }

    /// The frame to show, and whether the clip is at rest on frame 0 (a good moment to switch).
    func frame(at elapsed: TimeInterval) -> Int {
        let current = cycle(at: elapsed)
        let t = min(max(0, elapsed), 3600) - current.start - current.hold
        guard t >= 0, frames > 1 else { return 0 }
        switch style {
        case .loop: return 0
        case .gesture: return min(Int(t * fps), frames - 1)
        case .blink:
            func blinkFrame(_ t: TimeInterval) -> Int {
                let step = Int(t * Self.blinkFPS)
                // Frames 1…n-1, then back to 0.
                return step >= frames - 1 ? 0 : step + 1
            }
            if current.isDouble {
                if t < blinkLength { return blinkFrame(t) }
                let second = t - blinkLength - Self.doubleBlinkGap
                return second < 0 ? 0 : blinkFrame(second)
            }
            return blinkFrame(t)
        }
    }

    /// Whether `elapsed` falls in a hold, with its frame 0 showing.
    func isResting(at elapsed: TimeInterval) -> Bool {
        let current = cycle(at: elapsed)
        return min(max(0, elapsed), 3600) - current.start < current.hold
    }
}

struct CompanionPlayer {
    static let loopRotation: TimeInterval = 15
    static let lineRotation: TimeInterval = 20

    private(set) var mood: CompanionMood?
    private(set) var playingKey: String?
    private(set) var sequence: CompanionSequence?
    private(set) var sequenceStart = Date.distantPast
    /// Seeds the timing of a blink or gesture clip; new for every sequence that starts.
    private(set) var seed: UInt64 = 0
    /// The variant chosen to follow the loop in play, so its frames can load before the switch.
    private(set) var upcoming: CompanionSequence?
    private(set) var line: String?
    private var playingLineKey: String?
    private var lineStart = Date.distantPast

    /// Moves to a new sequence or line when the mood changed, a one-shot sequence ended, a loop
    /// has played long enough, or a line has been up long enough. Returns whether anything changed.
    @discardableResult
    mutating func advance(now: Date, mood newMood: CompanionMood, manifest: CompanionManifest,
                          sequenceKey: String? = nil, skin: String? = nil, lineKey: String? = nil,
                          onlySequence: CompanionSequence? = nil,
                          pick: (Int) -> Int = { Int.random(in: 0..<$0) },
                          isLoaded: (CompanionSequence) -> Bool = { _ in true }) -> Bool {
        var changed = false
        let moodChanged = mood != newMood
        let key = sequenceKey ?? newMood.rawValue
        let identity = (skin ?? "") + "|" + key
        let keyChanged = playingKey != identity
        let elapsed = now.timeIntervalSince(sequenceStart)
        let forced = moodChanged || keyChanged || sequence == nil
        var due = forced
        if !forced, let current = sequence {
            if current.loop || current.isStyled {
                // The next variant is chosen a little ahead so it can load; a blink or gesture
                // is never cut in the middle, and nothing is switched to before it is loaded.
                if upcoming == nil, elapsed >= Self.loopRotation - 3, elapsed < Self.loopRotation {
                    let others = manifest.sequences(forKey: key, skin: skin).filter { $0 != current }
                    upcoming = others.isEmpty ? nil : others[pick(others.count)]
                }
                let resting = !current.isStyled
                    || CompanionClipTimeline(sequence: current, seed: seed).isResting(at: elapsed)
                due = elapsed >= Self.loopRotation && resting && (upcoming.map(isLoaded) ?? true)
            } else {
                due = elapsed >= current.duration
            }
        }
        if due {
            let choices = onlySequence.map { [$0] } ?? manifest.sequences(forKey: key, skin: skin)
            // Not the same sequence twice in a row when there is another one.
            let others = choices.filter { $0 != sequence }
            let pool = others.isEmpty || moodChanged || keyChanged ? choices : others
            let next = (forced ? nil : upcoming) ?? (pool.isEmpty ? nil : pool[pick(pool.count)])
            changed = true
            sequence = next
            sequenceStart = now
            upcoming = nil
            seed = UInt64(truncatingIfNeeded: pick(Int(Int32.max)))
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

    /// The frame to show at `now`: a loop wraps, a one-shot holds its last frame, a blink or
    /// gesture follows its own timing.
    func frameIndex(at now: Date) -> Int {
        guard let sequence else { return 0 }
        if sequence.isStyled {
            return CompanionClipTimeline(sequence: sequence, seed: seed)
                .frame(at: now.timeIntervalSince(sequenceStart))
        }
        let step = Int(max(0, now.timeIntervalSince(sequenceStart)) * sequence.fps)
        return sequence.loop ? step % sequence.frames : min(step, sequence.frames - 1)
    }

    /// What the commander said, if its transcript gave anything; else, while working, its terminal
    /// title; else a line of the mood.
    func bubbleText(dialogue: String? = nil, title: String?, override: String? = nil) -> String? {
        if let override, !override.isEmpty { return override }
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

    static let maximumDisplayLength = 2000
    static let maximumSendLength = 4000

    /// The moods Ame can name in a trailing `[mood: X]`.
    static let validMoods: Set<String> = ["working", "idle", "done", "waiting", "angry", "stressed", "sad",
                                          "crying", "scared", "love"]

    /// Splits a trailing `[mood: X]` (any case, trailing spaces allowed) off a text. An unknown X
    /// is not a tag: the text stays as it is.
    static func moodTag(in text: String) -> (clean: String, mood: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix("]"), let open = trimmed.lastIndex(of: "[") else { return (text, nil) }
        let inner = trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)]
        let lowered = inner.lowercased()
        guard lowered.hasPrefix("mood:") else { return (text, nil) }
        let name = lowered.dropFirst("mood:".count).trimmingCharacters(in: .whitespaces)
        guard validMoods.contains(name) else { return (text, nil) }
        return (String(trimmed[..<open]).trimmingCharacters(in: .whitespacesAndNewlines), name)
    }

    /// The mood Ame tagged this text with, if any.
    var mood: String? { Self.moodTag(in: text).mood }

    /// The mood tag removed, markdown stripped, emoji turned into text emoticons, lines joined,
    /// capped for a bubble.
    var displayText: String {
        let flat = CompanionText.sanitized(CompanionDialogue.stripMarkdown(Self.moodTag(in: text).clean))
            .replacingOccurrences(of: "\n", with: " ")
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

    private var listings: [URL: (checked: Date, files: [(id: String, modified: Date)])] = [:]
    private var cwds: [String: String?] = [:]
    private var orphanInUse: [String: String] = [:]
    static let listingInterval: TimeInterval = 3

    /// The session to read for an agent whose registered session is `registered`: that one, or an
    /// unregistered newer file of the same folder (see `CompanionSessionChoice`). The folder is
    /// listed at most every 3 s; only file dates and the first lines of recent candidates are read.
    func effectiveSessionID(registered: String, registeredIDs: Set<String>, commanderCwd: String?,
                            now: Date = Date()) -> String {
        guard Self.isSessionID(registered) else { return registered }
        var entry = entries[registered] ?? Entry()
        if entry.url == nil { entry.url = locate(registered) }
        entries[registered] = entry
        guard let url = entry.url else { return registered }
        let folder = url.deletingLastPathComponent()
        let files = listing(of: folder, now: now)
        let registeredModified = files.first { $0.id == registered }?.modified
        let recent = files.filter { file in
            file.id != registered && !registeredIDs.contains(file.id)
                && file.modified > (registeredModified ?? .distantPast)
                && now.timeIntervalSince(file.modified) <= CompanionSessionChoice.freshness
        }
        let candidates = recent.map {
            CompanionSessionFile(id: $0.id, modified: $0.modified,
                                 cwd: commanderCwd == nil ? nil : cwd(ofSession: $0.id, in: folder))
        }
        let choice = CompanionSessionChoice.choose(
            registeredID: registered, registeredModified: registeredModified, listing: candidates,
            registeredIDs: registeredIDs, now: now, commanderCwd: commanderCwd, previous: orphanInUse[registered])
        orphanInUse[registered] = choice == registered ? nil : choice
        return choice
    }

    private func listing(of folder: URL, now: Date) -> [(id: String, modified: Date)] {
        if let cached = listings[folder], now.timeIntervalSince(cached.checked) < Self.listingInterval {
            return cached.files
        }
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles])) ?? []
        let files = urls.compactMap { url -> (id: String, modified: Date)? in
            guard url.pathExtension == "jsonl" else { return nil }
            let id = url.deletingPathExtension().lastPathComponent
            guard Self.isSessionID(id),
                  let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            else { return nil }
            return (id, modified)
        }
        listings[folder] = (now, files)
        return files
    }

    /// The working directory in the first lines of a transcript; nothing else is kept.
    private func cwd(ofSession id: String, in folder: URL) -> String? {
        if let known = cwds[id] { return known }
        var found: String?
        if let handle = try? FileHandle(forReadingFrom: folder.appendingPathComponent("\(id).jsonl")) {
            defer { try? handle.close() }
            if let head = try? handle.read(upToCount: 16 * 1024) {
                for line in head.split(separator: 0x0A).prefix(20) {
                    if let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                       let value = object["cwd"] as? String {
                        found = value
                        break
                    }
                }
            }
        }
        cwds[id] = .some(found)
        return found
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

    /// The frame to show for the wanted number when only `loadedCount` frames are decoded so far:
    /// the last decoded one past the end; nil only while none is decoded.
    static func index(_ wanted: Int, loadedCount: Int) -> Int? {
        loadedCount > 0 ? min(max(0, wanted), loadedCount - 1) : nil
    }
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
    /// The mood of Ame's newest JINE reply, and when it was sent.
    private var ameMood: String?
    private var ameMoodTime: Date?
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
    private var ambient = CompanionAmbientScheduler()
    private var ambientKey: String?
    private var baseKey: String?
    // Headpats, hearts and the nap.
    private var patSession = CompanionHeadpatSession()
    private var hovering = false
    private var effectiveKey: String?
    private var lastArguments: (mood: CompanionMood, activityID: String?, skin: String?, status: String?)?
    private var hearts: CompanionHeartsState?
    private var napPass: CompanionNap.Pass?
    private var patLastSent: Date?
    /// The hearts level in whole steps of the bar, for the view.
    @Published private(set) var heartsFilled = 0
    @Published private(set) var heartsLevel = 0.0
    /// The last sprite shown, kept on screen while the next sequence's frames load.
    private var lastImage: CGImage?
    private var sequenceChangedAt = Date.distantPast
    static let holdLastImage: TimeInterval = 1
    /// Sequence folders whose frames are all decoded; the others hold only their first frame, or
    /// the part decoded so far.
    private var loadedFully: Set<String> = []
    /// For each skin, the part of the picture she occupies over all her base and emotion
    /// animations; the zoom is centered on it, so no animation moves or rescales her.
    @Published private(set) var skinBounds: [String: CGRect] = [:]
    private var skinBoundsRequested: Set<String> = []
    private var lastCamera: CGRect?
    /// The cutscene being played, if any. Changes only when one starts or ends.
    @Published private(set) var cutscene: CompanionCutscene?
    /// Decoded cutscene frames by file number; only the ones about to play are kept.
    private var cutsceneImages: [Int: CGImage] = [:]
    private var cutsceneLoading: Set<Int> = []
    private var lastCutsceneImage: CGImage?

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
                let heart = manifest.hearts?.icon.map { [$0] } ?? []
                for path in manifest.activities.map(\.icon) + manifest.stickers.map(\.image) + previews + heart {
                    self.ensureImage(path)
                }
            }
        }
    }

    /// Called as time passes and when the commander's mood or the chosen activity changes.
    func advance(now: Date, mood: CompanionMood, activityID: String? = nil, skin: String? = nil,
                 status: String? = nil) {
        guard let manifest else { return }
        lastArguments = (mood, activityID, skin, status)
        var next = player
        let skin = manifest.skins.isEmpty ? nil : manifest.resolvedSkin(skin)
        if skin != currentSkin {
            // Another skin: the old one's frames are not needed any more.
            let old = currentSkin
            currentSkin = skin
            napPass = nil
            loaded = [:]
            loadedFully = []
            loading = loading.filter { $0.hasPrefix("image:") }
            if let old, let skin, CompanionPreferences.playsTransitions(),
               let transition = manifest.transition(from: old, to: skin) {
                startCutscene(transition)
            } else {
                endCutscene()
            }
        }
        statusTimer.observe(status ?? mood.rawValue, now: now)
        let candidate = CompanionEmotionRules.resolve(mood: mood, signals: signals, textTime: textTime,
                                                      statusElapsed: statusTimer.elapsed(now: now), now: now,
                                                      loveTime: loveTime)
        let applied = candidate.flatMap { manifest.hasOwnSequences(forKey: $0.rawValue, skin: skin) ? $0 : nil }
        if applied != emotion { emotion = applied }
        let lineKey = applied == .love && !manifest.lines(forKey: "love").isEmpty ? "love" : nil
        let commanderKey = applied?.rawValue ?? manifest.sequenceKey(mood: mood, activityID: activityID, skin: skin)
        // Ame's own mood from her newest JINE reply wins for ten minutes, except while the user's
        // love reaction shows.
        let loveReaction = loveTime.map { now.timeIntervalSince($0) <= CompanionAffection.duration } ?? false
        var key = commanderKey
        let wanted = CompanionMoodResolver.effective(
            commanderKey: commanderKey, ameMood: ameMood, age: ameMoodTime.map { now.timeIntervalSince($0) },
            loveReaction: loveReaction)
        if wanted != commanderKey {
            if let base = CompanionMood(rawValue: wanted) {
                key = manifest.sequenceKey(mood: base, activityID: activityID, skin: skin)
            } else if manifest.hasOwnSequences(forKey: wanted, skin: skin) {
                key = wanted
            }
        }
        baseKey = key
        effectiveKey = key
        // Headpats: a reached mood replaces the sequence; hovering shows the reaction's hover key.
        let usableKey: (String) -> String? = { candidate in
            if let base = CompanionMood(rawValue: candidate) {
                return manifest.sequenceKey(mood: base, activityID: activityID, skin: skin)
            }
            return manifest.hasOwnSequences(forKey: candidate, skin: skin) ? candidate : nil
        }
        // The nap pass outranks every sequence while it plays; a skin change or cutscene cancels it.
        if let config = manifest.hearts { tickHearts(now: now, config: config); checkTestCuddle(config: config) }
        if cutscene != nil { napPass = nil }
        if var pass = napPass {
            if pass.startedAt == nil { pass.startedAt = now }
            napPass = pass.isActive(now: now) ? pass : nil
        }
        let napping = napPass != nil
        var patBusy = false
        if let headpat = manifest.headpat, !napping {
            if let reached = patSession.overrideKey(now: now, ameMoodTime: ameMoodTime), let resolved = usableKey(reached) {
                key = resolved
            } else if hovering, let hover = (headpat.reaction(for: effectiveKey ?? "") ?? headpat.reaction(for: mood.rawValue))?.hover,
                      let resolved = usableKey(hover) {
                key = resolved
            }
            patBusy = hovering || patSession.isEngaged(now: now, ameMoodTime: ameMoodTime)
        }
        // While idle she does her own things now and then, as often as her hearts allow; any change
        // of mood, skin or activity, a cutscene, a pat, a nap, a game or stream activity, or the
        // setting off, ends it.
        let calm = CompanionAmbientScheduler.baseMoods.contains(key) && (activityID ?? CompanionPreferences.defaultActivity)
            == CompanionPreferences.defaultActivity && cutscene == nil && CompanionPreferences.ambientEnabled()
            && !napping && !patBusy
        let skinKeys = manifest
        let doing = ambient.update(
            now: now, context: "\(skin ?? "")|\(key)|\(activityID ?? "")|\(cutscene == nil)", baseMood: calm ? key : nil,
            entries: manifest.ambient, skinHas: { skinKeys.hasOwnSequences(forKey: $0, skin: skin) },
            hearts: hearts?.level ?? CompanionHeartsState.startLevel)
        ambientKey = doing
        if let doing { key = doing }
        var passSequence: CompanionSequence?
        if let pass = napPass {
            // A key of its own, so the pass restarts the player even when the same mood is in play.
            key = "nap|" + pass.key
            passSequence = pass.sequence
        }
        let before = player.sequence
        let changedPlayer = next.advance(now: now, mood: mood, manifest: manifest, sequenceKey: key, skin: skin,
                                         lineKey: lineKey, onlySequence: passSequence,
                                         isLoaded: { [fully = loadedFully] in fully.contains($0.dir) })
        if changedPlayer || next.upcoming != player.upcoming { player = next }
        if next.sequence != before { sequenceChangedAt = now }
        if let sequence = next.sequence { ensureLoaded(sequence) }
        if let upcoming = next.upcoming { ensureLoaded(upcoming) }
        // Only the sequence in play and the next variant stay decoded.
        let keepDirs = Set([next.sequence?.dir, next.upcoming?.dir].compactMap { $0 })
        if !loaded.keys.allSatisfy(keepDirs.contains) {
            loaded = loaded.filter { keepDirs.contains($0.key) }
            loadedFully = loadedFully.intersection(keepDirs)
        }
        ensureSkinBounds(skin: skin ?? CompanionManifest.defaultSkin, manifest: manifest)
        if let path = manifest.backgroundPath(at: now) { ensureImage(path) }
        publishMood(napping ? (manifest.hearts?.nap.key ?? key) : key, skin: skin ?? CompanionManifest.defaultSkin, now: now)
    }

    private var publishedKey: String?
    private var publishedAt: Date?
    private let stateWriter = CompanionStateWriter()

    /// Writes `state/mood.json` when the mood in play changes and every 30 s otherwise. Only the
    /// mood key, the skin and the time are in it.
    private func publishMood(_ key: String, skin: String, now: Date) {
        guard CompanionMoodState.isDue(key: key, lastKey: publishedKey, lastWrite: publishedAt, now: now) else { return }
        publishedKey = key
        publishedAt = now
        let data = CompanionMoodState.payload(mood: key, skin: skin, time: now)
        let url = CompanionMoodState.fileURL(companionDirectory: directory)
        let writer = stateWriter
        Task.detached(priority: .utility) { await writer.write(data, to: url) }
    }

    // MARK: Headpats, hearts and the nap

    /// Loads the hearts level once, then decays it by wall time and publishes the bar.
    private func tickHearts(now: Date, config: CompanionHearts) {
        if hearts == nil { hearts = CompanionHeartsState.load(now: now, config: config) }
        guard var state = hearts else { return }
        let before = state
        state.decay(now: now, config: config)
        hearts = state
        publishHearts(state)
        if state != before, now.timeIntervalSince(heartsSaved) >= 5 {
            state.save()
            heartsSaved = now
        }
    }

    private var heartsSaved = Date.distantPast

    private func publishHearts(_ state: CompanionHeartsState) {
        let filled = CompanionHeartsBar.filled(level: state.level)
        if filled != heartsFilled { heartsFilled = filled }
        let rounded = state.level.rounded()
        if rounded != heartsLevel { heartsLevel = rounded }
    }

    /// Applies a change of the hearts level and saves it at once.
    private func addHearts(_ delta: Double, now: Date) {
        guard let config = manifest?.hearts else { return }
        if hearts == nil { hearts = CompanionHeartsState.load(now: now, config: config) }
        guard var state = hearts else { return }
        let reachedFull = state.add(delta, now: now, config: config)
        hearts = state
        publishHearts(state)
        state.save()
        if reachedFull { startNap(config: config) }
    }

    /// The level just rose to 100: one pass of the nap clip, starting at the next advance.
    private func startNap(config: CompanionHearts) {
        guard cutscene == nil, let manifest else { return }
        let skin = manifest.skins.isEmpty ? nil : currentSkin
        guard let key = CompanionNap.key(config: config.nap, skinHas: { manifest.hasOwnSequences(forKey: $0, skin: skin) })
        else { return }
        napPass = CompanionNap.pass(key: key, sequences: manifest.sequences(forKey: key, skin: skin))
    }

    /// The pointer entered or left her head.
    func setHovering(_ value: Bool) {
        guard hovering != value else { return }
        hovering = value
        refresh()
    }

    /// Runs `advance` again with the last arguments, so a hover or a pat shows at once.
    func refresh(now: Date = Date()) {
        guard let last = lastArguments else { return }
        advance(now: now, mood: last.mood, activityID: last.activityID, skin: last.skin, status: last.status)
    }

    /// One click on her head: sounds, the session and the mood steps, hearts.
    func pat(now: Date = Date()) {
        guard let manifest, let headpat = manifest.headpat else { return }
        let count = patSession.pat(now: now, base: effectiveKey ?? "idle", reactions: headpat.reactions)
        if CompanionPreferences.headpatSoundsEnabled() {
            CompanionHeadpatSound.play(CompanionHeadpatSound.paths(count: count, sounds: headpat.sounds), in: directory)
        }
        addHearts(manifest.hearts?.gains.pat ?? 0, now: now)
        refresh(now: now)
    }

    /// The speech bubble that comes before the commander's words: the nap, else a headpat line.
    func patBubble(now: Date) -> String? {
        if napPass?.isActive(now: now) == true { return CompanionNap.bubble }
        return patSession.bubbleLine(now: now)
    }

    /// Seconds into the nap pass and its length; nil when no pass plays.
    func cuddle(at now: Date) -> (elapsed: TimeInterval, duration: TimeInterval)? {
        guard let pass = napPass, let started = pass.startedAt, pass.isActive(now: now) else { return nil }
        return (now.timeIntervalSince(started), pass.sequence.duration)
    }

    private var testCuddleSeen: String??

    /// A new value of `companionTestCuddle` while running fires the pass once; nothing else changes.
    private func checkTestCuddle(config: CompanionHearts) {
        let current = UserDefaults.standard.string(forKey: CompanionNap.testDefaultsKey)
        guard let seen = testCuddleSeen else { testCuddleSeen = .some(current); return }
        guard CompanionNap.testTriggered(current: current, last: seen) else { return }
        testCuddleSeen = .some(current)
        if napPass == nil { startNap(config: config) }
    }

    /// The hearts bar is shown when the manifest has hearts.
    var showsHearts: Bool { manifest?.hearts != nil }
    var heartsIcon: String? { manifest?.hearts?.icon }

    /// The head in the room's coordinates now; nil during a cutscene or without art.
    func headRect(area: CGSize, zoom: Double, now: Date) -> CGRect? {
        guard cutscene == nil, let manifest, let headpat = manifest.headpat,
              let head = headpat.head(forSkin: currentSkin ?? CompanionManifest.defaultSkin),
              let sprite = image(at: now) else { return nil }
        let background = backgroundImage(at: now).map { CGSize(width: $0.width, height: $0.height) }
        return CompanionScene.headRect(head: head, imageSize: CGSize(width: sprite.width, height: sprite.height),
                                       background: background, spriteRect: manifest.spriteRect, visible: camera(),
                                       area: area, zoom: zoom)
    }

    /// After a pat session of three or more ended: tells Ame, if she is free, once per ten minutes,
    /// never in the quiet hours or during a nap. The text is never logged or kept.
    func tickPat(now: Date, ame: HerdrAgent?, store: HerdrStore) {
        guard let report = patSession.takeEnded(now: now) else { return }
        guard let ame, store.isConnected else { return }
        let sentBefore = patLastSent ?? {
            let saved = UserDefaults.standard.double(forKey: CompanionPatMessage.lastSentKey)
            return saved > 0 ? Date(timeIntervalSince1970: saved) : nil
        }()
        guard CompanionPatMessage.allowed(count: report.count, lastSent: sentBefore, now: now, ameStatus: ame.agentStatus),
              let params = CompanionMessage.promptParams(paneID: ame.paneID,
                                                         text: CompanionPatMessage.text(count: report.count, key: report.key))
        else { return }
        patLastSent = now
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: CompanionPatMessage.lastSentKey)
        Task { try? await store.sendAgentPrompt(params) }
    }

    /// The commander's words for the current mood, from its newest reply.
    var dialogue: String? {
        player.mood.flatMap { CompanionDialogue.pick(mood: $0, emotion: emotion, sentences: sentences) }
    }

    /// Re-reads the commander's transcript, off the main thread and at most every 1.5 s.
    func refreshDialogue(sessionID: String?, registeredIDs: Set<String> = [], cwd: String? = nil,
                         now: Date = Date()) {
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
            // A background job writes a session Herdr never registered; follow it when it is newer.
            let effective = await reader.effectiveSessionID(registered: sessionID, registeredIDs: registeredIDs,
                                                            commanderCwd: cwd)
            let snapshot = await reader.snapshot(sessionID: effective)
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
            ameMood = nil
            ameMoodTime = nil
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
            let next = Array(shown.suffix(24))
            if next != self.messages { self.messages = next }
            let loveLabels = (self.manifest?.stickers ?? []).filter { $0.id == "love" }.map(\.label)
            self.ameLoveTime = CompanionAffection.newestLove(in: shown, extra: loveLabels)
            // Her newest reply decides how she feels: the tag, else the emotion words of the text.
            self.countHearts(shown, loveLabels: loveLabels, now: Date())
            if let reply = shown.last(where: { $0.role == .assistant && $0.time != nil }), let time = reply.time {
                self.ameMood = Self.mood(of: reply)
                self.ameMoodTime = time
            } else {
                self.ameMood = nil
                self.ameMoodTime = nil
            }
            self.updateUnread()
        }
    }

    /// The mood of one reply of Ame: the tag, else the emotion words of the text.
    static func mood(of reply: CompanionMessage) -> String? {
        guard let time = reply.time else { return reply.mood }
        let wording = CompanionEmotionRules.resolve(
            mood: .idle, signals: CompanionTextSignals(text: CompanionMessage.moodTag(in: reply.text).clean),
            textTime: time, statusElapsed: 0, now: time)
        return reply.mood ?? wording?.rawValue
    }

    /// Each new reply of Ame and each new loving message of the user changes the hearts once.
    private func countHearts(_ shown: [CompanionMessage], loveLabels: [String], now: Date) {
        guard let config = manifest?.hearts else { return }
        if hearts == nil { hearts = CompanionHeartsState.load(now: now, config: config) }
        guard var state = hearts else { return }
        let before = state
        let reachedFull = state.count(messages: shown, ameMood: { Self.mood(of: $0) }, loveExtra: loveLabels,
                                      now: now, config: config)
        guard state != before else { return }
        hearts = state
        publishHearts(state)
        state.save()
        if reachedFull { startNap(config: config) }
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
        guard CompanionPreferences.nudgesEnabled() else { return }
        let mood = baseKey ?? "idle"
        guard nudges.due(now: now, ameIsIdle: CompanionNudge.isAvailable(status: ame.agentStatus), mood: mood)
        else { return }
        let hint = CompanionNudge.hint(commanderWorking: CompanionMood(agentStatus: commanderStatus) == .working,
                                       runningTasks: 0)
        guard let params = CompanionMessage.promptParams(paneID: ame.paneID, text: CompanionNudge.text(now: now, mood: mood, doing: ambientKey.flatMap(CompanionNudge.doingPhrase(forAmbientKey:)),
                                                                  hint: hint))
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

    /// The sprite frame to show: a new sequence has its first frame at once, and a frame that is
    /// not decoded yet shows the last one that is. The previous sprite stays only if even the
    /// first frame cannot be read.
    func image(at now: Date) -> CGImage? {
        if let sequence = player.sequence, let frames = loaded[sequence.dir]?.images,
           let index = CompanionFrames.index(player.frameIndex(at: now), loadedCount: frames.count) {
            let image = frames[index]
            lastImage = image
            return image
        }
        if let lastImage, now.timeIntervalSince(sequenceChangedAt) < Self.holdLastImage { return lastImage }
        return nil
    }

    /// The part of the picture to center the zoom on: this skin's, else the last known one.
    func camera() -> CGRect? {
        let bounds = skinBounds[currentSkin ?? CompanionManifest.defaultSkin]
        if let bounds { lastCamera = bounds }
        return bounds ?? lastCamera
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

    // MARK: Skin change cutscenes

    private func startCutscene(_ transition: CompanionTransition) {
        cutsceneImages = [:]
        cutsceneLoading = []
        lastCutsceneImage = nil
        cutscene = CompanionCutscene(transition: transition, token: UUID(), requestedAt: Date(), startedAt: nil)
        prefetchCutscene(from: 0)
    }

    private func endCutscene() {
        guard cutscene != nil else { return }
        cutscene = nil
        cutsceneImages = [:]
        cutsceneLoading = []
        lastCutsceneImage = nil
    }

    /// Starts the clock once the first frame is decoded, moves on, keeps the next frames coming and
    /// lets the finished ones go; ends the cutscene after its last frame.
    func tickCutscene(now: Date) {
        guard var current = cutscene else { return }
        let order = current.transition.order
        guard let first = order.first else { endCutscene(); return }
        guard let started = current.startedAt else {
            if cutsceneImages[first] != nil {
                current.startedAt = now
                cutscene = current
            } else if now.timeIntervalSince(current.requestedAt) > CompanionCutscene.loadTimeout {
                endCutscene()
            } else {
                prefetchCutscene(from: 0)
            }
            return
        }
        guard let position = current.transition.position(elapsed: now.timeIntervalSince(started)) else {
            endCutscene()
            return
        }
        prefetchCutscene(from: position)
        let keep = Set(order[position..<min(order.count, position + Self.cutscenePrefetch)])
        for key in cutsceneImages.keys where !keep.contains(key) { cutsceneImages[key] = nil }
    }

    /// The frame to show at `now`: the newest decoded one at or before the playing position.
    func cutsceneImage(at now: Date) -> CGImage? {
        guard let current = cutscene, let started = current.startedAt,
              let position = current.transition.position(elapsed: now.timeIntervalSince(started)) else { return nil }
        if let image = cutsceneImages[current.transition.order[position]] {
            lastCutsceneImage = image
            return image
        }
        return lastCutsceneImage
    }

    private static let cutscenePrefetch = 16

    private func prefetchCutscene(from position: Int) {
        guard let current = cutscene else { return }
        let order = current.transition.order
        let folder = directory.appendingPathComponent(current.transition.dir, isDirectory: true)
        let token = current.token
        for file in order[min(position, order.count)..<min(order.count, position + Self.cutscenePrefetch)]
        where cutsceneImages[file] == nil && cutsceneLoading.insert(file).inserted {
            Task {
                let image = await Task.detached(priority: .utility) {
                    Self.loadCutsceneFrame(in: folder, number: file)
                }.value
                guard self.cutscene?.token == token else { return }
                self.cutsceneLoading.remove(file)
                if let image { self.cutsceneImages[file] = image }
            }
        }
    }

    /// `000.png`-style names first, then plain numbers.
    nonisolated private static func loadCutsceneFrame(in folder: URL, number: Int) -> CGImage? {
        for name in [String(format: "%03d.png", number), "\(number).png"] {
            let url = folder.appendingPathComponent(name)
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let image = CGImageSourceCreateImageAtIndex(source, 0, nil) { return image }
        }
        return nil
    }

    private func ensureLoaded(_ sequence: CompanionSequence) {
        let folder = directory.appendingPathComponent(sequence.dir, isDirectory: true)
        // The first frame is read here and now (one PNG), so a new sequence is drawn in the same
        // pass; the rest follows in the background.
        if loaded[sequence.dir] == nil,
           let first = Self.readFrame(folder.appendingPathComponent("0.png")) {
            loaded[sequence.dir] = CompanionFrames(images: [first])
        }
        guard !loadedFully.contains(sequence.dir), loading.insert(sequence.dir).inserted else { return }
        let count = sequence.frames
        let dir = sequence.dir
        Task {
            let frames = await Task.detached(priority: .utility) { () -> CompanionFrames in
                CompanionFrames(images: (0..<count).compactMap { Self.readFrame(folder.appendingPathComponent("\($0).png")) })
            }.value
            self.loading.remove(dir)
            // Dropped while it loaded (another sequence took over): leave it out.
            let wanted = Set([self.player.sequence?.dir, self.player.upcoming?.dir].compactMap { $0 })
            guard wanted.contains(dir), !frames.images.isEmpty else { return }
            self.loaded[dir] = frames
            self.loadedFully.insert(dir)
        }
    }

    nonisolated private static func readFrame(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Finds, once per skin, the part of the picture she occupies in her base and emotion
    /// animations. Frames are read from disk as small thumbnails, one at a time, and dropped.
    private func ensureSkinBounds(skin: String, manifest: CompanionManifest) {
        guard skinBoundsRequested.insert(skin).inserted else { return }
        let sequences = manifest.cameraSequences(skin: skin == CompanionManifest.defaultSkin && manifest.skins.isEmpty ? nil : skin)
        let root = directory
        Task {
            let bounds = await Task.detached(priority: .utility) { () -> CGRect? in
                var found: [CGRect?] = []
                for sequence in sequences {
                    for index in CompanionSprite.sampleIndices(frames: sequence.frames) {
                        let url = root.appendingPathComponent(sequence.dir).appendingPathComponent("\(index).png")
                        found.append(CompanionSprite.thumbnailBounds(at: url))
                    }
                }
                return CompanionSprite.union(found, ignoringFullCanvas: true)
            }.value
            if let bounds { self.skinBounds[skin] = bounds }
        }
    }
}

/// A cutscene in progress: `startedAt` is set once its first frame is ready.
struct CompanionCutscene: Equatable, Sendable {
    let transition: CompanionTransition
    let token: UUID
    let requestedAt: Date
    var startedAt: Date?

    /// A first frame that has not come after this long means the cutscene cannot play.
    static let loadTimeout: TimeInterval = 3
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
    /// The session ids Herdr has registered for any agent, so none of them is taken for a background job.
    var registeredSessionIDs: Set<String> = []
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
        TimelineView(.animation(minimumInterval: 1 / max(model.player.sequence?.fps ?? 10,
                                                         model.cutscene?.transition.fps ?? 0,
                                                         model.cuddle(at: Date()) == nil ? 0 : 1 / CompanionCuddle.tick))) { context in
            VStack(spacing: 6) {
                room(at: context.date)
                .frame(height: CompanionPreferences.roomHeight(width: width, factor: heightFactor))
                .overlay { cuddleLayer(at: context.date) }
                .overlay { headpatLayer(at: context.date) }
                .overlay(alignment: .topLeading) {
                    // Over the cutscene too; left-aligned, so it never covers the gear button.
                    if model.showsHearts {
                        CompanionHeartsBarView(filled: model.heartsFilled, level: model.heartsLevel,
                                               icon: model.heartsIcon.flatMap { model.image(forPath: $0) })
                            .frame(width: max(0, width * 0.45), alignment: .leading)
                            .padding(3)
                    }
                }
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
                                                      title: commander?.terminalTitleStripped,
                                                      override: model.patBubble(now: context.date)) {
                    CompanionBubble(text: text)
                }
            }
            .onChange(of: context.date) { _, date in
                model.advance(now: date, mood: mood, activityID: activityID, skin: skin, status: commander?.agentStatus)
                model.tickCutscene(now: date)
                model.refreshDialogue(sessionID: commander?.agentSessionID, registeredIDs: registeredSessionIDs,
                                     cwd: commander?.cwd, now: date)
                model.refreshAme(sessionID: ame?.agentSessionID, now: date)
                if let store {
                    model.tickNudge(now: date, ame: ame, commanderStatus: commander?.agentStatus, store: store)
                    model.tickPat(now: date, ame: ame, store: store)
                }
            }
            .onChange(of: mood) { _, mood in model.advance(now: Date(), mood: mood, activityID: activityID, skin: skin, status: commander?.agentStatus) }
            .onChange(of: activityID) { _, id in model.advance(now: Date(), mood: mood, activityID: id, skin: skin, status: commander?.agentStatus) }
            .onChange(of: skin) { _, skin in model.advance(now: Date(), mood: mood, activityID: activityID, skin: skin, status: commander?.agentStatus) }
            .onAppear { model.advance(now: Date(), mood: mood, activityID: activityID, skin: skin, status: commander?.agentStatus) }
        }
        .accessibilityHidden(true)
    }
}

extension CompanionView {
    /// Her head: a pointing hand over it, a click is a pat. Not while a cutscene plays.
    @ViewBuilder
    fileprivate func cuddleLayer(at date: Date) -> some View {
        if let run = model.cuddle(at: date), let icon = model.heartsIcon.flatMap({ model.image(forPath: $0) }) {
            GeometryReader { area in
                let height = CompanionHeartsBarView.iconHeight
                let width = height * CGFloat(icon.width) / CGFloat(max(icon.height, 1))
                let head = model.headRect(area: area.size, zoom: CompanionPreferences.clampedZoom(zoom), now: date)
                ForEach(Array(CompanionCuddle.positions(elapsed: run.elapsed, duration: run.duration,
                                                        head: head, area: area.size).enumerated()), id: \.offset) { _, point in
                    Image(decorative: icon, scale: 1).interpolation(.none).resizable()
                        .frame(width: width, height: height)
                        .position(point)
                }
            }
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    fileprivate func headpatLayer(at date: Date) -> some View {
        if model.manifest?.headpat != nil {
            CompanionHeadpatLayer(
                head: { area in model.headRect(area: area, zoom: CompanionPreferences.clampedZoom(zoom), now: date) },
                onHover: { model.setHovering($0) },
                onPat: { model.pat() })
        }
    }

    /// The scene, or a skin-change cutscene frame in its place (no sprite, no zoom).
    @ViewBuilder
    fileprivate func room(at date: Date) -> some View {
        if model.cutscene != nil {
            if let frame = model.cutsceneImage(at: date) {
                CompanionCutsceneFrame(image: frame)
            } else {
                // The first frame is still being decoded: the empty room, without her.
                CompanionScene(background: model.backgroundImage(at: date),
                               spriteRect: model.manifest?.spriteRect, sprite: nil, zoom: 1)
            }
        } else {
            CompanionScene(background: model.backgroundImage(at: date),
                           spriteRect: model.manifest?.spriteRect,
                           sprite: model.image(at: date),
                           spriteVisible: model.camera(),
                           zoom: CompanionPreferences.clampedZoom(zoom))
        }
    }
}

/// A full-scene cutscene frame, filling the room like the background: bottom-centered, cropped.
struct CompanionCutsceneFrame: View {
    let image: CGImage

    var body: some View {
        GeometryReader { area in
            let size = CGSize(width: image.width, height: image.height)
            let scale = CompanionScene.fillScale(content: size, in: area.size)
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .frame(width: size.width * scale, height: size.height * scale)
                .frame(width: area.size.width, height: area.size.height, alignment: .bottom)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                let anchor = Self.zoomAnchor(
                    spriteRect: rect, backgroundSize: size,
                    imageSize: sprite.map { CGSize(width: $0.width, height: $0.height) } ?? .zero,
                    visible: spriteVisible)
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
                .scaleEffect(zoom, anchor: anchor)
                // Bottom-center: the extra width is cropped evenly left and right, the extra
                // height at the top, so the picture always reaches every edge of the room.
                .frame(width: area.size.width, height: area.size.height, alignment: .bottom)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            } else if let sprite {
                let spriteAnchor = Self.zoomAnchor(
                    visible: spriteVisible, imageSize: CGSize(width: sprite.width, height: sprite.height),
                    area: area.size)
                Image(decorative: sprite, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: area.size.width, height: area.size.height)
                    .scaleEffect(zoom, anchor: spriteAnchor)
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
        Text(CompanionText.sanitized(text))
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
    /// The smallest rectangle holding all the rectangles; nil when there are none. With
    /// `ignoringFullCanvas`, a rectangle covering more than 90% of both the width and the height
    /// (a frame that is all background) is left out.
    static func union(_ rects: [CGRect?], ignoringFullCanvas: Bool = false) -> CGRect? {
        rects.compactMap { $0 }
            .filter { !(ignoringFullCanvas && $0.width > 0.9 && $0.height > 0.9) }
            .reduce(nil) { (total: CGRect?, rect) in total.map { $0.union(rect) } ?? rect }
    }

    /// Up to eight frame numbers spread over a clip.
    static func sampleIndices(frames: Int) -> [Int] {
        guard frames > 0 else { return [] }
        let count = min(frames, 8)
        return Array(Set((0..<count).map { $0 * frames / count })).sorted()
    }

    /// The visible part of a PNG on disk as 0...1 fractions, found on a small thumbnail so the
    /// full image is never kept.
    static func thumbnailBounds(at url: URL) -> CGRect? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 256]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return visibleBounds(of: thumbnail)
    }

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

/// How Ame feels, grouped by how often she wants to text.
enum CompanionNudgeMood: Equatable, Sendable {
    case lonely, loving, happy, calm, upset, busy

    init(key: String) {
        switch key.lowercased() {
        case "waiting": self = .lonely
        case "love": self = .loving
        case "done": self = .happy
        case "sad", "crying", "scared", "stressed", "angry": self = .upset
        case "working": self = .busy
        default: self = .calm
        }
    }

    /// Seconds between two nudges while she feels this way.
    var delayRange: ClosedRange<TimeInterval> {
        switch self {
        case .lonely: return (20 * 60)...(50 * 60)
        case .loving: return (30 * 60)...(70 * 60)
        case .happy: return (40 * 60)...(90 * 60)
        case .calm: return (45 * 60)...(120 * 60)
        case .upset: return (25 * 60)...(60 * 60)
        case .busy: return (60 * 60)...(150 * 60)
        }
    }
}

/// The random texts the app sends to the "ame" agent, and which messages the JINE box hides.
enum CompanionNudge {
    static let prefix = "[nudge]"
    static let stylePrefix = "[style]"
    /// Local hours in which nothing is sent: 01:00 up to 09:00.
    static let quietHours = 1..<9
    static let maximumPerDay = 8
    /// A reply this short right after a `[style]` turn is only an acknowledgement.
    static let acknowledgementLength = 40

    private static func startsWith(_ text: String, _ prefix: String) -> Bool {
        text.drop(while: { $0.isWhitespace }).lowercased().hasPrefix(prefix)
    }

    static func isNudge(_ text: String) -> Bool { startsWith(text, prefix) }
    static func isStyle(_ text: String) -> Bool { startsWith(text, stylePrefix) }

    /// Without the user messages that are nudges, `[pat]` or `[style]` instructions, and without Ame's
    /// short acknowledgement right after a `[style]` one.
    static func visible(_ messages: [CompanionMessage]) -> [CompanionMessage] {
        var result: [CompanionMessage] = []
        var hideAcknowledgement = false
        for message in messages {
            defer { hideAcknowledgement = message.role == .user && isStyle(message.text) }
            if message.role == .user, isNudge(message.text) || isStyle(message.text) || CompanionPatMessage.isPat(message.text) { continue }
            if hideAcknowledgement, message.role == .assistant,
               message.text.trimmingCharacters(in: .whitespacesAndNewlines).count <= acknowledgementLength { continue }
            result.append(message)
        }
        return result
    }

    /// Ame can take a text unless she is working on something or waiting for an answer.
    static func isAvailable(status: String?) -> Bool {
        switch status?.lowercased() {
        case "working", "blocked", "needs-input", "needs_input", "request": return false
        default: return true
        }
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

    /// How a mood key reads in a nudge.
    static func moodWord(_ key: String) -> String {
        switch key.lowercased() {
        case "done": return "happy"
        case "love": return "loving"
        case "waiting": return "lonely"
        case "angry": return "annoyed"
        case "stressed": return "anxious"
        case "sad": return "sad"
        case "crying": return "very sad"
        case "scared": return "scared"
        case "working": return "busy"
        default: return "calm"
        }
    }

    /// What an ambient clip is, in words; nil for a key without a phrase.
    static func doingPhrase(forAmbientKey key: String) -> String? {
        [
            "tweet": "tweeting", "sleep": "sleeping", "tv": "watching TV", "music": "listening to music",
            "spinner": "spinning a hand spinner", "comics": "reading comics", "selfcare": "doing self-care",
            "voice": "voice training", "egosearch": "ego-searching", "out": "out and about",
            "streamprep": "stream prep",
        ][key.lowercased()]
    }

    /// "[nudge] it's Sunday 2:40 AM; mood: lonely; doing: reading comics; the commander is working"
    static func text(now: Date, mood: String = "idle", doing: String? = nil, hint: String,
                     calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEEE h:mm a"
        return "\(prefix) it's \(formatter.string(from: now)); mood: \(moodWord(mood)); "
            + "doing: \(doing ?? "just hanging out"); \(hint)"
    }
}

/// When the next nudge is due. The count per local day and the next time are kept in UserDefaults,
/// so relaunching the app neither resets the wait nor sends one at once.
struct CompanionNudgeScheduler {
    static let dayKey = "companionNudgeDay"
    static let countKey = "companionNudgeCount"
    static let nextKey = "companionNudgeNext"
    /// A saved time that has already passed waits this long after launch.
    static let relaunchDelay: TimeInterval = 10 * 60

    private(set) var nextFire: Date?
    private var pickedFor: CompanionNudgeMood?
    private var rerolled = false

    private mutating func schedule(_ date: Date, mood: CompanionNudgeMood, defaults: UserDefaults,
                                   rerolled: Bool = false) {
        nextFire = date
        pickedFor = mood
        self.rerolled = rerolled
        defaults.set(date.timeIntervalSince1970, forKey: Self.nextKey)
    }

    /// True once, when a nudge should go out now; this counts it and picks the next time. Out of
    /// hours or past the daily limit the time is only moved on. A busy Ame waits, without moving
    /// it. If her mood turns into another kind while waiting, the wait is drawn again once.
    mutating func due(now: Date, ameIsIdle: Bool, mood: String = "idle", calendar: Calendar = .current,
                      defaults: UserDefaults = .standard,
                      random: (ClosedRange<TimeInterval>) -> TimeInterval = { Double.random(in: $0) }) -> Bool {
        let kind = CompanionNudgeMood(key: mood)
        guard let fire = nextFire else {
            let saved = defaults.double(forKey: Self.nextKey)
            if saved > now.timeIntervalSince1970 {
                schedule(Date(timeIntervalSince1970: saved), mood: kind, defaults: defaults)
            } else if saved > 0 {
                schedule(now.addingTimeInterval(Self.relaunchDelay), mood: kind, defaults: defaults)
            } else {
                schedule(now.addingTimeInterval(random(kind.delayRange)), mood: kind, defaults: defaults)
            }
            return false
        }
        if kind != pickedFor, !rerolled, now < fire {
            schedule(now.addingTimeInterval(random(kind.delayRange)), mood: kind, defaults: defaults, rerolled: true)
            return false
        }
        guard now >= fire else { return false }
        let today = CompanionNudge.dayKey(now, calendar: calendar)
        let sent = defaults.string(forKey: Self.dayKey) == today ? defaults.integer(forKey: Self.countKey) : 0
        if CompanionNudge.isQuiet(now, calendar: calendar) || sent >= CompanionNudge.maximumPerDay {
            schedule(now.addingTimeInterval(random(kind.delayRange)), mood: kind, defaults: defaults)
            return false
        }
        guard ameIsIdle else { return false }
        defaults.set(today, forKey: Self.dayKey)
        defaults.set(sent + 1, forKey: Self.countKey)
        schedule(now.addingTimeInterval(random(kind.delayRange)), mood: kind, defaults: defaults)
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

// MARK: Which transcript the commander is really writing

/// A transcript file next to the registered one: its session id, last write and working directory.
struct CompanionSessionFile: Equatable, Sendable {
    let id: String
    let modified: Date
    let cwd: String?
}

/// Claude Code background jobs write a session file that Herdr never registered. When the
/// registered file has gone quiet and another file of the same project folder is newer, that is
/// the transcript to read.
enum CompanionSessionChoice {
    /// How recent an unregistered file must be, and how long it may stay quiet before the
    /// registered one is used again.
    static let freshness: TimeInterval = 10 * 60
    /// A second candidate has to be this much newer before it replaces the one in use.
    static let switchMargin: TimeInterval = 30

    /// The session id to read. `listing` is the other `.jsonl` files of the registered file's
    /// folder; `registeredIDs` are the sessions of every agent Herdr knows; `previous` is the
    /// orphan chosen last time, if any.
    static func choose(registeredID: String, registeredModified: Date?, listing: [CompanionSessionFile],
                       registeredIDs: Set<String>, now: Date, commanderCwd: String?,
                       previous: String?) -> String {
        let candidates = listing.filter { file in
            file.id != registeredID
                && !registeredIDs.contains(file.id)
                && file.modified > (registeredModified ?? .distantPast)
                && now.timeIntervalSince(file.modified) <= freshness
                && (commanderCwd.map { same($0, file.cwd) } ?? true)
        }
        guard let newest = candidates.max(by: { $0.modified < $1.modified }) else { return registeredID }
        if let previous, let kept = candidates.first(where: { $0.id == previous }),
           newest.modified.timeIntervalSince(kept.modified) <= switchMargin {
            return kept.id
        }
        return newest.id
    }

    /// Paths equal apart from a trailing slash; a file without a cwd never matches.
    static func same(_ path: String, _ other: String?) -> Bool {
        guard let other else { return false }
        func trimmed(_ value: String) -> String {
            value.count > 1 && value.hasSuffix("/") ? String(value.dropLast()) : value
        }
        return trimmed(path) == trimmed(other)
    }
}

/// What the strip reads from `state/mood.json`: only the mood key, the skin and the time.
enum CompanionMoodState {
    static let heartbeat: TimeInterval = 30

    static func payload(mood: String, skin: String, time: Date) -> Data {
        let object: [String: Any] = ["mood": mood, "skin": skin, "t": Int(time.timeIntervalSince1970)]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    /// Next to the `ame` folder: `…/wooloo-companion/state/mood.json`.
    static func fileURL(companionDirectory: URL) -> URL {
        companionDirectory.deletingLastPathComponent()
            .appendingPathComponent("state", isDirectory: true).appendingPathComponent("mood.json")
    }

    /// Whether the file is due: the mood key changed, or the heartbeat has run out.
    static func isDue(key: String, lastKey: String?, lastWrite: Date?, now: Date) -> Bool {
        guard key == lastKey, let lastWrite else { return true }
        return now.timeIntervalSince(lastWrite) >= heartbeat
    }
}

/// Writes the mood file one at a time, off the main thread; best effort.
actor CompanionStateWriter {
    func write(_ data: Data, to url: URL) {
        let manager = FileManager.default
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: Text emoticons and Ame's mood

/// Emoji do not render in the pixel font: they become text emoticons, or go.
enum CompanionText {
    private static let replacements: [UInt32: String] = {
        var table: [UInt32: String] = [:]
        for value: UInt32 in [0x2764, 0x1F495, 0x1F496, 0x1F497, 0x1F493, 0x2665] { table[value] = "<3" }
        for value: UInt32 in [0x1F60A, 0x1F604, 0x1F601, 0x1F970, 0x1F60D, 0x263A] { table[value] = "^^" }
        for value: UInt32 in [0x1F62D, 0x1F622, 0x1F979, 0x1F63F] { table[value] = "(;_;)" }
        for value: UInt32 in [0x1F620, 0x1F621] { table[value] = ">:(" }
        table[0x1F633] = "(//_//)"
        table[0x1F44B] = "~"
        table[0x2728] = "*"
        table[0x1F389] = "\\(^o^)/"
        return table
    }()

    /// Hearts, smiles, tears, anger, blushes, waves, sparkles and party poppers become emoticons;
    /// every other emoji (with variation selectors, joiners and skin tones) is removed and doubled
    /// spaces are closed up. Ordinary text, digits, `#`, `*` and kaomoji characters are left alone.
    static func sanitized(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var output = String.UnicodeScalarView()
        var changed = false
        var afterEmoji = false
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            let next = index + 1 < scalars.count ? scalars[index + 1] : nil
            index += 1
            if let replacement = replacements[scalar.value] {
                output.append(contentsOf: replacement.unicodeScalars)
                changed = true
                afterEmoji = true
                continue
            }
            switch scalar.value {
            case 0xFE0F, 0x20E3:
                changed = true
                continue
            case 0x200D:
                if afterEmoji { changed = true } else { output.append(scalar) }
                continue
            default:
                break
            }
            if scalar.value >= 0x80,
               scalar.properties.isEmojiPresentation || (scalar.properties.isEmoji && next?.value == 0xFE0F) {
                changed = true
                afterEmoji = true
                continue
            }
            afterEmoji = false
            output.append(scalar)
        }
        guard changed else { return text }
        var result = String(output)
        while result.contains("  ") { result = result.replacingOccurrences(of: "  ", with: " ") }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: " "))
    }
}

/// Ame's own words about how she feels override what the commander's status would show.
enum CompanionMoodResolver {
    /// How long her latest reply keeps the mood.
    static let window: TimeInterval = 10 * 60

    /// The mood key to show: her tagged (or worded) mood while her reply is at most ten minutes old
    /// and is one of the known moods; else the commander-driven key. The user's own love reaction
    /// always comes first.
    static func effective(commanderKey: String, ameMood: String?, age: TimeInterval?,
                          loveReaction: Bool) -> String {
        guard !loveReaction, let mood = ameMood?.lowercased(), CompanionMessage.validMoods.contains(mood),
              let age, age <= window else { return commanderKey }
        return mood
    }
}

// MARK: Things she does on her own

/// A small seeded generator, so the scheduler can be tested.
struct CompanionSplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Decides when she does one of her ambient things. In a calm base mood (idle, done or waiting)
/// she waits, picks one entry that fits her hearts level by weight, plays it for 20-45 s, rests
/// and may pick again. The more hearts, the shorter the waits: 90-180 s before a clip and 180-300 s
/// of rest at level 0, 25-60 s and 30-90 s at level 100. Any change of `context` (mood, skin, activity, a cutscene...) stops it at once.
struct CompanionAmbientScheduler {
    static let dwellAtZero: ClosedRange<TimeInterval> = 90...180
    static let dwellAtFull: ClosedRange<TimeInterval> = 25...60
    static let play: ClosedRange<TimeInterval> = 20...45
    static let cooldownAtZero: ClosedRange<TimeInterval> = 180...300
    static let cooldownAtFull: ClosedRange<TimeInterval> = 30...90

    /// The range for a hearts level (0...100): a straight line between the two ends.
    static func scaled(_ zero: ClosedRange<TimeInterval>, _ full: ClosedRange<TimeInterval>,
                       hearts: Double) -> ClosedRange<TimeInterval> {
        let t = hearts.isFinite ? min(max(hearts, 0), 100) / 100 : 0
        return (zero.lowerBound + (full.lowerBound - zero.lowerBound) * t)...(zero.upperBound + (full.upperBound - zero.upperBound) * t)
    }
    static let baseMoods: Set<String> = ["idle", "done", "waiting"]

    enum Phase: Equatable {
        case idle
        case dwelling(until: Date)
        case playing(key: String, until: Date)
        case cooling(until: Date)
    }

    private(set) var phase = Phase.idle
    private(set) var lastKey: String?
    private var context: String?
    private var generator: CompanionSplitMix64

    init(seed: UInt64 = UInt64.random(in: 0...UInt64.max)) {
        generator = CompanionSplitMix64(seed: seed)
    }

    var playingKey: String? {
        if case .playing(let key, _) = phase { return key }
        return nil
    }

    private mutating func random(_ range: ClosedRange<TimeInterval>) -> TimeInterval {
        range.lowerBound + Double.random(in: 0..<1, using: &generator) * (range.upperBound - range.lowerBound)
    }

    /// The entry to play now, if any: it suits the mood, the skin has its clip, it fits the hour
    /// and the commander's idle time, and it is not the one played last.
    mutating func pick(baseMood: String, entries: [CompanionAmbient], skinHas: (String) -> Bool,
                       hearts: Double) -> CompanionAmbient? {
        let candidates = entries.filter {
            $0.moods.contains(baseMood) && skinHas($0.key) && $0.key != lastKey
                && $0.fits(hearts: hearts)
        }
        let total = candidates.reduce(0) { $0 + $1.weight }
        guard !candidates.isEmpty, total > 0 else { return nil }
        var point = Double.random(in: 0..<total, using: &generator)
        for entry in candidates {
            if point < entry.weight { return entry }
            point -= entry.weight
        }
        return candidates.last
    }

    /// Call often. `baseMood` is nil whenever she must not do anything (a cutscene, a game or
    /// stream activity, the setting off). Returns the key of the clip to play, or nil.
    mutating func update(now: Date, context: String, baseMood: String?, entries: [CompanionAmbient],
                         skinHas: (String) -> Bool, hearts: Double) -> String? {
        if context != self.context {
            self.context = context
            phase = .idle
        }
        guard let baseMood, Self.baseMoods.contains(baseMood), !entries.isEmpty else {
            phase = .idle
            return nil
        }
        func choose(_ scheduler: inout CompanionAmbientScheduler) {
            if let entry = scheduler.pick(baseMood: baseMood, entries: entries, skinHas: skinHas,
                                          hearts: hearts) {
                scheduler.lastKey = entry.key
                scheduler.phase = .playing(key: entry.key, until: now.addingTimeInterval(scheduler.random(Self.play)))
            } else {
                // Nothing fits right now: look again after another wait.
                scheduler.phase = .dwelling(until: now.addingTimeInterval(scheduler.random(Self.scaled(Self.dwellAtZero, Self.dwellAtFull, hearts: hearts))))
            }
        }
        switch phase {
        case .idle:
            phase = .dwelling(until: now.addingTimeInterval(random(Self.scaled(Self.dwellAtZero, Self.dwellAtFull, hearts: hearts))))
        case .dwelling(let until):
            if now >= until { choose(&self) }
        case .playing(_, let until):
            if now >= until { phase = .cooling(until: now.addingTimeInterval(random(Self.scaled(Self.cooldownAtZero, Self.cooldownAtFull, hearts: hearts)))) }
        case .cooling(let until):
            if now >= until { choose(&self) }
        }
        return playingKey
    }
}

// MARK: Headpats

/// The optional `headpat` part of the manifest. Decoding never fails: a part that is missing or
/// malformed is simply empty, and without any head the feature is off.
struct CompanionHeadpat: Decodable, Equatable, Sendable {
    struct Sounds: Decodable, Equatable, Sendable {
        var pat: String?
        var third: String?

        init(pat: String? = nil, third: String? = nil) {
            self.pat = pat
            self.third = third
        }

        private enum Keys: String, CodingKey { case pat, third }

        init(from decoder: Decoder) {
            let container = try? decoder.container(keyedBy: Keys.self)
            pat = CompanionHeadpat.lossy(container, .pat, String.self).flatMap { CompanionBackground.isSafe($0) ? $0 : nil }
            third = CompanionHeadpat.lossy(container, .third, String.self).flatMap { CompanionBackground.isSafe($0) ? $0 : nil }
        }
    }

    /// From this many pats on, the mood shows `key`.
    struct Step: Equatable, Sendable {
        var pats: Int
        var key: String
    }

    struct Reaction: Decodable, Equatable, Sendable {
        /// The sequence key played while the pointer is on her head; nil = no change.
        var hover: String?
        var steps: [Step]
        var lines: [String]

        init(hover: String? = nil, steps: [Step] = [], lines: [String] = []) {
            self.hover = hover
            self.steps = steps
            self.lines = lines
        }

        private enum Keys: String, CodingKey { case hover, steps, lines }

        /// One `[pats, key]` pair; anything else is dropped.
        private struct RawStep: Decodable {
            var pats: Int?
            var key: String?

            init(from decoder: Decoder) {
                var container = try? decoder.unkeyedContainer()
                pats = try? container?.decode(Int.self)
                key = try? container?.decode(String.self)
            }
        }

        init(from decoder: Decoder) {
            let container = try? decoder.container(keyedBy: Keys.self)
            hover = CompanionHeadpat.lossy(container, .hover, String.self)
            let raw = CompanionHeadpat.lossy(container, .steps, [RawStep].self) ?? []
            steps = raw.compactMap { step in
                guard let pats = step.pats, pats >= 1, let key = step.key, !key.isEmpty else { return nil }
                return Step(pats: pats, key: key)
            }
            lines = (CompanionHeadpat.lossy(container, .lines, [String].self) ?? []).filter { !$0.isEmpty }
        }
    }

    var sounds = Sounds()
    /// Each skin's head as x, y, width, height in the pixels of the sprite image.
    var heads: [String: [Double]] = [:]
    /// By the mood she is in when the pats start.
    var reactions: [String: Reaction] = [:]

    init(sounds: Sounds = Sounds(), heads: [String: [Double]] = [:], reactions: [String: Reaction] = [:]) {
        self.sounds = sounds
        self.heads = heads
        self.reactions = reactions
    }

    private enum Keys: String, CodingKey { case sounds, heads, reactions }

    init(from decoder: Decoder) {
        let container = try? decoder.container(keyedBy: Keys.self)
        sounds = Self.lossy(container, .sounds, Sounds.self) ?? Sounds()
        let rawHeads = Self.lossy(container, .heads, [String: [Double]].self) ?? [:]
        heads = rawHeads.filter { Self.isValidHead($0.value) }
        reactions = Self.lossy(container, .reactions, [String: Reaction].self) ?? [:]
    }

    fileprivate static func lossy<T: Decodable, K: CodingKey>(_ container: KeyedDecodingContainer<K>?, _ key: K,
                                                              _ type: T.Type) -> T? {
        guard let container else { return nil }
        return try? container.decode(T.self, forKey: key)
    }

    static func isValidHead(_ rect: [Double]) -> Bool {
        rect.count == 4 && rect.allSatisfy(\.isFinite) && rect[2] > 0 && rect[3] > 0
    }

    /// Off without a single head.
    var isUsable: Bool { !heads.isEmpty }

    func head(forSkin skin: String) -> [Double]? { heads[skin] }

    /// The reaction for the mood she was in; falls back to the commander's plain mood.
    func reaction(for key: String) -> Reaction? { reactions[key] }

    /// The step with the highest pats that is at most `count`; nil below the first step.
    static func step(for count: Int, in steps: [Step]) -> Step? {
        steps.filter { $0.pats <= count }.max { $0.pats < $1.pats }
    }
}

/// One run of pats: they count while each comes within 20 s of the one before. Pure, so the
/// rules are testable.
struct CompanionHeadpatSession: Equatable {
    struct Report: Equatable {
        var count: Int
        var key: String
    }

    /// A pause longer than this ends the session.
    static let gap: TimeInterval = 20
    /// How long the reached mood stays after the last pat.
    static let hold: TimeInterval = 5 * 60
    /// Where the base was "working", "done" lasts only this long.
    static let workingDoneHold: TimeInterval = 4
    /// How long the line of a new step stays in the speech bubble.
    static let lineDuration: TimeInterval = 6

    private(set) var count = 0
    private(set) var base: String?
    private(set) var lastPat: Date?
    private(set) var reachedKey: String?
    private(set) var reachedPats = 0
    private(set) var line: String?
    private var lineUntil: Date?
    private var reported = true
    private var pending: Report?

    /// Whether `now` is still inside the session of the last pat.
    func isOngoing(now: Date) -> Bool {
        lastPat.map { now.timeIntervalSince($0) <= Self.gap } ?? false
    }

    /// Counts a pat. A pat after a pause starts a new session on `base`, the mood she is in now.
    /// Returns the number of pats of the session.
    @discardableResult
    mutating func pat(now: Date, base currentBase: String, reactions: [String: CompanionHeadpat.Reaction],
                      pick: (Int) -> Int = { Int.random(in: 0..<$0) }) -> Int {
        if !isOngoing(now: now) {
            if count >= CompanionPatMessage.minimumPats, !reported {
                pending = Report(count: count, key: reachedKey ?? base ?? currentBase)
            }
            count = 0
            base = currentBase
            reachedKey = nil
            reachedPats = 0
            line = nil
            lineUntil = nil
            reported = false
        }
        count += 1
        lastPat = now
        let reaction = base.flatMap { reactions[$0] }
        if let reaction, let step = CompanionHeadpat.step(for: count, in: reaction.steps) {
            let isNew = step.pats != reachedPats
            reachedKey = step.key
            reachedPats = step.pats
            if isNew, !reaction.lines.isEmpty {
                line = reaction.lines[min(max(0, pick(reaction.lines.count)), reaction.lines.count - 1)]
                lineUntil = now.addingTimeInterval(Self.lineDuration)
            }
        }
        return count
    }

    /// How long the reached mood stays.
    var holdDuration: TimeInterval {
        base == "working" && reachedKey == "done" ? Self.workingDoneHold : Self.hold
    }

    /// The mood key that overrides the sequence now: the reached one for five minutes after the
    /// last pat (four seconds for "done" on top of "working"), unless Ame's JINE reply is newer.
    func overrideKey(now: Date, ameMoodTime: Date?) -> String? {
        guard let reachedKey, let lastPat, now.timeIntervalSince(lastPat) < holdDuration else { return nil }
        if let ameMoodTime, ameMoodTime > lastPat { return nil }
        return reachedKey
    }

    /// True while the pats go on or their mood shows: an ambient clip must not run then.
    func isEngaged(now: Date, ameMoodTime: Date?) -> Bool {
        isOngoing(now: now) || overrideKey(now: now, ameMoodTime: ameMoodTime) != nil
    }

    /// The line for the speech bubble while it is due.
    func bubbleLine(now: Date) -> String? {
        guard let line, let lineUntil, now < lineUntil else { return nil }
        return line
    }

    /// Once per session of at least three pats, after it ended: how many pats and the feeling.
    mutating func takeEnded(now: Date) -> Report? {
        if let report = pending {
            pending = nil
            return report
        }
        guard count >= CompanionPatMessage.minimumPats, !reported, !isOngoing(now: now) else { return nil }
        reported = true
        return Report(count: count, key: reachedKey ?? base ?? "idle")
    }
}

/// The hidden turn that tells Ame about a headpat session.
enum CompanionPatMessage {
    static let prefix = "[pat]"
    static let minimumPats = 3
    static let minimumInterval: TimeInterval = 10 * 60
    static let lastSentKey = "companionPatLastSent"

    static func isPat(_ text: String) -> Bool {
        text.drop(while: { $0.isWhitespace }).lowercased().hasPrefix(prefix)
    }

    /// "[pat] P-chan gave you 5 headpats; you feel: loving"
    static func text(count: Int, key: String) -> String {
        "\(prefix) P-chan gave you \(count) headpats; you feel: \(CompanionNudge.moodWord(key))"
    }

    /// Enough pats, Ame free to answer, ten minutes since the last one sent, and not in the quiet hours.
    static func allowed(count: Int, lastSent: Date?, now: Date, ameStatus: String?,
                        calendar: Calendar = .current) -> Bool {
        guard count >= minimumPats, CompanionNudge.isAvailable(status: ameStatus),
              !CompanionNudge.isQuiet(now, calendar: calendar) else { return false }
        if let lastSent, now.timeIntervalSince(lastSent) < minimumInterval { return false }
        return true
    }
}

/// Pat sounds: which ones a pat plays, and playing them.
enum CompanionHeadpatSound {
    /// Every third pat of a session also plays the "third" sound.
    static func playsThird(count: Int) -> Bool { count > 0 && count % 3 == 0 }

    static func paths(count: Int, sounds: CompanionHeadpat.Sounds) -> [String] {
        var result: [String] = []
        if let pat = sounds.pat { result.append(pat) }
        if playsThird(count: count), let third = sounds.third { result.append(third) }
        return result
    }

    @MainActor private static var playing: [NSSound] = []

    @MainActor
    static func play(_ paths: [String], in directory: URL) {
        playing.removeAll { !$0.isPlaying }
        for path in paths {
            guard CompanionBackground.isSafe(path),
                  let sound = NSSound(contentsOf: directory.appendingPathComponent(path), byReference: false)
            else { continue }
            playing.append(sound)
            sound.play()
        }
    }
}

/// Where her head is in the room, and whether the pointer is on it.
enum CompanionHeadpatHit {
    /// The settings button in the top-right corner (16 pt plus padding) and the resize strip along
    /// the bottom edge keep their clicks.
    static let gearSize: CGFloat = 22
    static let stripHeight: CGFloat = 7

    static func contains(_ point: CGPoint, head: CGRect?, area: CGSize) -> Bool {
        guard let head, head.contains(point) else { return false }
        let gear = CGRect(x: area.width - gearSize, y: 0, width: gearSize, height: gearSize)
        let strip = CGRect(x: 0, y: area.height - stripHeight, width: area.width, height: stripHeight)
        return !gear.contains(point) && !strip.contains(point)
    }
}

extension CompanionScene {
    /// The head rectangle (x, y, width, height in the pixels of the sprite image) in the room's
    /// coordinates, through the same fit, magnification and placement as `body`.
    static func headRect(head: [Double], imageSize: CGSize, background: CGSize?, spriteRect: [Double]?,
                         visible: CGRect?, area: CGSize, zoom: Double) -> CGRect? {
        guard CompanionHeadpat.isValidHead(head), imageSize.width > 0, imageSize.height > 0,
              area.width > 0, area.height > 0, zoom.isFinite, zoom > 0 else { return nil }
        let origin: CGPoint
        let fit: CGFloat
        let anchor: CGPoint
        let offset: CGPoint
        if let background, let rect = spriteRect, rect.count == 4, background.width > 0, background.height > 0,
           rect[2] > 0, rect[3] > 0 {
            let scale = fillScale(content: background, in: area)
            let unit = zoomAnchor(spriteRect: rect, backgroundSize: background, imageSize: imageSize, visible: visible)
            anchor = CGPoint(x: unit.x * background.width * scale, y: unit.y * background.height * scale)
            let backgroundFit = min(rect[2] / imageSize.width, rect[3] / imageSize.height)
            let shown = CGSize(width: imageSize.width * backgroundFit, height: imageSize.height * backgroundFit)
            origin = CGPoint(x: (rect[0] + (rect[2] - shown.width) / 2) * scale,
                             y: (rect[1] + (rect[3] - shown.height) / 2) * scale)
            fit = backgroundFit * scale
            offset = CGPoint(x: (area.width - background.width * scale) / 2,
                             y: area.height - background.height * scale)
        } else {
            let unit = zoomAnchor(visible: visible, imageSize: imageSize, area: area)
            anchor = CGPoint(x: unit.x * area.width, y: unit.y * area.height)
            fit = min(area.width / imageSize.width, area.height / imageSize.height)
            origin = CGPoint(x: (area.width - imageSize.width * fit) / 2, y: (area.height - imageSize.height * fit) / 2)
            offset = .zero
        }
        let z = CGFloat(zoom)
        let x = origin.x + head[0] * fit
        let y = origin.y + head[1] * fit
        return CGRect(x: offset.x + anchor.x + z * (x - anchor.x), y: offset.y + anchor.y + z * (y - anchor.y),
                      width: head[2] * fit * z, height: head[3] * fit * z)
    }
}

// MARK: Hearts

/// The optional `hearts` part of the manifest. Decoding never fails; without it the feature is off.
struct CompanionHearts: Decodable, Equatable, Sendable {
    struct Nap: Equatable, Sendable {
        var key = "sleep"
        var fallback: String?
    }

    struct Gains: Equatable, Sendable {
        var pat = 4.0
        var jineLove = 8.0
        var jineHappy = 4.0
        var userLove = 6.0
    }

    struct Losses: Equatable, Sendable {
        var jineSad = 5.0
        var jineAngry = 8.0
    }

    var icon: String?
    var nap = Nap()
    var gains = Gains()
    var losses = Losses()
    var decayPerHour = 10.0
    private var valid = true

    init() {}

    private enum Keys: String, CodingKey { case icon, nap, gains, losses, decayPerHour }
    private enum NapKeys: String, CodingKey { case key, fallback }
    private enum GainKeys: String, CodingKey { case pat, jineLove, jineHappy, userLove }
    private enum LossKeys: String, CodingKey { case jineSad, jineAngry }

    private static func number<K: CodingKey>(_ container: KeyedDecodingContainer<K>?, _ key: K, _ fallback: Double,
                                             _ range: ClosedRange<Double>) -> Double {
        guard let value = CompanionHeadpat.lossy(container, key, Double.self), value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    init(from decoder: Decoder) {
        guard let container = try? decoder.container(keyedBy: Keys.self) else {
            valid = false
            return
        }
        icon = CompanionHeadpat.lossy(container, .icon, String.self).flatMap { CompanionBackground.isSafe($0) ? $0 : nil }
        if let nap = try? container.nestedContainer(keyedBy: NapKeys.self, forKey: .nap) {
            if let key = CompanionHeadpat.lossy(nap, .key, String.self), !key.isEmpty { self.nap.key = key }
            self.nap.fallback = CompanionHeadpat.lossy(nap, .fallback, String.self)
        }
        if let gains = try? container.nestedContainer(keyedBy: GainKeys.self, forKey: .gains) {
            self.gains.pat = Self.number(gains, .pat, 4, 0...100)
            self.gains.jineLove = Self.number(gains, .jineLove, 8, 0...100)
            self.gains.jineHappy = Self.number(gains, .jineHappy, 4, 0...100)
            self.gains.userLove = Self.number(gains, .userLove, 6, 0...100)
        }
        if let losses = try? container.nestedContainer(keyedBy: LossKeys.self, forKey: .losses) {
            self.losses.jineSad = Self.number(losses, .jineSad, 5, 0...100)
            self.losses.jineAngry = Self.number(losses, .jineAngry, 8, 0...100)
        }
        decayPerHour = Self.number(container, .decayPerHour, 10, 0...100)
    }

    var isUsable: Bool { valid }

    /// The level change of one reply of Ame, by its mood.
    func delta(forAmeMood mood: String?) -> Double {
        switch mood?.lowercased() {
        case "love": return gains.jineLove
        case "done": return gains.jineHappy
        case "sad", "crying": return -losses.jineSad
        case "angry": return -losses.jineAngry
        default: return 0
        }
    }
}

/// Her hearts level (0...100), kept in UserDefaults with the time it was last updated, so the
/// decay runs by wall time across relaunches. Pure apart from `load` and `save`.
struct CompanionHeartsState: Equatable {
    static let levelKey = "companionHearts"
    static let updatedKey = "companionHeartsUpdated"
    static let ameCountedKey = "companionHeartsAme"
    static let userCountedKey = "companionHeartsUser"
    static let startLevel = 40.0

    private(set) var level = CompanionHeartsState.startLevel
    private(set) var updated: Date
    /// The newest Ame reply and the newest user message already counted.
    private(set) var ameCounted: Date?
    private(set) var userCounted: Date?

    init(now: Date) { updated = now }

    /// Takes away `decayPerHour` for each hour since the last update.
    mutating func decay(now: Date, config: CompanionHearts) {
        let elapsed = now.timeIntervalSince(updated)
        guard elapsed > 0 else { return }
        updated = now
        level = max(0, level - config.decayPerHour * elapsed / 3600)
    }

    /// Changes the level, kept in 0...100. True only on the upward edge: the level was below 100
    /// and is now 100. Staying at 100 never fires again; it re-arms once the level is below 100.
    @discardableResult
    mutating func add(_ delta: Double, now: Date, config: CompanionHearts) -> Bool {
        decay(now: now, config: config)
        guard delta.isFinite else { return false }
        let before = level
        level = min(100, max(0, level + delta))
        return before < 100 && level >= 100
    }

    /// Counts the replies of Ame and the messages of the user that are newer than the ones counted
    /// before, each once. The very first sight of a conversation only notes its newest message, so
    /// the old history does not count. Returns true when the change took the level up to 100.
    @discardableResult
    mutating func count(messages: [CompanionMessage], ameMood: (CompanionMessage) -> String?,
                        loveExtra: [String], now: Date, config: CompanionHearts) -> Bool {
        var total = 0.0
        let replies = messages.filter { $0.role == .assistant && $0.time != nil }.sorted { $0.time! < $1.time! }
        let mine = messages.filter { $0.role == .user && $0.time != nil }.sorted { $0.time! < $1.time! }
        if let counted = ameCounted {
            for reply in replies where reply.time! > counted { total += config.delta(forAmeMood: ameMood(reply)) }
        }
        if let newest = replies.last?.time, newest > (ameCounted ?? .distantPast) { ameCounted = newest }
        if let counted = userCounted {
            for message in mine where message.time! > counted && CompanionAffection.matches(message.text, extra: loveExtra) {
                total += config.gains.userLove
            }
        }
        if let newest = mine.last?.time, newest > (userCounted ?? .distantPast) { userCounted = newest }
        decay(now: now, config: config)
        return total != 0 && add(total, now: now, config: config)
    }

    static func load(defaults: UserDefaults = .standard, now: Date, config: CompanionHearts) -> CompanionHeartsState {
        var state = CompanionHeartsState(now: now)
        if defaults.object(forKey: levelKey) != nil {
            let level = defaults.double(forKey: levelKey)
            state.level = level.isFinite ? min(100, max(0, level)) : startLevel
        }
        let updated = defaults.double(forKey: updatedKey)
        state.updated = updated > 0 ? Date(timeIntervalSince1970: updated) : now
        func date(_ key: String) -> Date? {
            let value = defaults.double(forKey: key)
            return value > 0 ? Date(timeIntervalSince1970: value) : nil
        }
        state.ameCounted = date(ameCountedKey)
        state.userCounted = date(userCountedKey)
        // A launch at 100 does not fire the nap; only a rise to 100 does.
        state.decay(now: now, config: config)
        return state
    }

    func save(defaults: UserDefaults = .standard) {
        defaults.set(level, forKey: Self.levelKey)
        defaults.set(updated.timeIntervalSince1970, forKey: Self.updatedKey)
        func store(_ date: Date?, _ key: String) {
            if let date { defaults.set(date.timeIntervalSince1970, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        store(ameCounted, Self.ameCountedKey)
        store(userCounted, Self.userCountedKey)
    }
}

/// The nap: when the level reaches 100 she plays one clip once, then goes back to her mood.
enum CompanionNap {
    static let bubble = "zzz... ♡"

    /// `nap.key` if the skin has its own, else the fallback; nil when neither exists.
    static func key(config: CompanionHearts.Nap, skinHas: (String) -> Bool) -> String? {
        if skinHas(config.key) { return config.key }
        if let fallback = config.fallback, skinHas(fallback) { return fallback }
        return nil
    }

    /// The clip played once: no loop, and no blink or gesture holds.
    static func oneShot(_ sequence: CompanionSequence) -> CompanionSequence {
        CompanionSequence(dir: sequence.dir, frames: sequence.frames, fps: fps, loop: false, style: nil)
    }

    /// The nap clip always plays at this speed, so a 9-frame clip takes 3 seconds.
    static let fps = 3.0

    /// The test trigger: a value of `companionTestCuddle` that differs from the last one seen
    /// (the first one seen, at launch, only becomes the baseline).
    static let testDefaultsKey = "companionTestCuddle"

    static func testTriggered(current: String?, last: String?) -> Bool {
        guard let current, !current.isEmpty else { return false }
        return current != last
    }

    /// A pass in play: it started at `startedAt` (set when its first frame shows) and lasts one run.
    struct Pass: Equatable {
        var key: String
        var sequence: CompanionSequence
        var startedAt: Date?

        func isActive(now: Date) -> Bool {
            guard let startedAt else { return true }
            return now < startedAt.addingTimeInterval(sequence.duration)
        }
    }

    /// The pass to start for an upward edge: one variant of the key, picked by `pick`.
    static func pass(key: String, sequences: [CompanionSequence], pick: (Int) -> Int = { Int.random(in: 0..<$0) }) -> Pass? {
        guard !sequences.isEmpty else { return nil }
        return Pass(key: key, sequence: oneShot(sequences[min(max(0, pick(sequences.count)), sequences.count - 1)]),
                    startedAt: nil)
    }
}

/// The hearts that float up from her head while the nap pass plays.
enum CompanionCuddle {
    static let count = 7
    static let life: TimeInterval = 1.2
    static let step: CGFloat = 4
    static let tick: TimeInterval = 1.0 / 6

    /// Centres of the hearts alive `elapsed` seconds into a pass of `duration`: they start one after
    /// another, rise from the head across the room in hard steps, sway sideways, and are all gone
    /// when the pass ends.
    static func positions(elapsed: TimeInterval, duration: TimeInterval, head: CGRect?, area: CGSize) -> [CGPoint] {
        guard elapsed >= 0, elapsed < duration, duration > life, area.width > 0, area.height > 0 else { return [] }
        // From her chest (the head's bottom edge) up to just inside the top of the room; always inside it.
        let inset: CGFloat = 8
        let topY = max(inset, 12)
        let originX = head?.midX ?? area.width / 2
        let originY = min(max(head?.maxY ?? area.height * 0.7, area.height * 0.4), area.height - inset)
        let stepped = (elapsed / tick).rounded(.down) * tick
        var result: [CGPoint] = []
        for i in 0..<count {
            let start = Double(i) * (duration - life) / Double(count - 1)
            let age = stepped - start
            guard age >= 0, age < life else { continue }
            let progress = CGFloat(age / life)
            let spread = CGFloat((i * 5) % 7 - 3) * 8
            let sway = (Int(age / tick) % 4 < 2 ? -1 : 1) * CGFloat(4 + i % 3 * 2)
            let x = min(max(originX + spread + sway, inset), area.width - inset)
            let y = max(originY - progress * (originY - topY), topY)
            result.append(CGPoint(x: min(max((x / step).rounded() * step, inset), area.width - inset),
                                  y: min(max((y / step).rounded() * step, inset), area.height - inset)))
        }
        return result
    }
}

/// The bar's fill as a whole number of steps: a hard step, never a slide.
enum CompanionHeartsBar {
    static let steps = 20

    static func filled(level: Double) -> Int {
        guard level.isFinite else { return 0 }
        return Int((min(max(level, 0), 100) / 100 * Double(steps)).rounded(.down))
    }

    /// The x of the heart's centre: the tip of the fill, kept so the whole icon stays inside the track.
    static func tipX(trackWidth: CGFloat, filled: Int, iconWidth: CGFloat) -> CGFloat {
        guard trackWidth.isFinite, trackWidth > 0 else { return 0 }
        let tip = trackWidth * CGFloat(min(max(filled, 0), steps)) / CGFloat(steps)
        let half = iconWidth / 2
        if trackWidth <= iconWidth { return trackWidth / 2 }
        return min(max(tip, half), trackWidth - half)
    }
}

/// The invisible layer over the room that finds her head: hover shows the pointing hand and the
/// reaction's hover animation, a click is one pat. The gear button and the resize strip keep
/// their own clicks.
struct CompanionHeadpatLayer: View {
    let head: (CGSize) -> CGRect?
    let onHover: (Bool) -> Void
    let onPat: () -> Void
    @State private var over = false

    var body: some View {
        GeometryReader { area in
            Color.clear
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        set(CompanionHeadpatHit.contains(point, head: head(area.size), area: area.size))
                    case .ended:
                        set(false)
                    }
                }
                .gesture(SpatialTapGesture().onEnded { tap in
                    if CompanionHeadpatHit.contains(tap.location, head: head(area.size), area: area.size) { onPat() }
                })
        }
        .onDisappear { set(false) }
    }

    private func set(_ value: Bool) {
        guard value != over else { return }
        over = value
        if value { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        onHover(value)
    }
}

/// Her hearts: a small pink bar with the heart on the left. The fill moves in whole steps.
struct CompanionHeartsBarView: View {
    let filled: Int
    let level: Double
    let icon: CGImage?
    static let iconHeight: CGFloat = 16

    var body: some View {
        let height = Self.iconHeight
        let width = icon.map { height * CGFloat($0.width) / CGFloat(max($0.height, 1)) } ?? height
        GeometryReader { track in
            let x = CompanionHeartsBar.tipX(trackWidth: track.size.width, filled: filled, iconWidth: width)
            ZStack(alignment: .leading) {
                Rectangle().fill(CompanionPalette.panel).frame(height: 8)
                Rectangle().fill(CompanionPalette.pink)
                    .frame(width: track.size.width * CGFloat(filled) / CGFloat(CompanionHeartsBar.steps), height: 8)
                Rectangle().strokeBorder(CompanionPalette.indigo, lineWidth: 1).frame(height: 8)
                Group {
                    if let icon {
                        Image(decorative: icon, scale: 1).interpolation(.none).resizable()
                    } else {
                        Image(systemName: "heart.fill").resizable().foregroundStyle(CompanionPalette.pink)
                    }
                }
                .aspectRatio(contentMode: .fit)
                .frame(width: width, height: height)
                .offset(x: x - width / 2)
            }
            .frame(height: height, alignment: .leading)
        }
        .frame(height: height)
        .transaction { $0.animation = nil }
        .help("Ame's hearts")
        .accessibilityLabel("Ame's hearts")
        .accessibilityValue("\(Int(level)) percent")
    }
}
