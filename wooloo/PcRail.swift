import SwiftUI

/// What the Windows PC publishes for the Mac's left rail (`pc-agents-export.py` writes it every 20 s):
/// Claude plan usage, token totals and the PC's CPU and memory. It carries no sign-in tokens.
struct PcRail: Equatable {
    var updated: Date
    var sessionPercent: Double?
    var sessionReset: Date?
    var weekPercent: Double?
    var weekReset: Date?
    var tokensToday: Double?
    var tokens5h: Double?
    var cpu: Double?
    var memoryUsedGB: Double?
    var memoryTotalGB: Double?

    /// Older than this and the PC has stopped exporting, so the rail shows nothing instead of stale numbers.
    static let staleAfter: TimeInterval = 120

    static func load() -> PcRail? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard let data = FileManager.default.contents(atPath: "\(home)/.local/share/unit-strip/pc-rail.json"),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stamp = object["updated"] as? Double else { return nil }
        let updated = Date(timeIntervalSince1970: stamp)
        guard Date().timeIntervalSince(updated) < staleAfter else { return nil }
        let session = object["session"] as? [String: Any]
        let week = object["week"] as? [String: Any]
        let host = object["host"] as? [String: Any]
        return PcRail(updated: updated,
                      sessionPercent: session?["pct"] as? Double,
                      sessionReset: parseDate(session?["reset"] as? String),
                      weekPercent: week?["pct"] as? Double,
                      weekReset: parseDate(week?["reset"] as? String),
                      tokensToday: object["tokensToday"] as? Double,
                      tokens5h: object["tokens5h"] as? Double,
                      cpu: host?["cpu"] as? Double,
                      memoryUsedGB: host?["memUsedGB"] as? Double,
                      memoryTotalGB: host?["memTotalGB"] as? Double)
    }

    private static func parseDate(_ text: String?) -> Date? {
        guard let text else { return nil }
        return ISO8601DateFormatter().date(from: text)
    }

    static func tokensText(_ value: Double?) -> String {
        guard let value else { return "…" }
        if value >= 1_000_000 { return String(format: "%.1fM", value / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fk", value / 1_000) }
        return String(Int(value))
    }
}

/// Reads the PC's published numbers and refreshes them every ten seconds.
@MainActor
final class PcRailModel: ObservableObject {
    @Published var rail: PcRail?
    private var task: Task<Void, Never>?

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                let loaded = await Task.detached(priority: .utility) { PcRail.load() }.value
                self?.rail = loaded
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

/// The PC rail's CLAUDE section: session and week usage bars, then the token totals.
struct PcClaudeSection: View {
    @Environment(\.woolooTypography) private var typography
    @Environment(\.woolooTheme) private var theme
    @AppStorage("PcClaudeCollapsed") private var collapsed = false
    @StateObject private var model = PcRailModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SidebarSectionToggle(title: "CLAUDE", systemImage: "chart.bar.xaxis",
                                 help: "Claude Usage", collapsed: $collapsed)
            content
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    @ViewBuilder private var content: some View {
        if let rail = model.rail {
            if collapsed {
                Text(summary(rail))
                    .font(theme.chromeFont(typography.secondary))
                    .foregroundStyle(theme.muted)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
            } else {
                expanded(rail)
            }
        } else {
            Text("Waiting for the PC")
                .font(theme.chromeFont(typography.secondary))
                .foregroundStyle(theme.muted)
                .padding(.horizontal, 8)
        }
    }

    private func expanded(_ rail: PcRail) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            usageMeter("Session", percent: rail.sessionPercent, reset: rail.sessionReset)
            usageMeter("Week", percent: rail.weekPercent, reset: rail.weekReset)
            Text("Tokens today  \(PcRail.tokensText(rail.tokensToday))")
                .font(theme.chromeFont(typography.secondary))
                .foregroundStyle(theme.muted)
            Text("Tokens (5h)  \(PcRail.tokensText(rail.tokens5h))")
                .font(theme.chromeFont(typography.secondary))
                .foregroundStyle(theme.muted)
        }
        .padding(.horizontal, 8)
    }

    private func usageMeter(_ label: String, percent: Double?, reset: Date?) -> some View {
        let used: Double = (percent ?? 0) / 100
        var value: String = percent.map { "\(Int($0.rounded()))% used" } ?? "…"
        if let reset, reset > Date() {
            value += " · " + HostStats.uptimeText(reset.timeIntervalSince(Date()))
        }
        return SidebarMeter(label: label, fraction: used, value: value, labelWidth: 52)
    }

    private func summary(_ rail: PcRail) -> String {
        let session: String = rail.sessionPercent.map { "\(Int($0.rounded()))%" } ?? "…"
        let week: String = rail.weekPercent.map { "\(Int($0.rounded()))%" } ?? "…"
        return "Session \(session) · Week \(week)"
    }
}

