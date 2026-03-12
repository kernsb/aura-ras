import Foundation
import CoreFoundation

// Extreme Debugger: Writes directly to a physical file so we bypass macOS log filters completely!
func debugLog(_ msg: String) {
    let logMsg = "[\(Date())] \(msg)\n"
    if let handle = FileHandle(forWritingAtPath: "/tmp/auraras_daemon_debug.log") {
        handle.seekToEndOfFile()
        if let data = logMsg.data(using: .utf8) {
            handle.write(data)
        }
        handle.closeFile()
    } else {
        try? logMsg.write(toFile: "/tmp/auraras_daemon_debug.log", atomically: true, encoding: .utf8)
    }
    NSLog(msg)
}

class TunnelManager: NSObject, AuraRASTunnelProtocol {
    var activeBridges: [String: Process] = [:]

    func establishBridge(toRemotePort remotePort: String, withReply reply: @escaping (String?) -> Void) {
        debugLog("DAEMON: Received request to establish bridge to remote port: \(remotePort)")
        
        let bundleID = "edu.purdue.pae.aura-ras" as CFString
        
        // Attempt 1: Standard App Preferences (works if daemon context is friendly)
        var serverAddress = CFPreferencesCopyAppValue("ServerAddress" as CFString, bundleID) as? String ?? ""
        var serverPort = CFPreferencesCopyAppValue("ServerPort" as CFString, bundleID) as? Int ?? 9922
        
        // Attempt 2: Sterile Daemon Fallback (Directly read the Jamf Managed Plist from disk!)
        if serverAddress.isEmpty {
            debugLog("DAEMON: Standard preference read failed. Attempting direct disk read of Jamf profile...")
            let plistPath = "/Library/Managed Preferences/edu.purdue.pae.aura-ras.plist"
            if let dict = NSDictionary(contentsOfFile: plistPath) as? [String: Any] {
                serverAddress = dict["ServerAddress"] as? String ?? ""
                
                // Port might be parsed as a String or Int depending on Jamf schema formatting
                if let portInt = dict["ServerPort"] as? Int {
                    serverPort = portInt
                } else if let portString = dict["ServerPort"] as? String, let parsedPort = Int(portString) {
                    serverPort = parsedPort
                }
                debugLog("DAEMON: Successfully read MDM config from disk.")
            }
        }
        
        debugLog("DAEMON: Parsed MDM Config - Address: '\(serverAddress)', Port: '\(serverPort)'")
        
        guard !serverAddress.isEmpty else {
            debugLog("DAEMON ERROR: ServerAddress is empty or could not be read from MDM profile.")
            reply(nil)
            return
        }

        // Pick a random local port to act as the proxy for the user
        let localPort = String(Int.random(in: 10000...60000))
        debugLog("DAEMON: Selected local proxy port: \(localPort). Spawning SSH...")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        // Since this daemon runs as root, it naturally has access to the root key
        process.arguments = [
            "-i", "/var/root/.ssh/aura_ed25519",
            "-o", "StrictHostKeyChecking=accept-new",
            "-N",
            "-L", "\(localPort):127.0.0.1:\(remotePort)",
            "aura-tunnel@\(serverAddress)",
            "-p", "\(serverPort)"
        ]

        do {
            try process.run()
            activeBridges[localPort] = process
            debugLog("DAEMON SUCCESS: Spawned SSH process mapping local port \(localPort) to remote \(remotePort)")
            
            // Give the tunnel 1.5 seconds to establish, then check if it crashed
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
                if process.isRunning {
                    debugLog("DAEMON: SSH process is stable after 1.5s. Returning local port \(localPort) to UI.")
                    reply(localPort)
                } else {
                    debugLog("DAEMON ERROR: SSH process crashed immediately! Exit code: \(process.terminationStatus)")
                    reply(nil)
                }
            }
        } catch {
            debugLog("DAEMON ERROR: Failed to execute ssh process. \(error.localizedDescription)")
            reply(nil)
        }
    }

    func teardownBridge(localPort: String) {
        debugLog("DAEMON: Received request to teardown bridge on port \(localPort)")
        if let process = activeBridges[localPort] {
            process.terminate()
            activeBridges.removeValue(forKey: localPort)
            debugLog("DAEMON: Successfully terminated bridge on port \(localPort)")
        } else {
            debugLog("DAEMON WARN: No active process found for port \(localPort)")
        }
    }
}

class DaemonDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        debugLog("DAEMON: Accepted new XPC connection from Helper App.")
        newConnection.exportedInterface = NSXPCInterface(with: AuraRASTunnelProtocol.self)
        newConnection.exportedObject = TunnelManager()
        newConnection.resume()
        return true
    }
}

// Start the XPC Listener using a Mach Service defined in the LaunchDaemon plist
debugLog("--- DAEMON STARTING UP ---")
let delegate = DaemonDelegate()
let listener = NSXPCListener(machServiceName: "edu.purdue.pae.aura-ras.daemon.xpc")
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
