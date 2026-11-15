import Foundation

// Persistent sync state (~/.config/wooloo-sync/state.json), its lock, the
// unit-state category file bridge and thin Space-metadata adapters.

/// Everything persisted for this machine.
struct PeerSyncState {
    var node: String
    var replica: PeerSyncReplica
    var unitcatSnapshot: [(String, String)] = []

    static func fresh() -> PeerSyncState {
        let hex = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(8)
        let node = "mac-\(hex)"
        return PeerSyncState(node: node, replica: PeerSyncReplica(node: node))
    }
}

final class PeerSyncStore {
    let path: URL
    private var lockPath: URL { URL(fileURLWithPath: path.path + ".lock") }
    private var ownsLock = false

    init(path: URL = PeerSyncStore.defaultPath()) { self.path = path }

    static func defaultPath() -> URL {
        let env = ProcessInfo.processInfo.environment
        if let p = env["WOOLOO_SYNC_STATE"], !p.isEmpty { return URL(fileURLWithPath: p) }
        let home = env["HOME"] ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appendingPathComponent(".config/wooloo-sync/state.json")
    }

    // MARK: load / save

    func load() throws -> PeerSyncState {
        let data: Data
        do { data = try Data(contentsOf: path) } catch {
            let ns = error as NSError
            if ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadNoSuchFileError { return .fresh() }
            if !FileManager.default.fileExists(atPath: path.path) { return .fresh() }
            throw PeerSyncError.io("\(error)")
        }
        let root: PeerSyncJSONValue
        do { root = try PeerSyncJSON.parse(String(decoding: data, as: UTF8.self)) } catch {
            throw PeerSyncError.invalid("state file is not valid JSON")
        }
        guard case .int(let fmt)? = root["format"], fmt == Int64(PeerSync.format) else {
            throw PeerSyncError.invalid("unsupported state format")
        }
        guard let node = root["node"]?.stringValue, PeerSyncValidate.isNodeId(node) else {
            throw PeerSyncError.invalid("bad node id in state")
        }
        var replica = PeerSyncReplica(node: node)
        if let c = root["clock"], let h = PeerSyncHlc.from(json: c) { replica.clock = h }
        if let items = root["registers"]?.arrayValue {
            for item in items {
                guard let r = PeerSyncRegister.from(json: item), r.isValid else { continue }
                if let cur = replica.get(r.key, r.field), r.lwwCompare(cur) <= 0 { continue }
                replica.insertRaw(r)
            }
        }
        var snap: [(String, String)] = []
        if let m = root["local"]?["unitcat_snapshot"]?.objectValue {
            for (k, v) in m { if let s = v.stringValue { snap.append((k, s)) } }
            snap.sort { utf8Less($0.0, $1.0) }
        }
        return PeerSyncState(node: node, replica: replica, unitcatSnapshot: snap)
    }

    func save(_ s: PeerSyncState) throws {
        let snap: [(String, PeerSyncJSONValue)] = s.unitcatSnapshot.map { ($0.0, .string($0.1)) }
        let root: PeerSyncJSONValue = .object([
            ("format", .int(Int64(PeerSync.format))),
            ("node", .string(s.node)),
            ("clock", s.replica.clock.json),
            ("registers", .array(s.replica.sortedRegs().map { $0.json })),
            ("local", .object([("unitcat_snapshot", .object(snap))])),
        ])
        let text = PeerSyncJSON.canonical(root) + "\n"
        try PeerSyncStore.atomicWrite(Data(text.utf8), to: path)
    }

