import XCTest
@testable import wooloo

/// Runs the shared conformance vectors (docs/sync-vectors.json in wooloo-win) against the Swift port.
final class PeerSyncTests: XCTestCase {
    private static let vectors: JSONValue = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/sync-vectors.json")
        let text = String(decoding: (try? Data(contentsOf: url)) ?? Data(), as: UTF8.self)
        return (try? PeerSyncJSON.parse(text)) ?? .null
    }()

    private func section(_ name: String) -> [JSONValue] {
        let a = Self.vectors[name]?.arrayValue ?? []
        XCTAssertFalse(a.isEmpty, "missing vector section \(name)")
        return a
    }

    private func str(_ v: JSONValue, _ k: String) -> String { v[k]?.stringValue ?? "" }
    private func u64(_ v: JSONValue?) -> UInt64 { v?.uint64Value ?? 0 }
    private func regs(_ v: JSONValue?) -> [Register] { (v?.arrayValue ?? []).compactMap { Register.from(json: $0) } }
    private func hlc(_ v: JSONValue?) -> Hlc { v.flatMap { Hlc.from(json: $0) } ?? .zero }
    private func canon(_ rs: [Register]) -> [String] { rs.map { PeerSyncJSON.canonical($0.json) } }

    func testHeaderMatches() {
        XCTAssertEqual(Self.vectors["format"]?.uint64Value, UInt64(PeerSync.format))
        XCTAssertEqual(Self.vectors["max_future_ms"]?.uint64Value, PeerSync.maxFutureMs)
    }

    func testHlcVectors() {
        for v in section("hlc") {
            var c = hlc(v["start"])
            for (i, s) in (v["steps"]?.arrayValue ?? []).enumerated() {
                let label = "\(str(v, "name")) step \(i)"
                if str(s, "op") == "tick" {
                    _ = c.tick(now: u64(s["now"]))
                } else {
                    c.observe(hlc(s["remote"]))
                }
                XCTAssertEqual(c, hlc(s["expect"]), label)
            }
        }
    }

    func testCanonicalVectors() {
        for v in section("canonical") {
            XCTAssertEqual(PeerSyncJSON.canonical(v["value"] ?? .null), str(v, "text"))
        }
    }

    func testCompareVectors() {
        for v in section("compare") {
            guard let a = Register.from(json: v["a"] ?? .null), let b = Register.from(json: v["b"] ?? .null) else {
                XCTFail("bad compare vector \(str(v, "name"))"); continue
            }
            let w = str(v, "winner")
            let name = str(v, "name")
            switch w {
            case "a": XCTAssertGreaterThan(a.lwwCompare(b), 0, name); XCTAssertLessThan(b.lwwCompare(a), 0, name)
            case "b": XCTAssertLessThan(a.lwwCompare(b), 0, name); XCTAssertGreaterThan(b.lwwCompare(a), 0, name)
            default: XCTAssertEqual(a.lwwCompare(b), 0, name)
            }
        }
    }

    func testValidateVectors() {
        for v in section("validate") {
            let name = str(v, "name")
            let want = v["valid"]?.boolValue ?? false
            let ok = v["op"].flatMap { Register.from(json: $0) }?.isValid ?? false
            XCTAssertEqual(ok, want, name)
        }
    }

    private func mergeRun(_ ops: [Register], now: UInt64) -> (Replica, Int) {
        var r = Replica(node: "ref-node")
        var rejected = 0
        for op in ops where r.apply(op, now: now).isRejected { rejected += 1 }
        return (r, rejected)
    }

    func testMergeVectors() {
        for v in section("merge") {
            let name = str(v, "name")
            let ops = regs(v["ops"])
            let now = u64(v["now"])
            for (label, list) in [("forward", ops), ("reversed", Array(ops.reversed()))] {
                let (r, rejected) = mergeRun(list, now: now)
                if label == "forward" {
                    XCTAssertEqual(rejected, Int(u64(v["expect_rejected"])), name)
                    XCTAssertEqual(r.clock, hlc(v["expect_clock"]), "\(name) clock")
                }
                XCTAssertEqual(canon(r.sortedRegs()), canon(regs(v["expect_registers"])), "\(name) \(label)")
                let live = (v["expect_live_spaces"]?.arrayValue ?? []).compactMap { $0.stringValue }
                XCTAssertEqual(r.liveSpaces(), live, "\(name) \(label) live")
            }
        }
    }

    func testExchangeVectors() throws {
        for v in section("exchange") {
            let name = str(v, "name")
            let now = u64(v["now"])
            let mac = "mac-3f9a21c0", win = "win-07be55d1"
            var ini = Replica(node: win)
            for r in regs(v["initiator"]) { ini.insertRaw(r) }
            var resp = Replica(node: mac)
            for r in regs(v["responder"]) { resp.insertRaw(r) }

            // Responder runs against initiator bytes produced by the real initiator code path.
            let fromResponder = PeerSyncMemoryChannel()
            // Build the initiator stream first: hello, ops, end.
            var stream = Data()
            let hello = PeerSyncJSON.canonical(PeerSyncExchange.hello(win)) + "\n"
            stream.append(Data(hello.utf8))
            let sent = ini.sortedRegs()
            for r in sent { stream.append(Data((PeerSyncJSON.canonical(r.wire) + "\n").utf8)) }
            stream.append(Data((PeerSyncJSON.canonical(.object([("t", .string("end")), ("count", .int(Int64(sent.count)))])) + "\n").utf8))
            let rIn = PeerSyncMemoryChannel(stream)
            var absorbed: Absorbed?
            try PeerSyncExchange.respond(input: rIn, output: fromResponder, node: mac) { _, ops, malformed in
                let a = resp.absorb(ops, malformed: malformed, now: now)
                absorbed = a
                return a
            }
            // Initiator reads responder reply.
            let iIn = PeerSyncMemoryChannel(fromResponder.written)
            let sink = PeerSyncMemoryChannel()
            let got = try PeerSyncExchange.initiate(input: iIn, output: sink, node: win, regs: sent)
            var iniAfter = ini
            for r in got.reply { _ = iniAfter.apply(r, now: now) }
            XCTAssertEqual(absorbed?.accepted, u64(v["expect_accepted"]), "\(name) accepted")
            XCTAssertEqual(absorbed?.rejected, u64(v["expect_rejected"]), "\(name) rejected")
            XCTAssertEqual(canon(absorbed?.reply ?? []), canon(regs(v["expect_reply"])), "\(name) reply")
            XCTAssertEqual(canon(iniAfter.sortedRegs()), canon(regs(v["expect_initiator"])), "\(name) initiator")
            XCTAssertEqual(canon(resp.sortedRegs()), canon(regs(v["expect_responder"])), "\(name) responder")
        }
    }

    func testBindingVectors() throws {
        for v in section("binding") {
            let name = str(v, "name")
            var r = Replica(node: str(v, "node"))
            for reg in regs(v["registers"]) { r.insertRaw(reg) }
            let ws = (v["workspaces"]?.arrayValue ?? []).map { (id: str($0, "herdr_id"), label: str($0, "label")) }
            let plan = r.planBinding(ws)
            let want = (v["expect"]?.arrayValue ?? []).map {
                Binding(herdrId: str($0, "herdr_id"), label: str($0, "label"),
                        kind: BindKind(rawValue: str($0, "kind")) ?? .minted,
                        space: $0["space"]?.stringValue)
            }
            let orphans = (v["expect_orphans"]?.arrayValue ?? []).compactMap { $0.stringValue }
            // Minted spaces have fresh UUIDs: compare them by kind only.
            XCTAssertEqual(plan.bindings.count, want.count, name)
            for (g, w) in zip(plan.bindings, want) {
                XCTAssertEqual(g.herdrId, w.herdrId, name)
                XCTAssertEqual(g.label, w.label, name)
                XCTAssertEqual(g.kind, w.kind, name)
                if w.kind != .minted { XCTAssertEqual(g.space, w.space, name) }
            }
            XCTAssertEqual(plan.orphans, orphans, name)

            var applied = r
            let done = try applied.bindHost(ws, now: 1763112000000)
            for (g, w) in zip(done.bindings, want) {
                XCTAssertNotNil(g.space, name)
                if w.kind != .minted { XCTAssertEqual(g.space, w.space, name) }
            }
        }
    }

    private func pairs(_ v: JSONValue?) -> [(String, String)] {
        (v?.objectValue ?? []).compactMap { k, x in x.stringValue.map { (k, $0) } }
    }

    func testUnitCatImportVectors() throws {
        for v in section("unitcat_import") {
            let name = str(v, "name")
            var s = PeerSyncState(node: "mac-3f9a21c0", replica: Replica(node: "mac-3f9a21c0"))
            s.unitcatSnapshot = pairs(v["snapshot"])
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wooloo-sync-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let file = dir.appendingPathComponent("cats.json")
            try Data(PeerSyncJSON.canonical(v["file"] ?? .object([])).utf8).write(to: file)
            let n = try PeerSyncUnitCats.importFile(file, into: &s, now: 1763112000000)
            let want = v["expect_ops"]?.arrayValue ?? []
            XCTAssertEqual(n, want.count, name)
            for w in want {
                let r = s.replica.get(str(w, "key"), str(w, "field"))
                XCTAssertEqual(r?.value, w["value"] ?? .null, name)
            }
            XCTAssertEqual(s.replica.sortedRegs().count, want.count, name)
            XCTAssertEqual(s.unitcatSnapshot.map { "\($0.0)=\($0.1)" }.sorted(),
                           pairs(v["expect_snapshot"]).map { "\($0.0)=\($0.1)" }.sorted(), name)
        }
    }

    func testUnitCatExportVectors() throws {
        for v in section("unitcat_export") {
            var s = PeerSyncState(node: "mac-3f9a21c0", replica: Replica(node: "mac-3f9a21c0"))
            for r in regs(v["registers"]) { s.replica.insertRaw(r) }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wooloo-sync-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let file = dir.appendingPathComponent("cats.json")
            XCTAssertTrue(try PeerSyncUnitCats.exportFile(file, from: &s))
            let got = PeerSyncUnitCats.readFile(file) ?? []
            XCTAssertEqual(got.map { "\($0.0)=\($0.1.stringValue ?? "")" }.sorted(),
                           pairs(v["expect"]).map { "\($0.0)=\($0.1)" }.sorted())
        }
    }

    func testHelloVectors() throws {
        for v in section("hello") {
            let name = str(v, "name")
            let own = str(v, "own")
            let line = str(v, "line")
            let ok = v["expect_ok"]?.boolValue ?? false
            let parsed = try? PeerSyncJSON.parse(line)
            let res = parsed.flatMap { try? PeerSyncExchange.checkHello($0, own: own) }
            XCTAssertEqual(res != nil, ok, name)
            if ok, let res {
                XCTAssertEqual(res.node, str(v, "expect_peer"), name)
                XCTAssertEqual(res.herdrVersion, v["expect_herdr_version"]?.stringValue, name)
                if v["wire"]?.boolValue == true {
                    let emitted = PeerSyncExchange.hello(res.node, herdrVersion: res.herdrVersion)
                    XCTAssertEqual(PeerSyncJSON.canonical(emitted), line, name)
                }
            }
        }
    }

    // MARK: exchange refusals

    private func line(_ v: JSONValue) -> Data { Data((PeerSyncJSON.compact(v) + "\n").utf8) }

    func testResponderRefusesSameNodeId() {
        let input = PeerSyncMemoryChannel(line(PeerSyncExchange.hello("mac-3f9a21c0")))
        let out = PeerSyncMemoryChannel()
        XCTAssertThrowsError(try PeerSyncExchange.respond(input: input, output: out, node: "mac-3f9a21c0") { _, _, _ in
            Absorbed(accepted: 0, rejected: 0, reply: [])
        })
        XCTAssertTrue(out.writtenLines.last?.contains("\"error\"") == true)
    }

    func testResponderRefusesProto2() {
        let hello: JSONValue = .object([("t", .string("hello")), ("proto", .int(2)), ("node", .string("win-07be55d1"))])
        let out = PeerSyncMemoryChannel()
        XCTAssertThrowsError(try PeerSyncExchange.respond(input: PeerSyncMemoryChannel(line(hello)), output: out, node: "mac-3f9a21c0") { _, _, _ in
            Absorbed(accepted: 0, rejected: 0, reply: [])
        })
    }

    func testResponderRejectsTruncatedStream() {
        var d = line(PeerSyncExchange.hello("win-07be55d1"))
        d.append(Data("{\"t\":\"op\"".utf8))
        XCTAssertThrowsError(try PeerSyncExchange.respond(input: PeerSyncMemoryChannel(d), output: PeerSyncMemoryChannel(), node: "mac-3f9a21c0") { _, _, _ in
            Absorbed(accepted: 0, rejected: 0, reply: [])
        })
    }

    func testInitiatorSurfacesRemoteError() {
        let input = PeerSyncMemoryChannel(Data("{\"t\":\"error\",\"msg\":\"nope\"}\n".utf8))
        XCTAssertThrowsError(try PeerSyncExchange.initiate(input: input, output: PeerSyncMemoryChannel(), node: "win-07be55d1", regs: [])) {
            XCTAssertEqual($0 as? PeerSyncError, .remote("nope"))
        }
    }
}
