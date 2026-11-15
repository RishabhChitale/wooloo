import Darwin
import Foundation

/// Where the other side reaches a machine: `user@host`, `host:port`, `[v6]:port` or a bare IPv6.
struct PeerPairingTarget: Equatable, Sendable {
    let user: String?
    let host: String
    let port: Int?

    init(_ text: String) throws {
        func fail() -> WorkspaceFileError {
            .message("Enter the target as user@host, optionally with :port (for example me@mac.tailnet.ts.net).")
        }
        guard (1...255).contains(text.utf8.count), !text.hasPrefix("-"),
              PeerPairing.matches(text, #"^[A-Za-z0-9._@:\[\]-]+$"#) else { throw fail() }
        let parts = text.split(separator: "@", omittingEmptySubsequences: false).map(String.init)
        guard parts.count <= 2 else { throw fail() }
        var rest = text
        if parts.count == 2 {
            guard !parts[0].hasPrefix("-"), PeerPairing.matches(parts[0], #"^[A-Za-z0-9._-]+$"#) else { throw fail() }
            user = parts[0]
            rest = parts[1]
        } else {
            user = nil
        }
        func parsePort(_ digits: Substring) throws -> Int {
            guard !digits.isEmpty, digits.count <= 5, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(digits), (1...65535).contains(value) else { throw fail() }
            return value
        }
        if rest.hasPrefix("[") {
            guard let close = rest.firstIndex(of: "]") else { throw fail() }
            host = String(rest[rest.index(after: rest.startIndex)..<close])
            let after = rest[rest.index(after: close)...]
            if after.isEmpty {
                port = nil
            } else {
                guard after.hasPrefix(":") else { throw fail() }
                port = try parsePort(after.dropFirst())
            }
            guard host.contains(":"), PeerPairing.matches(host, #"^[0-9A-Fa-f:.]+$"#) else { throw fail() }
        } else if rest.filter({ $0 == ":" }).count > 1 {
            host = rest
            port = nil
            guard PeerPairing.matches(host, #"^[0-9A-Fa-f:.]+$"#) else { throw fail() }
        } else if let colon = rest.firstIndex(of: ":") {
            host = String(rest[..<colon])
            port = try parsePort(rest[rest.index(after: colon)...])
        } else {
            host = rest
            port = nil
        }
        guard !host.isEmpty, !host.hasPrefix("-"), !host.contains("["), !host.contains("]") else { throw fail() }
    }
}

/// The text both machines show and paste: `wooloo-pair-v1:` + base64url(JSON, sorted keys, no padding).
/// Every way of making one validates it, so a code pasted from anywhere is safe to review.
struct PeerPairingCode: Codable, Equatable, Sendable {
    static let prefix = "wooloo-pair-v1:"

    let herdrVersion: String
    let hostKey: String
    let label: String
    let publicKey: String
    let session: String
    let target: String

    init(target: String, publicKey: String, hostKey: String, herdrVersion: String, session: String, label: String) throws {
        let target = target.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try PeerPairingTarget(target)
        guard PeerPairing.matches(herdrVersion, #"^[0-9A-Za-z.+-]{1,32}$"#) else {
            throw WorkspaceFileError.message("The pairing code has an invalid Herdr version.")
        }
        guard PeerPairing.isValidSession(session) else {
            throw WorkspaceFileError.message("The pairing code's session must use letters, digits, - or _ (at most 64).")
        }
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label.count <= 64,
              !label.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw WorkspaceFileError.message("The pairing code's name must be 1 to 64 characters on one line.")
        }
        self.target = target
        self.publicKey = try Self.normalized(publicKey, what: "device key")
        self.hostKey = try Self.normalized(hostKey, what: "host key")
        self.herdrVersion = herdrVersion
        self.session = session
        self.label = label
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(target: container.decode(String.self, forKey: .target),
                      publicKey: container.decode(String.self, forKey: .publicKey),
                      hostKey: container.decode(String.self, forKey: .hostKey),
                      herdrVersion: container.decode(String.self, forKey: .herdrVersion),
                      session: container.decode(String.self, forKey: .session),
                      label: container.decode(String.self, forKey: .label))
    }

    /// Accepts the code with surrounding or wrapped whitespace, as it comes out of chat apps.
    init(code text: String) throws {
        let compact = String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
        guard compact.hasPrefix(Self.prefix), compact.utf8.count <= 8192 else {
            throw WorkspaceFileError.message("Paste a code that starts with \(Self.prefix)")
        }
        var base64 = String(compact.dropFirst(Self.prefix.count))
            .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard !base64.contains("=") else { throw WorkspaceFileError.message("The pairing code is damaged.") }
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else {
            throw WorkspaceFileError.message("The pairing code is damaged.")
        }
        do {
            self = try JSONDecoder().decode(Self.self, from: data)
        } catch let error as WorkspaceFileError {
            throw error
        } catch {
            throw WorkspaceFileError.message("The pairing code is damaged or from a different wooloo version.")
        }
    }

    var code: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(self)) ?? Data()
        return Self.prefix + data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // swiftlint:disable:next force_try
    var endpoint: PeerPairingTarget { try! PeerPairingTarget(target) }

    var publicKeyFingerprint: String { RemoteAccessHostKeys.fingerprint(ofPublicKeyLine: publicKey) ?? "?" }
    var hostKeyFingerprint: String { RemoteAccessHostKeys.fingerprint(ofPublicKeyLine: hostKey) ?? "?" }

    /// The label lowercased to `[a-z0-9-]`, at most 32 characters; pairing the same name replaces its files.
    var peerID: String { PeerPairing.peerID(for: label) }

    private static func normalized(_ text: String, what: String) throws -> String {
        let key: MobileSSHPublicKey
        do { key = try MobileSSHPublicKey(text) } catch {
            throw WorkspaceFileError.message("The pairing code's \(what) is not a valid OpenSSH public key.")
        }
        return key.line.split(whereSeparator: { $0 == " " || $0 == "\t" }).prefix(2).joined(separator: " ")
    }
}

/// Mac side of peer pairing (docs/peer-pairing.md). Every function takes the home directory so
/// tests run in a temporary one; none of them ever reads a private key.
enum PeerPairing {
    static let deviceKeyName = "wooloo_peer_ed25519"
    static let hostKeyPath = "/etc/ssh/ssh_host_ed25519_key.pub"
    static let includeLine = "Include ~/.ssh/wooloo_peers/*.conf"

    static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    static func isValidSession(_ name: String) -> Bool { matches(name, #"^[A-Za-z0-9_-]{1,64}$"#) }

    static func peerID(for label: String) -> String {
        var id = ""
        for scalar in label.lowercased().unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                id.unicodeScalars.append(scalar)
            } else if !id.isEmpty, !id.hasSuffix("-") {
                id += "-"
            }
        }
        id = String(id.prefix(32))
        while id.hasSuffix("-") { id.removeLast() }
        return id.isEmpty ? "device" : id
    }

    static func alias(_ peerID: String) -> String { "wooloo-peer-" + peerID }
    static func sshDirectory(home: URL) -> URL { home.appendingPathComponent(".ssh", isDirectory: true) }
    static func peersDirectory(home: URL) -> URL { sshDirectory(home: home).appendingPathComponent("wooloo_peers", isDirectory: true) }
    static func dispatcherURL(home: URL) -> URL { home.appendingPathComponent(".local/share/wooloo/peer-bridge") }
    /// The space-free path the dispatcher runs as Herdr (a symbolic link to the real binary). The
    /// real path usually sits under "Application Support", which the forced command cannot hold safely.
    static func stableHerdrURL(home: URL) -> URL { home.appendingPathComponent(".local/share/wooloo/peer/herdr") }
    static func presenceDirectory(home: URL) -> URL { home.appendingPathComponent(".local/state/wooloo/peer-presence", isDirectory: true) }

    /// `<user>@<host name>`, for the user to replace with the Tailscale name; empty host if none is usable.
    static func defaultTarget(user: String = NSUserName(), hostName: String = ProcessInfo.processInfo.hostName) -> String {
        let target = user + "@" + hostName
        return (try? PeerPairingTarget(target)) == nil ? user + "@" : target
    }

    // MARK: This Mac's code

    /// Creates `~/.ssh/wooloo_peer_ed25519` without a passphrase when missing (Herdr connects
    /// with BatchMode) and returns only its public half.
    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
    static func deviceKey(home: URL, machineName: String) throws -> MobileSSHPublicKey {
        let directory = try ensureDirectory(sshDirectory(home: home))
        let key = directory.appendingPathComponent(deviceKeyName)
        let pub = directory.appendingPathComponent(deviceKeyName + ".pub")
        let manager = FileManager.default
        if !manager.fileExists(atPath: key.path), !manager.fileExists(atPath: pub.path) {
            let comment = "wooloo-peer@" + String(machineName.unicodeScalars.map {
                CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "-"
            })
            _ = try WorkspaceFiles.run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-C", comment, "-f", key.path],
                                       limit: 4096, label: "create peer device key")
        }
        guard manager.fileExists(atPath: pub.path) else {
            throw WorkspaceFileError.message("\(key.path) exists without its .pub file. Restore or remove it, then pair again.")
        }
        return try readPublicKey(pub)
    }

    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
    static func hostKey(path: String = hostKeyPath) throws -> MobileSSHPublicKey {
        do { return try readPublicKey(URL(fileURLWithPath: path)) } catch {
            throw WorkspaceFileError.message("Could not read this Mac's SSH host key (\(path)). Turn on Remote Login first.")
        }
    }

    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
    static func herdrVersion(executable: String) throws -> String {
        let output = try WorkspaceFiles.run(executable, ["--version"], limit: 4096, label: "herdr version")
        let version = String(decoding: output, as: UTF8.self)
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).last.map(String.init) ?? ""
        guard matches(version, #"^[0-9A-Za-z.+-]{1,32}$"#) else {
            throw WorkspaceFileError.message("Could not read Herdr's version.")
        }
        return version
    }

    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
    static func localCode(target: String, session: String, label: String, home: URL,
                          herdr: String, hostKeyPath: String = hostKeyPath) throws -> PeerPairingCode {
        let device = try deviceKey(home: home, machineName: label)
        return try PeerPairingCode(target: target, publicKey: device.line, hostKey: hostKey(path: hostKeyPath).line,
                                   herdrVersion: herdrVersion(executable: herdr), session: session, label: label)
    }

