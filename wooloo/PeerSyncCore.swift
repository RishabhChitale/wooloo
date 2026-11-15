import Foundation

// Peer-to-peer Space metadata sync: core data model (HLC, canonical JSON,
// LWW registers, validation, replica, host binding). Port of wooloo-win's
// crates/wooloo-sync (docs/sync-protocol.md). Pure Swift, no UI, no I/O.

enum PeerSync {
    static let proto = 1
    static let format = 1
    static let maxFutureMs: UInt64 = 600_000
    static let spacePrefix = "space:"
    static let unitcatPrefix = "unitcat:"
}

enum PeerSyncError: Error, Equatable, CustomStringConvertible {
    case io(String)
    case invalid(String)
    case `protocol`(String)
    case remote(String)
    case busy

    var description: String {
        switch self {
        case .io(let m): return "i/o error: \(m)"
        case .invalid(let m): return "invalid: \(m)"
        case .protocol(let m): return "protocol error: \(m)"
        case .remote(let m): return "peer error: \(m)"
        case .busy: return "sync state is busy"
        }
    }
}

// MARK: - Byte-order helpers (Swift String ordering/equality is not byte order)

func utf8Less(_ a: String, _ b: String) -> Bool {
    Array(a.utf8).lexicographicallyPrecedes(Array(b.utf8))
}

func utf8Compare(_ a: String, _ b: String) -> Int {
    let x = Array(a.utf8), y = Array(b.utf8)
    if x == y { return 0 }
    return x.lexicographicallyPrecedes(y) ? -1 : 1
}

func utf8Equal(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }

// MARK: - JSON value

indirect enum JSONValue: Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([(String, JSONValue)])

    static func == (l: JSONValue, r: JSONValue) -> Bool {
        PeerSyncJSON.canonical(l) == PeerSyncJSON.canonical(r)
    }

    var isNull: Bool { if case .null = self { return true }; return false }
    var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    var isNumber: Bool {
        switch self {
        case .int: return true
        case .double(let d): return d.isFinite
        default: return false
        }
    }
    var objectValue: [(String, JSONValue)]? { if case .object(let o) = self { return o }; return nil }
    var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }

    subscript(member: String) -> JSONValue? {
        guard case .object(let o) = self else { return nil }
        // Last duplicate wins, like serde_json's map.
        return o.last(where: { utf8Equal($0.0, member) })?.1
    }

    var uint64Value: UInt64? {
        switch self {
        case .int(let i): return i >= 0 ? UInt64(i) : nil
        case .double(let d):
            if d >= 0, d < 18446744073709551616.0, d == d.rounded() { return UInt64(d) }
            return nil
        default: return nil
        }
    }
}

enum PeerSyncJSON {
    // MARK: canonical writer

    static func canonical(_ v: JSONValue) -> String {
        var out = ""
        write(v, into: &out, sorted: true)
        return out
    }

    /// Compact (non-sorted) writer used on the wire; object members keep insertion order.
    static func compact(_ v: JSONValue) -> String {
        var out = ""
        write(v, into: &out, sorted: false)
        return out
    }

    private static func write(_ v: JSONValue, into out: inout String, sorted: Bool) {
        switch v {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .int(let i): out += String(i)
        case .double(let d): out += formatDouble(d)
        case .string(let s): writeString(s, into: &out)
        case .array(let a):
            out += "["
            for (i, e) in a.enumerated() {
                if i > 0 { out += "," }
                write(e, into: &out, sorted: sorted)
            }
            out += "]"
        case .object(let o):
            let members = sorted ? o.sorted(by: { utf8Less($0.0, $1.0) }) : o
            out += "{"
            for (i, m) in members.enumerated() {
                if i > 0 { out += "," }
                writeString(m.0, into: &out)
                out += ":"
                write(m.1, into: &out, sorted: sorted)
            }
            out += "}"
        }
    }

    static func writeString(_ s: String, into out: inout String) {
        out += "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if u.value < 0x20 {
                    let hex = String(u.value, radix: 16)
                    out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        out += "\""
    }

    /// Shortest round-trip, serde_json/ryu style: no "+" and no leading zeros in exponents.
    static func formatDouble(_ d: Double) -> String {
        var s = d.description  // shortest round-trip
        guard let e = s.firstIndex(where: { $0 == "e" || $0 == "E" }) else { return s }
        let mant = String(s[s.startIndex..<e])
        var exp = String(s[s.index(after: e)...])
        var neg = false
        if exp.hasPrefix("+") { exp.removeFirst() } else if exp.hasPrefix("-") { neg = true; exp.removeFirst() }
        while exp.count > 1 && exp.hasPrefix("0") { exp.removeFirst() }
        s = mant + "e" + (neg ? "-" : "") + exp
        return s
    }

