import Foundation
import Combine
import SwiftUI

// Peer metadata sync for the Mac app (docs/sync-protocol.md). The wire exchange lives in
// PeerSyncExchange.swift; this file owns the replica on disk, the ssh transport, the per-peer service
// loop (timer, on-change, backoff) and the status shown on the Connections row.

/// Blocking pipe ends used for both the ssh child process and the in-process test peer.
/// Plain-text step log for diagnosing stuck exchanges: ~/Library/Logs/wooloo-peer-sync.log (no message contents).
enum PeerSyncLog {
    private static let lock = NSLock()
    static func write(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/wooloo-peer-sync.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(text)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            if (try? h.seekToEnd()) != nil { try? h.write(contentsOf: Data(line.utf8)) }
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}

final class PeerSyncPipeInput: PeerSyncInput {
    private let handle: FileHandle
    init(_ handle: FileHandle) { self.handle = handle }
    func readChunk(max: Int) throws -> Data {
        // read(upToCount:) on a pipe waits for `max` bytes or end of stream, which deadlocks a ping-pong exchange
        // (the peer's short hello is never delivered). POSIX read returns what has arrived.
        var buf = [UInt8](repeating: 0, count: max)
        while true {
            let n = buf.withUnsafeMutableBytes { Darwin.read(handle.fileDescriptor, $0.baseAddress, max) }
            if n > 0 { PeerSyncLog.write("read \(n) bytes"); return Data(buf[0..<n]) }
            if n == 0 { PeerSyncLog.write("read EOF"); return Data() }
            if errno == EINTR { continue }
            throw PeerSyncError.io("read failed: errno \(errno)")
        }
    }
}

final class PeerSyncPipeOutput: PeerSyncOutput {
    private let handle: FileHandle
    init(_ handle: FileHandle) { self.handle = handle }
    func write(_ data: Data) throws {
        do { try handle.write(contentsOf: data) } catch { throw PeerSyncError.io("\(error)") }
    }
    func flush() throws {}
}

/// What one exchange changed.
struct PeerSyncExchangeResult: Equatable {
    var peerNode: String
    var received: Int
    var accepted: UInt64
    var rejected: UInt64
}

/// The local replica plus the exchange driver. All methods block, so call them off the main thread.
final class PeerSyncEngine: @unchecked Sendable {
    let store: PeerSyncStore
    let unitCatsURL: URL?
    private let clock: @Sendable () -> UInt64

    init(store: PeerSyncStore, unitCatsURL: URL? = PeerSyncUnitCats.defaultPath(),
         clock: @escaping @Sendable () -> UInt64 = { UInt64(Date().timeIntervalSince1970 * 1000) }) {
        self.store = store
        self.unitCatsURL = unitCatsURL
        self.clock = clock
    }

    static func defaultStore() -> PeerSyncStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return PeerSyncStore(path: base.appendingPathComponent("wooloo/sync/state.json"))
    }

    /// Our own node id, creating the state file on first use.
    func node() throws -> String { try store.withState { $0.node } }

    /// Records edits made outside the replica (the unit categories file) as ops. Returns the registers to send.
    func prepare() throws -> [PeerSyncRegister] {
        try store.withState { state in
            if let url = unitCatsURL { _ = try PeerSyncUnitCats.importFile(url, into: &state, now: clock()) }
            return state.replica.sortedRegs()
        }
    }

    /// Applies what the peer sent back, then refreshes the unit categories file from the merged replica.
    func finish(_ initiated: PeerSyncInitiated) throws -> PeerSyncExchangeResult {
        try store.withState { state in
            let now = clock()
            for op in initiated.reply { _ = state.replica.apply(op, now: now) }
            if let url = unitCatsURL { _ = try PeerSyncUnitCats.exportFile(url, from: &state) }
            return PeerSyncExchangeResult(peerNode: initiated.peer, received: initiated.reply.count,
                                   accepted: initiated.accepted, rejected: initiated.rejected)
        }
    }

