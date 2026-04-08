import Foundation

// MARK: - Global Configuration
let agentVersion = "0.1.6"
let bundleID = "edu.purdue.pae.aura-ras" as CFString
let privateKeyPath = "/var/root/.ssh/aura_ed25519"
let publicKeyPath = "/var/root/.ssh/aura_ed25519.pub"

struct AuraRASConfig {
    let jssID: String
    let role: String
    let serverAddress: String
    let serverPort: Int
    let apiSecret: String
    let serverURL: URL
}

// MARK: - Core Functions

func getManagedConfig() -> AuraRASConfig? {
    let jssIDRaw = CFPreferencesCopyAppValue("JSSID" as CFString, bundleID)
    let jssID = (jssIDRaw as? String) ?? (jssIDRaw as? Int).map { String($0) } ?? ""
    
    let role = CFPreferencesCopyAppValue("AgentRole" as CFString, bundleID) as? String ?? "Endpoint"
    let serverPort = CFPreferencesCopyAppValue("ServerPort" as CFString, bundleID) as? Int ?? 9922
    let apiSecret = CFPreferencesCopyAppValue("APISecret" as CFString, bundleID) as? String ?? ""
    
    guard let serverAddress = CFPreferencesCopyAppValue("ServerAddress" as CFString, bundleID) as? String, !serverAddress.isEmpty else {
        print("ERROR: ServerAddress is not populated by MDM. Cannot locate AuraRAS Appliance. Aborting.")
        return nil
    }

    guard let serverURL = URL(string: "https://\(serverAddress)/api/register") else {
        print("ERROR: Could not construct a valid URL from ServerAddress: \(serverAddress)")
        return nil
    }
    
    guard !jssID.isEmpty, jssID != "$JSSID" else {
        print("ERROR: JSSID is missing or not populated by Jamf.")
        return nil
    }
    
    return AuraRASConfig(jssID: jssID, role: role, serverAddress: serverAddress, serverPort: serverPort, apiSecret: apiSecret, serverURL: serverURL)
}

func ensureSSHKeysExist(forceRotate: Bool) -> String? {
    let fm = FileManager.default
    let sshDir = "/var/root/.ssh"
    
    if !fm.fileExists(atPath: sshDir) {
        do {
            try fm.createDirectory(atPath: sshDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            print("ERROR: Failed to create .ssh directory: \(error.localizedDescription)")
            return nil
        }
    }
    
    if forceRotate {
        try? fm.removeItem(atPath: privateKeyPath)
        try? fm.removeItem(atPath: publicKeyPath)
        print("Rotating keys: Old SSH keys removed.")
    }
    
    if !fm.fileExists(atPath: privateKeyPath) {
        print("Generating new Ed25519 key pair...")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = ["-t", "ed25519", "-f", privateKeyPath, "-N", "", "-q"]
        
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                print("ERROR: ssh-keygen failed with exit code \(process.terminationStatus)")
                return nil
            } else {
                print("Successfully generated Ed25519 keys.")
            }
        } catch {
            print("ERROR: Failed to execute ssh-keygen: \(error.localizedDescription)")
            return nil
        }
    }
    
    do {
        let pubKey = try String(contentsOfFile: publicKeyPath, encoding: .utf8)
        return pubKey.trimmingCharacters(in: .whitespacesAndNewlines)
    } catch {
        print("ERROR: Could not read public key at \(publicKeyPath). \(error.localizedDescription)")
        return nil
    }
}

func unregisterFromServer(config: AuraRASConfig) -> Bool {
    guard let url = URL(string: "https://\(config.serverAddress)/api/unregister") else { return false }
    var success = false
    let semaphore = DispatchSemaphore(value: 0)
    
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(config.apiSecret)", forHTTPHeaderField: "Authorization")
    
    let payload: [String: Any] = ["jssid": Int(config.jssID) ?? 0]
    request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
    
    let task = URLSession.shared.dataTask(with: request) { data, response, error in
        defer { semaphore.signal() }
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
            print("SUCCESS: Endpoint unregistered from server and SSH keys revoked.")
            success = true
        }
    }
    task.resume()
    semaphore.wait()
    return success
}

