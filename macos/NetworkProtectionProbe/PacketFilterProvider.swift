import Network
import NetworkExtension

final class PacketFilterProvider: NEFilterPacketProvider {
    override func startFilter(completionHandler: @escaping (Error?) -> Void) {
        packetHandler = { _, interface, direction, _, _ in
            if direction == .inbound || nw_interface_get_type(interface) == nw_interface_type_loopback {
                return .allow
            }
            return .drop
        }
        completionHandler(nil)
    }
}