    /// One full exchange as the initiator over the given channel. The store lock is not held while the network is.
    func exchange(input: PeerSyncInput, output: PeerSyncOutput) throws -> PeerSyncExchangeResult {
        let regs = try prepare()
        let me = try node()
        let initiated = try PeerSyncExchange.initiate(input: input, output: output, node: me, regs: regs)
        return try finish(initiated)
    }

    /// Responder side, for the fake peer in tests (the real responder is the forced command on the other machine).
    func respond(input: PeerSyncInput, output: PeerSyncOutput) throws {
        let me = try node()
        try PeerSyncExchange.respond(input: input, output: output, node: me) { [self] _, ops, malformed in
            try store.withState { state in
                let absorbed = state.replica.absorb(ops, malformed: malformed, now: clock())
                if let url = unitCatsURL { _ = try PeerSyncUnitCats.exportFile(url, from: &state) }
                return absorbed
            }
        }
    }

    /// Publishes local Space names and categories: binds this machine's workspaces to Space uuids and writes the
    /// fields that differ. `categories` is keyed by lowercased label and holds the user's manual choices.
    @discardableResult
    func publishLocal(workspaces: [(id: String, label: String)], categories: [String: String]) throws -> Int {
        try store.withState { state in
            let now = clock()
            let plan = try state.replica.bindHost(workspaces, now: now)
            var changed = plan.bindings.filter { $0.kind != .bound }.count
            for b in plan.bindings {
                guard let uuid = b.space else { continue }
                let view = state.replica.spaceView(uuid)
                if view.name != b.label { try state.replica.setSpaceName(uuid, b.label, now: now); changed += 1 }
                if let wanted = categories[b.label.lowercased()], view.category != wanted,
                   PeerSyncValidate.isText(wanted, 1, 64) {
                    try state.replica.setSpaceCategory(uuid, wanted, now: now); changed += 1
                }
            }
            return changed
        }
    }

    /// Registers written here that no exchange has delivered yet.
    func pendingCount(since delivered: PeerSyncHlc?) -> Int {
        guard let state = try? store.load() else { return 0 }
        return state.replica.sortedRegs().filter { r in
            r.node == state.node && (delivered.map { $0 < r.hlc } ?? true)
        }.count
    }

    func snapshot() -> PeerSyncReplica? { try? store.load().replica }

    func latestLocalClock() -> PeerSyncHlc? {
        guard let state = try? store.load() else { return nil }
        return state.replica.sortedRegs().filter { $0.node == state.node }.map(\.hlc).max()
    }
}

enum PeerSyncStatus: Equatable {
    case idle
    case syncing
    case synced(Date)
    case offline(pending: Int, reason: String)

    func label(now: Date = Date()) -> String {
        switch self {
        case .idle: return "Sync waiting"
        case .syncing: return "Syncing"
        case .synced(let at):
            let s = max(0, Int(now.timeIntervalSince(at)))
            return s < 60 ? "synced \(s) s ago" : "synced \(s / 60) min ago"
        case .offline(let pending, _): return "offline, \(pending) pending"
        }
    }
}

/// Keeps one peer's metadata in step with this machine: on a timer, on request, with backoff, off the main thread.
@MainActor
final class PeerSyncService: ObservableObject, PeerSpaceMetadataProviding {
    typealias Transport = @Sendable (HerdrMachineProfile, PeerSyncEngine) throws -> PeerSyncExchangeResult

    @Published private(set) var status: PeerSyncStatus = .idle
    @Published private(set) var revision = 0
    @Published var skew: HerdrVersionSkew?

    let machine: HerdrMachineProfile
    private let engine: PeerSyncEngine
    private let transport: Transport
    private let interval: TimeInterval
    private let sleep: @Sendable (TimeInterval) async -> Void
    private var backoff = PeerBackoff()
    private var task: Task<Void, Never>?
    private var wake: CheckedContinuation<Void, Never>?
    private var delivered: PeerSyncHlc?
    private(set) var peerNode: String?
    private var replica: PeerSyncReplica?
    private var localStore: HerdrStore?
    private var cancellable: AnyCancellable?
    /// Per local workspace id: the label both sides last agreed on, to tell a local rename from a remote one.
    private var known: [String: String] = [:]

