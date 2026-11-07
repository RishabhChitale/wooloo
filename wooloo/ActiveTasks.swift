import AppKit
import Darwin
import SwiftUI

// "ACTIVE TASKS" in the right sidebar: jobs that other tools register in a local folder, and the
// GitHub Actions runs of the Space's repository (and of the repositories listed in a local file)
// that are queued or in progress.

/// A job registered as `~/.local/share/wooloo-companion/tasks/<id>.json` by whatever started it.
struct TrackedTask: Decodable, Equatable, Sendable, Identifiable {
    let id: String
    let label: String
    let pid: Int32
    /// Unix seconds.
    let started: Double
    /// A Space's id; nil for a job that belongs to no Space and shows everywhere.
    let space: String?
    let cwd: String?
    let command: String?
}

/// A queued or running GitHub Actions run, as `gh run list --json …` reports it.
struct CIRun: Decodable, Equatable, Sendable {
    let databaseId: Int
    let workflowName: String?
    let displayTitle: String?
    let headBranch: String?
    let createdAt: String?
    let url: String?
}

struct ActiveTaskRow: Equatable, Identifiable, Sendable {
    enum Source: Equatable, Sendable { case tracked, ci }
    let id: String
    let label: String
    let started: Date?
    let source: Source
    /// Shown as the row's tooltip.
    let detail: String?
    let url: URL?
}

enum ActiveTasks {
    static let trackedInterval: Duration = .seconds(2)
    static let ciInterval: Duration = .seconds(45)
    static let maximumRows = 6

    static var tasksDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/wooloo-companion/tasks")
    }

    static var repositoriesFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/wooloo-companion/ci-repos.txt")
    }

    // MARK: Tracked jobs

    /// Probes a process with signal 0: it exists unless the answer is ESRCH. Replaceable for tests.
    typealias ProcessProbe = @Sendable (Int32) -> (result: Int32, error: Int32)
    static let systemProbe: ProcessProbe = { pid in
        let result = kill(pid, 0)
        return (result, result == 0 ? 0 : errno)
    }

    static func isAlive(pid: Int32, probe: ProcessProbe = systemProbe) -> Bool {
        guard pid > 0 else { return false }
        let answer = probe(pid)
        return !(answer.result != 0 && answer.error == ESRCH)
    }

    /// The registered jobs whose process still runs, oldest first. Unreadable files are skipped.
    static func loadTasks(in directory: URL = tasksDirectory, probe: ProcessProbe = systemProbe) -> [TrackedTask] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return [] }
        let tasks = files.filter { $0.pathExtension == "json" }.prefix(200).compactMap { url -> TrackedTask? in
            guard let data = try? Data(contentsOf: url), data.count <= 64 * 1024 else { return nil }
            return try? JSONDecoder().decode(TrackedTask.self, from: data)
        }
        return tasks.filter { isAlive(pid: $0.pid, probe: probe) }.sorted { $0.started < $1.started }
    }

    /// The jobs of the selected Space (and those without one), and how many belong to other Spaces.
    static func visible(_ tasks: [TrackedTask], selectedSpace: String?) -> (shown: [TrackedTask], others: Int) {
        let shown = tasks.filter { $0.space == nil || $0.space == selectedSpace }
        return (shown, tasks.count - shown.count)
    }

    // MARK: GitHub

    static func arguments(repository: String, status: String) -> [String] {
        ["run", "list", "-R", repository, "--status", status, "--limit", "20",
         "--json", "databaseId,workflowName,displayTitle,headBranch,createdAt,url"]
    }

    /// `owner/name` lines; blank lines, comments and anything else are ignored.
    static func repositories(inList text: String) -> [String] {
        var seen: Set<String> = []
        return text.components(separatedBy: .newlines).compactMap { line in
            let repository = line.trimmingCharacters(in: .whitespaces)
            guard repository.range(of: #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil,
                  seen.insert(repository.lowercased()).inserted else { return nil }
            return repository
        }
    }

    static func shortName(_ repository: String) -> String {
        repository.split(separator: "/").last.map(String.init) ?? repository
    }

    static func parseTime(_ value: String?) -> Date? {
        value.flatMap { ISO8601DateFormatter().date(from: $0) }
    }

    // MARK: Rows

    static func rows(tracked: [TrackedTask], ci: [(repository: String, run: CIRun)], selectedSpace: String?)
        -> (rows: [ActiveTaskRow], others: Int) {
        let (shown, others) = visible(tracked, selectedSpace: selectedSpace)
        var rows = shown.map { task in
            ActiveTaskRow(id: "task:" + task.id, label: task.label, started: Date(timeIntervalSince1970: task.started),
                          source: .tracked,
                          detail: [task.command, task.cwd.map { "in " + $0 }].compactMap { $0 }.joined(separator: "\n"),
                          url: nil)
        }
        var seen: Set<String> = []
        for (repository, run) in ci where seen.insert("\(repository)#\(run.databaseId)").inserted {
            rows.append(ActiveTaskRow(
                id: "ci:\(repository)#\(run.databaseId)",
                label: "\(run.workflowName ?? run.displayTitle ?? "Run") · \(shortName(repository))",
                started: parseTime(run.createdAt), source: .ci,
                detail: [run.displayTitle, run.headBranch.map { "branch " + $0 }].compactMap { $0 }.joined(separator: "\n"),
                url: run.url.flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }))
        }
        return (rows, others)
    }

    /// "42s", "12m", "1h 3m", "2d 4h".
    static func elapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        switch total {
        case ..<60: return "\(total)s"
        case ..<3600: return "\(total / 60)m"
        case ..<86_400:
            let minutes = (total % 3600) / 60
            return minutes == 0 ? "\(total / 3600)h" : "\(total / 3600)h \(minutes)m"
        default:
            let hours = (total % 86_400) / 3600
            return hours == 0 ? "\(total / 86_400)d" : "\(total / 86_400)d \(hours)h"
        }
    }
}

