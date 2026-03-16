import Cocoa

// Using @main natively on the AppDelegate forces Apple's standard C-level bootstrapper
// to handle the LaunchServices and Apple Event lifecycles flawlessly.
@main
class AppDelegate: NSObject, NSApplicationDelegate {
    
    lazy var daemonConnection: NSXPCConnection = {
        let connection = NSXPCConnection(machServiceName: "edu.purdue.pae.aura-ras.daemon.xpc")
        connection.remoteObjectInterface = NSXPCInterface(with: AuraRASTunnelProtocol.self)
        connection.resume()
        return connection
    }()

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSLog("AuraRAS Helper is booting up. Registering Apple Event handler.")
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Explicitly set as accessory so it doesn't show a Dock icon
        NSApp.setActivationPolicy(.accessory)
        NSLog("AuraRAS Helper application run loop has started natively.")
    }
    
    func fatalErrorAlert(_ message: String) {
        NSLog("FATAL ERROR: \(message)")
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "AuraRAS Helper Error"
            alert.informativeText = message
            alert.alertStyle = .critical
            
            // 1. Try to load the universal ICNS from the Asset Catalog
            // 2. Fall back to asking Finder to resolve the bundle icon
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
        NSLog("SUCCESS: handleURLEvent triggered! The click was intercepted.")
        
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URLComponents(string: urlString) else {
            fatalErrorAlert("Failed to parse incoming URL from the web dashboard.")
            return
        }

        let type = url.queryItems?.first(where: { $0.name == "type" })?.value
        let port = url.queryItems?.first(where: { $0.name == "port" })?.value ?? ""
        let host = url.queryItems?.first(where: { $0.name == "host" })?.value ?? "Endpoint"

        NSLog("Helper parsed URL successfully. Type: \(type ?? "nil"), Host: \(host), Port: \(port)")

        let daemon = daemonConnection.remoteObjectProxyWithErrorHandler { error in
            self.fatalErrorAlert("CRITICAL XPC Error: Could not connect to the root daemon.\n\nError: \(error.localizedDescription)")
        } as? AuraRASTunnelProtocol

        guard let daemon = daemon else {
            fatalErrorAlert("Failed to cast the XPC proxy to AuraRASTunnelProtocol.")
            return
        }

        NSLog("Requesting daemon to establish bridge to remote port \(port)...")
        
        daemon.establishBridge(toRemotePort: port) { localPort in
            guard let localPort = localPort else {
                self.fatalErrorAlert("Daemon Error: The root daemon failed to establish the SSH bridge and returned a nil port.")
                return
            }
            
            NSLog("Helper received valid proxy port from daemon: \(localPort)")
            
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
        NSLog("Launching Screen Sharing on local port \(localPort)")
        if let vncURL = URL(string: "vnc://127.0.0.1:\(localPort)") {
            NSWorkspace.shared.open(vncURL)
        }
        
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { timer in
            let apps = NSWorkspace.shared.runningApplications
            if !apps.contains(where: { $0.bundleIdentifier == "com.apple.ScreenSharing" }) {
                NSLog("Screen Sharing app closed. Tearing down bridge and exiting.")
                daemon?.teardownBridge(localPort: localPort)
                NSApp.terminate(nil)
            }
        }
    }

    func launchSSH(localPort: String, host: String, daemon: AuraRASTunnelProtocol?) {
        NSLog("Prompting user for SSH credentials for host \(host)")
        let alert = NSAlert()
        alert.messageText = "Connect to \(host)"
        alert.informativeText = "Enter the local username for the remote Mac:"
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        
        // 1. Try to load the universal ICNS from the Asset Catalog
        // 2. Fall back to asking Finder to resolve the bundle icon
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
            NSLog("User initiated SSH connection as '\(user)'. Launching Terminal.")
            
            let command = "ssh -o StrictHostKeyChecking=no \(user)@127.0.0.1 -p \(localPort)"
            let appleScript = "tell application \"Terminal\"\nactivate\ndo script \"\(command)\"\nend tell"
            
            var error: NSDictionary?
            NSAppleScript(source: appleScript)?.executeAndReturnError(&error)
            
            if let error = error {
                self.fatalErrorAlert("AppleScript Error launching Terminal: \(error)")
            }
            
            Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { timer in
                let apps = NSWorkspace.shared.runningApplications
                if !apps.contains(where: { $0.bundleIdentifier == "com.apple.Terminal" }) {
                    NSLog("Terminal app closed. Tearing down bridge and exiting.")
                    daemon?.teardownBridge(localPort: localPort)
                    NSApp.terminate(nil)
                }
            }
        } else {
            NSLog("User cancelled SSH connection prompt.")
            daemon?.teardownBridge(localPort: localPort)
            NSApp.terminate(nil)
        }
    }
}