    init(machine: HerdrMachineProfile, engine: PeerSyncEngine = PeerSyncEngine(store: PeerSyncEngine.defaultStore()),
         interval: TimeInterval = 60,
         transport: @escaping Transport = PeerSyncService.sshTransport,
         sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }) {
        self.machine = machine
        self.engine = engine
        self.transport = transport
        self.interval = interval
        self.sleep = sleep
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let delay = await self.syncNow()
                await self.waitForWakeOrTimer(delay)
            }
        }
    }

    func stop() { task?.cancel(); task = nil; wake?.resume(); wake = nil }

    /// Call after a local edit so it goes out without waiting for the timer.
    func requestSync() { wake?.resume(); wake = nil }

    private func waitForWakeOrTimer(_ delay: TimeInterval) async {
        await withTaskGroup(of: Void.self) { group in
            // The wake child parks on a continuation, which cancellation cannot end: the timer must resume it, or the
            // group never finishes and the loop stalls after the first exchange.
            group.addTask { @MainActor [weak self, sleep] in
                await sleep(delay)
                self?.wake?.resume(); self?.wake = nil
            }
            group.addTask { @MainActor [weak self] in
                await withCheckedContinuation { c in self?.wake = c }
            }
            await group.next()
            group.cancelAll()
        }
        wake?.resume(); wake = nil
    }

    /// One exchange; returns how long to wait before the next.
    @discardableResult
    func syncNow() async -> TimeInterval {
        status = .syncing
        PeerSyncLog.write("syncNow begin")
        let machine = machine, engine = engine, transport = transport
        do {
            let outcome = try await BlockingWork.run(priority: .utility) { PeerSyncLog.write("transport start"); return try transport(machine, engine) }
            PeerSyncLog.write("syncNow ok received=\(outcome.received)")
            peerNode = outcome.peerNode
            delivered = engine.latestLocalClock()
            replica = engine.snapshot()
            reconcile()
            status = .synced(Date())
            if outcome.received > 0 { revision += 1 }
            backoff.reset()
            return interval
        } catch {
            let pending = engine.pendingCount(since: delivered)
            PeerSyncLog.write("syncNow failed: \(error)")
            status = .offline(pending: pending, reason: "\(error)")
            let delay = backoff.delay
            backoff.failed()
            return delay
        }
    }

    // MARK: Local Herdr workspaces

    /// Follows this Mac's own Herdr workspace list: local renames are published, synced names are applied
    /// through Herdr's own workspace.rename. Categories travel through the unit state file instead.
    func observe(_ store: HerdrStore) {
        guard localStore !== store else { return }
        localStore = store
        cancellable = store.snapshotPublisher.sink { [weak self] _ in
            Task { @MainActor in self?.reconcile() }
        }
    }

    private func syncedName(_ id: String, node: String) -> String? {
        guard let replica, let uuid = replica.lookup(host: node, herdrId: id) else { return nil }
        return replica.spaceView(uuid).name
    }

    /// Pure diff: a label that moved locally is published; a replica name that differs while the local label is
    /// unchanged is a remote edit and gets applied. `known` stops either side echoing back.
    nonisolated static func labelPlan(current: [String: String], known: [String: String], remote: [String: String])
        -> (renames: [String: String], published: [String], known: [String: String]) {
        var renames: [String: String] = [:], published: [String] = [], next: [String: String] = [:]
        for (id, label) in current {
            if let was = known[id] {
                if label != was { published.append(id); next[id] = label }
                else if let r = remote[id], r != label { renames[id] = r; next[id] = r }
                else { next[id] = label }
            } else if let r = remote[id], r != label { renames[id] = r; next[id] = r }
            else { next[id] = label; published.append(id) }
        }
        return (renames, published, next)
    }

    func reconcile() {
        guard let store = localStore, let snap = store.snapshot, let node = try? engine.node() else { return }
        let labels = snap.workspaces.map { ($0.workspaceID, $0.label) }
        var remote: [String: String] = [:]
        for (id, _) in labels { if let n = syncedName(id, node: node) { remote[id] = n } }
        let plan = Self.labelPlan(current: Dictionary(labels, uniquingKeysWith: { a, _ in a }), known: known, remote: remote)
        known = plan.known
        for (id, name) in plan.renames { store.renameWorkspace(id, to: name) }
        let edited = plan.published
        guard !edited.isEmpty else { return }
        let engine = engine
        let all = snap.workspaces.map { ($0.workspaceID, $0.label) }
        Task {
            _ = try? await BlockingWork.run(priority: .utility) {
                try engine.publishLocal(workspaces: all.map { (id: $0.0, label: $0.1) }, categories: [:])
            }
            self.replica = engine.snapshot()
            self.requestSync()
        }
    }

    // MARK: PeerSpaceMetadataProviding

    func metadata(peerID: String, workspaceID: String) -> PeerSpaceMetadata? {
        guard peerID == machine.id, let host = peerNode, let replica,
              let uuid = replica.lookup(host: host, herdrId: workspaceID) else { return nil }
        let view = replica.spaceView(uuid)
        return PeerSpaceMetadata(name: view.name, category: view.category, color: view.color)
    }

    // MARK: ssh transport

    nonisolated static func syncArguments(_ machine: HerdrMachineProfile) -> [String] {
        var args = PeerMachine.helloArguments(machine)
        args.removeLast()
        return args + ["wooloo-peer sync"]
    }

    /// Runs `wooloo-peer sync` over ssh and drives the exchange on the process pipes. A watchdog ends a stuck link.
    nonisolated static func sshTransport(_ machine: HerdrMachineProfile, _ engine: PeerSyncEngine) throws -> PeerSyncExchangeResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: WorkspaceFiles.sshExecutable)
        process.arguments = syncArguments(machine)
        let toChild = Pipe(), fromChild = Pipe()
        process.standardInput = toChild
        process.standardOutput = fromChild
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw PeerSyncError.io("ssh failed to start: \(error)") }
        PeerSyncLog.write("ssh pid \(process.processIdentifier)")
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 90, execute: watchdog)
        defer {
            watchdog.cancel()
            try? toChild.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        return try engine.exchange(input: PeerSyncPipeInput(fromChild.fileHandleForReading),
                                   output: PeerSyncPipeOutput(toChild.fileHandleForWriting))
    }
}

