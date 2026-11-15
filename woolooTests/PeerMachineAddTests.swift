import XCTest
@testable import wooloo

@MainActor
private final class FakeCatalog: PeerMachineManaging {
    var failures: [String]
    private(set) var calls: [[String]] = []
    init(failures: [String] = []) { self.failures = failures }
    func manage(_ arguments: [String]) async throws {
        calls.append(arguments)
        if !failures.isEmpty { throw WorkspaceFileError.message(failures.removeFirst()) }
    }
}

@MainActor
final class PeerMachineAddTests: XCTestCase {
    private let key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPL0n3RNg08SCe1ezkGWADmJUd0dqkjBMG/0hF2rKRlT wooloo-mobile"

    private func code() throws -> PeerPairingCode {
        try PeerPairingCode(target: "me@pc.ts.net", publicKey: key, hostKey: key, herdrVersion: "0.9.5",
                            session: "wooloo", label: "Win PC")
    }

    func testFailureKeepsHerdrTextVerbatim() async throws {
        let text = "error: remote probe failed\nuname: Windows_NT: not supported"
        let adder = PeerMachineAdder(catalog: FakeCatalog(failures: [text]))
        let ok = await adder.add(try code())
        XCTAssertFalse(ok)
        XCTAssertEqual(adder.state, .failed(text))
        XCTAssertEqual(adder.failureText, text)
    }

    func testRetryReRunsAddAndSucceeds() async throws {
        let fake = FakeCatalog(failures: ["boom"])
        let adder = PeerMachineAdder(catalog: fake)
        let pairing = try code()
        let first = await adder.add(pairing)
        let second = await adder.add(pairing)
        XCTAssertFalse(first)
        XCTAssertTrue(second)
        XCTAssertEqual(adder.state, .added)
        XCTAssertNil(adder.failureText)
        XCTAssertEqual(fake.calls.count, 2)
        XCTAssertEqual(fake.calls[0], fake.calls[1])
    }

    func testSessionDefaultsToCodeAndCanBeOverridden() async throws {
        let fake = FakeCatalog()
        let adder = PeerMachineAdder(catalog: fake)
        let pairing = try code()
        await adder.add(pairing)
        await adder.add(pairing, session: "  ")
        await adder.add(pairing, session: " default ")
        func session(_ args: [String]) -> String? { args.firstIndex(of: "--remote-session").map { args[$0 + 1] } }
        XCTAssertEqual(fake.calls.map(session), ["wooloo", "wooloo", "default"])
        XCTAssertEqual(fake.calls[0].prefix(2), ["add", PeerPairing.alias(pairing.peerID)])
    }
}
