import SwiftUI

/// One row of the tasks file a unit agent writes when it is handed work.
struct ActiveTaskLabel: Equatable {
    let label: String
    let started: Double?
}

/// The Windows strip's ACTIVE TASKS: every agent that is working or waiting on you, with the label
/// of the task it was handed (from ~/.local/share/wooloo-companion/tasks/agent-*.json) and for how long.
struct ActiveTasksSection: View {
    let agents: [HerdrAgent]
    @Environment(\.woolooTypography) private var typography
    @Environment(\.woolooTheme) private var theme
    @AppStorage("ActiveTasksCollapsed") private var collapsed = false
    @State private var labels: [String: ActiveTaskLabel] = [:]
    @State private var now = Date()

    private var busy: [HerdrAgent] {
        agents.filter { $0.agentStatus == "working" || $0.agentStatus == "blocked" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            SidebarSectionToggle(title: "ACTIVE TASKS · \(busy.count)", systemImage: "checklist",
                                 help: "Active Tasks", collapsed: $collapsed)
            if collapsed {
                Text(summaryText)
                    .font(theme.chromeFont(typography.secondary))
                    .foregroundStyle(theme.muted)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
            } else if busy.isEmpty {
                Text("Nothing running")
                    .font(theme.chromeFont(typography.body))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
            } else {
                ForEach(busy) { agent in row(agent) }
            }
        }
        .task {
            while !Task.isCancelled {
                labels = await ActiveTasksSection.loadLabels()
                now = Date()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    private var summaryText: String {
        busy.isEmpty ? "idle" : "\(busy.count) running · " + (busy.first.map { taskText($0) } ?? "")
    }

    /// The task file is keyed by the Herdr agent's name, which may sit in `name`, `agent` or the display name.
    private func entry(_ agent: HerdrAgent) -> ActiveTaskLabel? {
        let keys: [String?] = [agent.name, agent.agent, agent.displayName]
        for key in keys {
            if let key, let found = labels[key.lowercased()] { return found }
        }
        return nil
    }

    private func taskText(_ agent: HerdrAgent) -> String {
        entry(agent)?.label ?? agent.displayName
    }

    private func elapsed(_ agent: HerdrAgent) -> String? {
        guard let started = entry(agent)?.started else { return nil }
        let seconds = Int(now.timeIntervalSince1970 - started)
        guard seconds >= 0, seconds < 86_400 else { return nil }
        if seconds >= 3_600 { return "\(seconds / 3_600)h \(seconds % 3_600 / 60)m" }
        if seconds >= 60 { return "\(seconds / 60)m" }
        return "\(seconds)s"
    }

    private func row(_ agent: HerdrAgent) -> some View {
        HStack(spacing: 7) {
            AgentStatusDot(status: agent.agentStatus)
            Text(taskText(agent))
                .font(theme.chromeFont(typography.body))
                .foregroundStyle(theme.text)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let time = elapsed(agent) {
                Text(time)
                    .font(theme.chromeFont(typography.secondary))
                    .foregroundStyle(theme.muted)
            }
        }
        .padding(.horizontal, 8)
        .frame(minHeight: typography.metric(22))
    }

    /// The task files keyed by lower-cased agent name.
    private static func loadLabels() async -> [String: ActiveTaskLabel] {
        await Task.detached(priority: .utility) { () -> [String: ActiveTaskLabel] in
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let dir = "\(home)/.local/share/wooloo-companion/tasks"
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            var found: [String: ActiveTaskLabel] = [:]
            for name in names where name.hasPrefix("agent-") && name.hasSuffix(".json") {
                guard let data = FileManager.default.contents(atPath: "\(dir)/\(name)"),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let agent = object["agent"] as? String,
                      let label = object["label"] as? String else { continue }
                let started = object["started"] as? Double
                found[agent.lowercased()] = ActiveTaskLabel(label: label, started: started)
            }
            return found
        }.value
    }
}