    // MARK: Pairing a peer

    struct Outcome: Sendable {
        var keyAlreadyAuthorized = false
        var includeAdded = false
    }

    /// Steps 1–4 of docs/peer-pairing.md. Herdr's `machine add` (step 5) runs afterwards through
    /// `HerdrConnectionCatalog.manage(machineArguments(for:))`.
    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
    static func pair(_ code: PeerPairingCode, home: URL, user: String = NSUserName(), herdr: String,
                     herdrVersion: String, addInclude: Bool) throws -> Outcome {
        let id = code.peerID
        let options = try authorizedKeyOptions(home: home.path, peerID: id)
        let stable = try refreshHerdrLink(home: home, herdr: herdr)
        try installDispatcher(home: home, herdr: stable, version: herdrVersion)
        var outcome = Outcome()
        outcome.keyAlreadyAuthorized = !(try authorize(code.publicKey + " " + alias(id), options: options, home: home, user: user))
        try writePeerFiles(code, home: home)
        if addInclude { outcome.includeAdded = try self.addInclude(home: home) }
        return outcome
    }

    static func machineArguments(for code: PeerPairingCode) -> [String] {
        ["add", alias(code.peerID), "--remote-session", code.session, "--label", code.label]
    }

    /// sshd does not unquote inside `command="…"`, so only paths without special characters are accepted.
    static func authorizedKeyOptions(home: String, peerID: String) throws -> String {
        guard matches(home, #"^/[A-Za-z0-9._/-]+$"#) else {
            throw WorkspaceFileError.message("The home folder path has characters a forced SSH command cannot hold safely.")
        }
        guard matches(peerID, #"^[A-Za-z0-9_-]{1,32}$"#) else { throw WorkspaceFileError.message("Invalid peer name.") }
        return #"command=""# + home + "/.local/share/wooloo/peer-bridge --peer " + peerID + #"",restrict"#
    }

    /// Points `~/.local/share/wooloo/peer/herdr` at `herdr` (absolute, executable) and returns that
    /// stable path. Idempotent; a changed target is swapped with an atomic rename, never a gap.
    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
    @discardableResult
    static func refreshHerdrLink(home: URL, herdr: String) throws -> String {
        guard herdr.hasPrefix("/"), !herdr.unicodeScalars.contains(where: { $0.value < 0x20 }),
              FileManager.default.isExecutableFile(atPath: herdr) else {
            throw WorkspaceFileError.message("Herdr was not found at \(herdr).")
        }
        let link = stableHerdrURL(home: home)
        let directory = try ensureDirectory(link.deletingLastPathComponent())
        let manager = FileManager.default
        if (try? manager.destinationOfSymbolicLink(atPath: link.path)) == herdr { return link.path }
        let temporary = directory.appendingPathComponent(".herdr.\(UUID().uuidString)")
        guard symlink(herdr, temporary.path) == 0 else { throw WorkspaceFileError.message("Could not create \(link.path).") }
        guard rename(temporary.path, link.path) == 0 else {
            try? manager.removeItem(at: temporary)
            throw WorkspaceFileError.message("Could not replace \(link.path).")
        }
        return link.path
    }

    /// At launch: when this Mac is already paired, re-point the link at the current Herdr (it moves
    /// when Herdr updates). The dispatcher text never changes, so pairings stay valid.
    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
    static func refreshHerdrLinkIfPaired(home: URL, herdr: String?) {
        guard let herdr, FileManager.default.fileExists(atPath: dispatcherURL(home: home).path) else { return }
        _ = try? refreshHerdrLink(home: home, herdr: herdr)
    }

    static func dispatcherScript(herdr: String, version: String) -> String {
        "#!/bin/sh\npeer_herdr=" + WorkspaceFiles.quote(herdr) + "\npeer_version=" + WorkspaceFiles.quote(version)
            + "\n" + dispatcherBody + "\n"
    }

    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
    static func installDispatcher(home: URL, herdr: String, version: String) throws {
        guard matches(herdr, #"^/[A-Za-z0-9._/-]+$"#) else {
            throw WorkspaceFileError.message("Herdr's path (\(herdr)) has characters the peer bridge cannot hold safely.")
        }
        guard matches(version, #"^[0-9A-Za-z.+-]{1,32}$"#) else { throw WorkspaceFileError.message("Invalid Herdr version.") }
        let url = dispatcherURL(home: home)
        let directory = try ensureDirectory(url.deletingLastPathComponent())
        try writeAtomically(Data(dispatcherScript(herdr: herdr, version: version).utf8),
                            to: directory.appendingPathComponent(url.lastPathComponent), mode: 0o700)
    }

    /// Adds the key with `options` through MobileSSHAccess's locked, atomic installer. False when
    /// the key was already present, in which case its existing entry was left unchanged.
    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
    static func authorize(_ keyLine: String, options: String, home: URL, user: String) throws -> Bool {
        let script = MobileSSHAccess.installationScript(homeDirectory: home.path, user: user, options: options)
        let data = try WorkspaceFiles.run("/bin/sh", ["-c", script], input: Data((keyLine + "\n").utf8), limit: 4096,
                                          label: "authorize peer SSH key")
        switch String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) {
        case "added": return true
        case "exists": return false
        default: throw WorkspaceFileError.message("authorized_keys was not confirmed. Check it before pairing again.")
        }
    }

    static func knownHostsLine(_ code: PeerPairingCode) -> String { alias(code.peerID) + " " + code.hostKey + "\n" }

    static func configBlock(_ code: PeerPairingCode) -> String {
        let id = code.peerID
        let endpoint = code.endpoint
        var lines = ["Host " + alias(id), "    HostName " + endpoint.host]
        if let user = endpoint.user { lines.append("    User " + user) }
        if let port = endpoint.port { lines.append("    Port \(port)") }
        lines += ["    IdentityFile ~/.ssh/" + deviceKeyName, "    IdentitiesOnly yes", "    HostKeyAlias " + alias(id),
                  "    UserKnownHostsFile ~/.ssh/wooloo_peers/\(id).known_hosts", "    StrictHostKeyChecking yes"]
        return lines.joined(separator: "\n") + "\n"
    }

    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
    static func writePeerFiles(_ code: PeerPairingCode, home: URL) throws {
        _ = try ensureDirectory(sshDirectory(home: home))
        let directory = try ensureDirectory(peersDirectory(home: home))
        try writeAtomically(Data(knownHostsLine(code).utf8), to: directory.appendingPathComponent(code.peerID + ".known_hosts"), mode: 0o600)
        try writeAtomically(Data(configBlock(code).utf8), to: directory.appendingPathComponent(code.peerID + ".conf"), mode: 0o600)
    }

    /// Puts the Include first in `~/.ssh/config` so it applies outside any Host block. False when present.
    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
    static func addInclude(home: URL) throws -> Bool {
        let directory = try ensureDirectory(sshDirectory(home: home))
        let config = directory.appendingPathComponent("config")
        let manager = FileManager.default
        var existing = ""
        if let attributes = try? manager.attributesOfItem(atPath: config.path) {
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw WorkspaceFileError.message("~/.ssh/config is a symbolic link or not a file. Add \"\(includeLine)\" to it by hand.")
            }
            let data = try Data(contentsOf: config)
            guard data.count <= 1_048_576 else { throw WorkspaceFileError.message("~/.ssh/config is too large to edit.") }
            existing = String(decoding: data, as: UTF8.self)
            if existing.split(whereSeparator: \.isNewline).contains(where: {
                $0.trimmingCharacters(in: .whitespaces) == includeLine
            }) { return false }
        }
        try writeAtomically(Data((includeLine + "\n" + existing).utf8), to: config, mode: 0o600)
        return true
    }

