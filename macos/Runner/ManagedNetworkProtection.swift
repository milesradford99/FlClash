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

    func environment() async -> [String: Any] {
        let chrome = "com.google.Chrome" as CFString
        let webRtc = "WebRtcIPHandling" as CFString
        let doh = "DnsOverHttpsMode" as CFString
        let templates = "DnsOverHttpsTemplates" as CFString
        let installed = chromeURL != nil
        let resolvers = await Task.detached { Self.resolverCounts() }.value
        return [
            "locale": Locale.current.identifier,
            "languages": Locale.preferredLanguages,
            "timeZone": TimeZone.current.identifier,
            "chromeInstalled": installed,
            "chromeProfiles": installed ? Self.chromeProfiles() : [],
            "webRtcForced": CFPreferencesAppValueIsForced(webRtc, chrome),
            "webRtcValue": CFPreferencesCopyAppValue(webRtc, chrome) as? String ?? "",
            "dohMode": CFPreferencesCopyAppValue(doh, chrome) as? String ?? "",
            "dohForced": CFPreferencesAppValueIsForced(doh, chrome),
            "dohTemplatesSet": !(CFPreferencesCopyAppValue(templates, chrome) as? String ?? "").isEmpty,
            "dohTemplatesForced": CFPreferencesAppValueIsForced(templates, chrome),
            "resolvers": resolvers,
            "tunReady": tunReady,
        ]
    }

    private var chromeURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome")
    }

    private static let ispChromeID = "flclash-isp-chrome"

    private static var ispChromeData: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent(Bundle.main.bundleIdentifier ?? "flclash")
            .appendingPathComponent("Chrome ISP")
    }

    private static func chromeProfiles() -> [[String: String]] {
        var result = [[String: String]]()
        if let data = ispChromeData, FileManager.default.fileExists(atPath: data.path) {
            result.append(["id": ispChromeID, "name": "Chrome ISP"])
        }
        let state = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome/Local State")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: state.path),
              let size = attrs[.size] as? NSNumber, size.intValue <= 16 * 1024 * 1024,
              let data = try? Data(contentsOf: state),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = root["profile"] as? [String: Any],
              let cache = profile["info_cache"] as? [String: [String: Any]] else { return result }
        return result + cache.keys.sorted().compactMap { directory in
            guard validChromeDirectory(directory), cache[directory]?["is_omitted"] as? Bool != true
            else { return nil }
            let name = (cache[directory]?["name"] as? String ?? directory)
                .replacingOccurrences(of: "[[:cntrl:]]", with: "", options: .regularExpression)
            return ["id": directory, "name": String(name.prefix(80))]
        }
    }

    private static func validChromeDirectory(_ directory: String) -> Bool {
        directory.range(of: #"^(Default|Profile [0-9]{1,8})$"#, options: .regularExpression) != nil
    }

    private nonisolated static func resolverCounts() -> [String: Int] {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/scutil")
        process.arguments = ["--dns"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.environment = ["LC_ALL": "C"]
        do { try process.run() } catch { return [:] }
        let bytes = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let output = String(data: bytes, encoding: .utf8)
        else { return [:] }
        var counts = ["default": 0, "domain": 0, "scoped": 0]
        var scoped = false
        for block in output.components(separatedBy: "\n\n") {
            if block.contains("for scoped queries") { scoped = true }
            guard block.contains("resolver #"), block.contains("nameserver[") else { continue }
            let byDomain = block.split(separator: "\n").contains {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix("domain ")
            }
            let key = scoped ? "scoped" : (byDomain ? "domain" : "default")
            counts[key, default: 0] += 1
        }
        return counts
    }

    func openEnvironmentShortcut(_ kind: String, directory: String?) throws {
        let settings: [String: String] = [
            "locale": "com.apple.Localization-Settings.extension",
            "timeZone": "com.apple.Date-Time-Settings.extension",
            "profiles": "com.apple.Profiles-Settings.extension",
        ]
        if let pane = settings[kind] {
            guard let url = URL(string: "x-apple.systempreferences:" + pane),
                  NSWorkspace.shared.open(url) else { throw ProtectionError.unavailable }
            return
        }
        let pages: [String: String] = [
            "version": "chrome://version/",
            "policy": "chrome://policy/",
            "security": "chrome://settings/security",
            "languages": "chrome://settings/languages",
            "picker": "chrome://profile-picker/",
        ]
        guard let target = pages[kind] else { throw ProtectionError.unavailable }
        try openChrome(target, directory: directory)
    }

    func openBrowserProbe(_ html: String, directory: String) throws {
        guard html.utf8.count <= 64 * 1024 else { throw ProtectionError.unavailable }
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlClash-ISP-browser-check.html")
        try Data(html.utf8).write(to: file, options: .atomic)
        try openChrome(file.absoluteString, directory: directory)
    }

    func openIspChrome(_ port: Int) throws {
        guard (1...65535).contains(port) else { throw ProtectionError.unavailable }
        try openChrome("about:blank", directory: Self.ispChromeID, ispPort: port)
    }

    private func openChrome(_ target: String, directory: String?, ispPort: Int? = nil) throws {
        guard let app = chromeURL, let executable = Bundle(url: app)?.executableURL else {
            throw ProtectionError.unavailable
        }
        var arguments: [String] = []
        if directory == Self.ispChromeID {
            guard let data = Self.ispChromeData else { throw ProtectionError.unavailable }
            arguments = [
                "--user-data-dir=" + data.path,
                "--profile-directory=Default",
                "--no-first-run",
                "--proxy-server=socks5://127.0.0.1:" + String(ispPort ?? 17890),
                "--force-webrtc-ip-handling-policy=disable_non_proxied_udp",
            ]
        } else if let directory {
            guard Self.validChromeDirectory(directory),
                  Self.chromeProfiles().contains(where: { $0["id"] == directory })
            else { throw ProtectionError.unavailable }
            arguments.append("--profile-directory=" + directory)
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments + [target]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    func openChromeProfile() throws {
        let chrome = "com.google.Chrome" as CFString
        let key = "WebRtcIPHandling" as CFString
        guard chromeURL != nil, !CFPreferencesAppValueIsForced(key, chrome) else {
            throw ProtectionError.unavailable
        }
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
