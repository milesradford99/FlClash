import Network
import NetworkExtension
import Security

@available(macOS 15.0, *)
final class SocketFilterProvider: NEFilterDataProvider {
    private var policy: FilterPolicy?
    private var coreRequirement: SecRequirement?

    override func startFilter(completionHandler: @escaping (Error?) -> Void) {
        policy = FilterPolicy(filterConfiguration.vendorConfiguration)
        if let identifier = Bundle.main.bundleIdentifier?.dropLast(".filter".count),
           let team = Bundle.main.object(forInfoDictionaryKey: "FilterTeam") as? String,
           !team.isEmpty {
            let expression = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and identifier \"\(identifier).core\""
            SecRequirementCreateWithString(expression as CFString, [], &coreRequirement)
        }
        apply(NEFilterSettings(rules: [], defaultAction: .filterData)) { error in
            if error == nil, self.coreRequirement != nil {
                FilterStatus.shared.setSocket(self.policy?.token)
            }
            completionHandler(error)
        }
    }

    override func stopFilter(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        FilterStatus.shared.setSocket(nil)
        completionHandler()
    }

    override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        if flow.direction == .inbound { return .allow() }
        guard let policy = FilterStatus.shared.currentPolicy(),
              let flow = flow as? NEFilterSocketFlow,
              case let .hostPort(host, port)? = flow.remoteFlowEndpoint else { return .drop() }

        let ip: String
        switch host {
        case .ipv4(let address):
            ip = address.rawValue.map(String.init).joined(separator: ".")
        case .ipv6(let address):
            let bytes = address.rawValue
            guard bytes.prefix(12).elementsEqual([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 255, 255])
            else { return .allow() }
            ip = bytes.suffix(4).map(String.init).joined(separator: ".")
        default:
            return .drop()
        }
        let transport = flow.socketProtocol == IPPROTO_UDP ? "udp" : "tcp"
        guard policy.endpoints.contains("\(transport)/\(ip)/\(port.rawValue)") else { return .allow() }
        guard let requirement = coreRequirement, let audit = flow.sourceProcessAuditToken else { return .drop() }
        var process: SecCode?
        let attributes = [kSecGuestAttributeAudit: audit] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &process) == errSecSuccess,
              let process, SecCodeCheckValidity(process, [], requirement) == errSecSuccess else {
            return .drop()
        }
        return .allow()
    }
}
