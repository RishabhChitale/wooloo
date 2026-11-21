import Foundation

// Line-delimited JSON exchange over any read/write pair (docs/sync-protocol.md).

protocol PeerSyncInput: AnyObject {
    /// Up to `max` bytes; empty Data means end of stream.
    func readChunk(max: Int) throws -> Data
}

protocol PeerSyncOutput: AnyObject {
    func write(_ data: Data) throws
    func flush() throws
}

enum PeerSyncWire {
    static let maxLine = 1 << 20
    static let maxOps = 200_000
    static let maxErrorChars = 300
}

final class PeerSyncLineReader {
    private let input: PeerSyncInput
    private var buf = [UInt8]()
    private var eof = false

    init(_ input: PeerSyncInput) { self.input = input }

    /// One message object. Throws Protocol/Remote/Io as the protocol requires.
    func readMessage() throws -> PeerSyncJSONValue {
        var line = [UInt8]()
        while true {
            if let nl = buf.firstIndex(of: 0x0A) {
                line = Array(buf[0..<nl])
                buf.removeSubrange(0...nl)
                break
            }
            if buf.count > PeerSyncWire.maxLine { throw PeerSyncError.protocol("line too long") }
            if eof {
                throw PeerSyncError.protocol(buf.isEmpty ? "connection closed" : "connection closed mid-line")
            }
            let chunk: Data
            do { chunk = try input.readChunk(max: 64 * 1024) } catch let e as PeerSyncError { throw e } catch { throw PeerSyncError.io("\(error)") }
            if chunk.isEmpty { eof = true } else { buf.append(contentsOf: chunk) }
        }
        if line.count > PeerSyncWire.maxLine { throw PeerSyncError.protocol("line too long") }
        if line.last == 0x0D { line.removeLast() }
        let text = String(decoding: line, as: UTF8.self)
        let v: PeerSyncJSONValue
        do { v = try PeerSyncJSON.parse(text) } catch { throw PeerSyncError.protocol("bad json") }
        guard case .object = v, let t = v["t"]?.stringValue else { throw PeerSyncError.protocol("missing message type") }
        if t == "error" {
            let raw = v["msg"]?.stringValue ?? "(no message)"
            throw PeerSyncError.remote(PeerSyncExchange.sanitize(raw))
        }
        return v
    }
}

struct PeerSyncInitiated {
    var peer: String
    var peerHerdrVersion: String?
    var reply: [PeerSyncRegister]
    var malformed: UInt64
    var accepted: UInt64
    var rejected: UInt64
}

struct PeerSyncHello: Equatable {
    var node: String
    var herdrVersion: String?
}

struct PeerSyncResponded: Equatable {
    var peer: String
    var peerHerdrVersion: String?
}

