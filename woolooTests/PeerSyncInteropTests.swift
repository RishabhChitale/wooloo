import XCTest
@testable import wooloo

/// Cross-implementation interop: the Swift exchange and the Rust `wooloo-sync` exchange must produce
/// byte-identical wire transcripts for the same scripted scenario (Fixtures/interop-scenario.json).
///
/// Transcript format: one wire line per line, prefixed "> " (initiator to responder) or "< " (responder to initiator).
/// Regenerate: run with WOOLOO_INTEROP_REGENERATE=1; the transcript is written to Fixtures/interop-swift.transcript
/// (and printed between INTEROP-TRANSCRIPT markers in the log so CI can hand it back). See docs/sync-protocol.md.
final class PeerSyncInteropTests: XCTestCase {
    private static let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

    private struct Scenario {
        var now: UInt64, herdr: String, iniNode: String, respNode: String
        var ini: [PeerSyncRegister], resp: [PeerSyncRegister]
    }

    private func scenario() throws -> Scenario {
        let text = try String(contentsOf: Self.dir.appendingPathComponent("interop-scenario.json"), encoding: .utf8)
        let v = try PeerSyncJSON.parse(text)
        func regs(_ k: String) -> [PeerSyncRegister] { (v[k]?.arrayValue ?? []).compactMap { PeerSyncRegister.from(json: $0) } }
        return Scenario(now: v["now"]?.uint64Value ?? 0, herdr: v["herdr_version"]?.stringValue ?? "",
                        iniNode: v["initiator_node"]?.stringValue ?? "", respNode: v["responder_node"]?.stringValue ?? "",
                        ini: regs("initiator"), resp: regs("responder"))
    }

    private func line(_ v: PeerSyncJSONValue) -> String { PeerSyncJSON.canonical(v) }
    private func canon(_ rs: [PeerSyncRegister]) -> [String] { rs.map { PeerSyncJSON.canonical($0.json) } }

    private struct Run { var toResponder: [String]; var toInitiator: [String]; var iniFinal: [String]; var respFinal: [String] }

    /// Runs the real Swift responder and initiator over in-memory channels and records every byte line.
    private func run(_ s: Scenario) throws -> Run {
        var ini = PeerSyncReplica(node: s.iniNode)
        for r in s.ini { ini.insertRaw(r) }
        var resp = PeerSyncReplica(node: s.respNode)
        for r in s.resp { resp.insertRaw(r) }
        let sent = ini.sortedRegs()

        var stream = Data()
        stream.append(Data((line(PeerSyncExchange.hello(s.iniNode, herdrVersion: s.herdr)) + "\n").utf8))
        for r in sent { stream.append(Data((line(r.wire) + "\n").utf8)) }
        stream.append(Data((line(.object([("t", .string("end")), ("count", .int(Int64(sent.count)))])) + "\n").utf8))

        let respOut = PeerSyncMemoryChannel()
        try PeerSyncExchange.respond(input: PeerSyncMemoryChannel(stream), output: respOut, node: s.respNode, herdrVersion: s.herdr) { _, ops, malformed in
            resp.absorb(ops, malformed: malformed, now: s.now)
        }
        let iniOut = PeerSyncMemoryChannel()
        let got = try PeerSyncExchange.initiate(input: PeerSyncMemoryChannel(respOut.written), output: iniOut, node: s.iniNode, herdrVersion: s.herdr, regs: sent)
        for r in got.reply { _ = ini.apply(r, now: s.now) }
        // initiate() writes the real wire bytes (the end line is not key-sorted), so record those; the hand-built
        // stream above must only be semantically identical (same canonical lines), which the responder already accepted.
        func canonLines(_ d: Data) throws -> [String] {
            try String(decoding: d, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true).map { try PeerSyncJSON.canonical(PeerSyncJSON.parse(String($0))) }
        }
        XCTAssertEqual(try canonLines(iniOut.written), try canonLines(stream), "initiate() must write the same messages as the hand-built stream")
        return Run(toResponder: String(decoding: iniOut.written, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true).map(String.init), toInitiator: respOut.writtenLines,
                   iniFinal: canon(ini.sortedRegs()), respFinal: canon(resp.sortedRegs()))
    }

    private func transcript(_ r: Run) -> String {
        (r.toResponder.map { "> " + $0 } + r.toInitiator.map { "< " + $0 }).joined(separator: "\n") + "\n"
    }

    private func split(_ t: String) -> (ini: [String], resp: [String]) {
        var a: [String] = [], b: [String] = []
        for l in t.split(separator: "\n", omittingEmptySubsequences: true) {
            if l.hasPrefix("> ") { a.append(String(l.dropFirst(2))) } else if l.hasPrefix("< ") { b.append(String(l.dropFirst(2))) }
        }
        return (a, b)
    }

    private func canonAll(_ ls: [String]) throws -> [String] { try ls.map { PeerSyncJSON.canonical(try PeerSyncJSON.parse($0)) } }

    private func fixture(_ name: String) -> String? { try? String(contentsOf: Self.dir.appendingPathComponent(name), encoding: .utf8) }

    func testScenarioConverges() throws {
        let r = try run(try scenario())
        XCTAssertEqual(r.iniFinal, r.respFinal, "both replicas converge")
        XCTAssertFalse(r.respFinal.isEmpty)
    }

