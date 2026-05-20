# AuraRAS Production Server Setup Guide (RHEL / Oracle Linux)

This guide walks you through deploying the AuraRAS infrastructure onto a clean RHEL, Oracle Linux, AlmaLinux, or Rocky Linux server using the files hosted in this repository.

> **⚠️ STOP:** Before proceeding, ensure you have reviewed the `prerequisites.md` document and have your SSL certificates, API credentials, and network firewall rules ready.

## Step 1: System Packages & Restricted User

First, install the necessary system dependencies (Apache `httpd`, Python tools, and MySQL) using `dnf`, and create the restricted user that will securely manage the reverse SSH tunnels.

```bash
# Enable the EPEL repository for additional Python packages
sudo dnf install epel-release -y

# Install core dependencies 
# (Note: If you are hosting the database locally, also append 'mysql-server' to this command)
sudo dnf install git httpd mod_ssl python3-mod_wsgi python3-pip mariadb-connector-c-devel gcc python3-devel pkgconf-pkg-config policycoreutils-python-utils -y

# Create the restricted tunnel user (no password, no shell)
sudo useradd --system --create-home --shell /usr/sbin/nologin aura-tunnel

# Prepare the SSH directory for the tunnel user
sudo mkdir -p /home/aura-tunnel/.ssh
sudo touch /home/aura-tunnel/.ssh/authorized_keys
sudo chown -R aura-tunnel:aura-tunnel /home/aura-tunnel/.ssh
sudo chmod 700 /home/aura-tunnel/.ssh
sudo chmod 600 /home/aura-tunnel/.ssh/authorized_keys
```

## Step 2: Database Configuration

AuraRAS uses MySQL to safely handle concurrent connections and endpoint data. You can host this locally or use an external database cluster.

**Option A: Local Database (Standard)**
1. Enable and start the MySQL daemon:
   ```bash
   sudo systemctl enable --now mysqld
   ```
2. Open the MySQL root prompt:
   ```bash
   sudo mysql
   ```
3. Create the database and a dedicated application user. **(Replace `YourSecureDbPassword` with a strong password!)**
   ```sql
   CREATE DATABASE auraras_db;
   CREATE USER 'auraras_user'@'localhost' IDENTIFIED BY 'YourSecureDbPassword';
   GRANT ALL PRIVILEGES ON auraras_db.* TO 'auraras_user'@'localhost';
   FLUSH PRIVILEGES;
   EXIT;
   ```

**Option B: Externally Hosted Database**
If you are using an external database server or managed DBaaS (like AWS RDS or Azure Database for MySQL):
1. Ensure your external database server has a blank database named `auraras_db` created.
2. Ensure you have a user provisioned with full read/write privileges to that database.
3. Skip the local MySQL commands above and proceed to Step 3.

## Step 3: Deploy the Codebase

Clone this repository and move the server files into their production locations.

```bash
# Clone the repository to your home directory
cd ~
git clone [https://github.com/kernsb/aura-ras.git](https://github.com/kernsb/aura-ras.git)

# Move the Django web application to the Apache web root
sudo cp -r aura-ras/server/root/var/www/aura-ras /var/www/

# Set the correct permissions so the tunnel user can manage SSH keys
# Note: RHEL uses the 'apache' group instead of 'www-data'
sudo chown -R aura-tunnel:apache /var/www/aura-ras
sudo chmod -R 750 /var/www/aura-ras
```

## Step 4: Python Virtual Environment

Create the isolated Python environment and install the required packages.

```bash
# Switch to the aura-tunnel user to ensure files are owned correctly
sudo -u aura-tunnel -H bash
cd /var/www/aura-ras

# Create and activate the virtual environment
python3 -m venv venv
source venv/bin/activate

# Install the required Django and cryptography packages
pip install django mysqlclient mozilla-django-oidc cryptography requests
```

## Step 5: Configure Application Secrets (`settings.py`)

While still logged in as the `aura-tunnel` user, input your specific API keys, database passwords, and secrets into the Django settings file.

```bash
nano aura_ras_server/settings.py
```

Update the following sections:

1. **`SECRET_KEY`**: Generate a new random Django secret key.
2. **`ALLOWED_HOSTS`**: Add your server's DNS name (e.g., `['auraras.yourdomain.edu']`).
3. **`DATABASES`**: Enter the `YourSecureDbPassword` you created in Step 2. 
   * *If using an externally hosted MySQL 8.4+ database, ensure you update `'HOST'` and set `'PORT'` to `'3306'`. You may also need to provide an `'OPTIONS'` dictionary with your OS CA Certificate bundle to fulfill strict `caching_sha2_password` SSL requirements.*
