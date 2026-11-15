import Combine
import Foundation
import SwiftUI

/// A paired computer (docs/peer-pairing.md) is a saved Herdr machine whose SSH target is the
/// `wooloo-peer-<id>` alias. Its Spaces are listed and opened by the same store as any remote
/// machine; this file adds what is specific to a peer: the restricted-command bridge, a
/// connection state with backoff, the Herdr version-skew banner and hooks for sync and presence.
enum PeerMachine {
    static let aliasPrefix = "wooloo-peer-"

    static func isPeer(_ machine: HerdrMachineProfile) -> Bool {
        WorkspaceFiles.SSHEndpoint(machine.target).destination.hasPrefix(aliasPrefix)
    }

    /// A peer's key may only run the dispatcher's allow-listed argv (docs/peer-allowlist.json).
    static func bridgeCommand(_ command: String, session: String) -> String? {
        switch command {
        case "remote-api-bridge": return "wooloo-peer api \(session)"
        case "remote-client-bridge": return "wooloo-peer client \(session)"
        default: return nil
        }
    }

    /// Profiles synthesized from `~/.ssh/wooloo_peers/<id>.conf`, read-only: Herdr's own machine
    /// catalog cannot hold a peer, since Herdr always multiplexes and the bridge refuses that.
    /// Confs written before pairing recorded a label or session fall back to the id and `default`.
    static func profiles(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [HerdrMachineProfile] {
        let directory = PeerPairing.peersDirectory(home: home)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".conf") }.sorted().compactMap { name in
            let id = String(name.dropLast(".conf".count))
            guard PeerPairing.matches(id, #"^[a-z0-9-]{1,32}$"#),
                  let text = try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8) else { return nil }
            return profile(id: id, conf: text)
        }
    }

    static func profile(id: String, conf: String) -> HerdrMachineProfile {
        func comment(_ key: String) -> String? {
            conf.split(whereSeparator: \.isNewline).lazy
                .compactMap { line -> String? in
                    let prefix = "# wooloo-\(key) "
                    return line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) : nil
                }.first
        }
        let session = comment("session").flatMap { PeerPairing.isValidSession($0) ? $0 : nil } ?? "default"
        let label = comment("label").flatMap { $0.isEmpty ? nil : $0 } ?? id
        let alias = aliasPrefix + id
        return HerdrMachineProfile(id: alias, label: label, target: alias, session: session, enabled: true)
    }

    static let helloCommand = "wooloo-peer hello"

    /// `wooloo-peer hello` answers `wooloo-peer-bridge-v1 <herdr version>`.
    static func parseHello(_ output: String) -> String? {
        let parts = output.split(whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count == 2, parts[0] == "wooloo-peer-bridge-v1",
              PeerPairing.matches(parts[1], #"^[0-9A-Za-z.+-]{1,32}$"#) else { return nil }
        return parts[1]
    }

    static func helloArguments(_ machine: HerdrMachineProfile) -> [String] {
        let endpoint = WorkspaceFiles.SSHEndpoint(machine.target)
        var args = ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
                    "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=2"]
        if let port = endpoint.port { args += ["-p", port] }
        return args + [endpoint.destination, helloCommand]
    }
}

/// Mirrors wooloo-win/src/version-skew.ts: warn on a patch difference, error on minor or major.
struct HerdrVersionSkew: Equatable {
    enum Severity: Equatable { case warn, error }
    let severity: Severity
    let message: String

    static func parse(_ version: String) -> [Int]? {
        let pattern = #"^\s*v?(\d+)\.(\d+)\.(\d+)(?:[-+][0-9A-Za-z.-]+)?\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(version.startIndex..., in: version)
        guard let match = regex.firstMatch(in: version, range: range), match.numberOfRanges == 4 else { return nil }
        let numbers = (1...3).compactMap { Range(match.range(at: $0), in: version).flatMap { Int(version[$0]) } }
        return numbers.count == 3 ? numbers : nil
    }

    /// No banner unless both versions are known and differ.
    static func banner(local: String?, peer: String?) -> HerdrVersionSkew? {
        guard let local, let peer, !local.isEmpty, !peer.isEmpty, local != peer else { return nil }
        guard let l = parse(local), let r = parse(peer) else {
            return HerdrVersionSkew(severity: .warn,
                                    message: "Could not parse Herdr versions (this Mac \(local), peer \(peer)).")
        }
        if l[0] != r[0] || l[1] != r[1] {
            return HerdrVersionSkew(severity: .error,
                                    message: "Herdr version mismatch: this Mac \(local), peer \(peer). Update one side so major.minor match.")
        }
        if l[2] != r[2] {
            return HerdrVersionSkew(severity: .warn,
                                    message: "Herdr patch versions differ: this Mac \(local), peer \(peer).")
        }
        return nil
    }
}

