import Darwin
import Foundation
import XCTest
@testable import wooloo

/// docs/peer-pairing.md. Everything runs in a temporary home under /private/tmp with a fake Herdr;
/// nothing touches the real ~/.ssh, Herdr sessions or config.
final class PeerPairingTests: XCTestCase {
    private var directory: URL!
    private let publicLine = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPL0n3RNg08SCe1ezkGWADmJUd0dqkjBMG/0hF2rKRlT wooloo-mobile"
    private let keyOnly = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPL0n3RNg08SCe1ezkGWADmJUd0dqkjBMG/0hF2rKRlT"
    private let fingerprint = "SHA256:lfPaKzZw8nfzEEUg5v3/z//Ygs88PEFWZsjdzwAM2MI"

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("wooloo-peer-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    // MARK: Helpers

    private func code(label: String = "Work PC", target: String = "me@mac.ts.net:2222") throws -> PeerPairingCode {
        try PeerPairingCode(target: target, publicKey: publicLine, hostKey: publicLine, herdrVersion: "0.9.5",
                            session: "work", label: label)
    }

    private func permissions(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber).intValue
    }

    private func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    private func rawCode(_ fields: [String: String]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        return PeerPairingCode.prefix + data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private var validFields: [String: String] {
        ["target": "me@mac.ts.net", "publicKey": keyOnly, "hostKey": keyOnly, "herdrVersion": "0.9.5",
         "session": "work", "label": "Work PC"]
    }

    @discardableResult
    private func makeFakeHerdr() throws -> String {
        let bin = directory.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let herdr = bin.appendingPathComponent("herdr")
        let script = "#!/bin/sh\nif [ \"$1\" = --version ]; then echo \"herdr 0.9.5\"; else printf 'ARGS:%s\\n' \"$*\"; fi\n"
        try Data(script.utf8).write(to: herdr)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: herdr.path)
        return herdr.path
    }

    private struct Run {
        let status: Int32
        let stdout: String
        let stderr: String
        let pid: Int32
    }

    private func runProcess(_ executable: String, _ arguments: [String], environment: [String: String] = [:]) throws -> Run {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let pid = process.processIdentifier
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Run(status: process.terminationStatus, stdout: String(decoding: stdout, as: UTF8.self),
                   stderr: String(decoding: stderr, as: UTF8.self), pid: pid)
    }

    /// Installs the dispatcher for the fake Herdr and runs it the way sshd does.
    private func runDispatcher(_ request: String?, arguments: [String] = ["--peer", "p"]) throws -> Run {
        let dispatcher = PeerPairing.dispatcherURL(home: directory)
        if !FileManager.default.fileExists(atPath: dispatcher.path) {
            try PeerPairing.installDispatcher(home: directory, herdr: try makeFakeHerdr(), version: "0.9.5")
        }
        var environment = ["HOME": directory.path, "PATH": "/usr/bin:/bin"]
        environment["SSH_ORIGINAL_COMMAND"] = request
        return try runProcess("/bin/sh", [dispatcher.path] + arguments, environment: environment)
    }

    private var presence: URL { PeerPairing.presenceDirectory(home: directory) }