4. **Entra ID (OIDC)**: Enter your `OIDC_RP_CLIENT_ID`, `OIDC_RP_CLIENT_SECRET`, and Tenant ID URLs.
5. **`AURA_API_SECRET`**: Enter your 64-character pre-shared key (Must match the MDM Configuration Profile sent to Macs). Be careful not to include hidden newline characters if pasting from the terminal.

Save and exit (`Ctrl+O`, `Enter`, `Ctrl+X`).

## Step 6: Initialize the Database

Apply the database schema and verify everything is working.

> **External Database Note:** If you are using an external database, this step will reach out over port `3306` to build the tables on your remote server. Ensure your server has outbound network access to the database host before running these commands.

```bash
# Still inside the aura-tunnel session and venv:
python manage.py makemigrations api
python manage.py migrate

# Exit back to your standard admin user account
exit
```

## Step 7: SSH Daemon Configuration

Apply the custom SSH configuration to handle the reverse proxy ports securely.

```bash
# Copy the SSH config from your cloned repo
sudo cp ~/aura-ras/server/root/etc/ssh/sshd_config.d/99-aura-ras.conf /etc/ssh/sshd_config.d/

# Secure the file permissions
sudo chown root:root /etc/ssh/sshd_config.d/99-aura-ras.conf
sudo chmod 644 /etc/ssh/sshd_config.d/99-aura-ras.conf

# Restart the SSH daemon (Named 'sshd' on RHEL)
sudo systemctl restart sshd
```

> **⚠️ ENTERPRISE SECURITY WARNING (`AllowGroups`):** > Many strictly managed RHEL environments restrict SSH access using the `AllowGroups` directive in `/etc/ssh/sshd_config`. If your server enforces this, you **must** add the `aura-tunnel` user to an allowed group, or client tunnels will be instantly rejected. See the Troubleshooting section at the bottom of this document for instructions.

## Step 8: Apache & SSL Configuration

Configure `httpd` to serve the Web Dashboard on port `443` and the Agent API on port `8443`.

1. **Copy your SSL Certificates:** Ensure your `.crt`, `.key`, and chain files are placed in `/etc/pki/tls/certs/` and `/etc/pki/tls/private/`.

2. **Disable the Default SSL Config (CRITICAL):**
   Installing `mod_ssl` drops a default configuration file that will crash Apache on startup because it looks for dummy localhost certificates. Rename it to disable it:
   ```bash
   sudo mv /etc/httpd/conf.d/ssl.conf /etc/httpd/conf.d/ssl.conf.bak
   ```

3. **Create the VirtualHost Configuration:**
   Unlike Ubuntu, RHEL drops custom configuration files directly into `conf.d`.
   ```bash
   sudo nano /etc/httpd/conf.d/aura-ras.conf
   ```

4. **Paste the Apache Configuration:**
   Ensure you include `Listen 443` and `Listen 8443` at the top of the file. Update `ServerName` and the `SSLCertificateFile` paths to match your actual domain and certificates.
   ```apache
   Listen 443
   Listen 8443
   
   # HTTP (Port 80) - Redirect all traffic to HTTPS
   <VirtualHost *:80>
       ServerName auraras.yourdomain.edu
       Redirect permanent / [https://auraras.yourdomain.edu/](https://auraras.yourdomain.edu/)
   </VirtualHost>
   
   # HTTPS (Port 443 & 8443) - Django Application via WSGI
   <VirtualHost *:443 *:8443>
       ServerName auraras.yourdomain.edu
       DocumentRoot /var/www/aura-ras
   
       SSLEngine on
       SSLCertificateFile      /etc/pki/tls/certs/your_domain.crt
       SSLCertificateKeyFile   /etc/pki/tls/private/your_domain.key
       SSLCertificateChainFile /etc/pki/tls/certs/InCommon_chain.crt
   
       Alias /static/ /var/www/aura-ras/static/
       <Directory /var/www/aura-ras/static>
           Require all granted
       </Directory>
   
       WSGIDaemonProcess aura_ras_server python-home=/var/www/aura-ras/venv python-path=/var/www/aura-ras user=aura-tunnel group=apache threads=5
       WSGIProcessGroup aura_ras_server
       WSGIApplicationGroup %{GLOBAL}
       WSGIPassAuthorization On
       WSGIScriptAlias / /var/www/aura-ras/aura_ras_server/wsgi.py
   
       <Directory /var/www/aura-ras/aura_ras_server>
           <Files wsgi.py>
               Require all granted
           </Files>
       </Directory>
   
       ErrorLog /var/log/httpd/aura-ras_error.log
       CustomLog /var/log/httpd/aura-ras_access.log combined
   </VirtualHost>
   ```
   Save and exit (`Ctrl+O`, `Enter`, `Ctrl+X`).

