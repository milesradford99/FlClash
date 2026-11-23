import Foundation

@objc protocol FlClashFilterStatus {
    func configure(_ token: String, endpoints: [String], reply: @escaping (Bool) -> Void)
}

struct FilterPolicy {
    let token: String
    let tun: String
    let endpoints: Set<String>

    init?(_ values: [String: Any]?) {
        guard let values,
              let token = values["token"] as? String, UUID(uuidString: token) != nil,
              let tun = values["tun"] as? String,
              tun == "utun223",
              let list = values["endpoints"] as? [String],
              !list.isEmpty, list.count <= 8192,
              list.allSatisfy(Self.validEndpoint) else { return nil }
        self.token = token
        self.tun = tun
        self.endpoints = Set(list)
    }

    private static func validEndpoint(_ value: String) -> Bool {
        let fields = value.split(separator: "/")
        guard fields.count == 3, fields[0] == "tcp" || fields[0] == "udp",
              let port = UInt16(fields[2]), port != 0 else { return false }
        let bytes = fields[1].split(separator: ".")
        return bytes.count == 4 &&
            bytes.allSatisfy { UInt8($0).map(String.init) == String($0) } &&
            UInt8(bytes[0]).map { $0 > 0 && $0 != 127 && $0 < 224 } == true
    }

    func allowsIpv4Packet(_ data: UnsafeRawBufferPointer) -> Bool {
        guard data.count >= 20, data[0] >> 4 == 4 else { return false }
        let header = Int(data[0] & 15) * 4
        let totalLength = Int(data[2]) * 256 + Int(data[3])
        let fragment = UInt16(data[6]) * 256 + UInt16(data[7])
        guard header >= 20, totalLength >= header + 8,
              data.count >= totalLength, fragment & 0x3fff == 0 else { return false }

        let protocolName: String
        switch data[9] {
        case 6:
            guard totalLength >= header + 20 else { return false }
            protocolName = "tcp"
        case 17: protocolName = "udp"
        default: return false
        }

        let source = UInt16(data[header]) * 256 + UInt16(data[header + 1])
        let port = UInt16(data[header + 2]) * 256 + UInt16(data[header + 3])
        let address = data[16..<20].map(String.init).joined(separator: ".")
        if protocolName == "udp", source == 68, port == 67, address == "255.255.255.255" {
            return true
        }
        return endpoints.contains("\(protocolName)/\(address)/\(port)")
    }

    func replacingEndpoints(_ addresses: [String]) -> Self? {
        Self(["token": token, "tun": tun, "endpoints": addresses])
    }

    static func signingRequirement(identifier: String, team: String) -> String {
        "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and identifier \"\(identifier)\""
    }

    static var machService: String? {
        let configuration = Bundle.main.object(forInfoDictionaryKey: "NetworkExtension") as? [String: Any]
        return configuration?["NEMachServiceName"] as? String
    }
}
