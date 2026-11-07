import AppKit
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

    private static func isSafe(_ path: String) -> Bool {
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

    enum CodingKeys: String, CodingKey {
        case version, size, moods, lines, background
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
                                 spriteRect: scene != nil ? rect : nil)
    }

    /// The background file for `date`: the night one from 20:00 to 06:00 when there is one.
    func backgroundPath(at date: Date, calendar: Calendar = .current) -> String? {
        guard let background else { return nil }
        let night = CompanionBackground.isNight(hour: calendar.component(.hour, from: date))
        return night ? background.night ?? background.defaultPath : background.defaultPath
    }

    func sequences(for mood: CompanionMood) -> [CompanionSequence] { moods[mood.rawValue] ?? [] }
    func lines(for mood: CompanionMood) -> [String] { (lines[mood.rawValue] ?? []).filter { !$0.isEmpty } }
}

/// Which sequence and speech line show now. Pure, so rotation is testable: `pick` returns an index
/// below its argument.
struct CompanionPlayer {
    static let loopRotation: TimeInterval = 15
    static let lineRotation: TimeInterval = 20

    private(set) var mood: CompanionMood?
    private(set) var sequence: CompanionSequence?
    private(set) var sequenceStart = Date.distantPast
    private(set) var line: String?
    private var lineStart = Date.distantPast