## Step 9: SELinux Configuration (CRITICAL)

RHEL strictly enforces SELinux. By default, it will violently block Apache from connecting to the database or communicating with external APIs (like Entra ID and Jamf Pro).

```bash
# Allow Apache to make outbound network connections (DB, Jamf, Entra ID)
sudo setsebool -P httpd_can_network_connect 1

# Label the web directory so Apache has permission to read the files
sudo semanage fcontext -a -t httpd_sys_content_t "/var/www/aura-ras(/.*)?"
sudo restorecon -Rv /var/www/aura-ras

# Allow Apache (running as aura-tunnel via WSGI) to write to the SSH authorized_keys file
sudo semanage fcontext -a -t httpd_sys_rw_content_t "/home/aura-tunnel/.ssh(/.*)?"
sudo restorecon -Rv /home/aura-tunnel/.ssh

# Enable and Start Apache
sudo systemctl enable --now httpd
```

## Step 10: Firewall Configuration (Firewalld)

RHEL uses `firewalld` instead of `ufw`. Apply the exact same split-architecture rules. Choose the option below that fits your deployment.

**Option A: Open Architecture (Testing)**
Allows access to the dashboard from anywhere.
```bash
sudo firewall-cmd --permanent --add-service=http
sudo firewall-cmd --permanent --add-service=https
sudo firewall-cmd --permanent --add-service=ssh
sudo firewall-cmd --permanent --add-port=8443/tcp
sudo firewall-cmd --permanent --add-port=9922/tcp
sudo firewall-cmd --reload
```

**Option B: Zero-Trust Architecture (Recommended for Production)**
Locks the Web Dashboard and Server SSH down strictly to authorized IT subnets, while keeping the background agent API ports open to the public internet so remote Macs can still connect.
```bash
# Define your authorized Administrator IT Subnets (Space-separated inside the parentheses)
ADMIN_SUBNETS=("192.168.1.0/24" "10.15.0.0/16" "172.16.5.0/24")

# 1. Lock down Dashboard & SSH to the authorized subnets using Firewalld Rich Rules
for SUBNET in "${ADMIN_SUBNETS[@]}"; do
    sudo firewall-cmd --permanent --add-rich-rule="rule family='ipv4' source address='$SUBNET' port port='443' protocol='tcp' accept"
    sudo firewall-cmd --permanent --add-rich-rule="rule family='ipv4' source address='$SUBNET' port port='80' protocol='tcp' accept"
    sudo firewall-cmd --permanent --add-rich-rule="rule family='ipv4' source address='$SUBNET' port port='22' protocol='tcp' accept"
done

# Ensure the global open rules are removed if previously added
sudo firewall-cmd --permanent --remove-service=http
sudo firewall-cmd --permanent --remove-service=https
sudo firewall-cmd --permanent --remove-service=ssh

# 2. Leave Agent API & Reverse Tunnels open to the internet
sudo firewall-cmd --permanent --add-port=8443/tcp
sudo firewall-cmd --permanent --add-port=9922/tcp

# Reload the firewall to apply the changes
sudo firewall-cmd --reload
```

---

## Troubleshooting: "Tunnel Disconnected" Errors

If your server setup is complete but your macOS clients are showing a **"Tunnel Disconnected"** status in the web dashboard, the server's SSH daemon or firewall is actively rejecting their inbound connections. 

### 1. Check for Enterprise SSH Group Restrictions (Most Common)
In enterprise environments, `sshd` is often configured to only allow specific groups to connect. You can check if the server is rejecting the connection by reviewing the secure log while a client attempts to connect:
```bash
sudo tail -n 20 /var/log/secure
```
If you see an error stating: `User aura-tunnel... not allowed because none of user's groups are listed in AllowGroups`, you must add the tunnel user to the approved list.

1. Find the allowed groups on your server:
   ```bash
   sudo grep -i AllowGroups /etc/ssh/sshd_config
   ```
2. Add `aura-tunnel` to one of the groups returned by the previous command (e.g., `users`, `admins`):
   ```bash
   sudo usermod -aG GroupName aura-tunnel
   ```
3. Restart the SSH service:
   ```bash
   sudo systemctl restart sshd
   ```

### 2. Verify External Network Routing
If your server's local `firewalld` is configured correctly (confirmed via `sudo firewall-cmd --list-all`), but clients still cannot reach the server, an upstream network appliance (Campus Edge Firewall, AWS Security Group, VMware NSX, etc.) is likely dropping your packets.

You must request your network infrastructure team to open inbound TCP traffic for ports `443`, `8443`, and `9922` pointing to your server's public IP address.