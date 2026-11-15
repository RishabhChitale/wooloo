import AppKit
import SwiftUI

/// "Pair Device…" from the Connections window: shows this Mac's pairing code and pairs a code
/// pasted from another of the user's computers (docs/peer-pairing.md).
struct PeerPairingView: View {
    @ObservedObject var catalog: HerdrConnectionCatalog
    @ObservedObject var destinations: HerdrDestinations
    @Environment(\.dismiss) private var dismiss

    @State private var target = ""
    @State private var session = "default"
    @State private var localCode: PeerPairingCode?
    @State private var pasted = ""
    @State private var addInclude = false
    @State private var busy = false
    @State private var error: String?
    @State private var result: String?
    @State private var remoteSession = ""
    @State private var remoteSessionEdited = false
    @StateObject private var adder: PeerMachineAdder
    @State private var pairedCode: PeerPairingCode?

    init(catalog: HerdrConnectionCatalog, destinations: HerdrDestinations) {
        self.catalog = catalog
        self.destinations = destinations
        _adder = StateObject(wrappedValue: PeerMachineAdder(catalog: catalog))
    }

    private var peerCode: PeerPairingCode? {
        pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : try? PeerPairingCode(code: pasted)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pair Device").font(.title2.weight(.bold))
            Text("Use this only between your own computers, over Tailscale. Copy this Mac's code to the other computer and paste its code below, then compare the fingerprints on both screens.")
                .font(.caption).foregroundStyle(.secondary)

            GroupBox("This Mac") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Reach this Mac at (user@host[:port])", text: $target)
                    TextField("Herdr session to offer", text: $session)
                    HStack {
                        Button("Generate Code") { generate() }.disabled(busy)
                        if let localCode {
                            Button("Copy Code") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(localCode.code, forType: .string)
                            }
                        }
                    }
                    if let localCode {
                        Text(localCode.code).font(.caption.monospaced()).textSelection(.enabled).lineLimit(4)
                        fingerprints(localCode)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
            }

            GroupBox("Other computer") {
                VStack(alignment: .leading, spacing: 8) {
                    TextEditor(text: $pasted).font(.caption.monospaced()).frame(height: 60)
                        .accessibilityLabel("Paste the other device's code here")
                        .overlay(alignment: .topLeading) {
                            if pasted.isEmpty {
                                Text("Paste the other device's code here")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 8)
                                    .padding(.leading, 6)
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                            }
                        }
                    if let code = peerCode {
                        Text("\(code.label) · \(code.target) · session \(code.session) · Herdr \(code.herdrVersion)")
                            .textSelection(.enabled)
                        fingerprints(code)
                        Text("Pairing lets this device's key run only Herdr bridges on this Mac (\(PeerPairing.alias(code.peerID))).")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if !pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(decodeError).font(.caption).foregroundStyle(.red)
                    }
                    TextField("Session on the other computer", text: $remoteSession)
                        .onChange(of: remoteSession) { _, value in
                            remoteSessionEdited = value != (peerCode?.session ?? "")
                        }
                    Toggle("Add “\(PeerPairing.includeLine)” to ~/.ssh/config", isOn: $addInclude)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
            }

            if let result { Text(result).font(.caption).textSelection(.enabled) }
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if let failure = adder.failureText {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Profile written, but Herdr couldn't add the machine. Herdr said:")
                        .font(.caption.weight(.semibold)).foregroundStyle(.red)
                    ScrollView {
                        Text(failure).font(.caption.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 120)
                    HStack {
                        Button("Copy Error") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(failure, forType: .string)
                        }
                        Button("Retry") { retryAdd() }.disabled(busy || adder.state == .adding)
                    }
                }
            }

            HStack {
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Pair") { pair() }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || peerCode == nil)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onChange(of: pasted) { _, _ in
            if !remoteSessionEdited { remoteSession = peerCode?.session ?? "" }
        }
        .task {
            // The host name can block on the network, so it is read off the main thread.
            guard target.isEmpty, let value = await BlockingWork.run({ Optional(PeerPairing.defaultTarget()) }) else { return }
            if target.isEmpty { target = value }
        }
    }

    private var decodeError: String {
        do {
            _ = try PeerPairingCode(code: pasted)
            return ""
        } catch {
            return error.localizedDescription
        }
    }

    private func fingerprints(_ code: PeerPairingCode) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Device key \(code.publicKeyFingerprint)")
            Text("Host key \(code.hostKeyFingerprint)")
        }.font(.caption.monospaced()).textSelection(.enabled)
    }

    private func generate() {
        guard let herdr = RemoteAccessSystem.herdrExecutable else {
            error = "Herdr was not found on this Mac."
            return
        }
        let target = target.trimmingCharacters(in: .whitespacesAndNewlines)
        let session = session.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = RemoteAccessSystem.machineName
        let home = FileManager.default.homeDirectoryForCurrentUser
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                localCode = try await BlockingWork.run {
                    try PeerPairing.localCode(target: target, session: session, label: label, home: home, herdr: herdr)
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func pair() {
        guard let code = peerCode else { return }
        guard let herdr = RemoteAccessSystem.herdrExecutable else {
            error = "Herdr was not found on this Mac."
            return
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let include = addInclude
        busy = true
        error = nil
        result = nil
        Task {
            defer { busy = false }
            let outcome: PeerPairing.Outcome
            do {
                outcome = try await BlockingWork.run { () throws -> PeerPairing.Outcome in
                    let version = try PeerPairing.herdrVersion(executable: herdr)
                    return try PeerPairing.pair(code, home: home, herdr: herdr, herdrVersion: version, addInclude: include)
                }
            } catch {
                self.error = error.localizedDescription
                return
            }
            var notes = ["Paired \(code.label) as \(PeerPairing.alias(code.peerID))."]
            if outcome.keyAlreadyAuthorized {
                notes.append("Its key was already in ~/.ssh/authorized_keys, so that entry was left as it was and may not be restricted to bridges.")
            }
            if outcome.includeAdded { notes.append("Added the Include line to ~/.ssh/config.") }
            result = notes.joined(separator: " ")
            pairedCode = code
            await runAdd(code)
        }
    }

    private func retryAdd() {
        guard let code = pairedCode ?? peerCode else { return }
        Task { await runAdd(code) }
    }

    private func runAdd(_ code: PeerPairingCode) async {
        if await adder.add(code, session: remoteSession) {
            destinations.refresh(catalog.machines)
        }
    }
}
