import Cocoa

// 1. A foolproof file logger that macOS cannot filter or hide.
class FileLogger {
    static func log(_ message: String) {
        let logPath = "/tmp/auraras_helper_debug.log"
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let timestamp = formatter.string(from: Date())
        let fullMessage = "[\(timestamp)] \(message)\n"
        
        if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: logPath)) {
            handle.seekToEndOfFile()
            if let data = fullMessage.data(using: .utf8) {
                handle.write(data)
            }
            handle.closeFile()
        } else {
            try? fullMessage.write(to: URL(fileURLWithPath: logPath), atomically: true, encoding: .utf8)
        }
    }
}

// 2. Explicit entry point to bypass ghost Xcode Storyboards.
@main
struct AppRunner {
    // CRITICAL FIX: NSApplication.delegate is a weak property.
    // We MUST hold a strong reference here so it isn't instantly destroyed!
    static let appDelegate = AppDelegate()
    
    static func main() {
        FileLogger.log("--- AuraRAS Helper Executable Started ---")
        let app = NSApplication.shared
        app.delegate = appDelegate
        app.run()
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    
    lazy var daemonConnection: NSXPCConnection = {
        let connection = NSXPCConnection(machServiceName: "edu.purdue.pae.aura-ras.daemon.xpc")
        connection.remoteObjectInterface = NSXPCInterface(with: AuraRASTunnelProtocol.self)
        connection.resume()
        return connection
    }()

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Explicitly set as accessory so it doesn't show a Dock icon
        NSApp.setActivationPolicy(.accessory)
        FileLogger.log("applicationWillFinishLaunching: Binding URL Handler.")
        
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        FileLogger.log("applicationDidFinishLaunching: App run loop is fully active.")
    }
    
    func fatalErrorAlert(_ message: String) {
        FileLogger.log("FATAL ERROR: \(message)")
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "AuraRAS Helper Error"
            alert.informativeText = message
            alert.alertStyle = .critical
            
            if let appIcon = NSImage(named: "AppIcon") {
                alert.icon = appIcon
            } else {
                alert.icon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
            }
            
            alert.addButton(withTitle: "Quit")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    @objc func handleURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        FileLogger.log("SUCCESS: handleURLEvent triggered! The click was intercepted by the Helper.")
        
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let components = URLComponents(string: urlString) else {
            fatalErrorAlert("Failed to parse incoming URL from the web dashboard.")
            return
        }

        let type = components.queryItems?.first(where: { $0.name == "type" })?.value
        let port = components.queryItems?.first(where: { $0.name == "port" })?.value ?? ""
        let host = components.queryItems?.first(where: { $0.name == "host" })?.value ?? "Endpoint"

        FileLogger.log("URL Parsed -> Type: \(type ?? "nil"), Host: \(host), Port: \(port)")

        let daemon = daemonConnection.remoteObjectProxyWithErrorHandler { error in
            self.fatalErrorAlert("CRITICAL XPC Error: Could not connect to the root daemon.\n\nError: \(error.localizedDescription)")
        } as? AuraRASTunnelProtocol

        guard let daemon = daemon else {
            fatalErrorAlert("Failed to cast the XPC proxy to AuraRASTunnelProtocol.")
            return
        }

        FileLogger.log("Requesting root daemon to establish bridge to remote port \(port)...")
        
        daemon.establishBridge(toRemotePort: port) { localPort in
            guard let localPort = localPort else {
                self.fatalErrorAlert("Daemon Error: The root daemon failed to establish the SSH bridge and returned a nil port.")
                return
            }
            
            FileLogger.log("Received valid proxy port from daemon: \(localPort)")
            
            DispatchQueue.main.async {
                if type == "vnc" {
                    self.launchVNC(localPort: localPort, daemon: daemon)
                } else if type == "ssh" {
                    self.launchSSH(localPort: localPort, host: host, daemon: daemon)
                } else {
                    self.fatalErrorAlert("Unknown connection type requested: \(type ?? "nil")")
                }
            }
        }
    }

    func launchVNC(localPort: String, daemon: AuraRASTunnelProtocol?) {
        FileLogger.log("Launching Screen Sharing on local port \(localPort)")
        if let vncURL = URL(string: "vnc://127.0.0.1:\(localPort)") {
            NSWorkspace.shared.open(vncURL)
        }
        
        monitorApp(bundleIdentifier: "com.apple.ScreenSharing", localPort: localPort, daemon: daemon)
    }

    func launchSSH(localPort: String, host: String, daemon: AuraRASTunnelProtocol?) {
        FileLogger.log("Prompting user for SSH credentials for host \(host)")
        let alert = NSAlert()
        alert.messageText = "Connect to \(host)"
        alert.informativeText = "Enter the local username for the remote Mac:"
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        
        if let appIcon = NSImage(named: "AppIcon") {
            alert.icon = appIcon
        } else {
            alert.icon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        }
        
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        input.stringValue = "admin"
        alert.accessoryView = input
        NSApp.activate(ignoringOtherApps: true)
        
        if alert.runModal() == .alertFirstButtonReturn {
            let user = input.stringValue
            FileLogger.log("User initiated SSH connection as '\(user)'. Launching Terminal.")
            
            let command = "ssh -o StrictHostKeyChecking=no \(user)@127.0.0.1 -p \(localPort)"
            let appleScript = "tell application \"Terminal\"\nactivate\ndo script \"\(command)\"\nend tell"
            
            var error: NSDictionary?
            NSAppleScript(source: appleScript)?.executeAndReturnError(&error)
            
            if let error = error {
                self.fatalErrorAlert("AppleScript Error launching Terminal: \(error)")
            }
            
            monitorApp(bundleIdentifier: "com.apple.Terminal", localPort: localPort, daemon: daemon)
        } else {
            FileLogger.log("User cancelled SSH connection prompt.")
            daemon?.teardownBridge(localPort: localPort)
            NSApp.terminate(nil)
        }
    }
    
    func monitorApp(bundleIdentifier: String, localPort: String, daemon: AuraRASTunnelProtocol?) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
            Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { timer in
                let apps = NSWorkspace.shared.runningApplications
                if !apps.contains(where: { $0.bundleIdentifier == bundleIdentifier }) {
                    FileLogger.log("Target app \(bundleIdentifier) closed. Tearing down bridge and exiting.")
                    daemon?.teardownBridge(localPort: localPort)
                    NSApp.terminate(nil)
                }
            }
        }
    }
}