    // MARK: parser

    struct ParseError: Error { let msg: String }

    static func parse(_ text: String) throws -> JSONValue {
        var p = Parser(bytes: Array(text.utf8))
        p.skipWS()
        let v = try p.value(depth: 0)
        p.skipWS()
        if p.i != p.b.count { throw ParseError(msg: "trailing characters") }
        return v
    }

    private struct Parser {
        let b: [UInt8]
        var i = 0
        init(bytes: [UInt8]) { b = bytes }

        mutating func skipWS() {
            while i < b.count, b[i] == 0x20 || b[i] == 0x0A || b[i] == 0x0D || b[i] == 0x09 { i += 1 }
        }

        func err(_ m: String) -> ParseError { ParseError(msg: m) }

        mutating func value(depth: Int) throws -> JSONValue {
            if depth > 128 { throw err("too deep") }
            guard i < b.count else { throw err("unexpected end") }
            switch b[i] {
            case UInt8(ascii: "n"): try lit("null"); return .null
            case UInt8(ascii: "t"): try lit("true"); return .bool(true)
            case UInt8(ascii: "f"): try lit("false"); return .bool(false)
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "["):
                i += 1
                var arr: [JSONValue] = []
                skipWS()
                if i < b.count, b[i] == UInt8(ascii: "]") { i += 1; return .array(arr) }
                while true {
                    skipWS()
                    arr.append(try value(depth: depth + 1))
                    skipWS()
                    guard i < b.count else { throw err("unterminated array") }
                    if b[i] == UInt8(ascii: ",") { i += 1; continue }
                    if b[i] == UInt8(ascii: "]") { i += 1; return .array(arr) }
                    throw err("bad array")
                }
            case UInt8(ascii: "{"):
                i += 1
                var obj: [(String, JSONValue)] = []
                skipWS()
                if i < b.count, b[i] == UInt8(ascii: "}") { i += 1; return .object(obj) }
                while true {
                    skipWS()
                    guard i < b.count, b[i] == UInt8(ascii: "\"") else { throw err("expected key") }
                    let k = try string()
                    skipWS()
                    guard i < b.count, b[i] == UInt8(ascii: ":") else { throw err("expected colon") }
                    i += 1
                    skipWS()
                    let v = try value(depth: depth + 1)
                    // duplicate keys: last wins
                    if let idx = obj.firstIndex(where: { utf8Equal($0.0, k) }) { obj[idx] = (k, v) } else { obj.append((k, v)) }
                    skipWS()
                    guard i < b.count else { throw err("unterminated object") }
                    if b[i] == UInt8(ascii: ",") { i += 1; continue }
                    if b[i] == UInt8(ascii: "}") { i += 1; return .object(obj) }
                    throw err("bad object")
                }
            default: return try number()
            }
        }

        mutating func lit(_ s: String) throws {
            let u = Array(s.utf8)
            guard i + u.count <= b.count, Array(b[i..<i + u.count]) == u else { throw err("bad literal") }
            i += u.count
        }

        mutating func number() throws -> JSONValue {
            let start = i
            var isInt = true
            if i < b.count, b[i] == UInt8(ascii: "-") { i += 1 }
            guard i < b.count, b[i] >= 0x30, b[i] <= 0x39 else { throw err("bad number") }
            if b[i] == 0x30 { i += 1 } else { while i < b.count, b[i] >= 0x30, b[i] <= 0x39 { i += 1 } }
            if i < b.count, b[i] == UInt8(ascii: ".") {
                isInt = false
                i += 1
                guard i < b.count, b[i] >= 0x30, b[i] <= 0x39 else { throw err("bad fraction") }
                while i < b.count, b[i] >= 0x30, b[i] <= 0x39 { i += 1 }
            }
            if i < b.count, b[i] == UInt8(ascii: "e") || b[i] == UInt8(ascii: "E") {
                isInt = false
                i += 1
                if i < b.count, b[i] == UInt8(ascii: "+") || b[i] == UInt8(ascii: "-") { i += 1 }
                guard i < b.count, b[i] >= 0x30, b[i] <= 0x39 else { throw err("bad exponent") }
                while i < b.count, b[i] >= 0x30, b[i] <= 0x39 { i += 1 }
            }
            let lex = String(decoding: b[start..<i], as: UTF8.self)
            if isInt, let n = Int64(lex) { return .int(n) }
            guard let d = Double(lex), d.isFinite else { throw err("number out of range") }
            return .double(d)
        }

