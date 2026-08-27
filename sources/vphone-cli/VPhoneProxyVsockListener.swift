import Foundation
import Virtualization
import VPhoneCore

/// Bridges guest-originated vsock connections into the proxy relay.
///
/// The host firewall (default-deny pf rules) can silently drop inbound TCP
/// on the vmnet bridge, so the guest reaches the relay over virtio-vsock
/// instead: vphoned forwards guest-loopback TCP to vsock port 1338, this
/// listener hands each connection's fd to VPhoneProxyRelay.
final class VPhoneProxyVsockListener: NSObject, VZVirtioSocketListenerDelegate {
    static let vsockPort: UInt32 = 1338

    private let relay: VPhoneProxyRelay
    private var listener: VZVirtioSocketListener?
    private let lock = NSLock()
    private nonisolated(unsafe) var connections: [VZVirtioSocketConnection] = []

    init(relay: VPhoneProxyRelay) {
        self.relay = relay
        super.init()
    }

    /// Register on the VM's socket device (call before the guest connects).
    func attach(to device: VZVirtioSocketDevice) {
        let listener = VZVirtioSocketListener()
        listener.delegate = self
        device.setSocketListener(listener, forPort: Self.vsockPort)
        self.listener = listener
    }

    /// VZVirtioSocketConnection owns its file descriptor and closes it on
    /// release — retain every connection for the process lifetime (the relay
    /// only shuts the fd down, never closes it).
    nonisolated func listener(
        _: VZVirtioSocketListener,
        shouldAcceptNewConnection connection: VZVirtioSocketConnection,
        from _: VZVirtioSocketDevice
    ) -> Bool {
        lock.lock()
        connections.append(connection)
        lock.unlock()
        relay.handleExternalConnection(fd: connection.fileDescriptor)
        return true
    }
}
