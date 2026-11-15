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
    func readMessage() throws -> JSONValue {
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
        let v: JSONValue
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
    var reply: [Register]
    var malformed: UInt64
    var accepted: UInt64
    var rejected: UInt64
}

enum PeerSyncExchange {
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

    static func writeMessage(_ out: PeerSyncOutput, _ v: JSONValue, sorted: Bool = false) throws {
        let text = sorted ? PeerSyncJSON.canonical(v) : PeerSyncJSON.compact(v)
        let data = Data((text + "\n").utf8)
        if data.count - 1 > PeerSyncWire.maxLine { throw PeerSyncError.invalid("message too large") }
        do { try out.write(data) } catch let e as PeerSyncError { throw e } catch { throw PeerSyncError.io("\(error)") }
    }

    private static func flush(_ out: PeerSyncOutput) throws {
        do { try out.flush() } catch let e as PeerSyncError { throw e } catch { throw PeerSyncError.io("\(error)") }
    }

    static func hello(_ node: String) -> JSONValue {
        .object([("t", .string("hello")), ("proto", .int(Int64(PeerSync.proto))), ("node", .string(node))])
    }

    static func checkHello(_ v: JSONValue, own: String) throws -> String {
        guard v["t"]?.stringValue == "hello" else { throw PeerSyncError.protocol("expected hello") }
        guard case .int(let p)? = v["proto"], p == Int64(PeerSync.proto) else { throw PeerSyncError.protocol("unsupported protocol version") }
        guard let node = v["node"]?.stringValue, PeerSyncValidate.isNodeId(node) else { throw PeerSyncError.protocol("bad node id") }
        if utf8Equal(node, own) { throw PeerSyncError.protocol("peer has the same node id") }
        return node
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

    private static func readOps(_ r: PeerSyncLineReader) throws -> ([Register], UInt64) {
        var ops: [Register] = []
        var malformed: UInt64 = 0
        var end: JSONValue?
        while end == nil {
            let m = try r.readMessage()
            switch m["t"]?.stringValue {
            case "op":
                if let reg = Register.from(json: m) {
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

    private static func sendOps(_ out: PeerSyncOutput, _ regs: [Register]) throws {
        for r in regs { try writeMessage(out, r.wire, sorted: true) }
    }

    private static func endMessage(count: Int, accepted: UInt64? = nil, rejected: UInt64? = nil) -> JSONValue {
        var m: [(String, JSONValue)] = [("t", .string("end")), ("count", .int(Int64(count)))]
        if let a = accepted { m.append(("accepted", .int(Int64(clamping: a)))) }
        if let r = rejected { m.append(("rejected", .int(Int64(clamping: r)))) }
        return .object(m)
    }

    /// Responder side. `f` applies and saves, returning what was absorbed.
    static func respond(input: PeerSyncInput, output: PeerSyncOutput, node: String,
                        f: (_ peer: String, _ ops: [Register], _ malformed: UInt64) throws -> Absorbed) throws {
        do {
            let r = PeerSyncLineReader(input)
            let peer = try checkHello(try r.readMessage(), own: node)
            try writeMessage(output, hello(node))
            try flush(output)
            let (ops, malformed) = try readOps(r)
            let absorbed = try f(peer, ops, malformed)
            try sendOps(output, absorbed.reply)
            try writeMessage(output, endMessage(count: absorbed.reply.count, accepted: absorbed.accepted, rejected: absorbed.rejected))
            try flush(output)
        } catch let e as PeerSyncError {
            sendError(output, e)
            throw e
        }
    }

    /// Initiator side. Nothing is applied here; the caller applies the reply and saves.
    static func initiate(input: PeerSyncInput, output: PeerSyncOutput, node: String, regs: [Register]) throws -> PeerSyncInitiated {
        let r = PeerSyncLineReader(input)
        try writeMessage(output, hello(node))
        try flush(output)
        let peer = try checkHello(try r.readMessage(), own: node)
        if regs.count > PeerSyncWire.maxOps { throw PeerSyncError.invalid("too many registers") }
        try sendOps(output, regs)
        try writeMessage(output, endMessage(count: regs.count))
        try flush(output)

        var reply: [Register] = []
        var malformed: UInt64 = 0
        var end: JSONValue?
        while end == nil {
            let m = try r.readMessage()
            switch m["t"]?.stringValue {
            case "op":
                if let reg = Register.from(json: m) {
                    if reply.count >= PeerSyncWire.maxOps { throw PeerSyncError.protocol("too many ops") }
                    reply.append(reg)
                } else { malformed += 1 }
            case "end": end = m
            default: throw PeerSyncError.protocol("unexpected message")
            }
        }
        guard end?["count"]?.uint64Value == UInt64(reply.count) + malformed else { throw PeerSyncError.protocol("op count mismatch") }
        return PeerSyncInitiated(peer: peer, reply: reply, malformed: malformed,
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