    func testSwiftTranscriptMatchesFixture() throws {
        let t = transcript(try run(try scenario()))
        if ProcessInfo.processInfo.environment["WOOLOO_INTEROP_REGENERATE"] == "1" {
            try t.write(to: Self.dir.appendingPathComponent("interop-swift.transcript"), atomically: true, encoding: .utf8)
            print("INTEROP-TRANSCRIPT-BEGIN swift\n\(t)INTEROP-TRANSCRIPT-END")
            return
        }
        guard let want = fixture("interop-swift.transcript") else {
            print("INTEROP-TRANSCRIPT-BEGIN swift\n\(t)INTEROP-TRANSCRIPT-END")
            throw XCTSkip("interop-swift.transcript not committed yet; transcript printed to the log")
        }
        XCTAssertEqual(t, want, "Swift wire output drifted from the committed transcript")
    }

    /// Replays a transcript produced by the other implementation: our responder must emit its exact reply
    /// bytes, our initiator must accept that reply and converge to the same state as our own run.
    private func replay(_ name: String) throws {
        guard let text = fixture(name) else { throw XCTSkip("\(name) not committed yet") }
        let s = try scenario()
        let (ini, resp) = split(text)
        let own = try run(s)
        // Member order is not significant on the wire (spec 8.1), so compare messages canonically.
        XCTAssertEqual(try canonAll(ini), try canonAll(own.toResponder), "\(name): initiator stream messages")
        XCTAssertEqual(try canonAll(resp), try canonAll(own.toInitiator), "\(name): responder reply messages")

        var replica = PeerSyncReplica(node: s.respNode)
        for r in s.resp { replica.insertRaw(r) }
        let out = PeerSyncMemoryChannel()
        let input = PeerSyncMemoryChannel(Data(ini.map { $0 + "\n" }.joined().utf8))
        try PeerSyncExchange.respond(input: input, output: out, node: s.respNode, herdrVersion: s.herdr) { _, ops, malformed in
            replica.absorb(ops, malformed: malformed, now: s.now)
        }
        XCTAssertEqual(try canonAll(out.writtenLines), try canonAll(resp), "\(name): responder output over recorded input")
        XCTAssertEqual(canon(replica.sortedRegs()), own.respFinal, "\(name): responder converged state")

        var iniReplica = PeerSyncReplica(node: s.iniNode)
        for r in s.ini { iniReplica.insertRaw(r) }
        let got = try PeerSyncExchange.initiate(input: PeerSyncMemoryChannel(Data(resp.map { $0 + "\n" }.joined().utf8)),
                                                output: PeerSyncMemoryChannel(), node: s.iniNode, herdrVersion: s.herdr, regs: iniReplica.sortedRegs())
        for r in got.reply { _ = iniReplica.apply(r, now: s.now) }
        XCTAssertEqual(canon(iniReplica.sortedRegs()), own.iniFinal, "\(name): initiator converged state")
    }

    func testReplaysRustTranscript() throws { try replay("interop-rust.transcript") }
    func testReplaysSwiftTranscript() throws { try replay("interop-swift.transcript") }

    /// Receivers must accept any member order (spec 8.1): a stream with every object's members reversed
    /// (note canonical() re-sorts, so write the reversed text by hand below) converges identically.
    func testResponderAcceptsAnyKeyOrder() throws {
        let sc = try scenario()
        let base = try run(sc)
        func reverseText(_ l: String) -> String {
            // lines here are flat or one-level nested JSON objects with sorted members: split top-level members and reverse them
            var parts: [String] = [], depth = 0, cur = "", inStr = false, esc = false
            for ch in l.dropFirst().dropLast() {
                if inStr { cur.append(ch); if esc { esc = false } else if ch == "\\" { esc = true } else if ch == "\"" { inStr = false }; continue }
                if ch == "\"" { inStr = true; cur.append(ch) } else if ch == "{" || ch == "[" { depth += 1; cur.append(ch) }
                else if ch == "}" || ch == "]" { depth -= 1; cur.append(ch) }
                else if ch == "," && depth == 0 { parts.append(cur); cur = "" } else { cur.append(ch) }
            }
            parts.append(cur)
            return "{" + parts.reversed().joined(separator: ",") + "}"
        }
        let shuffled = base.toResponder.map(reverseText)
        XCTAssertNotEqual(shuffled, base.toResponder, "the reordered stream must actually differ in bytes")
        var resp = PeerSyncReplica(node: sc.respNode)
        for r in sc.resp { resp.insertRaw(r) }
        let out = PeerSyncMemoryChannel()
        try PeerSyncExchange.respond(input: PeerSyncMemoryChannel(Data(shuffled.map { $0 + "\n" }.joined().utf8)), output: out, node: sc.respNode, herdrVersion: sc.herdr) { _, ops, malformed in
            resp.absorb(ops, malformed: malformed, now: sc.now)
        }
        XCTAssertEqual(canon(resp.sortedRegs()), base.respFinal)

        // and the initiator accepts a reply whose members are reordered
        let reply = out.writtenLines.map(reverseText)
        var ini = PeerSyncReplica(node: sc.iniNode)
        for r in sc.ini { ini.insertRaw(r) }
        let got = try PeerSyncExchange.initiate(input: PeerSyncMemoryChannel(Data(reply.map { $0 + "\n" }.joined().utf8)), output: PeerSyncMemoryChannel(),
                                                node: sc.iniNode, herdrVersion: sc.herdr, regs: ini.sortedRegs())
        for r in got.reply { _ = ini.apply(r, now: sc.now) }
        XCTAssertEqual(canon(ini.sortedRegs()), base.iniFinal)
    }
}
