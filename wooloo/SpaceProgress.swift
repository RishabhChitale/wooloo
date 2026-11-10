import SwiftUI

// Unit progress pills for the right-sidebar Spaces. They show the same words and colours as the Pokemon strip,
// read from the unit's state files: ~/.local/state/unit-progress/<agent>.json (checklists), unit-ask entries in
// ~/.local/share/wooloo-companion/tasks/ask-*.json, and the strip's read-only background-shell cache.

struct UnitProgressEntry: Equatable, Sendable {
    var items: Int
    var done: Int
    var updatedAt: TimeInterval

    var percent: Int { items > 0 ? Int((Double(min(done, items)) / Double(items) * 100).rounded()) : 0 }
    var allDone: Bool { items > 0 && done >= items }
}

/// Everything read from the unit's files in one poll.
struct UnitFiles: Equatable, Sendable {
    var progress: [String: UnitProgressEntry] = [:]
    /// Agents named in unit-ask entries, one element per entry.
    var askers: [String] = []
    /// Panes the strip last saw with a background shell running, with the time it saw them.
    var backgroundPanes: [String: TimeInterval] = [:]
}

/// A Herdr agent reduced to what the pills need.
struct SpaceAgent: Equatable, Sendable {
    var name: String
    var paneID: String
    var status: String?
}

struct SpacePillSummary: Equatable, Sendable {
    var isUnitSpace = false
    var working = 0
    var workingPercent = 0
    var done = 0
    var unfinished = 0
    var waiting = 0
    var stale = 0

    var hasPills: Bool { working + done + unfinished + waiting + stale > 0 }

    static let staleAfter: TimeInterval = 600
    static let backgroundFreshFor: TimeInterval = 30

    static func isUnitName(_ name: String) -> Bool {
        name == "commander" || name.hasPrefix("commander-") || name.hasPrefix("second-commander") || name.hasPrefix("pawn-")
    }

    /// `agents` are the Space's agents; `unreadDone` the panes with an unseen Done notification.
    static func make(agents: [SpaceAgent], files: UnitFiles, unreadDone: Set<String>, now: TimeInterval) -> SpacePillSummary {
        var out = SpacePillSummary()
        out.isUnitSpace = agents.contains { isUnitName($0.name) || files.progress[$0.name] != nil }
        guard out.isUnitSpace else { return out }
        var percents: [Int] = []
        for agent in agents {
            guard let entry = files.progress[agent.name] else { continue }
            let status = agent.status ?? ""
            if status == "working" {
                if now - entry.updatedAt > staleAfter { out.stale += 1 } else { percents.append(entry.percent) }
            } else if status == "idle" || status == "done" {
                if entry.allDone {
                    if unreadDone.contains(agent.paneID) { out.done += 1 }
                } else if let seen = files.backgroundPanes[agent.paneID], now - seen < backgroundFreshFor, seen <= now + 5 {
                    percents.append(entry.percent)
                } else {
                    out.unfinished += 1
                }
            }
        }
        out.working = percents.count
        out.workingPercent = percents.isEmpty ? 0 : Int((Double(percents.reduce(0, +)) / Double(percents.count)).rounded())
        let names = Set(agents.map(\.name))
        out.waiting = files.askers.filter { names.contains($0) }.count
        return out
    }
}

enum UnitFilesReader {
    static var home: String { NSHomeDirectory() }

    /// A cheap fingerprint of the watched files (names and modification times) to skip decoding when nothing changed.
    static func signature() -> [String] {
        var out: [String] = []
        let fm = FileManager.default
        let dirs = ["\(home)/.local/state/unit-progress", "\(home)/.local/share/wooloo-companion/tasks"]
        for dir in dirs {
            for name in (try? fm.contentsOfDirectory(atPath: dir))?.sorted() ?? [] where name.hasSuffix(".json") {
                if dir.hasSuffix("tasks"), !name.hasPrefix("ask-") { continue }
                let m = (try? fm.attributesOfItem(atPath: "\(dir)/\(name)"))?[.modificationDate] as? Date
                out.append("\(dir)/\(name)@\(m?.timeIntervalSince1970 ?? 0)")
            }
        }
        let bg = "\(home)/.local/share/pokemon-agents/bg-shell.json"
        let m = (try? fm.attributesOfItem(atPath: bg))?[.modificationDate] as? Date
        out.append("bg@\(m?.timeIntervalSince1970 ?? 0)")
        return out
    }