@MainActor
final class ActiveTasksModel: ObservableObject {
    @Published private(set) var tracked: [TrackedTask] = []
    @Published private(set) var ci: [(repository: String, run: CIRun)] = []
    private var repositoryByLocation: [String: String] = [:]

    /// Reads the registered jobs every 2 s, off the main thread, until the view goes away.
    func trackTasks() async {
        while !Task.isCancelled {
            let tasks = (try? await BlockingWork.run(priority: .utility) { ActiveTasks.loadTasks() }) ?? []
            if tasks != tracked { tracked = tasks }
            try? await Task.sleep(for: ActiveTasks.trackedInterval)
        }
    }

    /// Polls `gh` every 45 s for the Space's repository and the listed ones. Missing or signed-out
    /// gh, or a Space without a GitHub remote, just gives no rows.
    func trackRuns(at location: WorkspaceFileLocation?) async {
        while !Task.isCancelled {
            let known = location.flatMap { repositoryByLocation[$0.identity] }
            let result = await ActiveTasksModel.pollRuns(at: location, knownRepository: known)
            if let location, let repository = result.repository { repositoryByLocation[location.identity] = repository }
            if result.runs.map({ "\($0.repository)#\($0.run.databaseId)" }) != ci.map({ "\($0.repository)#\($0.run.databaseId)" }) {
                ci = result.runs
            }
            try? await Task.sleep(for: ActiveTasks.ciInterval)
        }
    }