/// Status line under a peer row.
struct PeerSyncBadge: View {
    @ObservedObject var service: PeerSyncService

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            VStack(alignment: .leading, spacing: 2) {
                Text("Sync: " + service.status.label(now: context.date)).font(.caption).foregroundStyle(.secondary)
                if let skew = service.skew {
                    Text(skew.message).font(.caption)
                        .foregroundStyle(skew.severity == .error ? Color.red : Color.orange)
                }
            }
        }
    }
}

/// Owns one sync service per peer row, started when the row appears and stopped when it goes.
struct PeerSyncRow: View {
    let machine: HerdrMachineProfile
    var localStore: HerdrStore?
    @StateObject private var holder = PeerSyncHolder()

    var body: some View {
        PeerSyncBadge(service: holder.service(for: machine))
            .onAppear {
                let service = holder.service(for: machine)
                if let localStore { service.observe(localStore) }
                service.start()
            }
            .onDisappear { holder.current?.stop() }
    }
}

@MainActor
final class PeerSyncHolder: ObservableObject {
    private(set) var current: PeerSyncService?

    func service(for machine: HerdrMachineProfile) -> PeerSyncService {
        if let current, current.machine == machine { return current }
        current?.stop()
        let made = PeerSyncService(machine: machine)
        current = made
        return made
    }
}
