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
        let script = "#!/bin/sh\nif [ \"$1\" = --version ]; then echo \"herdr 0.9.5\"; "
            + "elif [ -e \"$HOME/herdr-capable\" ] && { last=; for a in \"$@\"; do last=$a; done; [ \"$last\" = --check ]; }; then echo herdr-api-bridge-v1; "
            + "else printf 'ARGS:%s\\n' \"$*\"; fi\n"
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

    private func runProcess(_ executable: String, _ arguments: [String], environment: [String: String] = [:], input: Data? = nil) throws -> Run {
        signal(SIGPIPE, SIG_IGN)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        let stdin = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let pid = process.processIdentifier
        if let input {
            // Written from another thread: the dispatcher may stop reading early (over a cap).
            DispatchQueue.global().async {
                try? stdin.fileHandleForWriting.write(contentsOf: input)
                try? stdin.fileHandleForWriting.close()
            }
        }
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Run(status: process.terminationStatus, stdout: String(decoding: stdout, as: UTF8.self),
                   stderr: String(decoding: stderr, as: UTF8.self), pid: pid)
    }

    /// Installs the dispatcher for the fake Herdr and runs it the way sshd does.
    private func runDispatcher(_ request: String?, arguments: [String] = ["--peer", "p"], input: Data? = nil) throws -> Run {
        let dispatcher = PeerPairing.dispatcherURL(home: directory)
        if !FileManager.default.fileExists(atPath: dispatcher.path) {
            try PeerPairing.installDispatcher(home: directory, herdr: try makeFakeHerdr(), version: "0.9.5")
        }
        var environment = ["HOME": directory.path, "PATH": "/usr/bin:/bin"]
        environment["SSH_ORIGINAL_COMMAND"] = request
        return try runProcess("/bin/sh", [dispatcher.path] + arguments, environment: environment, input: input)
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

    private func makeSpacedHerdr() throws -> String {
        let spaced = directory.appendingPathComponent("Application Support/wooloo/herdr", isDirectory: true)
        try FileManager.default.createDirectory(at: spaced, withIntermediateDirectories: true)
        let real = spaced.appendingPathComponent("herdr")
        try FileManager.default.copyItem(atPath: try makeFakeHerdr(), toPath: real.path)
        return real.path
    }

    func testPairWithSpacedHerdrPathUsesSafeStableLink() throws {
        let real = try makeSpacedHerdr()
        XCTAssertTrue(real.contains(" "))
        try PeerPairing.pair(try code(), home: directory, herdr: real, herdrVersion: "0.9.5", addInclude: false)
        let stable = PeerPairing.stableHerdrURL(home: directory).path
        XCTAssertTrue(PeerPairing.matches(stable, #"^/[A-Za-z0-9._/-]+$"#))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: stable), real)
        let script = try read(PeerPairing.dispatcherURL(home: directory))
        XCTAssertTrue(script.contains("peer_herdr=" + WorkspaceFiles.quote(stable)))
        XCTAssertFalse(script.contains("Application Support"))
    }

    func testPairWithCleanHerdrPathAlsoUsesStableLink() throws {
        let real = try makeFakeHerdr()
        try PeerPairing.pair(try code(), home: directory, herdr: real, herdrVersion: "0.9.5", addInclude: false)
        let stable = PeerPairing.stableHerdrURL(home: directory).path
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: stable), real)
        XCTAssertTrue(try read(PeerPairing.dispatcherURL(home: directory)).contains("peer_herdr=" + WorkspaceFiles.quote(stable)))
    }

    func testRefreshHerdrLinkIsIdempotentAndRepointsAtomically() throws {
        let first = try makeFakeHerdr()
        let stable = try PeerPairing.refreshHerdrLink(home: directory, herdr: first)
        XCTAssertEqual(stable, PeerPairing.stableHerdrURL(home: directory).path)
        XCTAssertEqual(try PeerPairing.refreshHerdrLink(home: directory, herdr: first), stable)
        let second = try makeSpacedHerdr()
        try PeerPairing.refreshHerdrLink(home: directory, herdr: second)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: stable), second)
        let left = try FileManager.default.contentsOfDirectory(atPath: (stable as NSString).deletingLastPathComponent)
        XCTAssertEqual(left, ["herdr"])
        XCTAssertThrowsError(try PeerPairing.refreshHerdrLink(home: directory, herdr: "relative/herdr"))
        XCTAssertThrowsError(try PeerPairing.refreshHerdrLink(home: directory, herdr: directory.appendingPathComponent("nope").path))
    }

    func testRefreshAtLaunchOnlyWhenPaired() throws {
        let real = try makeFakeHerdr()
        PeerPairing.refreshHerdrLinkIfPaired(home: directory, herdr: real)
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: PeerPairing.stableHerdrURL(home: directory).path))
        try PeerPairing.installDispatcher(home: directory, herdr: real, version: "0.9.5")
        PeerPairing.refreshHerdrLinkIfPaired(home: directory, herdr: real)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: PeerPairing.stableHerdrURL(home: directory).path), real)
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
        XCTAssertEqual(try read(dispatcher), PeerPairing.dispatcherScript(herdr: PeerPairing.stableHerdrURL(home: directory).path, version: "0.9.5"))
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

    private var fakeHerdrPath: String { directory.appendingPathComponent("bin/herdr").path }
    private let ready = "\nherdr-remote-output-ready:1\n"

    /// A template with its slots filled the way a client does: session `work`, this Herdr, version 0.9.5.
    private func filled(_ template: String, session: String = "work") -> String {
        template.replacingOccurrences(of: "{herdr}", with: fakeHerdrPath)
            .replacingOccurrences(of: "{sessionArgs}", with: session == "default" ? "" : "--session \(session) ")
            .replacingOccurrences(of: "{session}", with: session)
            .replacingOccurrences(of: "{version}", with: "0.9.5")
    }

    /// Sends a filled entry the way its transport does: SSH_ORIGINAL_COMMAND, or `/bin/sh -s` plus a stdin script.
    private func send(_ entry: PeerAllowList.Entry, session: String = "work") throws -> Run {
        let text = filled(entry.template, session: session)
        switch entry.transport {
        case .argv: return try runDispatcher(text)
        case .stdin: return try runDispatcher("/bin/sh -s", input: Data((PeerAllowList.markerPrefix + text).utf8))
        }
    }

    private func installFakeSync() throws {
        let bin = directory.appendingPathComponent(".local/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let sync = bin.appendingPathComponent("wooloo-sync")
        try Data("#!/bin/sh\necho \"sync-args:$*\"\ncat\n".utf8).write(to: sync)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sync.path)
    }

    func testDispatcherAllowsEveryTemplateExactlyOnce() throws {
        try makeFakeHerdr()
        FileManager.default.createFile(atPath: directory.appendingPathComponent("herdr-capable").path, contents: Data())
        let herdr = fakeHerdrPath
        let uname = try runProcess("/usr/bin/uname", ["-s"]).stdout + (try runProcess("/usr/bin/uname", ["-m"]).stdout)
        let expected: [String: String] = [
            "wooloo-hello": "wooloo-peer-bridge-v1 0.9.5\n",
            "wooloo-api": "ARGS:--session work remote-api-bridge\n",
            "wooloo-client": "ARGS:--session work remote-client-bridge\n",
            "wooloo-check": "herdr-api-bridge-v1\n",
            "wooloo-sync": "",
            "herdr-path-probe": ready + herdr + "\n",
            "herdr-client-bridge": ready + "ARGS:--session work remote-client-bridge\n",
            "herdr-client-bridge-idle": ready + "ARGS:--session work remote-client-bridge --idle-timeout-v1\n",
            "herdr-api-bridge": ready + "ARGS:--session work remote-api-bridge\n",
            "herdr-api-check": ready + "herdr-api-bridge-v1\n",
            "herdr-api-discovery": ready + herdr + "\n",
            "herdr-cached-api": ready + "ARGS:--session work remote-api-bridge\n",
            "sh-uname": ready + uname,
            "sh-path-probe": ready + herdr + "\n",
            "sh-candidates": ready + herdr + "\n",
            "sh-exists": ready,
            "sh-client-status": ready + "ARGS:status client --json\n",
            "sh-server-status": ready + "ARGS:--session work status server --json\n",
            "sh-session-list": ready + "ARGS:session list --json\n",
            "sh-saved-bridge": ready + "ARGS:--session work remote-client-bridge\n",
        ]
        XCTAssertEqual(Set(expected.keys), Set(PeerAllowList.entries.map(\.name)))
        for entry in PeerAllowList.entries where entry.name != "wooloo-sync" {
            let run = try send(entry)
            XCTAssertEqual(run.status, 0, entry.name + " " + run.stderr)
            XCTAssertEqual(run.stdout, expected[entry.name], entry.name)
            XCTAssertEqual(run.stderr, "", entry.name)
        }
        try installFakeSync()
        let sync = try runDispatcher("wooloo-peer sync", input: Data("{\"a\":1}\n".utf8))
        XCTAssertEqual(sync.status, 0, sync.stderr)
        XCTAssertEqual(sync.stdout, "sync-args:exchange\n{\"a\":1}\n")
        XCTAssertEqual(sync.stderr, "")
    }

    func testDispatcherSessionDefaultAndSessionArgs() throws {
        try makeFakeHerdr()
        let status = try XCTUnwrap(PeerAllowList.entries.first { $0.name == "sh-server-status" })
        let plain = try send(status, session: "default")
        XCTAssertEqual(plain.stdout, ready + "ARGS:status server --json\n", plain.stderr)
        // `--session default ` is not what a client sends for the default session.
        let explicit = try runDispatcher("/bin/sh -s", input: Data((PeerAllowList.markerPrefix + "\(fakeHerdrPath) --session default status server --json").utf8))
        XCTAssertEqual(explicit.status, 64)
        XCTAssertEqual(explicit.stderr, "wooloo-peer-bridge: unsupported request\n")
        let bridge = try send(try XCTUnwrap(PeerAllowList.entries.first { $0.name == "herdr-client-bridge" }), session: "default")
        XCTAssertEqual(bridge.stdout, ready + "ARGS:remote-client-bridge\n", bridge.stderr)
    }

    func testDispatcherCachedApiAndDiscoveryRefuseIncapableHerdr() throws {
        try makeFakeHerdr()
        let cached = try send(try XCTUnwrap(PeerAllowList.entries.first { $0.name == "herdr-cached-api" }))
        XCTAssertEqual(cached.status, 78)
        XCTAssertEqual(cached.stdout, "")
        XCTAssertEqual(cached.stderr, "herdr-machine-metadata-stale-v1\n")
        let discovery = try send(try XCTUnwrap(PeerAllowList.entries.first { $0.name == "herdr-api-discovery" }))
        XCTAssertEqual(discovery.status, 2)
        XCTAssertEqual(discovery.stderr, "remote Herdr does not support machine API forwarding; update Herdr on this machine\n")
    }

    func testDispatcherRefusesEverythingElse() throws {
        let marker = directory.appendingPathComponent("ran")
        let touch = "touch \(marker.path)"
        try makeFakeHerdr()
        let herdr = fakeHerdrPath
        let bridge = "printf '\n%s\n' 'herdr-remote-output-ready:1'\nexec \(herdr) "
        let refused: [(String?, String)] = [
            ("wooloo-peer api S; \(touch)", "unsupported request"),
            ("wooloo-peer api S && \(touch)", "unsupported request"),
            ("wooloo-peer api bad.session", "unsupported request"),
            ("wooloo-peer api work ", "unsupported request"),
            ("wooloo-peer api work\n", "unsupported request"),
            ("wooloo-peer api", "unsupported request"),
            ("wooloo-peer api $(\(touch))", "unsupported request"),
            ("wooloo-peer api `\(touch)`", "unsupported request"),
            ("wooloo-peer api *", "unsupported request"),
            ("wooloo-peer shell work", "unsupported request"),
            ("wooloo-peer hello; \(touch)", "unsupported request"),
            ("wooloo-peer hello extra", "unsupported request"),
            ("wooloo-peer sync; \(touch)", "unsupported request"),
            ("wooloo-peer sync extra", "unsupported request"),
            ("wooloo-peer  sync", "unsupported request"),
            ("WOOLOO-PEER hello", "unsupported request"),
            (bridge + "remote-client-bridge; \(touch)", "unsupported request"),
            (bridge + "remote-client-bridge\n\(touch)", "unsupported request"),
            (bridge + "--session $(id) remote-client-bridge", "unsupported request"),
            (bridge + "--session `id` remote-client-bridge", "unsupported request"),
            (bridge + "--session default remote-client-bridge", "unsupported request"),
            (bridge + "--session work remote-client-bridge --idle-timeout-v1 --x", "unsupported request"),
            (bridge.replacingOccurrences(of: herdr, with: "/opt/herdr") + "remote-client-bridge", "unsupported request"),
            (bridge.replacingOccurrences(of: herdr, with: "'\(herdr)'") + "remote-client-bridge", "unsupported request"),
            (bridge.replacingOccurrences(of: herdr, with: "\(herdr)/../herdr") + "remote-client-bridge", "unsupported request"),
            ("exec \(herdr) remote-client-bridge", "unsupported request"),
            ("exec \(herdr) install", "unsupported request"),
            ("/bin/sh -s ", "unsupported request"),
            ("/bin/sh -s; \(touch)", "unsupported request"),
            ("/bin/sh -c '\(touch)'", "unsupported request"),
            ("/bin/sh -s", "unsupported request"),
            ("touch \(marker.path)", "unsupported request"),
            ("", "unsupported request"),
            (nil, "unsupported request"),
            (String(repeating: "x", count: 16385), "request too long"),
        ]
        for (request, reason) in refused {
            let run = try runDispatcher(request)
            XCTAssertEqual(run.status, 64, request ?? "nil")
            XCTAssertEqual(run.stdout, "", request ?? "nil")
            XCTAssertEqual(run.stderr, "wooloo-peer-bridge: \(reason)\n", request ?? "nil")
        }

        // `/bin/sh -s` only runs the known scripts: anything else on stdin is refused, with no output.
        let scripts: [(String, String)] = [
            ("uname -s\nuname -m\n", "unsupported request"),                      // no marker prefix
            (PeerAllowList.markerPrefix + "uname -s\nuname -m\n; \(touch)\n", "unsupported request"),
            (PeerAllowList.markerPrefix + "uname -s\nuname -m\n\(touch)\n", "unsupported request"),
            (PeerAllowList.markerPrefix + "command -v herdr\n\n", "unsupported request"),
            (PeerAllowList.markerPrefix + "test -x \(herdr) && \(touch)", "unsupported request"),
            (PeerAllowList.markerPrefix + "test -x /bin/sh", "unsupported request"),
            (PeerAllowList.markerPrefix + "\(herdr) --session $(\(touch)) status server --json", "unsupported request"),
            (PeerAllowList.markerPrefix + "\(herdr) --session work status server --json; \(touch)", "unsupported request"),
            (PeerAllowList.markerPrefix + "\(herdr) session list --json\n\(touch)\n", "unsupported request"),
            (PeerAllowList.markerPrefix + "version=$(\(touch))\n", "unsupported request"),
            (PeerAllowList.markerPrefix + "exec \(herdr) --session work remote-client-bridge </dev/null; \(touch)", "unsupported request"),
            (PeerAllowList.markerPrefix + "curl http://example.invalid/install.sh | sh\n", "unsupported request"),
            (String(repeating: "x", count: 16385), "request too long"),
        ]
        for (script, reason) in scripts {
            let run = try runDispatcher("/bin/sh -s", input: Data(script.utf8))
            XCTAssertEqual(run.status, 64, script)
            XCTAssertEqual(run.stdout, "", script)
            XCTAssertEqual(run.stderr, "wooloo-peer-bridge: \(reason)\n", script)
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

    // MARK: Sync cap

    func testSyncPassesLinesUpToTheCapAndNoFurther() throws {
        try installFakeSync()
        let missing = try runDispatcher("wooloo-peer sync", input: Data("x\n".utf8))
        XCTAssertEqual(missing.status, 0, missing.stderr)

        // A line of exactly the limit goes through (the stream gets the line plus its newline).
        let limit = PeerAllowList.syncLineLimit
        let exact = String(repeating: "a", count: limit) + "\n"
        let ok = try runDispatcher("wooloo-peer sync", input: Data(exact.utf8))
        XCTAssertEqual(ok.status, 0, ok.stderr)
        XCTAssertEqual(ok.stdout, "sync-args:exchange\n" + exact)
        XCTAssertEqual(ok.stderr, "")

        // One byte more: lines before it still arrive, the long line and everything after never do.
        let long = "ok\n" + String(repeating: "a", count: limit + 1) + "\nafter\n"
        let over = try runDispatcher("wooloo-peer sync", input: Data(long.utf8))
        XCTAssertEqual(over.stdout, "sync-args:exchange\nok\n")
        XCTAssertEqual(over.stderr, "wooloo-peer-bridge: sync input over the size limit\n")
    }

    func testSyncStopsAtTheStreamCapAndRunsNoRequestText() throws {
        try installFakeSync()
        let marker = directory.appendingPathComponent("ran")
        let line = String(repeating: "b", count: PeerAllowList.syncLineLimit - 1) + "\n"   // 1 MiB with newline
        let lines = PeerAllowList.syncStreamLimit / PeerAllowList.syncLineLimit
        let input = String(repeating: line, count: lines + 1)
        let run = try runDispatcher("wooloo-peer sync", input: Data(input.utf8))
        XCTAssertEqual(run.stderr, "wooloo-peer-bridge: sync input over the size limit\n")
        XCTAssertEqual(run.stdout.utf8.count, "sync-args:exchange\n".utf8.count + lines * line.utf8.count)

        // Input is data for wooloo-sync only: shell syntax in it is never evaluated.
        let hostile = "$(touch \(marker.path))\n`touch \(marker.path)`\n; touch \(marker.path)\n"
        let echoed = try runDispatcher("wooloo-peer sync", input: Data(hostile.utf8))
        XCTAssertEqual(echoed.stdout, "sync-args:exchange\n" + hostile)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testSyncDeliversEachLineWhileTheStreamStaysOpen() throws {
        // The exchange is ping-pong over one stream: a line must reach wooloo-sync before EOF.
        try makeFakeHerdr()
        let bin = directory.appendingPathComponent(".local/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let sync = bin.appendingPathComponent("wooloo-sync")
        try Data("#!/bin/sh\nwhile IFS= read -r line; do printf 'reply:%s\\n' \"$line\"; done\n".utf8).write(to: sync)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sync.path)
        try PeerPairing.installDispatcher(home: directory, herdr: fakeHerdrPath, version: "0.9.5")

        signal(SIGPIPE, SIG_IGN)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [PeerPairing.dispatcherURL(home: directory).path, "--peer", "p"]
        process.environment = ["HOME": directory.path, "PATH": "/usr/bin:/bin", "SSH_ORIGINAL_COMMAND": "wooloo-peer sync"]
        let stdin = Pipe()
        let out = Pipe()
        process.standardInput = stdin
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate() } }

        for index in 0..<3 {
            try stdin.fileHandleForWriting.write(contentsOf: Data("op\(index)\n".utf8))
            let reply = DispatchSemaphore(value: 0)
            let box = SyncReplyBox()
            let reader = out.fileHandleForReading
            DispatchQueue.global().async {
                box.data = reader.availableData
                reply.signal()
            }
            XCTAssertEqual(reply.wait(timeout: .now() + 5), .success, "line \(index) was held until EOF")
            XCTAssertEqual(String(decoding: box.data, as: UTF8.self), "reply:op\(index)\n")
        }
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testSyncWithoutTheBinaryFailsCleanly() throws {
        try makeFakeHerdr()
        let run = try runDispatcher("wooloo-peer sync", input: Data("x\n".utf8))
        XCTAssertEqual(run.status, 64)
        XCTAssertEqual(run.stderr, "wooloo-peer-bridge: wooloo-sync not found\n")
    }

    // MARK: Allow-list file

    func testAllowListTableEqualsTheJSONFile() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("docs/peer-allowlist.json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["revision"] as? Int, 2)
        XCTAssertEqual(json["provisional"] as? Bool, false)
        XCTAssertEqual(json["marker"] as? String, PeerAllowList.marker)
        XCTAssertEqual(json["markerPrefix"] as? String, PeerAllowList.markerPrefix)
        let entries = try XCTUnwrap(json["entries"] as? [[String: Any]]).map {
            PeerAllowList.Entry(name: $0["name"] as? String ?? "", transport: PeerAllowList.Transport(rawValue: $0["transport"] as? String ?? "") ?? .argv,
                                template: $0["template"] as? String ?? "")
        }
        XCTAssertEqual(entries, PeerAllowList.entries)
        XCTAssertEqual(entries.count, 20)
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

        let unnamed = try runDispatcher("printf '\n%s\n' 'herdr-remote-output-ready:1'\nexec \(fakeHerdrPath) remote-client-bridge")
        XCTAssertEqual(unnamed.status, 0, unnamed.stderr)
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

/// Carries one read result off a background queue; the semaphore orders the write before the read.
private final class SyncReplyBox: @unchecked Sendable {
    var data = Data()
}