    private static func pollRuns(at location: WorkspaceFileLocation?, knownRepository: String?) async
        -> (repository: String?, runs: [(repository: String, run: CIRun)]) {
        let host = location ?? WorkspaceFileLocation(machine: nil, session: "", workspaceID: "", workspaceLabel: "",
                                                     root: NSHomeDirectory())
        let known = knownRepository
        let isSpace = location != nil
        let outcome = try? await WorkspaceFiles.blocking(at: host, priority: .utility) { () -> PollOutcome in
            var repositories: [String] = []
            var spaceRepository = known
            if isSpace, spaceRepository == nil {
                spaceRepository = try? WorkspaceGitHub.repository(at: host).nameWithOwner
            }
            if let spaceRepository { repositories.append(spaceRepository) }
            if let text = try? String(contentsOf: ActiveTasks.repositoriesFile, encoding: .utf8) {
                for extra in ActiveTasks.repositories(inList: text) where !repositories.contains(where: {
                    $0.caseInsensitiveCompare(extra) == .orderedSame }) { repositories.append(extra) }
            }
            var runs: [PollOutcome.Run] = []
            for repository in repositories {
                for status in ["in_progress", "queued"] {
                    guard let data = try? WorkspaceFiles.shell(
                        WorkspaceGitHub.command(ActiveTasks.arguments(repository: repository, status: status)),
                        at: host, limit: 256_000),
                          let found = try? JSONDecoder().decode([CIRun].self, from: data) else { continue }
                    runs += found.map { PollOutcome.Run(repository: repository, run: $0) }
                }
            }
            return PollOutcome(repository: spaceRepository, runs: runs)
        }
        return (outcome?.repository, outcome?.runs.map { ($0.repository, $0.run) } ?? [])
    }

    private struct PollOutcome: Sendable {
        struct Run: Sendable { let repository: String; let run: CIRun }
        let repository: String?
        let runs: [Run]
    }
}

struct ActiveTasksSection: View {
    let selectedSpace: String?
    let location: WorkspaceFileLocation?
    @StateObject private var model = ActiveTasksModel()
    @Environment(\.openURL) private var openURL
    @Environment(\.woolooTypography) private var typography
    @Environment(\.woolooTheme) private var theme

    var body: some View {
        let result = ActiveTasks.rows(tracked: model.tracked, ci: model.ci, selectedSpace: selectedSpace)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text("ACTIVE TASKS")
                    .font(.system(size: typography.secondary, weight: .semibold))
                    .tracking(0.7)
                Image(systemName: "bolt.horizontal.circle")
                    .font(.system(size: typography.secondary))
                if !result.rows.isEmpty {
                    Text("\(result.rows.count)")
                        .font(.system(size: typography.caption, weight: .semibold))
                        .foregroundStyle(theme.accent)
                        .padding(.horizontal, 5)
                        .background(theme.accent.opacity(0.15), in: Capsule())
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            if result.rows.isEmpty {
                Text("Nothing running")
                    .font(.system(size: typography.body))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
            } else if result.rows.count > ActiveTasks.maximumRows {
                ScrollView { rowList(result.rows) }
                    .frame(height: CGFloat(ActiveTasks.maximumRows) * typography.metric(27))
            } else {
                rowList(result.rows)
            }
            if result.others > 0 {
                Text("other Spaces: \(result.others)")
                    .font(.system(size: typography.caption))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
            }
        }
        .padding(7)
        .task { await model.trackTasks() }
        .task(id: location?.identity) { await model.trackRuns(at: location) }
    }

    private func rowList(_ rows: [ActiveTaskRow]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { row in
                Button {
                    if let url = row.url { openURL(url) }
                } label: {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 14, height: 14)
                        Image(systemName: row.source == .tracked ? "terminal" : "arrow.triangle.branch")
                            .font(.system(size: typography.secondary))
                            .foregroundStyle(.secondary)
                        Text(row.label).lineLimit(1)
                        Spacer(minLength: 0)
                        if let started = row.started {
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                Text(ActiveTasks.elapsed(context.date.timeIntervalSince(started)))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .font(.system(size: typography.emphasis, weight: .medium))
                    .sidebarRow(selected: false)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(row.detail.flatMap { $0.isEmpty ? nil : $0 } ?? row.label)
            }
        }
    }
}