        mutating func hex4() throws -> UInt32 {
            guard i + 4 <= b.count else { throw err("bad \\u escape") }
            var v: UInt32 = 0
            for _ in 0..<4 {
                let c = b[i]
                var d: UInt32
                switch c {
                case 0x30...0x39: d = UInt32(c - 0x30)
                case 0x61...0x66: d = UInt32(c - 0x61 + 10)
                case 0x41...0x46: d = UInt32(c - 0x41 + 10)
                default: throw err("bad \\u escape")
                }
                v = v * 16 + d
                i += 1
            }
            return v
        }

        mutating func string() throws -> String {
            i += 1  // opening quote
            var out = [UInt8]()
            while true {
                guard i < b.count else { throw err("unterminated string") }
                let c = b[i]
                if c == UInt8(ascii: "\"") { i += 1; break }
                if c < 0x20 { throw err("control character in string") }
                if c != UInt8(ascii: "\\") { out.append(c); i += 1; continue }
                i += 1
                guard i < b.count else { throw err("bad escape") }
                let e = b[i]
                i += 1
                switch e {
                case UInt8(ascii: "\""): out.append(0x22)
                case UInt8(ascii: "\\"): out.append(0x5C)
                case UInt8(ascii: "/"): out.append(0x2F)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"):
                    var cp = try hex4()
                    if (0xD800...0xDBFF).contains(cp) {
                        guard i + 1 < b.count, b[i] == UInt8(ascii: "\\"), b[i + 1] == UInt8(ascii: "u") else { throw err("lone surrogate") }
                        i += 2
                        let lo = try hex4()
                        guard (0xDC00...0xDFFF).contains(lo) else { throw err("lone surrogate") }
                        cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
                    } else if (0xDC00...0xDFFF).contains(cp) {
                        throw err("lone surrogate")
                    }
                    guard let u = Unicode.Scalar(cp) else { throw err("bad scalar") }
                    out.append(contentsOf: Array(String(Character(u)).utf8))
                default: throw err("bad escape")
                }
            }
            return String(decoding: out, as: UTF8.self)
        }
    }
}

// MARK: - HLC

struct Hlc: Equatable, Comparable {
    var wall: UInt64
    var counter: UInt64
    static let zero = Hlc(wall: 0, counter: 0)

    static func < (a: Hlc, b: Hlc) -> Bool {
        a.wall != b.wall ? a.wall < b.wall : a.counter < b.counter
    }

    mutating func tick(now: UInt64) -> Hlc {
        if now > wall {
            self = Hlc(wall: now, counter: 0)
        } else {
            let (c, o) = counter.addingReportingOverflow(1)
            self.counter = o ? UInt64.max : c
        }
        return self
    }

    mutating func observe(_ r: Hlc) {
        if r > self { self = r }
    }

    static func from(json v: JSONValue) -> Hlc? {
        guard let w = v["wall"]?.uint64Value, let c = v["counter"]?.uint64Value else { return nil }
        return Hlc(wall: w, counter: c)
    }

    var json: JSONValue {
        .object([("wall", .int(Int64(clamping: wall))), ("counter", .int(Int64(clamping: counter)))])
    }
}

// MARK: - Validation (allow-list, section 4)

enum PeerSyncValidate {
    enum KeyKind { case space, unitcat }

    static let spaceFields = ["name", "category", "color", "order", "notes", "pinned_tabs", "host", "herdr_id", "deleted"]

    static func isControl(_ u: Unicode.Scalar) -> Bool { u.value < 0x20 || u.value == 0x7F }

    static func isText(_ s: String, _ lo: Int, _ hi: Int) -> Bool {
        var n = 0
        for u in s.unicodeScalars {
            if isControl(u) { return false }
            n += 1
            if n > hi { return false }
        }
        return n >= lo
    }

    private static func valueIsText(_ v: JSONValue, _ lo: Int, _ hi: Int) -> Bool {
        if case .string(let s) = v { return isText(s, lo, hi) }
        return false
    }

    private static func nullOrText(_ v: JSONValue, _ lo: Int, _ hi: Int) -> Bool {
        v.isNull || valueIsText(v, lo, hi)
    }

    static func isNodeId(_ s: String) -> Bool {
        let b = Array(s.utf8)
        return (1...64).contains(b.count) && b.allSatisfy { ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2D }
    }