    /// Moves to a new sequence or line when the mood changed, a one-shot sequence ended, a loop
    /// has played long enough, or a line has been up long enough. Returns whether anything changed.
    @discardableResult
    mutating func advance(now: Date, mood newMood: CompanionMood, manifest: CompanionManifest,
                          pick: (Int) -> Int = { Int.random(in: 0..<$0) }) -> Bool {
        var changed = false
        let moodChanged = mood != newMood
        let elapsed = now.timeIntervalSince(sequenceStart)
        if moodChanged || sequence == nil
            || (sequence.map { $0.loop ? elapsed >= Self.loopRotation : elapsed >= $0.duration } ?? true) {
            let choices = manifest.sequences(for: newMood)
            // Not the same sequence twice in a row when there is another one.
            let others = choices.filter { $0 != sequence }
            let pool = others.isEmpty || moodChanged ? choices : others
            let next = pool.isEmpty ? nil : pool[pick(pool.count)]
            changed = true
            sequence = next
            sequenceStart = now
        }
        if moodChanged || line == nil || now.timeIntervalSince(lineStart) >= Self.lineRotation {
            let lines = manifest.lines(for: newMood)
            let others = lines.filter { $0 != line }
            let pool = others.isEmpty ? lines : others
            line = pool.isEmpty ? nil : pool[pick(pool.count)]
            lineStart = now
            changed = true
        }
        mood = newMood
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

/// What the commander says, taken from the text parts of its newest Claude Code reply. Only those
/// parts are read; the text is never logged or stored.
enum CompanionDialogue {
    static let maximumLength = 140

    /// The text parts of the newest `assistant` record in the tail of a transcript. A tail that
    /// starts in the middle of the file begins with a partial line, which is dropped. Records of
    /// other types, and replies without a text part (tool calls only), are skipped.
    static func latestAssistantText(inTail data: Data, startsMidFile: Bool) -> String? {
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
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        }
        return nil
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
    static func pick(mood: CompanionMood, sentences: [String]) -> String? {
        let sentence: String?
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
        var text: String?
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
        guard Self.isSessionID(sessionID) else { return nil }
        var entry = entries[sessionID] ?? Entry()
        defer { entries[sessionID] = entry }
        if let checked = entry.checked, now.timeIntervalSince(checked) < Self.minimumInterval { return entry.text }
        entry.checked = now
        if entry.url == nil { entry.url = locate(sessionID) }
        guard let url = entry.url else { return nil }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.intValue else {
            entry.url = nil
            return nil
        }
        let modified = attributes[.modificationDate] as? Date
        if size == entry.size, modified == entry.modified { return entry.text }
        entry.size = size
        entry.modified = modified
        entry.text = Self.readTail(of: url, size: size)
        return entry.text
    }

    private func locate(_ sessionID: String) -> URL? {
        guard let folders = try? FileManager.default.contentsOfDirectory(
            at: projects, includingPropertiesForKeys: nil) else { return nil }
        return folders.map { $0.appendingPathComponent("\(sessionID).jsonl") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func readTail(of url: URL, size: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let offset = max(0, size - tailBytes)
        guard (try? handle.seek(toOffset: UInt64(offset))) != nil,
              let data = try? handle.readToEnd() else { return nil }
        return CompanionDialogue.latestAssistantText(inTail: data, startsMidFile: offset > 0)
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
    private var directory = CompanionManifest.directory
    @Published private(set) var sentences: [String] = []
    @Published private(set) var backgrounds: [String: CGImage] = [:]
    private var loading: Set<String> = []
    private var started = false
    private let reader = CompanionTranscriptReader()
    private var dialogueSession: String?
    private var dialogueRequested = Date.distantPast
    private var dialogueInFlight = false

    /// Loading starts at creation: the view shows nothing until the manifest is in, so an
    /// `onAppear` on that empty content would never fire.
    init() { start() }

    func start() {
        guard !started else { return }
        started = true
        let directory = directory
        Task {
            let manifest = await Task.detached(priority: .utility) { CompanionManifest.load(from: directory) }.value
            self.manifest = manifest
        }
    }

    /// Called as time passes and when the commander's mood changes.
    func advance(now: Date, mood: CompanionMood) {
        guard let manifest else { return }
        var next = player
        if next.advance(now: now, mood: mood, manifest: manifest) { player = next }
        if let sequence = next.sequence { ensureLoaded(sequence) }
        ensureBackground(at: now)
    }

    /// The commander's words for the current mood, from its newest reply.
    var dialogue: String? { player.mood.flatMap { CompanionDialogue.pick(mood: $0, sentences: sentences) } }

    /// Re-reads the commander's transcript, off the main thread and at most every 1.5 s.
    func refreshDialogue(sessionID: String?, now: Date = Date()) {
        if sessionID != dialogueSession {
            dialogueSession = sessionID
            dialogueRequested = .distantPast
            if !sentences.isEmpty { sentences = [] }
        }
        guard let sessionID, !dialogueInFlight,
              now.timeIntervalSince(dialogueRequested) >= CompanionTranscriptReader.minimumInterval else { return }
        dialogueRequested = now
        dialogueInFlight = true
        let reader = reader
        Task {
            let text = await reader.latestText(sessionID: sessionID)
            self.dialogueInFlight = false
            guard self.dialogueSession == sessionID else { return }
            let next = text.map { CompanionDialogue.sentences(fromMarkdown: $0) } ?? []
            if next != self.sentences { self.sentences = next }
        }
    }

    /// The scene behind her at `now` (the night one in the evening), once loaded.
    func backgroundImage(at now: Date) -> CGImage? {
        manifest?.backgroundPath(at: now).flatMap { backgrounds[$0] }
    }

    private func ensureBackground(at now: Date) {
        guard let path = manifest?.backgroundPath(at: now), backgrounds[path] == nil,
              loading.insert("bg:" + path).inserted else { return }
        let url = directory.appendingPathComponent(path)
        Task {
            let image = await Task.detached(priority: .utility) { () -> CGImage? in
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                return CGImageSourceCreateImageAtIndex(source, 0, nil)
            }.value
            if let image { self.backgrounds[path] = image }
        }
    }

    func image(at now: Date) -> CGImage? {
        guard let sequence = player.sequence, let frames = loaded[sequence.dir]?.images, !frames.isEmpty else { return nil }
        return frames[min(player.frameIndex(at: now), frames.count - 1)]
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

/// The companion and her speech bubble. Draws nothing when there is no manifest.
struct CompanionView: View {
    let agents: [HerdrAgent]
    let workspaceID: String?
    /// The sidebar's width; the companion is 0.9 times as tall.
    let width: CGFloat
    @StateObject private var model = CompanionModel()

    var body: some View {
        Group {
            if model.manifest != nil {
                let commander = CompanionMood.commander(in: agents, workspaceID: workspaceID)
                let mood = CompanionMood(agentStatus: commander?.agentStatus)
                VStack(spacing: 0) {
                    TimelineView(.animation(minimumInterval: 1 / (model.player.sequence?.fps ?? 10))) { context in
                        VStack(spacing: 6) {
                            CompanionScene(background: model.backgroundImage(at: context.date),
                                           spriteRect: model.manifest?.spriteRect,
                                           sprite: model.image(at: context.date))
                            if let text = model.player.bubbleText(dialogue: model.dialogue,
                                                                  title: commander?.terminalTitleStripped) {
                                CompanionBubble(text: text)
                            }
                        }
                        .onChange(of: context.date) { _, date in
                            model.advance(now: date, mood: mood)
                            model.refreshDialogue(sessionID: commander?.agentSessionID, now: date)
                        }
                        .onChange(of: mood) { _, mood in model.advance(now: Date(), mood: mood) }
                        .onAppear { model.advance(now: Date(), mood: mood) }
                    }
                    .padding(7)
                    .frame(height: width * 0.9)
                    Divider()
                }
            }
        }
        .onAppear { model.start() }
        .onChange(of: model.manifest != nil) { _, _ in
            model.advance(now: Date(), mood: CompanionMood(agentStatus:
                CompanionMood.commander(in: agents, workspaceID: workspaceID)?.agentStatus))
        }
        .accessibilityHidden(true)
    }
}

/// Her sprite, alone or in front of a background that is fitted into the area; the sprite is
/// fitted into `spriteRect`, given in background pixels, at the background's scale.
private struct CompanionScene: View {
    let background: CGImage?
    let spriteRect: [Double]?
    let sprite: CGImage?

    /// The scale that fits `content` into `area` without cropping.
    static func fitScale(content: CGSize, in area: CGSize) -> CGFloat {
        guard content.width > 0, content.height > 0 else { return 1 }
        return min(area.width / content.width, area.height / content.height)
    }

    var body: some View {
        GeometryReader { area in
            if let background, let rect = spriteRect, rect.count == 4 {
                let size = CGSize(width: background.width, height: background.height)
                let scale = Self.fitScale(content: size, in: area.size)
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
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .frame(width: area.size.width, height: area.size.height)
            } else if let sprite {
                Image(decorative: sprite, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: area.size.width, height: area.size.height)
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
