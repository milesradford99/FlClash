import Cocoa
import FlutterMacOS
import Security

@main
class AppDelegate: FlutterAppDelegate {
    private var pendingLinks: [String] = []
    private var linksTaken = false

    override func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURL(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
        super.applicationWillFinishLaunching(notification)
    }

    @objc private func handleGetURL(
        _ event: NSAppleEventDescriptor,
        withReplyEvent _: NSAppleEventDescriptor
    ) {
        guard let link = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue else {
            return
        }
        if linksTaken {
            NotificationCenter.default.post(name: .flClashApplicationOpenLink, object: link)
        } else {
            pendingLinks.append(link)
        }
    }

    @objc func takePendingLinks() -> [String] {
        linksTaken = true
        defer { pendingLinks = [] }
        return pendingLinks
    }

    override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        NotificationCenter.default.post(name: .flClashApplicationShouldTerminate, object: nil)
        return .terminateCancel
    }

    override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
      return true
    }

    override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NotificationCenter.default.post(name: .flClashApplicationReopen, object: nil)
        return false
    }
}

enum MacOSTunAuthorization {
    static func authorizeCore() -> String {
        guard let identifier = Bundle.main.bundleIdentifier,
              let directory = Bundle.main.executableURL?.deletingLastPathComponent() else {
            return "error"
        }
        let core = directory.appendingPathComponent("FlClashCore")
        guard let hostInfo = signingInfo(Bundle.main.bundleURL) else { return "signature" }
        guard let team = hostInfo[kSecCodeInfoTeamIdentifier] as? String, !team.isEmpty else {
            return "development"
        }
        guard (try? core.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
              let coreInfo = signingInfo(core),
              coreInfo[kSecCodeInfoTeamIdentifier] as? String == team,
              coreInfo[kSecCodeInfoIdentifier] as? String == identifier + ".core" else {
            return "signature"
        }

        switch FlClashAuthorizeCore(core.path) {
        case FlClashTunReady: return "success"
        case FlClashTunPermissionFailed: return "permissions"
        default: return "error"
        }
    }

    private static func signingInfo(_ url: URL) -> [CFString: Any]? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else {
            return nil
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess else {
            return nil
        }
        return information as? [CFString: Any]
    }
}

// rust_api's window module observes these; the names are fixed there.
extension Notification.Name {
    static let flClashApplicationShouldTerminate = Notification.Name("FlClashApplicationShouldTerminate")
    static let flClashApplicationReopen = Notification.Name("FlClashApplicationReopen")
    static let flClashApplicationOpenLink = Notification.Name("FlClashApplicationOpenLink")
}