    private func presenceFiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: presence.path)) ?? []).sorted()
    }

    // MARK: Pairing code

    func testCodeRoundTripsWithWhitespaceAndDropsKeyComments() throws {
        let original = try code()
        XCTAssertTrue(original.code.hasPrefix(PeerPairingCode.prefix))
        XCTAssertFalse(original.code.contains("="))
        XCTAssertEqual(try PeerPairingCode(code: original.code), original)
        let text = original.code
        let middle = text.index(text.startIndex, offsetBy: text.count / 2)
        let wrapped = "  \n" + text[..<middle] + "\n\t" + text[middle...] + " \r\n"
        XCTAssertEqual(try PeerPairingCode(code: wrapped), original)
        XCTAssertEqual(original.publicKey, keyOnly)
        XCTAssertEqual(original.hostKey, keyOnly)
        XCTAssertEqual(original.publicKeyFingerprint, fingerprint)
        XCTAssertEqual(original.hostKeyFingerprint, fingerprint)
        XCTAssertEqual(original.peerID, "work-pc")
        XCTAssertEqual(original.endpoint, try PeerPairingTarget("me@mac.ts.net:2222"))
        XCTAssertEqual(original.endpoint.user, "me")
        XCTAssertEqual(original.endpoint.host, "mac.ts.net")
        XCTAssertEqual(original.endpoint.port, 2222)
    }

    func testCodeRejectsDamagedAndInvalidCodes() throws {
        let valid = try code().code
        let cases: [(String, String)] = [
            ("wooloo-pair-v2:" + valid.dropFirst(PeerPairingCode.prefix.count), "Paste a code that starts with wooloo-pair-v1:"),
            (PeerPairingCode.prefix + String(repeating: "A", count: 8192), "Paste a code that starts with wooloo-pair-v1:"),
            (PeerPairingCode.prefix + "!!!", "The pairing code is damaged."),
            (valid + "=", "The pairing code is damaged."),
            (try rawCode([:]), "The pairing code is damaged or from a different wooloo version."),
        ]
        for (text, message) in cases {
            XCTAssertThrowsError(try PeerPairingCode(code: text), text) { XCTAssertEqual($0.localizedDescription, message) }
        }
        let invalid: [(String, String, String)] = [
            ("session", "bad.session", "The pairing code's session must use letters, digits, - or _ (at most 64)."),
            ("target", "me@-mac", "Enter the target as user@host, optionally with :port (for example me@mac.tailnet.ts.net)."),
            ("herdrVersion", "1;rm", "The pairing code has an invalid Herdr version."),
            ("label", "a\nb", "The pairing code's name must be 1 to 64 characters on one line."),
            ("label", String(repeating: "x", count: 65), "The pairing code's name must be 1 to 64 characters on one line."),
            ("publicKey", "restrict " + keyOnly, "The pairing code's device key is not a valid OpenSSH public key."),
            ("hostKey", "ssh-ed25519 AAAA", "The pairing code's host key is not a valid OpenSSH public key."),
        ]
        for (key, value, message) in invalid {
            var fields = validFields
            fields[key] = value
            XCTAssertThrowsError(try PeerPairingCode(code: rawCode(fields)), key) { XCTAssertEqual($0.localizedDescription, message) }
        }
        XCTAssertNoThrow(try PeerPairingCode(code: rawCode(validFields)))
    }

    func testTargetParsing() throws {
        let accepted: [(String, String?, String, Int?)] = [
            ("a@h", "a", "h", nil), ("h:22", nil, "h", 22), ("[fe80::1]:22", nil, "fe80::1", 22),
            ("fe80::1", nil, "fe80::1", nil), ("u@[::1]", "u", "::1", nil), ("me@100.64.0.1", "me", "100.64.0.1", nil),
        ]
        for (text, user, host, port) in accepted {
            let target = try PeerPairingTarget(text)
            XCTAssertEqual(target.user, user, text)
            XCTAssertEqual(target.host, host, text)
            XCTAssertEqual(target.port, port, text)
        }
        for text in ["", "-x", "a@b@c", "h:0", "h:70000", "h:", "u;x@h", "[::1", "a b", "@h", "u@-h", "[h]:22", "h:1:2",
                     "-u@h", "h:22x", String(repeating: "a", count: 256)] {
            XCTAssertThrowsError(try PeerPairingTarget(text), text)
        }
    }

    func testPeerIDAndDefaultTarget() {
        XCTAssertEqual(PeerPairing.peerID(for: "Rishabh's MacBook Pro"), "rishabh-s-macbook-pro")
        XCTAssertEqual(PeerPairing.peerID(for: "---"), "device")
        XCTAssertEqual(PeerPairing.peerID(for: String(repeating: "a", count: 40)), String(repeating: "a", count: 32))
        XCTAssertEqual(PeerPairing.peerID(for: "ab!"), "ab")
        XCTAssertEqual(PeerPairing.peerID(for: String(repeating: "a", count: 31) + " b"), String(repeating: "a", count: 31))
        XCTAssertEqual(PeerPairing.alias("work-pc"), "wooloo-peer-work-pc")
        XCTAssertEqual(PeerPairing.defaultTarget(user: "me", hostName: "mac.local"), "me@mac.local")
        XCTAssertEqual(PeerPairing.defaultTarget(user: "me", hostName: "bad host"), "me@")
    }

    // MARK: Pure helpers

    func testForcedCommandOptionsAndPeerFiles() throws {
        XCTAssertEqual(try PeerPairing.authorizedKeyOptions(home: "/Users/me", peerID: "work-pc"),
                       #"command="/Users/me/.local/share/wooloo/peer-bridge --peer work-pc",restrict"#)
        for (home, peer) in [("/Users/a b", "p"), ("Users/me", "p"), ("/Users/a\"b", "p"), ("/Users/me", "a b"),
                             ("/Users/me", ""), ("/Users/me", String(repeating: "a", count: 33))] {
            XCTAssertThrowsError(try PeerPairing.authorizedKeyOptions(home: home, peerID: peer), home + " " + peer)
        }

        XCTAssertEqual(PeerPairing.configBlock(try code()), """
            Host wooloo-peer-work-pc
                HostName mac.ts.net
                User me
                Port 2222
                IdentityFile ~/.ssh/wooloo_peer_ed25519
                IdentitiesOnly yes
                HostKeyAlias wooloo-peer-work-pc
                UserKnownHostsFile ~/.ssh/wooloo_peers/work-pc.known_hosts
                StrictHostKeyChecking yes

            """)
        XCTAssertEqual(PeerPairing.configBlock(try code(target: "[fd7a::1]")), """
            Host wooloo-peer-work-pc
                HostName fd7a::1
                IdentityFile ~/.ssh/wooloo_peer_ed25519
                IdentitiesOnly yes
                HostKeyAlias wooloo-peer-work-pc
                UserKnownHostsFile ~/.ssh/wooloo_peers/work-pc.known_hosts
                StrictHostKeyChecking yes

            """)
        XCTAssertEqual(PeerPairing.knownHostsLine(try code()), "wooloo-peer-work-pc " + keyOnly + "\n")
        XCTAssertEqual(PeerPairing.machineArguments(for: try code()),
                       ["add", "wooloo-peer-work-pc", "--remote-session", "work", "--label", "Work PC"])
    }

    func testInstallDispatcherRejectsUnsafeHerdrPathOrVersion() throws {
        XCTAssertThrowsError(try PeerPairing.installDispatcher(home: directory, herdr: "/opt/my herdr", version: "0.9.5"))
        XCTAssertThrowsError(try PeerPairing.installDispatcher(home: directory, herdr: "herdr", version: "0.9.5"))
        XCTAssertThrowsError(try PeerPairing.installDispatcher(home: directory, herdr: "/opt/herdr", version: "1;x"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: PeerPairing.dispatcherURL(home: directory).path))
    }

    // MARK: Files in the temporary home

    func testAuthorizeAddsRestrictedEntryOnce() throws {
        let options = try PeerPairing.authorizedKeyOptions(home: directory.path, peerID: "work-pc")
        let line = keyOnly + " wooloo-peer-work-pc"
        XCTAssertTrue(try PeerPairing.authorize(line, options: options, home: directory, user: NSUserName()))
        let keys = directory.appendingPathComponent(".ssh/authorized_keys")
        let expected = #"command=""# + directory.path + #"/.local/share/wooloo/peer-bridge --peer work-pc",restrict "# + line + "\n"
        XCTAssertEqual(try read(keys), expected)
        XCTAssertFalse(try PeerPairing.authorize(line, options: options, home: directory, user: NSUserName()))
        XCTAssertEqual(try read(keys), expected)
        XCTAssertEqual(try permissions(keys), 0o600)
        XCTAssertEqual(try permissions(directory.appendingPathComponent(".ssh")), 0o700)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".ssh/.wooloo-authorized-keys.lock").path))
    }

    func testPairInstallsDispatcherKeyPeerFilesAndInclude() throws {
        let herdr = try makeFakeHerdr()
        let peer = try code()
        let first = try PeerPairing.pair(peer, home: directory, herdr: herdr, herdrVersion: "0.9.5", addInclude: true)
        XCTAssertFalse(first.keyAlreadyAuthorized)
        XCTAssertTrue(first.includeAdded)

        let dispatcher = PeerPairing.dispatcherURL(home: directory)
        XCTAssertEqual(try read(dispatcher), PeerPairing.dispatcherScript(herdr: herdr, version: "0.9.5"))
        XCTAssertEqual(try permissions(dispatcher), 0o700)
        let keys = try read(directory.appendingPathComponent(".ssh/authorized_keys"))
        XCTAssertTrue(keys.hasPrefix(#"command=""# + dispatcher.path + #" --peer work-pc",restrict "#), keys)
        XCTAssertTrue(keys.hasSuffix(keyOnly + " wooloo-peer-work-pc\n"))

        let peers = PeerPairing.peersDirectory(home: directory)
        let known = peers.appendingPathComponent("work-pc.known_hosts")
        let conf = peers.appendingPathComponent("work-pc.conf")
        XCTAssertEqual(try read(known), PeerPairing.knownHostsLine(peer))
        XCTAssertEqual(try read(conf), PeerPairing.configBlock(peer))
        XCTAssertEqual(try permissions(known), 0o600)
        XCTAssertEqual(try permissions(conf), 0o600)
        XCTAssertTrue(try read(directory.appendingPathComponent(".ssh/config")).hasPrefix(PeerPairing.includeLine + "\n"))

        let second = try PeerPairing.pair(peer, home: directory, herdr: herdr, herdrVersion: "0.9.5", addInclude: true)
        XCTAssertTrue(second.keyAlreadyAuthorized)
        XCTAssertFalse(second.includeAdded)
        XCTAssertEqual(try read(directory.appendingPathComponent(".ssh/authorized_keys")), keys)
    }

    func testLocalCodeCreatesDeviceKeyAndReadsHostKeyAndVersion() throws {
        let herdr = try makeFakeHerdr()
        XCTAssertEqual(try PeerPairing.herdrVersion(executable: herdr), "0.9.5")
        XCTAssertThrowsError(try PeerPairing.hostKey(path: directory.appendingPathComponent("missing.pub").path)) {
            XCTAssertTrue($0.localizedDescription.hasPrefix("Could not read this Mac's SSH host key"))
        }
        let hostKey = directory.appendingPathComponent("hostkey")
        let keygen = try runProcess("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", hostKey.path])
        XCTAssertEqual(keygen.status, 0)

        let local = try PeerPairing.localCode(target: "me@mac.ts.net", session: "work", label: "Test Mac", home: directory,
                                              herdr: herdr, hostKeyPath: hostKey.path + ".pub")
        XCTAssertEqual(local.herdrVersion, "0.9.5")
        XCTAssertEqual(local.label, "Test Mac")
        XCTAssertTrue(local.publicKey.hasPrefix("ssh-ed25519 "))
        XCTAssertTrue(local.hostKey.hasPrefix("ssh-ed25519 "))
        XCTAssertNotEqual(local.publicKeyFingerprint, "?")
        XCTAssertEqual(try PeerPairingCode(code: local.code), local)

        let ssh = PeerPairing.sshDirectory(home: directory)
        let pub = ssh.appendingPathComponent(PeerPairing.deviceKeyName + ".pub")
        XCTAssertTrue(try read(pub).contains("wooloo-peer@Test-Mac"))
        XCTAssertEqual(try permissions(ssh), 0o700)
        let again = try PeerPairing.deviceKey(home: directory, machineName: "Other")
        XCTAssertEqual(again.line.split(separator: " ").prefix(2).joined(separator: " "), local.publicKey)

        try FileManager.default.removeItem(at: pub)
        XCTAssertThrowsError(try PeerPairing.deviceKey(home: directory, machineName: "Test Mac")) {
            XCTAssertTrue($0.localizedDescription.hasSuffix("exists without its .pub file. Restore or remove it, then pair again."))
        }
    }

    func testAddIncludeIsIdempotentAndRefusesSymlink() throws {
        let ssh = PeerPairing.sshDirectory(home: directory)
        let config = ssh.appendingPathComponent("config")
        XCTAssertTrue(try PeerPairing.addInclude(home: directory))
        XCTAssertEqual(try read(config), PeerPairing.includeLine + "\n")
        XCTAssertFalse(try PeerPairing.addInclude(home: directory))

        try Data("Host x\n".utf8).write(to: config)
        XCTAssertTrue(try PeerPairing.addInclude(home: directory))
        XCTAssertEqual(try read(config), PeerPairing.includeLine + "\nHost x\n")
        XCTAssertFalse(try PeerPairing.addInclude(home: directory))
        XCTAssertEqual(try permissions(config), 0o600)

        try FileManager.default.removeItem(at: config)
        let real = directory.appendingPathComponent("real-config")
        try Data("Host y\n".utf8).write(to: real)
        try FileManager.default.createSymbolicLink(at: config, withDestinationURL: real)
        XCTAssertThrowsError(try PeerPairing.addInclude(home: directory)) {
            XCTAssertTrue($0.localizedDescription.hasPrefix("~/.ssh/config is a symbolic link or not a file."))
        }
        XCTAssertEqual(try read(real), "Host y\n")
    }

    // MARK: Dispatcher

    func testDispatcherRunsOnlyFixedBridgeForms() throws {
        let cases: [(String, String)] = [
            ("wooloo-peer hello", "wooloo-peer-bridge-v1 0.9.5\n"),
            ("wooloo-peer api work", "ARGS:--session work remote-api-bridge\n"),
            ("wooloo-peer client work", "ARGS:--session work remote-client-bridge\n"),
            ("wooloo-peer check work", "ARGS:--session work remote-api-bridge --check\n"),
            ("printf herdr-remote-output-ready:1\nexec /opt/herdr --session work remote-client-bridge",
             "\nherdr-remote-output-ready:1\nARGS:--session work remote-client-bridge\n"),
            ("exec '/opt/herdr' --session 'work' remote-api-bridge --idle-timeout-v1 </dev/null'",
             "ARGS:--session work remote-api-bridge --idle-timeout-v1\n"),
            ("exec /opt/herdr remote-api-bridge", "ARGS:remote-api-bridge\n"),
        ]
        for (request, output) in cases {
            let run = try runDispatcher(request)
            XCTAssertEqual(run.status, 0, request + " " + run.stderr)
            XCTAssertEqual(run.stdout, output, request)
            XCTAssertEqual(run.stderr, "", request)
        }
    }

    func testDispatcherRefusesEverythingElse() throws {
        let marker = directory.appendingPathComponent("ran")
        let refused: [(String?, String)] = [
            ("wooloo-peer api S; touch \(marker.path)", "unsupported request"),
            ("wooloo-peer api bad.session", "unsupported request"),
            ("wooloo-peer api", "unsupported request"),
            ("wooloo-peer shell work", "unsupported request"),
            ("exec /x remote-api-bridge; touch \(marker.path)", "unsupported request; this key may only open Herdr bridges"),
            ("exec /x remote-api-bridge\nexec /x remote-client-bridge", "unsupported request; this key may only open Herdr bridges"),
            ("/bin/sh -s", "unsupported request; this key may only open Herdr bridges"),
            ("touch \(marker.path)", "unsupported request; this key may only open Herdr bridges"),
            ("", "unsupported request; this key may only open Herdr bridges"),
            (nil, "unsupported request; this key may only open Herdr bridges"),
            // A space inside the session token stops the bridge line from matching at all.
            ("exec /x --session $(touch \(marker.path)) remote-api-bridge", "unsupported request; this key may only open Herdr bridges"),
            ("exec /x --session $(id) remote-api-bridge", "invalid session name"),
            ("exec /x --session `id` remote-api-bridge", "invalid session name"),
            ("exec /x --session \(String(repeating: "s", count: 65)) remote-api-bridge", "invalid session name"),
            (String(repeating: "x", count: 16385), "request too long"),
        ]
        for (request, reason) in refused {
            let run = try runDispatcher(request)
            XCTAssertEqual(run.status, 64, request ?? "nil")
            XCTAssertEqual(run.stdout, "", request ?? "nil")
            XCTAssertEqual(run.stderr, "wooloo-peer-bridge: \(reason)\n", request ?? "nil")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(presenceFiles(), [])

        for (arguments, reason) in [(["--peer", "a b"], "invalid peer name"), (["--peer", ""], "invalid peer name"),
                                    (["--peer", String(repeating: "p", count: 33)], "invalid peer name"),
                                    (["--peer"], "misconfigured forced command"), (["-x", "p"], "misconfigured forced command"),
                                    (["--peer", "p", "x"], "misconfigured forced command")] {
            let run = try runDispatcher("wooloo-peer hello", arguments: arguments)
            XCTAssertEqual(run.status, 64, arguments.joined(separator: " "))
            XCTAssertEqual(run.stderr, "wooloo-peer-bridge: \(reason)\n", arguments.joined(separator: " "))
        }

        try FileManager.default.removeItem(at: directory.appendingPathComponent("bin/herdr"))
        let missing = try runDispatcher("wooloo-peer hello")
        XCTAssertEqual(missing.status, 64)
        XCTAssertEqual(missing.stderr, "wooloo-peer-bridge: Herdr is not installed at the paired path; pair this device again\n")
    }

    func testDispatcherRecordsPresenceForBridgesOnly() throws {
        XCTAssertEqual(try runDispatcher("wooloo-peer hello").status, 0)
        XCTAssertEqual(try runDispatcher("wooloo-peer check work").status, 0)
        XCTAssertEqual(presenceFiles(), [])

        let run = try runDispatcher("wooloo-peer api work")
        XCTAssertEqual(run.status, 0)
        XCTAssertEqual(presenceFiles(), ["p.\(run.pid)"])
        let file = presence.appendingPathComponent("p.\(run.pid)")
        let lines = try read(file).split(separator: "\n").map(String.init)
        XCTAssertEqual(Array(lines.prefix(3)), ["peer=p", "session=work", "verb=remote-api-bridge"])
        XCTAssertTrue(lines.count == 4 && lines[3].hasPrefix("started="), lines.joined(separator: ","))
        XCTAssertEqual(try permissions(file), 0o600)
        XCTAssertEqual(try permissions(presence), 0o700)

        XCTAssertEqual(PeerPresence.scan(directory: presence, isAlive: { _, _ in true }), ["work": ["p"]])
        XCTAssertEqual(PeerPresence.scan(directory: presence, isAlive: { _, _ in false }), [:])
        XCTAssertEqual(presenceFiles(), [])

        let unnamed = try runDispatcher("exec /opt/herdr remote-client-bridge")
        XCTAssertEqual(PeerPresence.scan(directory: presence, isAlive: { pid, _ in pid == unnamed.pid }), ["default": ["p"]])
    }

    // MARK: Presence scan

    func testPresenceScanKeepsLiveBridgesAndDeletesEndedOnes() throws {
        try FileManager.default.createDirectory(at: presence, withIntermediateDirectories: true)
        let files = ["a.100": "peer=a\nsession=work\n", "b.200": "peer=b\nsession=work\n", "c.300": "peer=c\nsession=work\n",
                     ".d.400": "peer=d\nsession=work\n", ".e.500": "", "junk": "peer=j\nsession=work\n",
                     "f.600": "peer=f\nsession=bad.session\n"]
        for (name, text) in files { try Data(text.utf8).write(to: presence.appendingPathComponent(name)) }
        let alive: Set<Int32> = [100, 200, 400, 600]
        XCTAssertEqual(PeerPresence.scan(directory: presence, isAlive: { pid, _ in alive.contains(pid) }), ["work": ["a", "b"]])
        XCTAssertEqual(presenceFiles(), [".d.400", "a.100", "b.200", "f.600", "junk"])
        XCTAssertEqual(PeerPresence.scan(directory: directory.appendingPathComponent("missing")), [:])

        XCTAssertTrue(PeerPresence.isBridge(getpid(), modified: Date()))
        let ended = try runProcess("/usr/bin/true", [])
        XCTAssertFalse(PeerPresence.isBridge(ended.pid, modified: .distantPast))
    }
}
