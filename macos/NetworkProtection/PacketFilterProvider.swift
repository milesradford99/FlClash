import Network
import NetworkExtension

final class PacketFilterProvider: NEFilterPacketProvider {
    override func startFilter(completionHandler: @escaping (Error?) -> Void) {
        let policy = FilterPolicy(filterConfiguration.vendorConfiguration)
        packetHandler = { _, interface, direction, bytes, count in
            if direction == .inbound || nw_interface_get_type(interface) == nw_interface_type_loopback {
                return .allow
            }
            guard let policy = FilterStatus.shared.currentPolicy() else { return .drop }
            if String(cString: nw_interface_get_name(interface)) == policy.tun {
                return .allow
            }
            let data = UnsafeRawBufferPointer(start: bytes, count: count)
            return policy.allowsIpv4Packet(data) ? .allow : .drop
        }
        FilterStatus.shared.setPacket(policy)
        completionHandler(nil)
    }

    override func stopFilter(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        FilterStatus.shared.setPacket(nil)
        completionHandler()
    }
}
