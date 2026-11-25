import Foundation
import Network

/// Tells the session when the network path becomes usable again (Wi-Fi ↔ cellular, Tailscale up).
/// The monitor delivers on the main queue, so the handler can hop into the main actor synchronously.
@MainActor
final class NetworkMonitor {
    var onPathUsable: (() -> Void)?

    private let monitor: NWPathMonitor = NWPathMonitor()
    private var lastSatisfied: Bool?
    private var lastInterfaces: [String] = []

    func start() {
        monitor.pathUpdateHandler = { [weak self] (path: NWPath) in
            let satisfied: Bool = path.status == .satisfied
            let interfaces: [String] = path.availableInterfaces.map { (i: NWInterface) -> String in i.name }
            MainActor.assumeIsolated {
                self?.handle(satisfied: satisfied, interfaces: interfaces)
            }
        }
        monitor.start(queue: DispatchQueue.main)
    }

    func stop() {
        monitor.cancel()
    }

    private func handle(satisfied: Bool, interfaces: [String]) {
        defer {
            lastSatisfied = satisfied
            lastInterfaces = interfaces
        }
        guard let previous = lastSatisfied else { return }   // first report: nothing changed yet
        if satisfied && (!previous || interfaces != lastInterfaces) {
            onPathUsable?()
        }
    }
}
