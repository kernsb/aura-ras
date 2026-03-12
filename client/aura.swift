import Foundation
import CoreFoundation

// MARK: - Constants
let agentVersion = "0.1.0"
let bundleIdentifier = "edu.purdue.pae.aura-ras" as CFString
let sshDirectory = "/var/root/.ssh"
let privateKeyPath = "\(sshDirectory)/aura-ras"
let publicKeyPath = "\(sshDirectory)/aura-ras.pub"

// MARK: - MDM Configuration Enforcement
func getManagedConfig() -> (role: String, jssID: Int, serverAddress: String, serverPort: Int)? {
    let roleKey = "AgentRole" as CFString
    let jssidKey = "JSSID" as CFString
    let serverAddressKey = "ServerAddress" as CFString
    let serverPortKey = "ServerPort" as CFString
    
    // 1. Verify strict MDM enforcement
    guard CFPreferencesAppValueIsForced(roleKey, bundleIdentifier) else {
        print("SECURITY FAULT: AgentRole is not strictly managed by MDM. Aborting.")
        return nil
    }
    
    guard CFPreferencesAppValueIsForced(jssidKey, bundleIdentifier) else {
        print("ERROR: JSSID is not strictly managed by MDM. Cannot calculate ports. Aborting.")
        return nil
    }

    guard CFPreferencesAppValueIsForced(serverAddressKey, bundleIdentifier) else {
        print("ERROR: ServerAddress is not strictly managed by MDM. Cannot locate AuraRAS Appliance. Aborting.")
        return nil
    }
    
    guard CFPreferencesAppValueIsForced(serverPortKey, bundleIdentifier) else {
        print("ERROR: ServerPort is not strictly managed by MDM. Cannot establish tunnel. Aborting.")
        return nil
    }
    
    // 2. Extract authentic values
    let roleValue = CFPreferencesCopyAppValue(roleKey, bundleIdentifier) as? String ?? "Endpoint"
    
    // Handle JSSID safely (Jamf payload variables are injected as Strings)
    let jssidRaw = CFPreferencesCopyAppValue(jssidKey, bundleIdentifier)
    var jssidValue = 0
    if let jInt = jssidRaw as? Int {
        jssidValue = jInt
    } else if let jStr = jssidRaw as? String, let jParsed = Int(jStr) {
        jssidValue = jParsed
    }
    
    guard jssidValue > 0 else {
        print("ERROR: JSSID could not be parsed or is 0. Ensure the Jamf payload variable is deploying correctly.")
        return nil
    }
    
    let serverAddressValue = CFPreferencesCopyAppValue(serverAddressKey, bundleIdentifier) as? String ?? ""
    // Default to 9922 if casting fails, though the guard above enforces it must exist
    let serverPortValue = CFPreferencesCopyAppValue(serverPortKey, bundleIdentifier) as? Int ?? 9922
    
    guard !serverAddressValue.isEmpty else {
        print("ERROR: Provided ServerAddress is empty.")
        return nil
    }

    return (role: roleValue, jssID: jssidValue, serverAddress: serverAddressValue, serverPort: serverPortValue)
}