    static func atomicWrite(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let tmp = URL(fileURLWithPath: url.path + ".tmp")
            try data.write(to: tmp)
            if rename(tmp.path, url.path) != 0 {
                throw PeerSyncError.io("rename failed (errno \(errno))")
            }
        } catch let e as PeerSyncError {
            throw e
        } catch {
            throw PeerSyncError.io("\(error)")
        }
    }

    // MARK: lock

    /// Create-exclusive lock file holding our pid. Stale after 30 s; waits up to 10 s.
    func lock() throws {
        let fm = FileManager.default
        try? fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let deadline = Date().addingTimeInterval(10)
        while true {
            let fd = open(lockPath.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            if fd >= 0 {
                let pid = "\(ProcessInfo.processInfo.processIdentifier)\n"
                _ = pid.withCString { write(fd, $0, strlen($0)) }
                close(fd)
                ownsLock = true
                return
            }
            if errno != EEXIST { throw PeerSyncError.io("lock: errno \(errno)") }
            if let attrs = try? fm.attributesOfItem(atPath: lockPath.path),
               let m = attrs[.modificationDate] as? Date, Date().timeIntervalSince(m) > 30 {
                try? fm.removeItem(at: lockPath)
                continue
            }
            if Date() >= deadline { throw PeerSyncError.busy }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    func unlock() {
        guard ownsLock else { return }
        ownsLock = false
        try? FileManager.default.removeItem(at: lockPath)
    }

    /// Load, run `body` (which may mutate and returns a value), save, all under the lock.
    func withState<T>(_ body: (inout PeerSyncState) throws -> T) throws -> T {
        try lock()
        defer { unlock() }
        var s = try load()
        let out = try body(&s)
        try save(s)
        return out
    }
}

// MARK: - Unit-state categories (~/.local/state/unit-space-categories.json)

enum PeerSyncUnitCats {
    static func defaultPath() -> URL {
        let env = ProcessInfo.processInfo.environment
        if let p = env["WOOLOO_SYNC_UNITCAT"], !p.isEmpty { return URL(fileURLWithPath: p) }
        let home = env["HOME"] ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appendingPathComponent(".local/state/unit-space-categories.json")
    }

    /// Parsed object members, or nil when the file is missing, unreadable or not an object.
    static func readFile(_ url: URL) -> [(String, PeerSyncJSONValue)]? {
        guard let data = try? Data(contentsOf: url),
              let v = try? PeerSyncJSON.parse(String(decoding: data, as: UTF8.self)),
              case .object(let o) = v else { return nil }
        return o
    }

    static func clean(_ members: [(String, PeerSyncJSONValue)]) -> [(String, String)] {
        var map: [String: String] = [:]
        var order: [String] = []
        for (k, v) in members {
            guard PeerSyncValidate.isText(k, 1, 200), case .string(let s) = v, PeerSyncValidate.isText(s, 1, 64) else { continue }
            if map[k] == nil { order.append(k) }
            map[k] = s
        }
        return order.sorted(by: utf8Less).map { ($0, map[$0] ?? "") }
    }

    /// Changes between a snapshot and the cleaned file: (name, newValue or nil when removed), by name.
    static func diff(snapshot: [(String, String)], file: [(String, String)]) -> [(String, String?)] {
        let old = Dictionary(snapshot.map { ($0.0, $0.1) }, uniquingKeysWith: { _, b in b })
        let new = Dictionary(file.map { ($0.0, $0.1) }, uniquingKeysWith: { _, b in b })
        var out: [(String, String?)] = []
        for (k, v) in new where old[k] != v { out.append((k, v)) }
        for k in old.keys where new[k] == nil { out.append((k, nil)) }
        return out.sorted { utf8Less($0.0, $1.0) }
    }

    /// Import local edits to the unit file into the replica. Returns the number of changes.
    @discardableResult
    static func importFile(_ url: URL, into s: inout PeerSyncState, now: UInt64) throws -> Int {
        guard let members = readFile(url) else { return 0 }
        let cleaned = clean(members)
        let changes = diff(snapshot: s.unitcatSnapshot, file: cleaned)
        for (name, value) in changes {
            try s.replica.set(key: PeerSync.unitcatPrefix + name, field: "category",
                              value: value.map { .string($0) } ?? .null, now: now)
        }
        s.unitcatSnapshot = cleaned
        return changes.count
    }

    /// Python json.dumps(indent=1, sort_keys=True) of a flat string map, ASCII only, no trailing newline.
    static func fileText(_ m: [(String, String)]) -> String {
        if m.isEmpty { return "{}" }
        func esc(_ s: String) -> String {
            var o = "\""
            for u in s.unicodeScalars {
                switch u {
                case "\"": o += "\\\""
                case "\\": o += "\\\\"
                case "\n": o += "\\n"
                case "\r": o += "\\r"
                case "\t": o += "\\t"
                case "\u{08}": o += "\\b"
                case "\u{0C}": o += "\\f"
                default:
                    if u.value >= 0x20 && u.value < 0x7F { o.unicodeScalars.append(u) } else {
                        func u4(_ n: UInt32) -> String {
                            let h = String(n, radix: 16)
                            return "\\u" + String(repeating: "0", count: 4 - h.count) + h
                        }
                        if u.value >= 0x10000 {
                            let v = u.value - 0x10000
                            o += u4(0xD800 + (v >> 10)) + u4(0xDC00 + (v & 0x3FF))
                        } else {
                            o += u4(u.value)
                        }
                    }
                }
            }
            return o + "\""
        }
        let rows = m.sorted { utf8Less($0.0, $1.0) }.map { " \(esc($0.0)): \(esc($0.1))" }
        return "{\n" + rows.joined(separator: ",\n") + "\n}"
    }

    /// Write replica categories to the unit file. Returns true when the file was written.
    @discardableResult
    static func exportFile(_ url: URL, from s: inout PeerSyncState) throws -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.deletingLastPathComponent().path, isDirectory: &isDir), isDir.boolValue else { return false }
        let wanted = clean(s.replica.unitcats().map { ($0.0, PeerSyncJSONValue.string($0.1)) })
        if fm.fileExists(atPath: url.path) {
            guard let members = readFile(url) else { return false }
            let current = clean(members)
            if current.elementsEqual(wanted, by: { utf8Equal($0.0, $1.0) && utf8Equal($0.1, $1.1) }) {
                s.unitcatSnapshot = wanted
                return false
            }
        } else if wanted.isEmpty {
            return false
        }
        try PeerSyncStore.atomicWrite(Data(fileText(wanted).utf8), to: url)
        s.unitcatSnapshot = wanted
        return true
    }
}

