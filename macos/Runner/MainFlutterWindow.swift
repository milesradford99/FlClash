import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
    private var hiddenAtLaunch = false

    override func awakeFromNib() {
        let flutterViewController = FlutterViewController()
        let windowFrame = self.frame
        self.contentViewController = flutterViewController
        self.setFrame(windowFrame, display: true)
        
        RegisterGeneratedPlugins(registry: flutterViewController)
        let registrar = flutterViewController.registrar(forPlugin: "ManagedNetworkProtection")
        let channel = FlutterMethodChannel(
            name: "flclash/managed_isp", binaryMessenger: registrar.messenger
        )
        if #available(macOS 15.0, *) {
            let protection = ManagedNetworkProtection()
            channel.setMethodCallHandler { call, reply in
                Task { @MainActor in
                    do {
                        switch call.method {
                        case "available":
                            reply(protection.available)
                        case "tunReady":
                            reply(protection.tunReady)
                        case "environment":
                            reply(await protection.environment())
                        case "environmentShortcut":
                            guard let args = call.arguments as? [String: String],
                                  let kind = args["kind"] else {
                                reply(FlutterError(code: "invalidShortcut", message: nil, details: nil))
                                return
                            }
                            try protection.openEnvironmentShortcut(kind, directory: args["directory"])
                            reply(nil)
                        case "openIspChrome":
                            guard let port = call.arguments as? Int else {
                                reply(FlutterError(code: "invalidPort", message: nil, details: nil))
                                return
                            }
                            try protection.openIspChrome(port)
                            reply(nil)
                        case "openBrowserProbe":
                            guard let args = call.arguments as? [String: String],
                                  let html = args["html"], let directory = args["directory"] else {
                                reply(FlutterError(code: "invalidProbe", message: nil, details: nil))
                                return
                            }
                            try protection.openBrowserProbe(html, directory: directory)
                            reply(nil)
                        case "openChromeProfile":
                            try protection.openChromeProfile()
                            reply(nil)
                        case "protectedProfile":
                            reply(try await protection.protectedValue("id"))
                        case "protectedSource":
                            reply(try await protection.protectedValue("sourceId"))
                        case "arm":
                            guard let arguments = call.arguments as? [String: Any] else {
                                reply(FlutterError(code: "invalidPolicy", message: nil, details: nil))
                                return
                            }
                            try await protection.arm(arguments)
                            reply(nil)
                        case "disarm":
                            try await protection.disarm()
                            reply(nil)
                        case "load", "remove":
                            guard let id = call.arguments as? Int else {
                                reply(FlutterError(code: "invalidProfile", message: nil, details: nil))
                                return
                            }
                            reply(try protection.keychain(call.method, id: id))
                        case "save":
                            guard let arguments = call.arguments as? [String: Any],
                                  let id = arguments["id"] as? Int,
                                  let data = arguments["data"] as? [String: Any] else {
                                reply(FlutterError(code: "invalidProfile", message: nil, details: nil))
                                return
                            }
                            reply(try protection.keychain(call.method, id: id, data: data))
                        case "writePrivate":
                            guard let arguments = call.arguments as? [String: String],
                                  let path = arguments["path"], let content = arguments["config"] else {
                                reply(FlutterError(code: "invalidConfig", message: nil, details: nil))
                                return
                            }
                            try protection.writePrivate(path: path, config: content)
                            reply(nil)
                        default:
                            reply(FlutterMethodNotImplemented)
                        }
                    } catch {
                        reply(FlutterError(
                            code: "managedIspError",
                            message: "macOS network protection did not complete.",
                            details: nil
                        ))
                    }
                }
            }
        } else {
            channel.setMethodCallHandler { call, reply in
                switch call.method {
                case "available": reply(false)
                case "protectedProfile", "protectedSource": reply(nil)
                default: reply(FlutterError(code: "macOS15Required", message: nil, details: nil))
                }
            }
        }
        super.awakeFromNib()
    }
    override public func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        super.order(place, relativeTo: otherWin)
        // Only the first order hides the window, which Dart shows once it is configured.
        if !hiddenAtLaunch {
            hiddenAtLaunch = true
            setIsVisible(false)
        }
    }
}
