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

struct CompanionManifest: Decodable, Equatable, Sendable {
    let version: Int
    let size: [Int]
    let moods: [String: [CompanionSequence]]
    let lines: [String: [String]]

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
        return CompanionManifest(version: 1, size: manifest.size, moods: usable, lines: manifest.lines)
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

    /// While working, the commander's terminal title says what it does; otherwise a line of the mood.
    func bubbleText(title: String?) -> String? {
        if mood == .working, let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        return line
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
    private var loading: Set<String> = []
    private var started = false

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
                            Group {
                                if let image = model.image(at: context.date) {
                                    Image(decorative: image, scale: 1)
                                        .interpolation(.none)
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                } else {
                                    Color.clear
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            if let text = model.player.bubbleText(title: commander?.terminalTitleStripped) {
                                CompanionBubble(text: text)
                            }
                        }
                        .onChange(of: context.date) { _, date in model.advance(now: date, mood: mood) }
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

/// A rounded speech bubble whose tail points up at the companion.
private struct CompanionBubble: View {
    let text: String
    @Environment(\.woolooTypography) private var typography

    var body: some View {
        Text(text)
            .font(.system(size: typography.secondary))
            .foregroundStyle(Color(red: 0.22, green: 0.15, blue: 0.3))
            .lineLimit(3)
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
