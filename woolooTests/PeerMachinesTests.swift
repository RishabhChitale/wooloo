import Foundation
import XCTest
@testable import wooloo

/// Peer machines (docs/peer-pairing.md). Pure logic plus fakes; nothing touches real Herdr sessions or ssh.
final class PeerMachinesTests: XCTestCase {
    private let peer = HerdrMachineProfile(id: "pc", label: "Work PC", target: "wooloo-peer-pc", session: "work", enabled: true)
    private let plain = HerdrMachineProfile(id: "box", label: "Box", target: "me@box.example", session: "work", enabled: true)

    func testSkewRules() {
        XCTAssertNil(HerdrVersionSkew.banner(local: nil, peer: "0.9.5"))
        XCTAssertNil(HerdrVersionSkew.banner(local: "0.9.5", peer: nil))
        XCTAssertNil(HerdrVersionSkew.banner(local: "0.9.5", peer: "0.9.5"))
        XCTAssertEqual(HerdrVersionSkew.banner(local: "0.9.5", peer: "v0.9.7")?.severity, .warn)
        XCTAssertEqual(HerdrVersionSkew.banner(local: "0.9.5", peer: "0.10.0")?.severity, .error)
        XCTAssertEqual(HerdrVersionSkew.banner(local: "1.0.0", peer: "0.9.5")?.severity, .error)
        XCTAssertEqual(HerdrVersionSkew.banner(local: "0.9.5", peer: "nightly")?.severity, .warn)
        XCTAssertEqual(HerdrVersionSkew.parse("v1.2.3-rc1"), [1, 2, 3])
        XCTAssertNil(HerdrVersionSkew.parse("1.2"))
    }

    func testBackoffDoublesToThirtyAndResets() {
        var backoff = PeerBackoff()
        var delays: [TimeInterval] = []
        for _ in 0..<8 { delays.append(backoff.delay); backoff.failed() }
        XCTAssertEqual(delays, [1, 2, 4, 8, 16, 30, 30, 30])
        backoff.reset()
        XCTAssertEqual(backoff.delay, 1)
    }

    func testParseHello() {
        XCTAssertEqual(PeerMachine.parseHello("wooloo-peer-bridge-v1 0.9.5\n"), "0.9.5")
        XCTAssertNil(PeerMachine.parseHello("hello 0.9.5"))
        XCTAssertNil(PeerMachine.parseHello("wooloo-peer-bridge-v1"))
        XCTAssertNil(PeerMachine.parseHello("wooloo-peer-bridge-v1 0.9.5; rm"))
    }

    func testPeerBridgeUsesAllowListedCommands() {
        XCTAssertTrue(PeerMachine.isPeer(peer))
        XCTAssertFalse(PeerMachine.isPeer(plain))
        let api = HerdrRemoteBridge.arguments(peer, command: "remote-api-bridge")
        XCTAssertEqual(Array(api.suffix(2)), ["wooloo-peer-pc", "wooloo-peer api work"])
        let client = HerdrRemoteBridge.arguments(peer, command: "remote-client-bridge")
        XCTAssertEqual(client.last, "wooloo-peer client work")
        let other = HerdrRemoteBridge.arguments(plain, command: "remote-api-bridge")
        XCTAssertFalse(other.contains { $0.hasPrefix("wooloo-peer ") })
    }

    @MainActor
    func testMonitorConnectsFailsAndBacksOff() async {
        let replies = ReplyQueue(["wooloo-peer-bridge-v1 0.9.7", "FAIL", "FAIL", "FAIL"])
        let monitor = PeerLinkMonitor(machine: peer, healthyInterval: 30,
                                      probe: { _ in try await replies.next() },
                                      localVersion: { "0.9.5" },
                                      sleep: { _ in })
        var delay = await monitor.check()
        XCTAssertEqual(monitor.state, .connected)
        XCTAssertEqual(monitor.peerVersion, "0.9.7")
        XCTAssertEqual(monitor.skew?.severity, .warn)
        XCTAssertEqual(delay, 30)
        delay = await monitor.check()
        if case .failed = monitor.state {} else { XCTFail("expected failed, got \(monitor.state)") }
        XCTAssertEqual(delay, 1)
        delay = await monitor.check()
        XCTAssertEqual(delay, 2)
        delay = await monitor.check()
        XCTAssertEqual(delay, 4)
    }

    @MainActor
    func testMonitorNoBannerWithoutLocalVersionAndRejectsBadReply() async {
        let replies = ReplyQueue(["wooloo-peer-bridge-v1 0.9.7", "garbage"])
        let monitor = PeerLinkMonitor(machine: peer, probe: { _ in try await replies.next() },
                                      localVersion: { nil }, sleep: { _ in })
        _ = await monitor.check()
        XCTAssertNil(monitor.skew)
        _ = await monitor.check()
        XCTAssertEqual(monitor.state, .failed("Unexpected reply from peer"))
    }
}

private actor ReplyQueue {
    private var items: [String]
    init(_ items: [String]) { self.items = items }
    func next() throws -> String {
        let item = items.isEmpty ? "FAIL" : items.removeFirst()
        if item == "FAIL" { throw WorkspaceFileError.message("ssh: connection refused") }
        return item
    }
}
