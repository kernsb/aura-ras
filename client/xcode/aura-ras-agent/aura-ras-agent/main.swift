import Foundation

// MARK: - Global Configuration
let agentVersion = "0.1.3"
let privateKeyPath = "/var/root/.ssh/aura_ed25519"
let publicKeyPath = "/var/root/.ssh/aura_ed25519.pub"

struct AuraRASConfig {
    let jssID: String
    let role: String
    let serverAddress: String
    let serverPort: Int
    let serverURL: URL
}

// MARK: - Core Functions

func getManagedConfig() -> AuraRASConfig? {
    let bundleID = "edu.purdue.pae.aura-ras" as CFString
    
    // Support parsing JSSID as either a String or an Integer (depending on how Jamf delivers it)
    let jssIDRaw = CFPreferencesCopyAppValue("JSSID" as CFString, bundleID)
    let jssID = (jssIDRaw as? String) ?? (jssIDRaw as? Int).map { String($0) } ?? ""
    
    let role = CFPreferencesCopyAppValue("AgentRole" as CFString, bundleID) as? String ?? "Endpoint"
    let serverPort = CFPreferencesCopyAppValue("ServerPort" as CFString, bundleID) as? Int ?? 9922
    
    guard let serverAddress = CFPreferencesCopyAppValue("ServerAddress" as CFString, bundleID) as? String, !serverAddress.isEmpty else {
        print("ERROR: ServerAddress is not strictly managed by MDM. Cannot locate AuraRAS Appliance. Aborting.")
        return nil
    }

    // Dynamically build the HTTPS API URL from the ServerAddress!
    guard let serverURL = URL(string: "https://\(serverAddress)/api/register") else {
        print("ERROR: Could not construct a valid URL from ServerAddress: \(serverAddress)")
        return nil
    }
    
    guard !jssID.isEmpty, jssID != "$JSSID" else {
        print("ERROR: JSSID is missing or not populated by Jamf.")
        return nil
    }
    
    return AuraRASConfig(jssID: jssID, role: role, serverAddress: serverAddress, serverPort: serverPort, serverURL: serverURL)
}

