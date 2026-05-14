# AuraRAS Client Deployment Guide (Jamf Pro)

This guide outlines the start-to-finish process for deploying the AuraRAS background agent to macOS endpoints using Jamf Pro.

Because the AuraRAS agent is strictly **stateless**, you will never need to modify or rebuild the `.pkg` installer to change your server settings. All routing and security credentials are fundamentally managed via Jamf Configuration Profiles.

## Step 1: Create the Configuration Profile (JSON Schema)

The Swift agent reads its configuration from the `edu.purdue.pae.aura-ras` preference domain. We will use Jamf's Application & Custom Settings payload to define this GUI.

1. In Jamf Pro, navigate to **Computers > Configuration Profiles** and click **New**.
2. Name the profile: `AuraRAS - Agent Configuration`.
3. Scroll down to the **Application & Custom Settings** payload and click **Configure**.
4. Select **External Applications** -> **Custom Schema**.
5. Set the **Preference Domain** to: `edu.purdue.pae.aura-ras`
6. Paste the following JSON into the **Schema** field:

```json
{
  "title": "AuraRAS Configuration",
  "description": "Settings for the AuraRAS background agent.",
  "properties": {
    "AgentRole": { "title": "Agent Role", "type": "string", "enum": ["Endpoint", "Administrator"], "default": "Endpoint" },
    "JSSID": { "title": "JSSID", "type": "string", "default": "$JSSID", "options": { "hidden": true } },
    "ServerAddress": { "title": "Server Address", "type": "string", "description": "e.g., auraras.yourdomain.edu" },
    "ServerPort": { "title": "Server SSH Port", "type": "integer", "default": 9922 },
    "ApiPort": { "title": "API Check-in Port", "type": "integer", "default": 8443 },
    "APISecret": { "title": "API Secret", "type": "string", "description": "The exact 64-character pre-shared key from your server settings." }
  }
}
```

7. Click **Save Schema**.
8. Fill out the newly generated form fields with your production Server Address, Port settings, and API Secret.
9. **Scope** this profile to your target macOS endpoints.

## Step 2: Upload the Package

You need to add the compiled `.pkg` to your Jamf instance. Because the `aura-ras-client.pkg` has a built-in `preinstall` script, it will automatically handle purging old tunnels and unregistering legacy agents before it installs the new files.

1. Navigate to **Settings > Computer Management > Packages**.
2. Click **New** and upload the latest compiled `aura-ras-client.pkg`.

## Step 3: Create the Deployment Policy

Now we link the package to a deployment policy.

1. Go to **Computers > Policies** and click **New**.
2. Name the policy: `Install - AuraRAS Agent`.
3. **Triggers:** Check `Recurring Check-in` (or your preferred trigger).
4. **Execution Frequency:** `Once per computer`.
5. Add the **Packages** payload:
   * Select your `aura-ras-client.pkg`.
   * Action: **Install**.
6. **Scope** the policy to your target test computers and click **Save**.

The next time those Macs check in, they will silently strip out any old ghosts, install the new agent, read your new API secret from the configuration profile, generate fresh Ed25519 keys, and securely register with your production server!

## Appendix: Command-Line Manual Overrides

The AuraRAS Swift agent has several built-in flags for manual troubleshooting and administrative control. These must be executed as root.

**1. Manual Telemetry Check-in**
Forces the Mac to immediately gather its current hardware/user telemetry and push an update to the server dashboard.
```bash
sudo /usr/local/aura-ras/aura-ras-agent --checkin
```

**2. Force Key Rotation**
If an endpoint's SSH keys are compromised, or the server DB is wiped, this command deletes the local `aura_ed25519` keys, generates a fresh pair, and re-registers the new public key with the server.
```bash
sudo /usr/local/aura-ras/aura-ras-agent --rotate-keys
```

**3. Manual Initialization**
If the installation succeeds but the tunnel fails to build (e.g., due to a temporary network outage during enrollment), you can manually kick off the initial registration process.
```bash
sudo /usr/local/aura-ras/aura-ras-agent --initialize
```

**4. Complete Uninstallation**
This command gracefully unregisters the Mac from the remote server, unloads all background LaunchDaemons, unregisters the `auraras://` URI scheme from macOS LaunchServices, and deletes all binaries and keys.
```bash
sudo /usr/local/aura-ras/aura-ras-agent --uninstall
```