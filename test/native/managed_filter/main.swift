import Foundation

func ipv4(protocolNumber: UInt8, destination: [UInt8], port: UInt16, source: UInt16 = 49152) -> [UInt8] {
    let total = protocolNumber == 6 ? 40 : 28
    var packet = [UInt8](repeating: 0, count: total)
    packet[0] = 0x45
    packet[3] = UInt8(total)
    packet[9] = protocolNumber
    packet.replaceSubrange(16..<20, with: destination)
    packet[20] = UInt8(source >> 8)
    packet[21] = UInt8(truncatingIfNeeded: source)
    packet[22] = UInt8(port >> 8)
    packet[23] = UInt8(truncatingIfNeeded: port)
    return packet
}

let input: [String: Any] = [
    "token": UUID().uuidString,
    "tun": "utun223",
    "endpoints": ["tcp/192.0.2.4/443", "udp/198.51.100.2/8443"],
]
guard let policy = FilterPolicy(input) else { fatalError("Fixture policy was rejected") }

func allowed(_ packet: [UInt8]) -> Bool {
    packet.withUnsafeBytes { policy.allowsIpv4Packet($0) }
}

assert(allowed(ipv4(protocolNumber: 6, destination: [192, 0, 2, 4], port: 443)))
assert(allowed(ipv4(protocolNumber: 17, destination: [198, 51, 100, 2], port: 8443)))
assert(!allowed(ipv4(protocolNumber: 6, destination: [192, 0, 2, 4], port: 444)))
assert(!allowed(ipv4(protocolNumber: 6, destination: [192, 0, 2, 5], port: 443)))
assert(!allowed(ipv4(protocolNumber: 17, destination: [192, 0, 2, 4], port: 443)))
assert(allowed(ipv4(protocolNumber: 17, destination: [255, 255, 255, 255], port: 67, source: 68)))
assert(!allowed(ipv4(protocolNumber: 17, destination: [255, 255, 255, 255], port: 67)))
assert(!allowed([UInt8](repeating: 0x60, count: 40)))
assert(!allowed([]))
var fragment = ipv4(protocolNumber: 6, destination: [192, 0, 2, 4], port: 443)
fragment[6] = 0x20
assert(!allowed(fragment))
assert(policy.replacingEndpoints(["tcp/127.0.0.1/443"]) == nil)
assert(policy.replacingEndpoints(["tcp/192.0.2.4/0"]) == nil)
assert(policy.replacingEndpoints([]) == nil)