func ensureSSHKeysExist(forceRotate: Bool) -> String? {
    let fm = FileManager.default
    let sshDir = "/var/root/.ssh"
    
    // Ensure the .ssh directory exists with strict permissions
    if !fm.fileExists(atPath: sshDir) {
        try? fm.createDirectory(atPath: sshDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    
    if forceRotate {
        try? fm.removeItem(atPath: privateKeyPath)
        try? fm.removeItem(atPath: publicKeyPath)
        print("Rotating keys: Old SSH keys removed.")
    }
    
    // Generate new Ed25519 keys if they don't exist
    if !fm.fileExists(atPath: privateKeyPath) {
        print("Generating new Ed25519 key pair...")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        // -t ed25519: Key type
        // -f: Output file
        // -N "": Empty passphrase
        // -q: Quiet mode
        process.arguments = ["-t", "ed25519", "-f", privateKeyPath, "-N", "", "-q"]
        try? process.run()
        process.waitUntilExit()
    }
    
    // Read and return the public key
    return try? String(contentsOfFile: publicKeyPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
}

func registerWithServer(jssID: String, role: String, publicKey: String, serverURL: URL) -> Bool {
    var success = false
    let semaphore = DispatchSemaphore(value: 0)
    
    var request = URLRequest(url: serverURL)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    
    let hostname = Host.current().localizedName ?? "Unknown-Mac"
    let payload: [String: Any] = [
        "jssid": Int(jssID) ?? 0,
        "role": role,
        "public_key": publicKey,
        "hostname": hostname
    ]
    
    request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
    
    let task = URLSession.shared.dataTask(with: request) { data, response, error in
        defer { semaphore.signal() }
        
        if let error = error {
            print("Network Error: \(error.localizedDescription)")
            return
        }
        
        if let httpResponse = response as? HTTPURLResponse {
            if httpResponse.statusCode == 200 {
                print("SUCCESS: Successfully registered with AuraRAS Appliance.")
                success = true
            } else {
                print("Server rejected registration. HTTP Status: \(httpResponse.statusCode)")
                if let data = data, let body = String(data: data, encoding: .utf8) {
                    print("Response: \(body)")
                }
            }
        }
    }
    
    task.resume()
    semaphore.wait() // Wait for the network request to finish before allowing the script to proceed
    return success
}

func restartTunnel(config: AuraRASConfig) {
    // Calculate ports based on JSSID (matching Django backend logic)
    guard let jssIDInt = Int(config.jssID) else {
        print("ERROR: JSSID is not an integer.")
        return
    }
    let sshPort = jssIDInt + 40000
    let vncPort = jssIDInt + 50000

    let daemonPath = "/Library/LaunchDaemons/edu.purdue.pae.aura-ras.tunnel.plist"
    
    // Dynamically build the LaunchDaemon plist for the autossh reverse tunnel
    let plistContent = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>Label</key>
        <string>edu.purdue.pae.aura-ras.tunnel</string>
        <key>ProgramArguments</key>
        <array>
            <string>/usr/local/aura-ras/autossh</string>
            <string>-M</string>
            <string>0</string>
            <string>-N</string>
            <string>-o</string>
            <string>ServerAliveInterval=30</string>
            <string>-o</string>
            <string>ServerAliveCountMax=3</string>
            <string>-o</string>
            <string>StrictHostKeyChecking=accept-new</string>
            <string>-i</string>
            <string>\(privateKeyPath)</string>
            <string>-R</string>
            <string>\(sshPort):127.0.0.1:22</string>
            <string>-R</string>
            <string>\(vncPort):127.0.0.1:5900</string>
            <string>-p</string>
            <string>\(config.serverPort)</string>
            <string>aura-tunnel@\(config.serverAddress)</string>
        </array>
        <key>RunAtLoad</key>
        <true/>
        <key>KeepAlive</key>
        <true/>
        <key>EnvironmentVariables</key>
        <dict>
            <key>AUTOSSH_GATETIME</key>
            <string>0</string>
        </dict>
    </dict>
    </plist>
    """
    
    do {
        // Write the plist to disk
        try plistContent.write(toFile: daemonPath, atomically: true, encoding: .utf8)
        
        // Ensure root owns the plist and permissions are strict
        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["644", daemonPath]
        try? chmod.run()
        chmod.waitUntilExit()

        // Unload the existing tunnel daemon (if it exists)
        let bootout = Process()
        bootout.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        bootout.arguments = ["bootout", "system", daemonPath]
        try? bootout.run()
        bootout.waitUntilExit()
        
        // Load the new tunnel daemon
        let bootstrap = Process()
        bootstrap.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        bootstrap.arguments = ["bootstrap", "system", daemonPath]
        try? bootstrap.run()
        bootstrap.waitUntilExit()
        
        if bootstrap.terminationStatus == 0 {
            print("Tunnel service successfully restarted.")
        } else {
            print("WARNING: Tunnel service restart may have failed (status \(bootstrap.terminationStatus)).")
        }
    } catch {
        print("ERROR: Failed to write tunnel LaunchDaemon: \(error)")
    }
}

// MARK: - Uninstallation Routine

func uninstallAuraRAS() {
    print("Starting complete uninstallation of AuraRAS components...")
    let fileManager = FileManager.default
    let tunnelDaemonPath = "/Library/LaunchDaemons/edu.purdue.pae.aura-ras.tunnel.plist"
    let helperDaemonPath = "/Library/LaunchDaemons/edu.purdue.pae.aura-ras.daemon.plist"
    let installDir = "/usr/local/aura-ras"
    let helperDaemon = "/Library/PrivilegedHelperTools/aura-ras-daemon"
    
    // 1. Force kill active ghost processes
    print("Terminating any active helper processes...")
    let killall = Process()
    killall.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
    // Include autossh to tear down the tunnel instantly
    killall.arguments = ["-9", "aura-ras-helper", "aura-ras-daemon", "autossh"]
    try? killall.run()
    killall.waitUntilExit()
    
    // 2. Unload and remove LaunchDaemons
    for path in [tunnelDaemonPath, helperDaemonPath] {
        if fileManager.fileExists(atPath: path) {
            print("Unloading LaunchDaemon at \(path)...")
            let bootout = Process()
            bootout.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            bootout.arguments = ["bootout", "system", path]
            try? bootout.run()
            bootout.waitUntilExit()
            
            try? fileManager.removeItem(atPath: path)
        }
    }
    print("Removed LaunchDaemon plists.")
    
    // 3. Unregister Helper App from LaunchServices
    print("Unregistering Helper App from LaunchServices...")
    let lsregister = Process()
    lsregister.executableURL = URL(fileURLWithPath: "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister")
    lsregister.arguments = ["-u", "\(installDir)/aura-ras-helper.app"]
    try? lsregister.run()
    lsregister.waitUntilExit()

    // 4. Remove application directory
    if fileManager.fileExists(atPath: installDir) {
        try? fileManager.removeItem(atPath: installDir)
        print("Removed AuraRAS directory and binaries.")
    }
    
    // 5. Remove root helper daemon
    if fileManager.fileExists(atPath: helperDaemon) {
        try? fileManager.removeItem(atPath: helperDaemon)
        print("Removed root XPC daemon.")
    }

    // 6. Remove SSH keys
    if fileManager.fileExists(atPath: privateKeyPath) {
        try? fileManager.removeItem(atPath: privateKeyPath)
    }
    if fileManager.fileExists(atPath: publicKeyPath) {
        try? fileManager.removeItem(atPath: publicKeyPath)
    }
    print("Removed AuraRAS SSH keys.")
    
    print("--- Uninstallation Complete ---")
}

func printUsage() {
    print("""
    AuraRAS Agent v\(agentVersion)
    Usage: aura-ras-agent [options]
    
    Options:
      --initialize    Register the endpoint with the AuraRAS server and establish the tunnel.
      --rotate-keys   Force generation of a new SSH keypair and update the AuraRAS server.
      --uninstall     Completely remove all AuraRAS components and configuration from this Mac.
      --version       Display the agent version.
      --help          Show this help message.
    """)
}

// MARK: - Main Execution Flow

let arguments = CommandLine.arguments.dropFirst()

if arguments.contains("--help") || arguments.isEmpty {
    printUsage()
    exit(0)
}

if arguments.contains("--version") {
    print("AuraRAS Agent v\(agentVersion)")
    exit(0)
}

let isRotation = arguments.contains("--rotate-keys")
let isInit = arguments.contains("--initialize")
let isUninstall = arguments.contains("--uninstall")

// Since this runs via postinstall script (or requires deep system changes), ensure we have root privileges
guard geteuid() == 0 else {
    print("FATAL ERROR: Commands must be run as root.")
    exit(1)
}

if isUninstall {
    uninstallAuraRAS()
    exit(0)
}

if !isRotation && !isInit {
    print("ERROR: Invalid argument provided.")
    printUsage()
    exit(1)
}

if isRotation {
    print("--- Starting AuraRAS Agent Key Rotation ---")
} else {
    print("--- Starting AuraRAS Agent Initialization ---")
}

// 1. Get Trusted Config
guard let config = getManagedConfig() else {
    print("Initialization aborted due to missing or untrusted configuration.")
    exit(1)
}
print("Verified MDM Configuration - Role: \(config.role), JSSID: \(config.jssID)")

// 2. Manage Keys
guard let publicKey = ensureSSHKeysExist(forceRotate: isRotation) else {
    print("FATAL ERROR: Could not establish SSH identities.")
    exit(1)
}

// 3. Register with Appliance
let registrationSuccess = registerWithServer(jssID: config.jssID, role: config.role, publicKey: publicKey, serverURL: config.serverURL)

if registrationSuccess {
    // ALWAYS rebuild the plist and start the autossh daemon when initializing or rotating
    restartTunnel(config: config)
    print("--- \(isRotation ? "Rotation" : "Initialization") Complete ---")
    exit(0)
} else {
    print("--- \(isRotation ? "Rotation" : "Initialization") Failed ---")
    exit(1)
}
