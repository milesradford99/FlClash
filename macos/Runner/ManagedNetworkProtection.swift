@preconcurrency import Foundation
import AppKit
import NetworkExtension
import Security
import SystemExtensions

@available(macOS 15.0, *)
@MainActor
final class ManagedNetworkProtection: NSObject, OSSystemExtensionRequestDelegate {
    private let manager = NEFilterManager.shared()
    private var activation: CheckedContinuation<Void, Error>?
    private var activationRequest: OSSystemExtensionRequest?
    private var changing = false

    private var identifier: String { (Bundle.main.bundleIdentifier ?? "") + ".filter" }
    private var extensionBundle: Bundle? {
        let directory = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/SystemExtensions")
        guard let bundle = Bundle(url: directory.appendingPathComponent(identifier + ".systemextension")),
              bundle.bundleIdentifier == identifier else { return nil }
        return bundle
    }

    var available: Bool { extensionBundle != nil }

    var tunReady: Bool {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return false }
        defer { freeifaddrs(first) }
        var next: UnsafeMutablePointer<ifaddrs>? = first
        while let item = next {
            let entry = item.pointee
            next = entry.ifa_next
            guard String(cString: entry.ifa_name) == "utun223",
                  entry.ifa_flags & UInt32(IFF_UP) != 0,
                  let address = entry.ifa_addr,
                  address.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let ipv4 = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee
            if UInt32(bigEndian: ipv4.sin_addr.s_addr) == 0xC6128001 { return true }
        }
        return false
    }

    func environment() -> [String: Any] {
        let chrome = "com.google.Chrome" as CFString
        let key = "WebRtcIPHandling" as CFString
        return [
            "locale": Locale.current.identifier,
            "timeZone": TimeZone.current.identifier,
            "chromeInstalled": NSWorkspace.shared.urlForApplication(withBundleIdentifier: chrome as String) != nil,
            "webRtcManaged": CFPreferencesAppValueIsForced(key, chrome) &&
                CFPreferencesCopyAppValue(key, chrome) as? String == "disable_non_proxied_udp",
        ]
    }

    func openChromeProfile() throws {
        let name = "FlClash ISP Chrome WebRTC"
        let domain = (Bundle.main.bundleIdentifier ?? "flclash") + ".chrome.webrtc"
        let policy: [String: Any] = [
            "PayloadType": "com.apple.ManagedClient.preferences",
            "PayloadVersion": 1,
            "PayloadIdentifier": domain + ".policy",
            "PayloadUUID": "864C50F0-9B1B-43C7-84CF-A5E935BB7A15",
            "PayloadDisplayName": name,
            "PayloadContent": [
                "com.google.Chrome": [
                    "Forced": [["mcx_preference_settings": [
                        "WebRtcIPHandling": "disable_non_proxied_udp",
                    ]]],
                ],
            ],
        ]
        let profile: [String: Any] = [
            "PayloadType": "Configuration",
            "PayloadVersion": 1,
            "PayloadIdentifier": domain,
            "PayloadScope": "System",
            "PayloadUUID": "7AE030B6-3101-411B-9A92-0E2FDE44F68D",
            "PayloadDisplayName": name,
            "PayloadContent": [policy],
        ]
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(domain + ".mobileconfig")
        let bytes = try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
        try bytes.write(to: file, options: .atomic)
        guard NSWorkspace.shared.open(file) else { throw ProtectionError.unavailable }
    }

    func protectedValue(_ key: String) async throws -> Int? {
        guard available else { return nil }
        try await manager.loadFromPreferences()
        guard manager.isEnabled, manager.providerConfiguration?.filterPacketProviderBundleIdentifier == identifier
        else { return nil }
        guard let id = manager.providerConfiguration?.vendorConfiguration?[key] as? Int else {
            throw ProtectionError.invalidPolicy
        }
        return id
    }

    func arm(_ input: [String: Any]) async throws {
        guard !changing else { throw ProtectionError.busy }
        changing = true
        defer { changing = false }
        guard let bundle = extensionBundle,
              let info = bundle.object(forInfoDictionaryKey: "NetworkExtension") as? [String: Any],
              let service = info["NEMachServiceName"] as? String, !service.isEmpty,
              let team = bundle.object(forInfoDictionaryKey: "FilterTeam") as? String, !team.isEmpty,
              let id = input["id"] as? Int, let source = input["sourceId"] as? Int,
              let endpoints = input["endpoints"] as? [String], let tun = input["tun"] as? String
        else { throw ProtectionError.unavailable }
        let values: [String: Any] = [
            "token": UUID().uuidString, "id": id, "sourceId": source,
            "endpoints": endpoints, "tun": tun,
        ]
        guard let policy = FilterPolicy(values) else { throw ProtectionError.invalidPolicy }

        try await manager.loadFromPreferences()
        if manager.isEnabled {
            guard let configuration = manager.providerConfiguration,
                  configuration.filterPacketProviderBundleIdentifier == identifier,
                  configuration.vendorConfiguration?["id"] as? Int == id,
                  configuration.vendorConfiguration?["sourceId"] as? Int == source,
                  let existing = FilterPolicy(configuration.vendorConfiguration)
            else { throw ProtectionError.policyChanged }
            try await waitForProvider(existing.token, service, team, endpoints)
            return
        }

        try await withCheckedThrowingContinuation { continuation in
            activation = continuation
            let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: identifier, queue: .main)
            activationRequest = request
            request.delegate = self
            OSSystemExtensionManager.shared.submitRequest(request)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 160_000_000_000)
                self?.finishActivation(request, error: ProtectionError.notReady)
            }
        }

        let configuration = NEFilterProviderConfiguration()
        configuration.filterPackets = true
        configuration.filterSockets = true
        configuration.filterPacketProviderBundleIdentifier = identifier
        configuration.filterDataProviderBundleIdentifier = identifier
        configuration.vendorConfiguration = values
        manager.providerConfiguration = configuration
        manager.localizedDescription = "FlClash Fixed ISP Protection"
        manager.isEnabled = true
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
        guard manager.isEnabled,
              manager.providerConfiguration?.vendorConfiguration?["token"] as? String == policy.token
        else { throw ProtectionError.notReady }
        try await waitForProvider(policy.token, service, team, endpoints)
    }

    func disarm() async throws {
        guard !changing else { throw ProtectionError.busy }
        changing = true
        defer { changing = false }
        try await manager.loadFromPreferences()
        guard manager.isEnabled else { return }
        guard manager.providerConfiguration?.filterPacketProviderBundleIdentifier == identifier
        else { throw ProtectionError.invalidPolicy }
        manager.isEnabled = false
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
        guard !manager.isEnabled else { throw ProtectionError.notReady }
    }

    private func waitForProvider(_ token: String, _ service: String, _ team: String, _ endpoints: [String]) async throws {
        for _ in 0..<20 {
            if await configure(token, service, team, endpoints) { return }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw ProtectionError.notReady
    }

    private func configure(_ token: String, _ service: String, _ team: String, _ endpoints: [String]) async -> Bool {
        await withCheckedContinuation { continuation in
            let connection = NSXPCConnection(machServiceName: service, options: .privileged)
            connection.setCodeSigningRequirement(FilterPolicy.signingRequirement(identifier: identifier, team: team))
            let reply = FilterReply(continuation)
            connection.remoteObjectInterface = NSXPCInterface(with: FlClashFilterStatus.self)
            connection.resume()
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in reply.finish(false) }
            (proxy as? FlClashFilterStatus)?.configure(token, endpoints: endpoints) { ready in reply.finish(ready) }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000)
                reply.finish(false)
                connection.invalidate()
            }
        }
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {}

    nonisolated func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties, withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        Task { @MainActor in
            finishActivation(request, error: result == .completed ? nil : ProtectionError.notReady)
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        Task { @MainActor in
            finishActivation(request, error: error)
        }
    }

    private func finishActivation(_ request: OSSystemExtensionRequest, error: Error?) {
        guard activationRequest === request else { return }
        let continuation = activation
        activation = nil
        activationRequest = nil
        if let error { continuation?.resume(throwing: error) }
        else { continuation?.resume() }
    }

    func keychain(_ method: String, id: Int, data: [String: Any]? = nil) throws -> Any? {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "") + ".protected-profiles",
            kSecAttrAccount as String: String(id),
        ]
        let status: OSStatus
        switch method {
        case "load":
            var result: CFTypeRef?
            status = SecItemCopyMatching(base.merging([kSecReturnData as String: true]) { a, _ in a } as CFDictionary, &result)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess, let bytes = result as? Data else { throw ProtectionError.keychain }
            return try JSONSerialization.jsonObject(with: bytes)
        case "save":
            guard let data else { throw ProtectionError.keychain }
            let attributes = [kSecValueData as String: try JSONSerialization.data(withJSONObject: data)]
            let changed = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
            status = changed == errSecItemNotFound
                ? SecItemAdd(base.merging(attributes) { a, _ in a } as CFDictionary, nil)
                : changed
        default:
            status = SecItemDelete(base as CFDictionary)
            if status == errSecItemNotFound { return nil }
        }
        guard status == errSecSuccess else { throw ProtectionError.keychain }
        return nil
    }

    func writePrivate(path: String, config: String) throws {
        let target = URL(fileURLWithPath: path)
        let temp = target.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        guard FileManager.default.createFile(
            atPath: temp.path, contents: Data(config.utf8),
            attributes: [.posixPermissions: 0o600]
        ), rename(temp.path, target.path) == 0 else { throw ProtectionError.privateFile }
    }
}

private final class FilterReply: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }

    func finish(_ result: Bool) {
        lock.lock()
        let reply = continuation
        continuation = nil
        lock.unlock()
        reply?.resume(returning: result)
    }
}

private enum ProtectionError: Error {
    case unavailable, invalidPolicy, notReady, policyChanged, keychain, privateFile, busy
}
