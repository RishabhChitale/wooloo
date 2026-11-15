import XCTest
@testable import wooloo

/// Two engines, each with its own store, talking over in-process pipes: A initiates, B runs the ported responder.
final class PeerSyncServiceTests: XCTestCase {
    private var dirs: [URL] = []

    override func tearDown() {
        dirs.forEach { try? FileManager.default.removeItem(at: $0) }
        dirs = []
        super.tearDown()
    }

    private func engine(_ node: String) throws -> PeerSyncEngine {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wooloo-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dirs.append(dir)
        let store = PeerSyncStore(path: dir.appendingPathComponent("state.json"))
        try store.withState { $0 = PeerSyncState(node: node, replica: PeerSyncReplica(node: node), unitcatSnapshot: []) }
        return PeerSyncEngine(store: store, unitCatsURL: nil)
    }

    /// One exchange, A initiating. `partitioned` makes the link fail before anything is sent.
    /// In-memory channels with bounded waits: no pipes, sockets or sleeps, and a stuck side fails the test fast.
    @discardableResult
    private func sync(_ a: PeerSyncEngine, _ b: PeerSyncEngine, partitioned: Bool = false) throws -> PeerSyncExchangeResult {
        if partitioned { throw PeerSyncError.io("partitioned") }
        let aToB = TestChannel(), bToA = TestChannel()
        let box = ResponderBox()
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            do { try b.respond(input: aToB, output: bToA) } catch { box.error = error }
            bToA.close()
            done.signal()
        }
        let outcome: PeerSyncExchangeResult
        do {
            outcome = try a.exchange(input: bToA, output: aToB)
        } catch {
            aToB.close(); bToA.close(); _ = done.wait(timeout: .now() + 10)
            throw error
        }
        aToB.close()
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success, "responder did not finish")
        XCTAssertNil(box.error)
        return outcome
    }

    private func view(_ e: PeerSyncEngine, host: String, id: String) throws -> PeerSyncSpaceView? {
        let r = try e.store.load().replica
        return r.lookup(host: host, herdrId: id).map { r.spaceView($0) }
    }

    func testEditOnAConvergesOnB() throws {
        let a = try engine("mac-aaaaaaaa"), b = try engine("win-bbbbbbbb")
        try a.publishLocal(workspaces: [(id: "w1", label: "Study")], categories: ["study": "school"])
        try sync(a, b)
        let seen = try view(b, host: "mac-aaaaaaaa", id: "w1")
        XCTAssertEqual(seen?.name, "Study")
        XCTAssertEqual(seen?.category, "school")
    }

    func testRenameAfterFirstSyncReachesB() throws {
        let a = try engine("mac-aaaaaaaa"), b = try engine("win-bbbbbbbb")
        try a.publishLocal(workspaces: [(id: "w1", label: "Study")], categories: [:])
        try sync(a, b)
        try a.publishLocal(workspaces: [(id: "w1", label: "Study Central")], categories: [:])
        try sync(a, b)
        XCTAssertEqual(try view(b, host: "mac-aaaaaaaa", id: "w1")?.name, "Study Central")
    }

    func testPartitionThenHeal() throws {
        let a = try engine("mac-aaaaaaaa"), b = try engine("win-bbbbbbbb")
        try a.publishLocal(workspaces: [(id: "w1", label: "One")], categories: [:])
        try sync(a, b)
        try a.publishLocal(workspaces: [(id: "w1", label: "Two")], categories: [:])
        XCTAssertThrowsError(try sync(a, b, partitioned: true))
        XCTAssertEqual(try view(b, host: "mac-aaaaaaaa", id: "w1")?.name, "One")
        XCTAssertGreaterThan(a.pendingCount(since: nil), 0)
        try sync(a, b)
        XCTAssertEqual(try view(b, host: "mac-aaaaaaaa", id: "w1")?.name, "Two")
    }

    func testTombstoneReplicates() throws {
        let a = try engine("mac-aaaaaaaa"), b = try engine("win-bbbbbbbb")
        try a.publishLocal(workspaces: [(id: "w1", label: "Gone")], categories: [:])
        try sync(a, b)
        let uuid = try a.store.load().replica.lookup(host: "mac-aaaaaaaa", herdrId: "w1")!
        try a.store.withState { try $0.replica.deleteSpace(uuid, now: UInt64(Date().timeIntervalSince1970 * 1000)) }
        try sync(a, b)
        let replica = try b.store.load().replica
        XCTAssertTrue(replica.isDeleted(uuid))
        XCTAssertNil(replica.lookup(host: "mac-aaaaaaaa", herdrId: "w1"))
    }

    func testSyncArgumentsEndWithSyncCommand() {
        let machine = HerdrMachineProfile(id: "p1", label: "PC", target: "user@host:2222", session: "default", enabled: true)
        let args = PeerSyncService.syncArguments(machine)
        XCTAssertEqual(args.last, "wooloo-peer sync")
        XCTAssertTrue(args.contains("BatchMode=yes"))
        XCTAssertTrue(args.contains("ControlMaster=no"))
        XCTAssertTrue(args.contains("ControlPath=none"))
    }

    func testStatusLabels() {
        let now = Date()
        XCTAssertEqual(PeerSyncStatus.synced(now.addingTimeInterval(-12)).label(now: now), "synced 12 s ago")
        XCTAssertEqual(PeerSyncStatus.offline(pending: 3, reason: "x").label(), "offline, 3 pending")
    }

    @MainActor func testLabelPlanLocalAndRemoteEdits() {
        let first = PeerSyncService.labelPlan(current: ["w1": "A"], known: [:], remote: [:])
        XCTAssertEqual(first.published, ["w1"]); XCTAssertTrue(first.renames.isEmpty)
        let local = PeerSyncService.labelPlan(current: ["w1": "B"], known: ["w1": "A"], remote: ["w1": "A"])
        XCTAssertEqual(local.published, ["w1"]); XCTAssertEqual(local.known["w1"], "B")
        let remote = PeerSyncService.labelPlan(current: ["w1": "A"], known: ["w1": "A"], remote: ["w1": "C"])
        XCTAssertEqual(remote.renames, ["w1": "C"]); XCTAssertTrue(remote.published.isEmpty)
        let settled = PeerSyncService.labelPlan(current: ["w1": "C"], known: remote.known, remote: ["w1": "C"])
        XCTAssertTrue(settled.renames.isEmpty); XCTAssertTrue(settled.published.isEmpty)
    }
}

private final class ResponderBox: @unchecked Sendable { var error: Error? }

/// One-way byte channel: write appends, readChunk waits (bounded) for data or close.
private final class TestChannel: PeerSyncInput, PeerSyncOutput, @unchecked Sendable {
    private let cond = NSCondition()
    private var data = Data()
    private var closed = false

    func write(_ d: Data) throws { cond.lock(); data.append(d); cond.broadcast(); cond.unlock() }
    func flush() throws {}
    func close() { cond.lock(); closed = true; cond.broadcast(); cond.unlock() }

    func readChunk(max: Int) throws -> Data {
        cond.lock(); defer { cond.unlock() }
        let deadline = Date().addingTimeInterval(10)
        while data.isEmpty && !closed {
            if !cond.wait(until: deadline) { throw PeerSyncError.io("test channel read timed out") }
        }
        let n = min(max, data.count)
        let out = data.prefix(n)
        data.removeFirst(n)
        return Data(out)
    }
}