func registerWithServer(config: AuraRASConfig, publicKey: String) -> Bool {
    var success = false
    let semaphore = DispatchSemaphore(value: 0)
    
    var request = URLRequest(url: config.serverURL)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(config.apiSecret)", forHTTPHeaderField: "Authorization")
    
    let hostname = Host.current().localizedName ?? "Unknown-Mac"
    let payload: [String: Any] = [
        "jssid": Int(config.jssID) ?? 0,
        "role": config.role,
        "public_key": publicKey,
        "hostname": hostname
    ]
    
    request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
    
    print("Attempting to register with server at \(config.serverURL.absoluteString)...")
    
    let task = URLSession.shared.dataTask(with: request) { data, response, error in
        defer { semaphore.signal() }
        
        if let error = error {
            print("NETWORK ERROR: Failed to reach server. \(error.localizedDescription)")
            return
        }
        
        if let httpResponse = response as? HTTPURLResponse {
            if httpResponse.statusCode == 200 {
                if let data = data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let assignedID = json["id"] as? Int,
                   let sshPort = json["ssh_port"] as? Int,
                   let vncPort = json["vnc_port"] as? Int {
                        
                    let prefsPath = "/Library/Preferences/edu.purdue.pae.aura-ras.plist"
                    let dict = NSMutableDictionary(contentsOfFile: prefsPath) ?? NSMutableDictionary()
                    dict.setValue(assignedID, forKey: "AuraID")
                    dict.setValue(sshPort, forKey: "LocalSSHPort")
                    dict.setValue(vncPort, forKey: "LocalVNCPort")
                    dict.write(toFile: prefsPath, atomically: true)
                    
                    print("SUCCESS: Registered with AuraRAS Appliance. Assigned ID: \(assignedID)")
                    success = true
                } else {
                    print("JSON ERROR: Server returned 200 OK, but response was invalid or missing port numbers.")
                }
            } else {
                print("SERVER ERROR: Registration rejected with HTTP Status \(httpResponse.statusCode)")
                if let data = data, let str = String(data: data, encoding: .utf8) {
                    print("Raw Response: \(str)")
                }
            }
        }
    }
    task.resume()
    semaphore.wait()
    return success
}

// MARK: - LaunchDaemon Generation & Tunnel Restart

func restartTunnel(config: AuraRASConfig) {
    let prefsPath = "/Library/Preferences/edu.purdue.pae.aura-ras.plist"
    guard let dict = NSDictionary(contentsOfFile: prefsPath),
          let sshPort = dict["LocalSSHPort"] as? Int,
          let vncPort = dict["LocalVNCPort"] as? Int else {
        print("ERROR: Could not read assigned ports from local preferences. Registration may have failed.")
        return
    }

    let daemonPath = "/Library/LaunchDaemons/edu.purdue.pae.aura-ras.tunnel.plist"
    
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
            <string>-o</string>
            <string>ExitOnForwardFailure=yes</string>
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
        <key>StandardErrorPath</key>
        <string>/var/log/autossh_error.log</string>
        <key>StandardOutPath</key>
        <string>/var/log/autossh.log</string>
    </dict>
    </plist>
    """
    
    do {
        try plistContent.write(toFile: daemonPath, atomically: true, encoding: .utf8)
        
        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["644", daemonPath]
        try? chmod.run()
        chmod.waitUntilExit()

        let bootout = Process()
        bootout.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        bootout.arguments = ["bootout", "system", daemonPath]
        try? bootout.run()
        bootout.waitUntilExit()
        
        // Brief pause to cleanly release sockets
        Thread.sleep(forTimeInterval: 0.5)
        
        let bootstrap = Process()
        bootstrap.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        bootstrap.arguments = ["bootstrap", "system", daemonPath]
        try? bootstrap.run()
        bootstrap.waitUntilExit()
        
        if bootstrap.terminationStatus == 0 {
            print("Tunnel service successfully restarted on assigned ports (\(sshPort), \(vncPort)).")
        }
    } catch {
        print("ERROR: Failed to write tunnel LaunchDaemon: \(error)")
    }
}

func configureXPCDaemon() {
    let daemonPath = "/Library/LaunchDaemons/edu.purdue.pae.aura-ras.daemon.plist"
    
    let plistContent = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>Label</key>
        <string>edu.purdue.pae.aura-ras.daemon</string>
        <key>MachServices</key>
        <dict>
            <key>edu.purdue.pae.aura-ras.daemon.xpc</key>
            <true/>
        </dict>
        <key>ProgramArguments</key>
        <array>
            <string>/Library/PrivilegedHelperTools/aura-ras-daemon</string>
        </array>
        <key>RunAtLoad</key>
        <true/>
        <key>KeepAlive</key>
        <true/>
    </dict>
    </plist>
    """

    do {
        try plistContent.write(toFile: daemonPath, atomically: true, encoding: .utf8)
        
        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["644", daemonPath]
        try? chmod.run()
        chmod.waitUntilExit()

        let bootout = Process()
        bootout.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        bootout.arguments = ["bootout", "system", daemonPath]
        try? bootout.run()
        bootout.waitUntilExit()
        
        let bootstrap = Process()
        bootstrap.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        bootstrap.arguments = ["bootstrap", "system", daemonPath]
        try? bootstrap.run()
        bootstrap.waitUntilExit()
        
        print("XPC Daemon successfully configured and loaded.")
    } catch {
        print("ERROR: Failed to write XPC LaunchDaemon: \(error)")
    }
}