    // MARK: Files

    private static func readPublicKey(_ url: URL) throws -> MobileSSHPublicKey {
        let data = try Data(contentsOf: url)
        guard data.count <= 16_384 else { throw WorkspaceFileError.message("\(url.path) is not a public key.") }
        return try MobileSSHPublicKey(String(decoding: data, as: UTF8.self))
    }

    /// Creates `url` with mode 700 when missing; refuses a symbolic link or a folder owned by someone else.
    private static func ensureDirectory(_ url: URL) throws -> URL {
        let manager = FileManager.default
        if (try? manager.attributesOfItem(atPath: url.path)) == nil {
            try manager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let attributes = try manager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
            throw WorkspaceFileError.message("\(url.path) must be a folder owned by you, not a symbolic link.")
        }
        return url
    }

    private static func writeAtomically(_ data: Data, to url: URL, mode: Int) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: mode]) else {
            throw WorkspaceFileError.message("Could not write \(url.path).")
        }
        do {
            let handle = try FileHandle(forWritingTo: temporary)
            defer { try? handle.close() }
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: temporary.path)
            guard rename(temporary.path, url.path) == 0 else { throw WorkspaceFileError.message("Could not replace \(url.path).") }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    /// The forced command installed at `~/.local/share/wooloo/peer-bridge`. It never runs request
    /// text: it compares `SSH_ORIGINAL_COMMAND` (or the stdin script of `/bin/sh -s`) with the
    /// `PeerAllowList` templates, byte for byte, and then runs fixed code for the matching entry.
    static var dispatcherBody: String { dispatcherHead + PeerAllowList.shellMatching() + dispatcherTail }

    private static let dispatcherHead = #"""
        set -u
        umask 077
        LC_ALL=C; export LC_ALL
        peer_fail() { printf 'wooloo-peer-bridge: %s\n' "$1" >&2; exit 64; }
        [ $# -eq 2 ] && [ "$1" = --peer ] || peer_fail 'misconfigured forced command'
        peer_name=$2
        case $peer_name in ''|*[!A-Za-z0-9_-]*) peer_fail 'invalid peer name';; esac
        [ ${#peer_name} -le 32 ] || peer_fail 'invalid peer name'
        [ -x "$peer_herdr" ] || peer_fail 'Herdr is not installed at the paired path; pair this device again'
        peer_request=${SSH_ORIGINAL_COMMAND-}
        [ ${#peer_request} -le 16384 ] || peer_fail 'request too long'
        peer_subject=$peer_request
        peer_stdin=
        if [ "$peer_request" = '/bin/sh -s' ]; then
            # sshd closes stdin after the client wrote the script, so reading to EOF ends.
            peer_stdin=1
            peer_subject=$(head -c 16385; printf x)
            peer_subject=${peer_subject%x}
            [ ${#peer_subject} -le 16384 ] || peer_fail 'request too long'
        fi
        # Slot values are cut out of the request only to rebuild the expected text; the request is
        # then compared with that text, so anything unexpected simply fails to match.
        peer_s=; peer_v=; peer_sa=; peer_t=
        case $peer_subject in
            'wooloo-peer '*' '*) peer_t=${peer_subject#wooloo-peer * }; peer_s=${peer_t%%[!A-Za-z0-9_-]*};;
            *--session\ *) peer_t=${peer_subject#*--session }; peer_s=${peer_t%%[!A-Za-z0-9_-]*};;
        esac
        [ ${#peer_s} -le 64 ] || peer_s=
        case $peer_subject in
            *version=*) peer_t=${peer_subject#*version=}; peer_v=${peer_t%%[!0-9A-Za-z.+-]*};;
        esac
        [ ${#peer_v} -le 32 ] || peer_v=
        if [ -n "$peer_s" ] && [ "$peer_s" != default ]; then peer_sa="--session $peer_s "; fi
        peer_entry=
        peer_verb=
        peer_flag=
        peer_null=
        peer_framed=
        peer_marker() { printf '\n%s\n' 'herdr-remote-output-ready:1'; }

        """#

    private static let dispatcherTail = #"""
        [ -n "$peer_entry" ] || peer_fail 'unsupported request'
        [ -z "$peer_framed" ] || peer_marker
        peer_check() { peer_cap=$("$peer_herdr" --session "$peer_s" remote-api-bridge --check </dev/null 2>/dev/null) && [ "$peer_cap" = herdr-api-bridge-v1 ]; }
        case $peer_entry in
            wooloo-hello) printf 'wooloo-peer-bridge-v1 %s\n' "$peer_version"; exit 0;;
            wooloo-api|herdr-api-bridge) peer_verb=remote-api-bridge;;
            wooloo-client|herdr-client-bridge) peer_verb=remote-client-bridge;;
            wooloo-check|herdr-api-check) peer_verb=remote-api-bridge; peer_flag=--check;;
            herdr-client-bridge-idle) peer_verb=remote-client-bridge; peer_flag=--idle-timeout-v1;;
            sh-saved-bridge) peer_verb=remote-client-bridge; peer_null=1;;
            herdr-cached-api)
                if peer_check; then peer_marker; peer_verb=remote-api-bridge
                else printf '%s\n' 'herdr-machine-metadata-stale-v1' >&2; exit 78; fi;;
            herdr-api-discovery)
                if peer_check; then printf '%s\n' "$peer_herdr"; exit 0; fi
                printf '%s\n' 'remote Herdr does not support machine API forwarding; update Herdr on this machine' >&2
                exit 2;;
            herdr-path-probe|sh-path-probe|sh-candidates) printf '%s\n' "$peer_herdr"; exit 0;;
            sh-exists) exit 0;;
            sh-uname) uname -s; uname -m; exit 0;;
            sh-client-status) exec "$peer_herdr" status client --json;;
            sh-session-list) exec "$peer_herdr" session list --json;;
            sh-server-status) if [ -n "$peer_sa" ]; then exec "$peer_herdr" --session "$peer_s" status server --json; fi
                exec "$peer_herdr" status server --json;;
            wooloo-sync)
                # Metadata sync responder (docs/sync-protocol.md): no arguments, runs nothing from the
                # request. awk caps each line and the whole stream before wooloo-sync sees it and
                # flushes every line, since the exchange is ping-pong over one open stream; over a cap
                # awk stops, wooloo-sync sees EOF and commits nothing.
                peer_sync=$HOME/.local/bin/wooloo-sync
                [ -x "$peer_sync" ] || peer_sync=$(command -v wooloo-sync 2>/dev/null) || peer_sync=
                { [ -n "$peer_sync" ] && [ -x "$peer_sync" ]; } || peer_fail 'wooloo-sync not found'
                awk -v line_max=1048576 -v total_max=33554432 '
                    { total += length($0) + 1
                      if (length($0) > line_max || total > total_max) {
                          print "wooloo-peer-bridge: sync input over the size limit" > "/dev/stderr"; exit 65 }
                      print; fflush() }' | "$peer_sync" exchange
                exit $?;;
            *) peer_fail 'unsupported request';;
        esac
        # Herdr bridges. Requests with {session} always pass it; {sessionArgs} ones only when set.
        case $peer_entry in
            wooloo-*|herdr-api-*|herdr-cached-api) ;;
            *) [ -n "$peer_sa" ] || peer_s=;;
        esac
        if [ -z "$peer_flag" ] || [ "$peer_flag" = --idle-timeout-v1 ]; then
            # Presence for wooloo's badge: this process keeps its pid through exec.
            peer_state="$HOME/.local/state/wooloo/peer-presence"
            if mkdir -p "$peer_state" 2>/dev/null && [ ! -L "$peer_state" ]; then
                printf 'peer=%s\nsession=%s\nverb=%s\nstarted=%s\n' "$peer_name" "${peer_s:-default}" \
                    "$peer_verb" "$(date +%s)" > "$peer_state/.$peer_name.$$" 2>/dev/null \
                    && mv -f "$peer_state/.$peer_name.$$" "$peer_state/$peer_name.$$" 2>/dev/null
            fi
        fi
        set -- "$peer_verb"
        [ -z "$peer_flag" ] || set -- "$@" "$peer_flag"
        [ -z "$peer_s" ] || set -- --session "$peer_s" "$@"
        if [ -n "$peer_null" ]; then exec "$peer_herdr" "$@" </dev/null; fi
        exec "$peer_herdr" "$@"
        """#
}

/// The peer allow-list: every request must equal one template exactly (docs/peer-allowlist.json,
/// generated by gen/allowlist.py; a test keeps this table identical to it). `dispatcherBody` is
/// generated from this table, so the shell script and the table cannot drift apart.
enum PeerAllowList {
    enum Transport: String, Sendable { case argv, stdin }
    struct Entry: Equatable, Sendable {
        let name: String
        let transport: Transport
        let template: String
    }

    static let marker = "herdr-remote-output-ready:1"
    static let markerPrefix = "printf '\n%s\n' 'herdr-remote-output-ready:1'\n"
    /// Largest line / whole stream the sync responder lets through to `wooloo-sync exchange`.
    static let syncLineLimit = 1_048_576
    static let syncStreamLimit = 33_554_432
    static let requestLimit = 16384

    static let entries: [Entry] = [
        Entry(name: "wooloo-hello", transport: .argv, template: "wooloo-peer hello"),
        Entry(name: "wooloo-api", transport: .argv, template: "wooloo-peer api {session}"),
        Entry(name: "wooloo-client", transport: .argv, template: "wooloo-peer client {session}"),
        Entry(name: "wooloo-check", transport: .argv, template: "wooloo-peer check {session}"),
        Entry(name: "wooloo-sync", transport: .argv, template: "wooloo-peer sync"),
        Entry(name: "herdr-path-probe", transport: .argv, template: "printf '\n%s\n' 'herdr-remote-output-ready:1'\ncommand -v herdr"),
        Entry(name: "herdr-client-bridge", transport: .argv, template: "printf '\n%s\n' 'herdr-remote-output-ready:1'\nexec {herdr} {sessionArgs}remote-client-bridge"),
        Entry(name: "herdr-client-bridge-idle", transport: .argv, template: "printf '\n%s\n' 'herdr-remote-output-ready:1'\nexec {herdr} {sessionArgs}remote-client-bridge --idle-timeout-v1"),
        Entry(name: "herdr-api-bridge", transport: .argv, template: "printf '\n%s\n' 'herdr-remote-output-ready:1'\nexec {herdr} --session {session} remote-api-bridge"),
        Entry(name: "herdr-api-check", transport: .argv, template: "printf '\n%s\n' 'herdr-remote-output-ready:1'\nexec {herdr} --session {session} remote-api-bridge --check"),
        Entry(name: "herdr-api-discovery", transport: .argv, template: "/bin/sh -c 'printf '\\''\n%s\n'\\'' '\\''herdr-remote-output-ready:1'\\''\nset -f\ncandidates=$(\ncommand -v herdr\nhome=${HOME:-}\nuser=${USER:-}\nversion={version}\nemit() {\n    path=$1\n    if [ -n \"$path\" ] && [ -x \"$path\" ]; then\n        printf '\\''%s\\n'\\'' \"$path\"\n    fi\n}\nif [ -n \"$home\" ]; then\n    emit \"$home/.local/bin/herdr\"\nfi\n    emit \"/opt/homebrew/bin/herdr\"\n    emit \"/usr/local/bin/herdr\"\nif [ -n \"$home\" ]; then\n    emit \"$home/.local/share/mise/installs/herdr/$version/bin/herdr\"\n    emit \"$home/.local/share/mise/installs/herdr/$version/herdr\"\n    emit \"$home/.local/share/mise/installs/github-ogulcancelik-herdr/$version/herdr\"\n    emit \"$home/.nix-profile/bin/herdr\"\nfi\nif [ -n \"$user\" ]; then\n    emit \"/etc/profiles/per-user/$user/bin/herdr\"\nfi\nemit \"/nix/var/nix/profiles/default/bin/herdr\"\nemit \"/run/current-system/sw/bin/herdr\"\n\n)\nIFS='\\''\n'\\''\nfor candidate in $candidates; do\n    case \"$candidate\" in\n        */mise/shims/herdr) continue ;;\n        /*) ;;\n        *) continue ;;\n    esac\n    [ -x \"$candidate\" ] || continue\n    if capability=$(\"$candidate\" --session {session} remote-api-bridge --check </dev/null 2>/dev/null) && [ \"$capability\" = herdr-api-bridge-v1 ]; then\n        printf '\\''%s\\n'\\'' \"$candidate\"\n        exit 0\n    fi\ndone\nprintf '\\''%s\\n'\\'' '\\''remote Herdr does not support machine API forwarding; update Herdr on this machine'\\'' >&2\nexit 2'"),
        Entry(name: "herdr-cached-api", transport: .argv, template: "/bin/sh -c 'if capability=$({herdr} --session {session} remote-api-bridge --check </dev/null 2>/dev/null) && [ \"$capability\" = herdr-api-bridge-v1 ]; then\nprintf '\\''\n%s\n'\\'' '\\''herdr-remote-output-ready:1'\\''\nexec {herdr} --session {session} remote-api-bridge\nelse\n    printf '\\''%s\\n'\\'' '\\''herdr-machine-metadata-stale-v1'\\'' >&2\n    exit 78\nfi'"),
        Entry(name: "sh-uname", transport: .stdin, template: "uname -s\nuname -m\n"),
        Entry(name: "sh-path-probe", transport: .stdin, template: "command -v herdr\n"),
        Entry(name: "sh-candidates", transport: .stdin, template: "home=${HOME:-}\nuser=${USER:-}\nversion={version}\nemit() {\n    path=$1\n    if [ -n \"$path\" ] && [ -x \"$path\" ]; then\n        printf '%s\\n' \"$path\"\n    fi\n}\nif [ -n \"$home\" ]; then\n    emit \"$home/.local/bin/herdr\"\nfi\n    emit \"/opt/homebrew/bin/herdr\"\n    emit \"/usr/local/bin/herdr\"\nif [ -n \"$home\" ]; then\n    emit \"$home/.local/share/mise/installs/herdr/$version/bin/herdr\"\n    emit \"$home/.local/share/mise/installs/herdr/$version/herdr\"\n    emit \"$home/.local/share/mise/installs/github-ogulcancelik-herdr/$version/herdr\"\n    emit \"$home/.nix-profile/bin/herdr\"\nfi\nif [ -n \"$user\" ]; then\n    emit \"/etc/profiles/per-user/$user/bin/herdr\"\nfi\nemit \"/nix/var/nix/profiles/default/bin/herdr\"\nemit \"/run/current-system/sw/bin/herdr\"\n"),
        Entry(name: "sh-exists", transport: .stdin, template: "test -x {herdr}"),
        Entry(name: "sh-client-status", transport: .stdin, template: "test -x {herdr} && {herdr} status client --json"),
        Entry(name: "sh-server-status", transport: .stdin, template: "{herdr} {sessionArgs}status server --json"),
        Entry(name: "sh-session-list", transport: .stdin, template: "{herdr} session list --json"),
        Entry(name: "sh-saved-bridge", transport: .stdin, template: "exec {herdr} {sessionArgs}remote-client-bridge </dev/null"),
    ]

    /// The matching section of the dispatcher: sets `peer_entry` (and `peer_framed`) when the
    /// request equals one template. Entries with `{session}` or `{version}` need a nonempty value.
    static func shellMatching() -> String {
        var lines: [String] = []
        for entry in entries {
            let stdin = entry.transport == .stdin
            var guards = [stdin ? #"[ -n "$peer_stdin" ]"# : #"[ -z "$peer_stdin" ]"#]
            if entry.template.contains("{session}") { guards.append(#"[ -n "$peer_s" ]"#) }
            if entry.template.contains("{version}") { guards.append(#"[ -n "$peer_v" ]"#) }
            let framed = stdin || entry.template.hasPrefix(markerPrefix) || entry.name == "herdr-api-discovery"
            lines.append(#"if [ -z "$peer_entry" ] && "# + guards.joined(separator: " && ")
                + #" && [ "$peer_subject" = "# + shellExpression(entry.template, stdin: stdin)
                + " ]; then peer_entry=" + entry.name + (framed ? "; peer_framed=1" : "") + "; fi")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Shell for `case`-free exact matching: the template as single-quoted pieces with the trusted
    /// slot values spliced in. The request text itself is only ever compared, never expanded.
    static func shellExpression(_ template: String, stdin: Bool) -> String {
        var text = template
        if stdin { text = markerPrefix + text }
        var pieces: [String] = []
        var literal = ""
        func flush() { if !literal.isEmpty { pieces.append("'" + literal.replacingOccurrences(of: "'", with: "'\\''") + "'"); literal = "" } }
        var rest = Substring(text)
        let slots: [(String, String)] = [("{herdr}", #""$peer_herdr""#), ("{sessionArgs}", #""$peer_sa""#),
                                         ("{session}", #""$peer_s""#), ("{version}", #""$peer_v""#)]
        outer: while !rest.isEmpty {
            for (name, value) in slots where rest.hasPrefix(name) {
                flush(); pieces.append(value); rest = rest.dropFirst(name.count); continue outer
            }
            literal.append(rest.removeFirst())
        }
        flush()
        return pieces.joined()
    }
}

/// Which paired peers have a bridge open on which local session, from the dispatcher's files.
enum PeerPresence {
    /// Deletes files whose bridge has ended and returns peers by session.
    @available(*, noasync, message: "Blocks its thread: call it inside BlockingWork.run")
    static func scan(directory: URL, isAlive: (Int32, Date) -> Bool = isBridge) -> [String: [String]] {
        let manager = FileManager.default
        guard let attributes = try? manager.attributesOfItem(atPath: directory.path),
              attributes[.type] as? FileAttributeType == .typeDirectory,
              let names = try? manager.contentsOfDirectory(atPath: directory.path) else { return [:] }
        var result: [String: Set<String>] = [:]
        for name in names {
            let url = directory.appendingPathComponent(name)
            let visible = name.hasPrefix(".") ? String(name.dropFirst()) : name
            guard let dot = visible.lastIndex(of: "."),
                  let pid = Int32(visible[visible.index(after: dot)...]), pid > 0,
                  PeerPairing.matches(String(visible[..<dot]), #"^[A-Za-z0-9_-]{1,32}$"#) else { continue }
            let modified = (try? manager.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
            guard isAlive(pid, modified) else {
                try? manager.removeItem(at: url)
                continue
            }
            guard !name.hasPrefix("."), let data = try? Data(contentsOf: url), data.count <= 4096 else { continue }
            var fields: [String: String] = [:]
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                let pair = line.split(separator: "=", maxSplits: 1).map(String.init)
                if pair.count == 2 { fields[pair[0]] = pair[1] }
            }
            guard let peer = fields["peer"], PeerPairing.matches(peer, #"^[A-Za-z0-9_-]{1,32}$"#),
                  let session = fields["session"], PeerPairing.isValidSession(session) else { continue }
            result[session, default: []].insert(peer)
        }
        return result.mapValues { $0.sorted() }
    }

    /// The pid still runs and is Herdr, or it is the dispatcher's shell in the moment before its exec.
    static func isBridge(_ pid: Int32, modified: Date) -> Bool {
        guard kill(pid, 0) == 0 || errno == EPERM else { return false }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return false }
        let name = withUnsafeBytes(of: info.kp_proc.p_comm) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
        return name.hasPrefix("herdr") || Date().timeIntervalSince(modified) < 10
    }
}
