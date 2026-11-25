import Foundation
import Network

final class NetworkReachabilityMonitor {
    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(label: "com.parkspot.history.reachability")
    private let lock = NSLock()
    private var _isConnected = false

    var onConnectionRestored: (() -> Void)?

    var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isConnected
    }

    init(startImmediately: Bool = true, initialConnectionState: Bool = false) {
        monitor = NWPathMonitor()
        _isConnected = initialConnectionState
        monitor.pathUpdateHandler = { [weak self] path in
            self?.handlePathUpdate(path)
        }
        if startImmediately {
            monitor.start(queue: queue)
        }
    }

    deinit {
        monitor.cancel()
    }

    private func handlePathUpdate(_ path: NWPath) {
        lock.lock()
        let previous = _isConnected
        _isConnected = (path.status == .satisfied)
        let restored = !previous && _isConnected
        lock.unlock()

        if restored {
            onConnectionRestored?()
        }
    }
}