enum PeerLinkState: Equatable {
    case connecting
    case connected
    case failed(String)

    var label: String {
        switch self {
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        case .failed(let reason): return "Failed: \(reason)"
        }
    }
}

/// 1, 2, 4 … capped at 30 seconds.
struct PeerBackoff: Equatable {
    private(set) var attempt = 0
    var delay: TimeInterval { min(30, pow(2, Double(min(attempt, 10)))) }
    mutating func failed() { attempt += 1 }
    mutating func reset() { attempt = 0 }
}

/// Future hook for names, categories and colours replicated by wooloo-sync; nothing implements it yet.
protocol PeerSpaceMetadataProviding {
    func metadata(peerID: String, workspaceID: String) -> PeerSpaceMetadata?
}

struct PeerSpaceMetadata: Equatable {
    var name: String?
    var category: String?
    var color: String?
}

/// Watches one peer with `wooloo-peer hello`. Probing runs off the main actor and never blocks the UI;
/// a failure schedules the next attempt with backoff, and success re-checks at a slow cadence.
@MainActor
final class PeerLinkMonitor: ObservableObject {
    typealias Probe = @Sendable (HerdrMachineProfile) async throws -> String

    @Published private(set) var state: PeerLinkState = .connecting
    @Published private(set) var peerVersion: String?
    @Published private(set) var skew: HerdrVersionSkew?

    let machine: HerdrMachineProfile
    private let probe: Probe
    private let localVersion: @Sendable () async -> String?
    private let sleep: @Sendable (TimeInterval) async -> Void
    private let healthyInterval: TimeInterval
    private var backoff = PeerBackoff()
    private var task: Task<Void, Never>?

    init(machine: HerdrMachineProfile,
         healthyInterval: TimeInterval = 30,
         probe: @escaping Probe = PeerLinkMonitor.sshProbe,
         localVersion: @escaping @Sendable () async -> String? = { nil },
         sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }) {
        self.machine = machine
        self.probe = probe
        self.localVersion = localVersion
        self.sleep = sleep
        self.healthyInterval = healthyInterval
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let delay = await self.check()
                await self.sleep(delay)
            }
        }
    }

    func stop() { task?.cancel(); task = nil }

    /// One probe; returns how long to wait before the next.
    func check() async -> TimeInterval {
        if state != .connected { state = .connecting }
        do {
            let output = try await probe(machine)
            guard let version = PeerMachine.parseHello(output) else {
                throw WorkspaceFileError.message("Unexpected reply from peer")
            }
            peerVersion = version
            skew = HerdrVersionSkew.banner(local: await localVersion(), peer: version)
            state = .connected
            backoff.reset()
            return healthyInterval
        } catch {
            state = .failed(error.localizedDescription)
            let delay = backoff.delay
            backoff.failed()
            return delay
        }
    }

    nonisolated static func sshProbe(_ machine: HerdrMachineProfile) async throws -> String {
        let arguments = PeerMachine.helloArguments(machine)
        return try await BlockingWork.run(priority: .utility) {
            let data = try WorkspaceFiles.run(WorkspaceFiles.sshExecutable, arguments, limit: 4096, label: "peer hello")
            return String(decoding: data, as: UTF8.self)
        }
    }
}

/// Dot plus reason, and the skew banner, for a peer row.
struct PeerLinkBadge: View {
    @ObservedObject var monitor: PeerLinkMonitor

    private var color: Color {
        switch monitor.state {
        case .connected: return .green
        case .connecting: return .yellow
        case .failed: return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(monitor.state.label).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            if let skew = monitor.skew {
                Text(skew.message).font(.caption)
                    .foregroundStyle(skew.severity == .error ? Color.red : Color.orange)
            }
        }
    }
}

/// Owns one monitor per peer row, started when the row appears and stopped when it goes.
struct PeerLinkRow: View {
    let machine: HerdrMachineProfile
    @StateObject private var holder = PeerLinkHolder()

    var body: some View {
        PeerLinkBadge(monitor: holder.monitor(for: machine))
            .onAppear { holder.monitor(for: machine).start() }
            .onDisappear { holder.current?.stop() }
    }
}

@MainActor
final class PeerLinkHolder: ObservableObject {
    private(set) var current: PeerLinkMonitor?

    func monitor(for machine: HerdrMachineProfile) -> PeerLinkMonitor {
        if let current, current.machine == machine { return current }
        current?.stop()
        let made = PeerLinkMonitor(machine: machine, localVersion: {
            await Self.localHerdrVersion()
        })
        current = made
        return made
    }

    nonisolated static func localHerdrVersion() async -> String? {
        guard let herdr = RemoteAccessSystem.herdrExecutable else { return nil }
        return try? await BlockingWork.run(priority: .utility) {
            try PeerPairing.herdrVersion(executable: herdr)
        }
    }
}