    static func isHerdrId(_ s: String) -> Bool {
        let b = Array(s.utf8)
        return (1...64).contains(b.count) && b.allSatisfy {
            ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x30 && $0 <= 0x39)
                || $0 == 0x5F || $0 == 0x2E || $0 == 0x3A || $0 == 0x2D
        }
    }

    private static func isLowerHex(_ c: UInt8) -> Bool { (c >= 0x30 && c <= 0x39) || (c >= 0x61 && c <= 0x66) }

    static func isUUID(_ s: String) -> Bool {
        let b = Array(s.utf8)
        guard b.count == 36 else { return false }
        for (i, c) in b.enumerated() {
            if i == 8 || i == 13 || i == 18 || i == 23 { if c != 0x2D { return false } } else if !isLowerHex(c) { return false }
        }
        return true
    }

    static func isColor(_ s: String) -> Bool {
        let b = Array(s.utf8)
        return b.count == 7 && b[0] == 0x23 && b[1...].allSatisfy(isLowerHex)
    }

    static func isNotes(_ s: String) -> Bool {
        s.utf8.count <= 65_536 && !s.unicodeScalars.contains { isControl($0) && $0 != "\n" && $0 != "\r" && $0 != "\t" }
    }

    static func hasPrefix(_ s: String, _ p: String) -> String? {
        let b = Array(s.utf8), pb = Array(p.utf8)
        guard b.count >= pb.count, Array(b[0..<pb.count]) == pb else { return nil }
        return String(decoding: b[pb.count...], as: UTF8.self)
    }

    static func keyKind(_ key: String) -> KeyKind? {
        if let rest = hasPrefix(key, PeerSync.spacePrefix), isUUID(rest) { return .space }
        if let rest = hasPrefix(key, PeerSync.unitcatPrefix), isText(rest, 1, 200) { return .unitcat }
        return nil
    }

    static func validValue(_ kind: KeyKind, field: String, value: JSONValue) -> Bool {
        switch kind {
        case .space:
            switch field {
            case "name": return valueIsText(value, 1, 200)
            case "category": return nullOrText(value, 1, 64)
            case "color":
                if value.isNull { return true }
                if case .string(let s) = value { return isColor(s) }
                return false
            case "order": return value.isNumber
            case "notes":
                if value.isNull { return true }
                if case .string(let s) = value { return isNotes(s) }
                return false
            case "pinned_tabs":
                if value.isNull { return true }
                if case .array(let items) = value { return items.count <= 64 && items.allSatisfy { valueIsText($0, 1, 200) } }
                return false
            case "host":
                if case .string(let s) = value { return isNodeId(s) }
                return false
            case "herdr_id":
                if case .string(let s) = value { return isHerdrId(s) }
                return false
            case "deleted": return value.boolValue != nil
            default: return false
            }
        case .unitcat:
            return field == "category" && nullOrText(value, 1, 64)
        }
    }

    static func validOp(key: String, field: String, value: JSONValue, node: String) -> Bool {
        guard let kind = keyKind(key) else { return false }
        return isNodeId(node) && validValue(kind, field: field, value: value)
    }
}

// MARK: - Register

struct Register: Equatable {
    var key: String
    var field: String
    var value: JSONValue
    var hlc: Hlc
    var node: String

    static func from(json v: JSONValue) -> Register? {
        guard case .object = v,
              let key = v["key"]?.stringValue,
              let field = v["field"]?.stringValue,
              let value = v["value"],
              let hlcJ = v["hlc"], let hlc = Hlc.from(json: hlcJ),
              let node = v["node"]?.stringValue
        else { return nil }
        return Register(key: key, field: field, value: value, hlc: hlc, node: node)
    }

    var json: JSONValue {
        .object([("key", .string(key)), ("field", .string(field)), ("value", value), ("hlc", hlc.json), ("node", .string(node))])
    }

    var wire: JSONValue {
        .object([("key", .string(key)), ("field", .string(field)), ("value", value), ("hlc", hlc.json), ("node", .string(node)), ("t", .string("op"))])
    }

    var isValid: Bool { PeerSyncValidate.validOp(key: key, field: field, value: value, node: node) }

    /// Negative: self loses; zero: identical; positive: self wins.
    func lwwCompare(_ o: Register) -> Int {
        if hlc != o.hlc { return hlc < o.hlc ? -1 : 1 }
        let n = utf8Compare(node, o.node)
        if n != 0 { return n }
        return utf8Compare(PeerSyncJSON.canonical(value), PeerSyncJSON.canonical(o.value))
    }