    static func read() -> UnitFiles {
        var files = UnitFiles()
        let fm = FileManager.default
        let progressDir = "\(home)/.local/state/unit-progress"
        for name in (try? fm.contentsOfDirectory(atPath: progressDir)) ?? [] where name.hasSuffix(".json") {
            guard let object = json("\(progressDir)/\(name)") as? [String: Any],
                  let items = object["items"] as? [Any], !items.isEmpty else { continue }
            let done = Set((object["done"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue }).filter { 1...items.count ~= $0 }
            let updated = (object["updated_at"] as? NSNumber)?.doubleValue ?? 0
            files.progress[String(name.dropLast(5))] = UnitProgressEntry(items: items.count, done: done.count, updatedAt: updated)
        }
        let tasksDir = "\(home)/.local/share/wooloo-companion/tasks"
        for name in (try? fm.contentsOfDirectory(atPath: tasksDir)) ?? [] where name.hasPrefix("ask-") && name.hasSuffix(".json") {
            if let object = json("\(tasksDir)/\(name)") as? [String: Any], let by = object["by"] as? String {
                files.askers.append(by)
            }
        }
        if let object = json("\(home)/.local/share/pokemon-agents/bg-shell.json") as? [String: Any] {
            for (pane, value) in object {
                if let pair = value as? [Any], pair.count == 2, let at = (pair[0] as? NSNumber)?.doubleValue,
                   (pair[1] as? NSNumber)?.boolValue == true {
                    files.backgroundPanes[pane] = at
                }
            }
        }
        return files
    }

    private static func json(_ path: String) -> Any? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }
}

/// Polls the unit's files every 2.5 s off the main thread and publishes only when something changed
/// (or when the minute changes, so stale pills appear on time).
@MainActor
final class UnitProgressMonitor: ObservableObject {
    static let shared = UnitProgressMonitor()

    @Published private(set) var files = UnitFiles()
    @Published private(set) var minute = 0
    private var task: Task<Void, Never>?
    private var lastSignature: [String] = []

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: .seconds(2.5))
            }
        }
    }

    private func poll() async {
        let previous = lastSignature
        let result: ([String], UnitFiles?) = await Task.detached(priority: .utility) {
            let signature = UnitFilesReader.signature()
            return (signature, signature == previous ? nil : UnitFilesReader.read())
        }.value
        lastSignature = result.0
        if let fresh = result.1, fresh != files { files = fresh }
        let now = Int(Date().timeIntervalSince1970 / 60)
        if now != minute { minute = now }
    }
}

/// Wraps its subviews onto further lines when they do not fit the width.
struct PillFlowLayout: Layout {
    var spacing: CGFloat = 3

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (index, origin) in result.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowHeight), origins)
    }
}

struct SpacePillsView: View {
    @Environment(\.woolooTypography) private var typography
    @Environment(\.woolooTheme) private var theme
    let summary: SpacePillSummary

    static let amber = Color(red: 1.0, green: 0.686, blue: 0.0)

    static let legend = """
        working N · P%: pawns working (background shells included) and their mean checklist progress
        done N: pawns that ticked every item and whose report you have not seen yet
        unfinished N: pawns idle with checklist items left and nothing running in the background
        waiting on you N: questions the unit has asked you
        stale N: pawns working with no checklist update for 10 minutes
        """

    var body: some View {
        PillFlowLayout {
            if summary.working > 0 { pill("working \(summary.working) · \(summary.workingPercent)%", theme.accent, "Pawns working, with their mean checklist progress") }
            if summary.done > 0 { pill("done \(summary.done)", theme.success, "Pawns that finished every item; you have not seen the report yet") }
            if summary.unfinished > 0 { pill("unfinished \(summary.unfinished)", Self.amber, "Pawns idle with checklist items left") }
            if summary.waiting > 0 { pill("waiting on you \(summary.waiting)", theme.warning, "Questions the unit is waiting for you to answer") }
            if summary.stale > 0 { pill("stale \(summary.stale)", theme.subtext, "Pawns working with no update for 10 minutes") }
        }
    }

    private func pill(_ text: String, _ color: Color, _ help: String) -> some View {
        Text(text)
            .font(.system(size: typography.caption, weight: .semibold))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .frame(height: 15)
            .background(color.opacity(0.16), in: Capsule())
            .help(help)
    }
}

/// The thin bar under a Space row while pawns are working.
struct SpaceProgressBar: View {
    @Environment(\.woolooTheme) private var theme
    let percent: Int

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.accent.opacity(0.18))
                Capsule().fill(theme.accent).frame(width: proxy.size.width * CGFloat(max(0, min(100, percent))) / 100)
            }
        }
        .frame(height: 2)
    }
}
