import Network
import Observation

/// Single source of truth for "are we online" — checked before every write
/// action (so a failure due to being offline never surfaces as an error,
/// only a genuine API rejection does) and used to trigger the offline
/// queue's replay the moment connectivity actually returns.
@Observable
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "NetworkMonitor")

    var isOnline = true
    /// Fired once, exactly on the offline -> online transition.
    var onBecomeOnline: (() -> Void)?

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                let wasOffline = !self.isOnline
                self.isOnline = online
                if online && wasOffline {
                    self.onBecomeOnline?()
                }
            }
        }
        monitor.start(queue: queue)
    }
}