/// The PC rail's HOST section: the PC's CPU and memory, as the Windows rail shows them.
struct PcHostSection: View {
    @Environment(\.woolooTypography) private var typography
    @Environment(\.woolooTheme) private var theme
    @AppStorage("PcHostCollapsed") private var collapsed = false
    @StateObject private var model = PcRailModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SidebarSectionToggle(title: "HOST", systemImage: "cpu", help: "Host Load", collapsed: $collapsed)
            if !collapsed {
                Text(line)
                    .font(theme.chromeFont(typography.secondary))
                    .foregroundStyle(theme.muted)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
            }
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    private var line: String {
        guard let rail = model.rail else { return "Waiting for the PC" }
        let cpu: String = rail.cpu.map { "\(Int($0.rounded()))%" } ?? "…"
        guard let used = rail.memoryUsedGB, let total = rail.memoryTotalGB else { return "CPU \(cpu)" }
        return "CPU \(cpu) · RAM \(Int(used.rounded()))/\(Int(total.rounded()))G"
    }
}

/// Splits a roster name such as "second-commander-wooloo-port-and" into the card's title and role label.
struct AgentCardRole {
    let title: String
    let label: String

    init(_ name: String) {
        let lower = name.lowercased()
        if lower.hasPrefix("second-commander") {
            title = "second-commander"
            label = "Second commander"
        } else if lower.hasPrefix("commander") {
            title = "commander"
            label = "Commander"
        } else {
            title = name
            label = "Agent"
        }
    }
}

/// The Pokemon the PC assigned to each agent (`pc-sprites.json`, role name to dex number) and its art, which
/// stays in ~/.local/share/pokemon-agents on this Mac and is never part of the app. Missing files draw nothing.
enum AgentSprites {
    private static let cache = NSCache<NSNumber, NSImage>()

    static func load() -> [String: Int] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard let data = FileManager.default.contents(atPath: "\(home)/.local/share/unit-strip/pc-sprites.json"),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var found: [String: Int] = [:]
        for (key, value) in object {
            if let number = value as? Int { found[key.lowercased()] = number }
        }
        return found
    }

    /// The first frame of `<dex>.gif`, or nil when the file is not there.
    static func image(dex: Int) -> NSImage? {
        if let cached = cache.object(forKey: NSNumber(value: dex)) { return cached }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let folder = "\(home)/.local/share/pokemon-agents"
        var loaded: NSImage?
        for name in ["bw-\(dex).gif", "\(dex).gif", "\(dex).png"] where loaded == nil {
            loaded = NSImage(contentsOfFile: "\(folder)/\(name)")
        }
        guard let image = loaded else { return nil }
        cache.setObject(image, forKey: NSNumber(value: dex))
        return image
    }
}

/// A square sprite for an agent card; nothing is drawn (and no space is kept) without a sprite and its art file.
struct AgentSpriteView: View {
    let agentName: String
    let size: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
            }
        }
        .task {
            while !Task.isCancelled {
                let name = agentName.lowercased()
                let loaded = await Task.detached(priority: .utility) { () -> NSImage? in
                    guard let dex = AgentSprites.load()[name] else { return nil }
                    return AgentSprites.image(dex: dex)
                }.value
                if image !== loaded { image = loaded }
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
        }
    }
}