// MARK: - Telemetry & Check-in Functions

func getSerialNumber() -> String {
    let task = Process()
    let pipe = Pipe()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
    task.arguments = ["SPHardwareDataType"]
    task.standardOutput = pipe
    try? task.run()
    task.waitUntilExit()
    
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    if let output = String(data: data, encoding: .utf8) {
        for line in output.components(separatedBy: .newlines) {
            if line.contains("Serial Number (system)") || line.contains("Serial Number") {
                let parts = line.components(separatedBy: ":")
                if parts.count == 2 {
                    return parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
    }
    return "Unknown"
}

func getUserStats() -> (lastUser: String, primaryUser: String) {
    let task = Process()
    let pipe = Pipe()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/last")
    task.standardOutput = pipe
    try? task.run()
    task.waitUntilExit()

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let output = String(data: data, encoding: .utf8) else { return ("Unknown", "Unknown") }

    var userCounts: [String: Int] = [:]
    var lastUser = ""

    let lines = output.components(separatedBy: .newlines)
    for line in lines {
        let components = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard let user = components.first, !user.isEmpty else { continue }

        let ignored = ["reboot", "shutdown", "root", "mbsetupuser", "wtmp"]
        if ignored.contains(user) || user.hasPrefix("_") { continue }

        if lastUser.isEmpty {
            lastUser = user
        }
        userCounts[user, default: 0] += 1
    }

    let primaryUser = userCounts.max { a, b in a.value < b.value }?.key ?? "Unknown"
    if lastUser.isEmpty { lastUser = "Unknown" }

    return (lastUser, primaryUser)
}

func configureCheckinDaemon(intervalMinutes: Int) {
    let daemonPath = "/Library/LaunchDaemons/edu.purdue.pae.aura-ras.checkin.plist"
    let intervalSeconds = intervalMinutes * 60

    if let dict = NSDictionary(contentsOfFile: daemonPath),
       let currentInterval = dict["StartInterval"] as? Int,
       currentInterval == intervalSeconds {
        print("Check-in daemon already configured for \(intervalMinutes) minutes. No changes needed.")
        return
    }

    let plistContent = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>Label</key>
        <string>edu.purdue.pae.aura-ras.checkin</string>
        <key>ProgramArguments</key>
        <array>
            <string>/usr/local/aura-ras/aura-ras-agent</string>
            <string>--checkin</string>
        </array>
        <key>StartInterval</key>
        <integer>\(intervalSeconds)</integer>
    </dict>
    </plist>
    """

    do {
        try plistContent.write(toFile: daemonPath, atomically: true, encoding: .utf8)
        
        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["644", daemonPath]
        try? chmod.run()
        chmod.waitUntilExit()

        let bootout = Process()
        bootout.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        bootout.arguments = ["bootout", "system", daemonPath]
        try? bootout.run()
        bootout.waitUntilExit()
        
        let bootstrap = Process()
        bootstrap.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        bootstrap.arguments = ["bootstrap", "system", daemonPath]
        try? bootstrap.run()
        bootstrap.waitUntilExit()
        
        print("Check-in daemon loaded with new interval of \(intervalSeconds) seconds.")
    } catch {
        print("ERROR: Failed to write checkin LaunchDaemon: \(error)")
    }
}

func performCheckin(config: AuraRASConfig) {
    let serial = getSerialNumber()
    let userStats = getUserStats()

    let payload: [String: Any] = [
        "jssid": Int(config.jssID) ?? 0,
        "hostname": Host.current().localizedName ?? "Unknown-Mac",
        "serial_number": serial,
        "last_user": userStats.lastUser,
        "primary_user": userStats.primaryUser
    ]

    guard let url = URL(string: "https://\(config.serverAddress)/api/checkin") else { return }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(config.apiSecret)", forHTTPHeaderField: "Authorization")
    
    request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

    let semaphore = DispatchSemaphore(value: 0)

    let task = URLSession.shared.dataTask(with: request) { data, response, error in
        defer { semaphore.signal() }

        if let error = error {
            print("Check-in Network Error: \(error.localizedDescription)")
            return
        }

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
           let data = data,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let interval = json["checkin_interval_minutes"] as? Int {

            print("SUCCESS: Telemetry sent. Server requested interval: \(interval) minutes.")
            configureCheckinDaemon(intervalMinutes: interval)

        } else {
            print("Check-in failed. HTTP Status: \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
    }
    task.resume()
    semaphore.wait()
}

// MARK: - Uninstallation Routine

func uninstallAuraRAS() {
    print("Starting complete uninstallation of AuraRAS components...")
    let fileManager = FileManager.default
    let tunnelDaemonPath = "/Library/LaunchDaemons/edu.purdue.pae.aura-ras.tunnel.plist"
    let helperDaemonPath = "/Library/LaunchDaemons/edu.purdue.pae.aura-ras.daemon.plist"
    let checkinDaemonPath = "/Library/LaunchDaemons/edu.purdue.pae.aura-ras.checkin.plist"
    let installDir = "/usr/local/aura-ras"
    let helperDaemon = "/Library/PrivilegedHelperTools/aura-ras-daemon"
    let prefsPath = "/Library/Preferences/edu.purdue.pae.aura-ras.plist"
    
    print("Terminating any active helper processes...")
    let killall = Process()
    killall.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
    killall.arguments = ["-9", "aura-ras-helper", "aura-ras-daemon", "autossh"]
    try? killall.run()
    killall.waitUntilExit()
    
    // Unload all 3 LaunchDaemons
    for path in [tunnelDaemonPath, helperDaemonPath, checkinDaemonPath] {
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
    
    print("Unregistering Helper App from LaunchServices...")
    let lsregister = Process()
    lsregister.executableURL = URL(fileURLWithPath: "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister")
    lsregister.arguments = ["-u", "\(installDir)/aura-ras-helper.app"]
    try? lsregister.run()
    lsregister.waitUntilExit()

    if fileManager.fileExists(atPath: installDir) {
        try? fileManager.removeItem(atPath: installDir)
        print("Removed AuraRAS directory and binaries.")
    }
    
    if fileManager.fileExists(atPath: helperDaemon) {
        try? fileManager.removeItem(atPath: helperDaemon)
        print("Removed root XPC daemon.")
    }

    if fileManager.fileExists(atPath: prefsPath) {
        try? fileManager.removeItem(atPath: prefsPath)
        print("Removed local ID preferences.")
    }

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
      --checkin       Gather system telemetry and ping the AuraRAS server.
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
let isCheckin = arguments.contains("--checkin")

// Ensure we have root privileges
guard geteuid() == 0 else {
    print("FATAL ERROR: Commands must be run as root.")
    exit(1)
}

if isUninstall {
    if let config = getManagedConfig() {
        print("Notifying server of uninstallation...")
        _ = unregisterFromServer(config: config)
    } else {
        print("WARNING: Could not read MDM config to contact server. Proceeding with local cleanup only.")
    }
    uninstallAuraRAS()
    exit(0)
}

if isCheckin {
    print("--- Starting AuraRAS Agent Telemetry Check-in ---")
    guard let config = getManagedConfig() else {
        print("Check-in aborted due to missing configuration.")
        exit(1)
    }
    performCheckin(config: config)
    print("--- Check-in Complete ---")
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
let registrationSuccess = registerWithServer(config: config, publicKey: publicKey)

if registrationSuccess {
    // Rebuild the plist and start the autossh daemon
    restartTunnel(config: config)
    
    // Dynamically build and configure the XPC daemon
    configureXPCDaemon()
    
    // 4. Immediately perform the first check-in to populate telemetry on the dashboard
    // and initialize the repeating background LaunchDaemon
    performCheckin(config: config)
    
    print("--- \(isRotation ? "Rotation" : "Initialization") Complete ---")
    exit(0)
} else {
    print("--- \(isRotation ? "Rotation" : "Initialization") Failed ---")
    exit(1)
}
