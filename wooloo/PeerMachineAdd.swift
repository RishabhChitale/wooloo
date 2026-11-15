import Foundation

/// What `PeerMachineAdder` needs from the Herdr connection catalog; tests supply a fake.
@MainActor
protocol PeerMachineManaging: AnyObject {
    func manage(_ arguments: [String]) async throws
}

extension HerdrConnectionCatalog: PeerMachineManaging {
    func manage(_ arguments: [String]) async throws {
        try await manage(arguments, expected: nil)
    }
}

/// Runs `herdr machine add` for a paired peer and keeps Herdr's own error text, so the pairing
/// screen can show it verbatim (copyable) and offer a Retry instead of a generic message.
@MainActor
final class PeerMachineAdder: ObservableObject {
    enum State: Equatable {
        case idle
        case adding
        case added
        /// Herdr's message exactly as reported (stderr, or stdout when it wrote no errors).
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    private let catalog: PeerMachineManaging

    init(catalog: PeerMachineManaging) { self.catalog = catalog }

    /// `session` overrides the session named in the pairing code; blank keeps the code's.
    @discardableResult
    func add(_ code: PeerPairingCode, session: String? = nil) async -> Bool {
        guard state != .adding else { return false }
        state = .adding
        do {
            try await catalog.manage(PeerPairing.machineArguments(for: code, session: session))
            state = .added
            return true
        } catch {
            state = .failed(error.localizedDescription)
            return false
        }
    }

    var failureText: String? {
        if case .failed(let text) = state { return text }
        return nil
    }
}
