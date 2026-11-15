// Minimal stand-ins so wooloo/PeerPairing.swift compiles alone with swiftc (no Xcode project).
// Only what the dispatcher/options generation path touches is real; the rest is never called.
import Foundation

enum WorkspaceFileError: Error { case message(String); case folder }
enum WorkspaceFiles {
    // Identical to WorkspaceFiles+Transport.swift `quote`.
    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func run(_ exe: String, _ args: [String], input: Data? = nil, limit: Int = 0, label: String) throws -> Data { Data() }
}
struct MobileSSHPublicKey: Equatable, Sendable { init(_ text: String) throws {}; var line: String { "" } }
enum MobileSSHAccess { static func installationScript(homeDirectory: String, user: String, options: String = "") -> String { "" } }
enum RemoteAccessHostKeys { static func fingerprint(ofPublicKeyLine: String) -> String? { nil } }