    func same(_ o: Register) -> Bool {
        utf8Equal(key, o.key) && utf8Equal(field, o.field) && hlc == o.hlc && utf8Equal(node, o.node)
            && utf8Equal(PeerSyncJSON.canonical(value), PeerSyncJSON.canonical(o.value))
    }

    fileprivate var pair: RegKey { RegKey(key: key, field: field) }
}

/// Dictionary key compared by UTF-8 bytes (no Unicode canonical equivalence).
struct RegKey: Hashable, Comparable {
    let k: [UInt8]
    let f: [UInt8]
    init(key: String, field: String) { k = Array(key.utf8); f = Array(field.utf8) }
    static func < (a: RegKey, b: RegKey) -> Bool {
        a.k != b.k ? a.k.lexicographicallyPrecedes(b.k) : a.f.lexicographicallyPrecedes(b.f)
    }
}

enum Rejection { case invalid, future }

enum Outcome: Equatable {
    case stored, duplicate, ignored
    case rejected(Rejection)
    var isRejected: Bool { if case .rejected = self { return true }; return false }
}

struct Absorbed {
    var accepted: UInt64
    var rejected: UInt64
    var reply: [Register]
}

enum BindKind: String { case bound, rebound, minted }

struct Binding: Equatable {
    var herdrId: String
    var label: String
    var kind: BindKind
    var space: String?
}

struct BindPlan: Equatable {
    var bindings: [Binding]
    var orphans: [String]
}

// MARK: - Replica

struct Replica {
    var node: String
    var clock: Hlc = .zero
    private var regs: [RegKey: Register] = [:]

    init(node: String) { self.node = node }

    private static func spaceKey(_ uuid: String) -> String { PeerSync.spacePrefix + uuid }

    mutating func apply(_ op: Register, now: UInt64) -> Outcome {
        if !op.isValid { return .rejected(.invalid) }
        let (limit, o) = now.addingReportingOverflow(PeerSync.maxFutureMs)
        if op.hlc.wall > (o ? UInt64.max : limit) { return .rejected(.future) }
        clock.observe(op.hlc)
        let p = op.pair
        guard let cur = regs[p] else { regs[p] = op; return .stored }
        let c = op.lwwCompare(cur)
        if c > 0 { regs[p] = op; return .stored }
        return c == 0 ? .duplicate : .ignored
    }

    @discardableResult
    mutating func set(key: String, field: String, value: JSONValue, now: UInt64) throws -> Register {
        guard PeerSyncValidate.validOp(key: key, field: field, value: value, node: node) else {
            throw PeerSyncError.invalid("value not allowed for \(key) \(field)")
        }
        let h = clock.tick(now: now)
        let op = Register(key: key, field: field, value: value, hlc: h, node: node)
        regs[op.pair] = op
        return op
    }

    mutating func insertRaw(_ r: Register) {
        clock.observe(r.hlc)
        regs[r.pair] = r
    }

    func get(_ key: String, _ field: String) -> Register? { regs[RegKey(key: key, field: field)] }
    func val(_ key: String, _ field: String) -> JSONValue { get(key, field)?.value ?? .null }

    func sortedRegs() -> [Register] {
        regs.keys.sorted().compactMap { regs[$0] }
    }

    var count: Int { regs.count }
    var isEmpty: Bool { regs.isEmpty }

    private func spaceUUIDs() -> [String] {
        var seen = Set<[UInt8]>()
        var out: [String] = []
        for k in regs.keys.sorted() {
            let key = String(decoding: k.k, as: UTF8.self)
            if let u = PeerSyncValidate.hasPrefix(key, PeerSync.spacePrefix), seen.insert(Array(u.utf8)).inserted { out.append(u) }
        }
        return out
    }

    func allSpaces() -> [String] { spaceUUIDs() }

    func isDeleted(_ uuid: String) -> Bool { val(Replica.spaceKey(uuid), "deleted").boolValue == true }

    func liveSpaces() -> [String] { spaceUUIDs().filter { !isDeleted($0) } }

    func lookup(host: String, herdrId: String) -> String? {
        liveSpaces().first {
            let k = Replica.spaceKey($0)
            return val(k, "host").stringValue.map { utf8Equal($0, host) } == true
                && val(k, "herdr_id").stringValue.map { utf8Equal($0, herdrId) } == true
        }
    }