// MARK: - SSH Key Management
func ensureSSHKeysExist(forceRotate: Bool = false) -> String? {
    let fileManager = FileManager.default
    
    // 1. Ensure /var/root/.ssh exists with strict 700 permissions
    if !fileManager.fileExists(atPath: sshDirectory) {
        do {
            try fileManager.createDirectory(atPath: sshDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            print("Created \(sshDirectory) with 700 permissions.")
        } catch {
            print("ERROR: Failed to create SSH directory. \(error.localizedDescription)")
            return nil
        }
    }
    
    if forceRotate {
        print("Key rotation requested. Removing existing keys...")
        try? fileManager.removeItem(atPath: privateKeyPath)
        try? fileManager.removeItem(atPath: publicKeyPath)
    }
    
    // 2. Check if keys already exist
    if fileManager.fileExists(atPath: privateKeyPath) && fileManager.fileExists(atPath: publicKeyPath) {
        print("Ed25519 key pair already exists at \(sshDirectory). Skipping generation.")
    } else {
        // 3. Generate new Ed25519 keys using native ssh-keygen for perfect OpenSSH compatibility
        print("Generating new Ed25519 key pair...")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        // -t: type, -f: output file, -N: empty passphrase, -q: quiet
        task.arguments = ["-t", "ed25519", "-f", privateKeyPath, "-N", "", "-q"]
        
        do {
            try task.run()
            task.waitUntilExit()
            
            if task.terminationStatus == 0 {
                print("Successfully generated Ed25519 keys.")
            } else {
                print("ERROR: ssh-keygen failed with status \(task.terminationStatus).")
                return nil
            }
        } catch {
            print("ERROR: Could not execute ssh-keygen. \(error.localizedDescription)")
            return nil
        }
    }
    
    // 4. Read and return the public key string to send to the server
    do {
        let pubKey = try String(contentsOfFile: publicKeyPath, encoding: .utf8)
        return pubKey.trimmingCharacters(in: .whitespacesAndNewlines)
    } catch {
        print("ERROR: Could not read public key. \(error.localizedDescription)")
        return nil
    }
}

// MARK: - Server Registration
func registerWithServer(jssID: Int, role: String, publicKey: String, serverAddress: String) -> Bool {
    print("Preparing registration payload for JSSID: \(jssID) (\(role))...")
    
    // Construct the full URL since the MDM profile now only provides the DNS name or IP address
    let endpointURLString = "https://\(serverAddress)/api/register"
    
    guard let url = URL(string: endpointURLString) else {
        print("ERROR: Invalid API Endpoint URL.")
        return false
    }
    
    let payload: [String: Any] = [
        "jssid": jssID,
        "role": role,
        "public_key": publicKey,
        "hostname": Host.current().name ?? "Unknown"
    ]
    
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    
    do {
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
    } catch {
        print("ERROR: Failed to serialize JSON payload. \(error.localizedDescription)")
        return false
    }
    
    // Use a semaphore to make the asynchronous network call synchronous
    // This is required so the command-line tool doesn't exit before the request completes
    let semaphore = DispatchSemaphore(value: 0)
    var success = false
    
    let task = URLSession.shared.dataTask(with: request) { data, response, error in
        defer { semaphore.signal() }
        
        if let error = error {
            print("NETWORK ERROR: Failed to register with server. \(error.localizedDescription)")
            return
        }
        
        if let httpResponse = response as? HTTPURLResponse {
            if (200...299).contains(httpResponse.statusCode) {
                print("SUCCESS: Successfully registered with AuraRAS Appliance.")
                success = true
            } else {
                print("SERVER ERROR: Server responded with status code \(httpResponse.statusCode).")
                if let data = data, let responseString = String(data: data, encoding: .utf8) {
                    print("Response Details: \(responseString)")
                }
            }
        }
    }
    
    task.resume()
    semaphore.wait() // Block execution until the network request finishes
    
    return success
}

// MARK: - Tunnel Management
func generateLaunchDaemon(jssID: Int, serverAddress: String, serverPort: Int) -> Bool {
    print("Generating LaunchDaemon configuration...")
    let sshPort = jssID + 40000
    let vncPort = jssID + 50000
    let daemonPath = "/Library/LaunchDaemons/edu.purdue.pae.aura-ras.daemon.plist"
    
    let daemonDict: [String: Any] = [
        "Label": "edu.purdue.pae.aura-ras.daemon",
        "ProgramArguments": [
            "/usr/local/aura-ras/autossh", // <-- Updated Path
            "-M", "0",
            "-N",
            "-p", "\(serverPort)",
            "-i", privateKeyPath,
            "-o", "StrictHostKeyChecking=accept-new",
            "-R", "\(sshPort):127.0.0.1:22",
            "-R", "\(vncPort):127.0.0.1:5900",
            "aura-tunnel@\(serverAddress)"
        ],
        "KeepAlive": true,
        "RunAtLoad": true,
        "StandardErrorPath": "/var/log/autossh_error.log",
        "StandardOutPath": "/var/log/autossh.log"
    ]
    
    do {
        let plistData = try PropertyListSerialization.data(fromPropertyList: daemonDict, format: .xml, options: 0)
        try plistData.write(to: URL(fileURLWithPath: daemonPath))
        
        let attributes: [FileAttributeKey: Any] = [
            .posixPermissions: 0o644,
            .ownerAccountName: "root",
            .groupOwnerAccountName: "wheel"
        ]
        try FileManager.default.setAttributes(attributes, ofItemAtPath: daemonPath)
        
        print("Successfully wrote LaunchDaemon to \(daemonPath)")
        return true
    } catch {
        print("ERROR: Failed to create LaunchDaemon. \(error.localizedDescription)")
        return false
    }
}

func restartTunnel() {
    print("Restarting AuraRAS tunnel service...")
    let daemonPath = "/Library/LaunchDaemons/edu.purdue.pae.aura-ras.daemon.plist"
    let fileManager = FileManager.default
    
    guard fileManager.fileExists(atPath: daemonPath) else {
        print("Daemon plist not found at \(daemonPath). Assuming first run, skipping restart.")
        return
    }
    
    let bootout = Process()
    bootout.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    bootout.arguments = ["bootout", "system", daemonPath]
    try? bootout.run()
    bootout.waitUntilExit()
    
    // Brief pause to ensure the system fully unloads the service before bootstrapping
    Thread.sleep(forTimeInterval: 1.0)
    
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
}

// MARK: - Command Line Usage
func printUsage() {
    print("""
    AuraRAS Agent v\(agentVersion)
    Usage: aura-ras-agent [options]
    
    Options:
      --initialize    Register the endpoint with the AuraRAS server and establish the tunnel.
      --rotate-keys   Force generation of a new SSH keypair and update the AuraRAS server.
      --version       Display the agent version.
      --help          Show this help message.
    """)
}

// MARK: - Main Execution Flow
let arguments = CommandLine.arguments.dropFirst()

if arguments.isEmpty || arguments.contains("--help") {
    printUsage()
    exit(0)
}

if arguments.contains("--version") {
    print("AuraRAS Agent v\(agentVersion)")
    exit(0)
}

let isRotation = arguments.contains("--rotate-keys")
let isInit = arguments.contains("--initialize")

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

// Ensure we have root privileges before making system changes
guard NSUserName() == "root" else {
    print("FATAL ERROR: Initialization and key rotation must be run as root.")
    exit(1)
}

// 1. Get Trusted Config
guard let config = getManagedConfig() else {
    print("Initialization aborted due to missing or untrusted configuration.")
    exit(1)
}
print("Verified MDM Configuration - Role: \(config.role), JSSID: \(config.jssID), ServerPort: \(config.serverPort)")

// 2. Manage Keys
guard let publicKey = ensureSSHKeysExist(forceRotate: isRotation) else {
    print("FATAL ERROR: Could not establish SSH identities.")
    exit(1)
}

// 3. Register with Appliance
let registrationSuccess = registerWithServer(jssID: config.jssID, role: config.role, publicKey: publicKey, serverAddress: config.serverAddress)

if registrationSuccess {
    // Dynamically build and configure the LaunchDaemon based on the latest MDM profile
    if generateLaunchDaemon(jssID: config.jssID, serverAddress: config.serverAddress, serverPort: config.serverPort) {
        restartTunnel()
    } else {
        print("FATAL ERROR: Failed to configure tunnel service.")
        exit(1)
    }
    
    print("--- \(isRotation ? "Rotation" : "Initialization") Complete ---")
    exit(0)
} else {
    print("--- \(isRotation ? "Rotation" : "Initialization") Failed ---")
    exit(1)
}