enum PeerSyncExchange {
    /// 1 to 32 bytes of ASCII letters, digits or `+.-`.
    static func isHerdrVersion(_ s: String) -> Bool {
        let b = Array(s.utf8)
        return !b.isEmpty && b.count <= 32 && b.allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A)
                || $0 == 0x2B || $0 == 0x2E || $0 == 0x2D
        }
    }

    static func sanitize(_ s: String) -> String {
        var out = ""
        var n = 0
        for u in s.unicodeScalars {
            if n >= PeerSyncWire.maxErrorChars { break }
            out.unicodeScalars.append(PeerSyncValidate.isControl(u) ? "?" : u)
            n += 1
        }
        return out
    }

    static func writeMessage(_ out: PeerSyncOutput, _ v: PeerSyncJSONValue, sorted: Bool = false) throws {
        let text = sorted ? PeerSyncJSON.canonical(v) : PeerSyncJSON.compact(v)
        let data = Data((text + "\n").utf8)
        if data.count - 1 > PeerSyncWire.maxLine { throw PeerSyncError.invalid("message too large") }
        do { try out.write(data) } catch let e as PeerSyncError { throw e } catch { throw PeerSyncError.io("\(error)") }
    }

    private static func flush(_ out: PeerSyncOutput) throws {
        do { try out.flush() } catch let e as PeerSyncError { throw e } catch { throw PeerSyncError.io("\(error)") }
    }

    static func hello(_ node: String, herdrVersion: String? = nil) -> PeerSyncJSONValue {
        var m: [(String, PeerSyncJSONValue)] = [("t", .string("hello")), ("proto", .int(Int64(PeerSync.proto))), ("node", .string(node))]
        if let hv = herdrVersion, isHerdrVersion(hv) { m.append(("herdr_version", .string(hv))) }
        return .object(m)
    }

    static func checkHello(_ v: PeerSyncJSONValue, own: String) throws -> PeerSyncHello {
        guard v["t"]?.stringValue == "hello" else { throw PeerSyncError.protocol("expected hello") }
        guard case .int(let p)? = v["proto"], p == Int64(PeerSync.proto) else { throw PeerSyncError.protocol("unsupported protocol version") }
        guard let node = v["node"]?.stringValue, PeerSyncValidate.isNodeId(node) else { throw PeerSyncError.protocol("bad node id") }
        if utf8Equal(node, own) { throw PeerSyncError.protocol("peer has the same node id") }
        var version: String?
        if let hv = v["herdr_version"]?.stringValue, isHerdrVersion(hv) { version = hv }
        return PeerSyncHello(node: node, herdrVersion: version)
    }

    static func sendError(_ out: PeerSyncOutput, _ e: PeerSyncError) {
        let msg: String
        switch e {
        case .protocol(let m): msg = "protocol error: \(m)"
        case .busy: msg = "the peer's sync state is busy; try again"
        case .io: msg = "i/o error on the peer"
        case .invalid: msg = "the peer could not process the exchange"
        case .remote: return
        }
        try? writeMessage(out, .object([("t", .string("error")), ("msg", .string(msg))]))
        try? out.flush()
    }

    private static func readOps(_ r: PeerSyncLineReader) throws -> ([PeerSyncRegister], UInt64) {
        var ops: [PeerSyncRegister] = []
        var malformed: UInt64 = 0
        var end: PeerSyncJSONValue?
        while end == nil {
            let m = try r.readMessage()
            switch m["t"]?.stringValue {
            case "op":
                if let reg = PeerSyncRegister.from(json: m) {
                    if ops.count >= PeerSyncWire.maxOps { throw PeerSyncError.protocol("too many ops") }
                    ops.append(reg)
                } else {
                    malformed += 1
                }
            case "end": end = m
            default: throw PeerSyncError.protocol("unexpected message")
            }
        }
        let count = end?["count"]?.uint64Value
        guard count == UInt64(ops.count) + malformed else { throw PeerSyncError.protocol("op count mismatch") }
        return (ops, malformed)
    }

    private static func sendOps(_ out: PeerSyncOutput, _ regs: [PeerSyncRegister]) throws {
        for r in regs { try writeMessage(out, r.wire, sorted: true) }
    }

    private static func endMessage(count: Int, accepted: UInt64? = nil, rejected: UInt64? = nil) -> PeerSyncJSONValue {
        var m: [(String, PeerSyncJSONValue)] = [("t", .string("end")), ("count", .int(Int64(count)))]
        if let a = accepted { m.append(("accepted", .int(Int64(clamping: a)))) }
        if let r = rejected { m.append(("rejected", .int(Int64(clamping: r)))) }
        return .object(m)
    }

    /// Responder side. `f` applies and saves, returning what was absorbed.
    @discardableResult
    static func respond(input: PeerSyncInput, output: PeerSyncOutput, node: String, herdrVersion: String? = nil,
                        f: (_ peer: String, _ ops: [PeerSyncRegister], _ malformed: UInt64) throws -> PeerSyncAbsorbed) throws -> PeerSyncResponded {
        do {
            let r = PeerSyncLineReader(input)
            let peerHello = try checkHello(try r.readMessage(), own: node)
            let peer = peerHello.node
            try writeMessage(output, hello(node, herdrVersion: herdrVersion), sorted: true)
            try flush(output)
            let (ops, malformed) = try readOps(r)
            let absorbed = try f(peer, ops, malformed)
            try sendOps(output, absorbed.reply)
            try writeMessage(output, endMessage(count: absorbed.reply.count, accepted: absorbed.accepted, rejected: absorbed.rejected))
            try flush(output)
            return PeerSyncResponded(peer: peer, peerHerdrVersion: peerHello.herdrVersion)
        } catch let e as PeerSyncError {
            sendError(output, e)
            throw e
        }
    }

    /// Initiator side. Nothing is applied here; the caller applies the reply and saves.
    static func initiate(input: PeerSyncInput, output: PeerSyncOutput, node: String, herdrVersion: String? = nil, regs: [PeerSyncRegister]) throws -> PeerSyncInitiated {
        let r = PeerSyncLineReader(input)
        try writeMessage(output, hello(node, herdrVersion: herdrVersion), sorted: true)
        try flush(output)
        PeerSyncLog.write("initiate: hello sent")
        let peerHello = try checkHello(try r.readMessage(), own: node)
        PeerSyncLog.write("initiate: hello received")
        let peer = peerHello.node
        if regs.count > PeerSyncWire.maxOps { throw PeerSyncError.invalid("too many registers") }
        try sendOps(output, regs)
        try writeMessage(output, endMessage(count: regs.count))
        try flush(output)
        PeerSyncLog.write("initiate: sent \(regs.count) ops and end")

        var reply: [PeerSyncRegister] = []
        var malformed: UInt64 = 0
        var end: PeerSyncJSONValue?
        while end == nil {
            let m = try r.readMessage()
            switch m["t"]?.stringValue {
            case "op":
                if let reg = PeerSyncRegister.from(json: m) {
                    if reply.count >= PeerSyncWire.maxOps { throw PeerSyncError.protocol("too many ops") }
                    reply.append(reg)
                } else { malformed += 1 }
            case "end": end = m
            default: throw PeerSyncError.protocol("unexpected message")
            }
        }
        guard end?["count"]?.uint64Value == UInt64(reply.count) + malformed else { throw PeerSyncError.protocol("op count mismatch") }
        return PeerSyncInitiated(peer: peer, peerHerdrVersion: peerHello.herdrVersion, reply: reply, malformed: malformed,
                                 accepted: end?["accepted"]?.uint64Value ?? 0, rejected: end?["rejected"]?.uint64Value ?? 0)
    }
}

/// In-memory channel, used by tests and loopback exchanges.
final class PeerSyncMemoryChannel: PeerSyncInput, PeerSyncOutput {
    private var data: Data
    private(set) var written = Data()
    init(_ initial: Data = Data()) { data = initial }
    func readChunk(max: Int) throws -> Data {
        let n = min(max, data.count)
        let out = data.prefix(n)
        data.removeFirst(n)
        return Data(out)
    }
    func write(_ d: Data) throws { written.append(d) }
    func flush() throws {}
    var writtenLines: [String] {
        String(decoding: written, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }
}