// MARK: - Space adapters

/// Thin typed views over the registers of one synced Space.
struct PeerSyncSpaceView {
    var uuid: String
    var name: String?
    var category: String?
    var color: String?
    var order: Double?
    var notes: String?
}

extension PeerSyncReplica {
    func spaceView(_ uuid: String) -> PeerSyncSpaceView {
        let k = PeerSync.spacePrefix + uuid
        var order: Double?
        switch val(k, "order") {
        case .int(let i): order = Double(i)
        case .double(let d): order = d
        default: break
        }
        return PeerSyncSpaceView(uuid: uuid, name: val(k, "name").stringValue, category: val(k, "category").stringValue,
                                 color: val(k, "color").stringValue, order: order, notes: val(k, "notes").stringValue)
    }

    /// Live Spaces ordered by `order` (missing last), ties by uuid bytes.
    func orderedSpaces() -> [PeerSyncSpaceView] {
        liveSpaces().map { spaceView($0) }.sorted {
            switch ($0.order, $1.order) {
            case let (a?, b?) where a != b: return a < b
            case (_?, nil): return true
            case (nil, _?): return false
            default: return utf8Less($0.uuid, $1.uuid)
            }
        }
    }

    @discardableResult
    mutating func setSpaceName(_ uuid: String, _ name: String, now: UInt64) throws -> PeerSyncRegister {
        try set(key: PeerSync.spacePrefix + uuid, field: "name", value: .string(name), now: now)
    }

    @discardableResult
    mutating func setSpaceCategory(_ uuid: String, _ category: String?, now: UInt64) throws -> PeerSyncRegister {
        try set(key: PeerSync.spacePrefix + uuid, field: "category", value: category.map { .string($0) } ?? .null, now: now)
    }

    @discardableResult
    mutating func setSpaceColor(_ uuid: String, _ color: String?, now: UInt64) throws -> PeerSyncRegister {
        try set(key: PeerSync.spacePrefix + uuid, field: "color", value: color.map { .string($0) } ?? .null, now: now)
    }

    @discardableResult
    mutating func setSpaceOrder(_ uuid: String, _ order: Double, now: UInt64) throws -> PeerSyncRegister {
        let v: PeerSyncJSONValue = order == order.rounded() && abs(order) < 1e15 ? .int(Int64(order)) : .double(order)
        return try set(key: PeerSync.spacePrefix + uuid, field: "order", value: v, now: now)
    }

    @discardableResult
    mutating func setSpaceNotes(_ uuid: String, _ notes: String?, now: UInt64) throws -> PeerSyncRegister {
        try set(key: PeerSync.spacePrefix + uuid, field: "notes", value: notes.map { .string($0) } ?? .null, now: now)
    }
}
