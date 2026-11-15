import AppKit
import SystemConfiguration

/// The primary IPv4 route as configd sees it. Our own 0/1 and 128/1 routes do
/// not change it, so a difference means the real network changed.
struct NetworkIdentity: Equatable, CustomStringConvertible {
    let interface: String
    let router: String

    var description: String {
        return router.isEmpty ? interface : "\(interface) через \(router)"
    }
}

/// Reports changes of the primary network and wake from sleep. Callbacks run
/// on the main queue.
final class NetworkChangeMonitor {
    var onChange: (() -> Void)?
    var onWake: (() -> Void)?

    private static let globalIPv4Key = "State:/Network/Global/IPv4" as CFString
    private var store: SCDynamicStore?
    private var wakeObserver: NSObjectProtocol?

    func start() {
        guard store == nil else { return }
        var context = SCDynamicStoreContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let callback: SCDynamicStoreCallBack = { _, _, info in
            guard let info = info else { return }
            Unmanaged<NetworkChangeMonitor>.fromOpaque(info).takeUnretainedValue().onChange?()
        }
        guard let created = SCDynamicStoreCreate(nil, "MojaveRay.monitor" as CFString, callback, &context) else {
            return
        }
        SCDynamicStoreSetNotificationKeys(created, [NetworkChangeMonitor.globalIPv4Key] as CFArray, nil)
        SCDynamicStoreSetDispatchQueue(created, DispatchQueue.main)
        store = created
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.onWake?()
        }
    }

    func stop() {
        if let current = store {
            SCDynamicStoreSetDispatchQueue(current, nil)
        }
        store = nil
        if let observer = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        wakeObserver = nil
    }

    deinit {
        stop()
    }

    /// Reads the current primary network; safe from any thread.
    static func current() -> NetworkIdentity? {
        guard let reader = SCDynamicStoreCreate(nil, "MojaveRay.reader" as CFString, nil, nil),
              let value = SCDynamicStoreCopyValue(reader, globalIPv4Key) as? [String: Any],
              let interface = value["PrimaryInterface"] as? String,
              !interface.isEmpty else {
            return nil
        }
        return NetworkIdentity(interface: interface, router: value["Router"] as? String ?? "")
    }
}