    mutating func mintSpace(herdrId: String, name: String, now: UInt64) throws -> String {
        guard PeerSyncValidate.isHerdrId(herdrId), PeerSyncValidate.isText(name, 1, 200) else {
            throw PeerSyncError.invalid("workspace id or name not allowed")
        }
        var uuid: String
        repeat { uuid = UUID().uuidString.lowercased() } while spaceUUIDs().contains(uuid)
        let key = Replica.spaceKey(uuid)
        try set(key: key, field: "host", value: .string(node), now: now)
        try set(key: key, field: "herdr_id", value: .string(herdrId), now: now)
        try set(key: key, field: "name", value: .string(name), now: now)
        return uuid
    }

    mutating func deleteSpace(_ uuid: String, now: UInt64) throws {
        let key = Replica.spaceKey(uuid)
        try set(key: key, field: "deleted", value: .bool(true), now: now)
        try set(key: key, field: "notes", value: .null, now: now)
        try set(key: key, field: "pinned_tabs", value: .null, now: now)
    }

    mutating func restoreSpace(_ uuid: String, now: UInt64) throws {
        try set(key: Replica.spaceKey(uuid), field: "deleted", value: .bool(false), now: now)
    }

    /// Non-null `unitcat:*` categories, by name (sorted by UTF-8 bytes).
    func unitcats() -> [(String, String)] {
        var out: [(String, String)] = []
        for k in regs.keys.sorted() where utf8Equal(String(decoding: k.f, as: UTF8.self), "category") {
            let key = String(decoding: k.k, as: UTF8.self)
            if let name = PeerSyncValidate.hasPrefix(key, PeerSync.unitcatPrefix), case .string(let s)? = regs[k]?.value {
                out.append((name, s))
            }
        }
        return out
    }

    func planBinding(_ workspaces: [(id: String, label: String)]) -> BindPlan {
        let me = node
        let live = liveSpaces().filter { val(Replica.spaceKey($0), "host").stringValue.map { utf8Equal($0, me) } == true }
        let ids = Set(workspaces.map { Array($0.id.utf8) })
        var used = Set<String>()
        var bound: [Int: (BindKind, String)] = [:]

        for (i, w) in workspaces.enumerated() {
            if let u = live.first(where: {
                !used.contains($0) && val(Replica.spaceKey($0), "herdr_id").stringValue.map { utf8Equal($0, w.id) } == true
            }) {
                used.insert(u)
                bound[i] = (.bound, u)
            }
        }
        for (i, w) in workspaces.enumerated() where bound[i] == nil {
            if let u = live.first(where: {
                let k = Replica.spaceKey($0)
                let stale: Bool
                if let h = val(k, "herdr_id").stringValue { stale = !ids.contains(Array(h.utf8)) } else { stale = true }
                return !used.contains($0) && stale && val(k, "name").stringValue.map { utf8Equal($0, w.label) } == true
            }) {
                used.insert(u)
                bound[i] = (.rebound, u)
            }
        }
        let bindings = workspaces.enumerated().map { (i, w) -> Binding in
            if let (kind, u) = bound[i] { return Binding(herdrId: w.id, label: w.label, kind: kind, space: u) }
            return Binding(herdrId: w.id, label: w.label, kind: .minted, space: nil)
        }
        return BindPlan(bindings: bindings, orphans: live.filter { !used.contains($0) })
    }

    mutating func bindHost(_ workspaces: [(id: String, label: String)], now: UInt64) throws -> BindPlan {
        var plan = planBinding(workspaces)
        for i in plan.bindings.indices {
            let b = plan.bindings[i]
            switch b.kind {
            case .bound: break
            case .rebound:
                try set(key: Replica.spaceKey(b.space ?? ""), field: "herdr_id", value: .string(b.herdrId), now: now)
            case .minted:
                plan.bindings[i].space = try mintSpace(herdrId: b.herdrId, name: b.label, now: now)
            }
        }
        return plan
    }

    mutating func absorb(_ received: [Register], malformed: UInt64, now: UInt64) -> Absorbed {
        var accepted: UInt64 = 0
        var rejected = malformed
        var got: [RegKey: Register] = [:]
        for op in received {
            got[op.pair] = op
            if apply(op, now: now).isRejected { rejected += 1 } else { accepted += 1 }
        }
        let reply = regs.keys.sorted().compactMap { k -> Register? in
            guard let r = regs[k] else { return nil }
            if let g = got[k], g.same(r) { return nil }
            return r
        }
        return Absorbed(accepted: accepted, rejected: rejected, reply: reply)
    }
}
