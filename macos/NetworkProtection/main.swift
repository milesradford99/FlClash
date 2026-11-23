import Foundation
import NetworkExtension

final class FilterStatus: NSObject, NSXPCListenerDelegate, FlClashFilterStatus {
    static let shared = FilterStatus()

    private let lock = NSLock()
    private var packet: String?
    private var socket: String?
    private var policy: FilterPolicy?

    func setPacket(_ value: FilterPolicy?) {
        lock.lock()
        packet = value?.token
        policy = value
        lock.unlock()
    }

    func setSocket(_ value: String?) {
        lock.lock()
        socket = value
        lock.unlock()
    }

    func currentPolicy() -> FilterPolicy? {
        lock.lock()
        defer { lock.unlock() }
        guard let policy, packet == policy.token, socket == policy.token else { return nil }
        return policy
    }

    func configure(_ token: String, endpoints: [String], reply: @escaping (Bool) -> Void) {
        lock.lock()
        let updated = socket == token && packet == token ? policy?.replacingEndpoints(endpoints) : nil
        if let updated { policy = updated }
        lock.unlock()
        reply(updated != nil)
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard let identifier = Bundle.main.bundleIdentifier, identifier.hasSuffix(".filter"),
              let team = Bundle.main.object(forInfoDictionaryKey: "FilterTeam") as? String,
              !team.isEmpty else { return false }
        connection.setCodeSigningRequirement(FilterPolicy.signingRequirement(
            identifier: String(identifier.dropLast(".filter".count)), team: team
        ))
        connection.exportedInterface = NSXPCInterface(with: FlClashFilterStatus.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }
}

guard let service = FilterPolicy.machService else { exit(EX_CONFIG) }
NEProvider.startSystemExtensionMode()
let listener = NSXPCListener(machServiceName: service)
listener.delegate = FilterStatus.shared
listener.resume()
dispatchMain()
