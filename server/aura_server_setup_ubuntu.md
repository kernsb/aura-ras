# AuraRAS Production Server Setup Guide (Debian / Ubuntu)

This guide walks you through deploying the AuraRAS infrastructure onto a clean Debian or Ubuntu server using the files hosted in this repository.

> **⚠️ STOP:** Before proceeding, ensure you have reviewed the `prerequisites.md` document and have your SSL certificates, API credentials, and network firewall rules ready.

## Step 1: System Packages & Restricted User

First, install the necessary system dependencies (Apache, Python tools, and MySQL) and create the restricted user that will securely manage the reverse SSH tunnels.

```bash
# Install core dependencies (Omit 'mysql-server' if you are using an externally hosted database)
sudo apt update
sudo apt install git apache2 libapache2-mod-wsgi-py3 python3-venv python3-pip mysql-server default-libmysqlclient-dev pkg-config -y

# Create the restricted tunnel user (no password, no shell)
sudo adduser --system --group --disabled-password --shell /usr/sbin/nologin aura-tunnel

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
1. Open the MySQL root prompt:
   ```bash
   sudo mysql
   ```
2. Create the database and a dedicated application user. **(Replace `YourSecureDbPassword` with a strong password!)**
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
# Clone the repository to your home directory (Change URL to your actual repo)
cd ~
git clone [https://github.com/kernsb/aura-ras.git](https://github.com/kernsb/aura-ras.git)

# Move the Django web application to the Apache web root
sudo cp -r aura-ras/server/root/var/www/aura-ras /var/www/

# Set the correct permissions so the tunnel user can manage SSH keys
sudo chown -R aura-tunnel:www-data /var/www/aura-ras
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

While still logged in as the `aura-tunnel` user, you must input your specific API keys, database passwords, and secrets into the Django settings file.

```bash
nano aura_ras_server/settings.py
```

Update the following sections:

1. **`SECRET_KEY`**: Generate a new random Django secret key.
2. **`DATABASES`**: Enter the `YourSecureDbPassword` you created in Step 2. 
   * *If using an externally hosted MySQL 8.4+ database, ensure you update `'HOST'` and set `'PORT'` to `'3306'`. You may also need to provide an `'OPTIONS'` dictionary with your OS CA Certificate bundle to fulfill strict `caching_sha2_password` SSL requirements.*
3. **Entra ID (OIDC)**: Enter your `OIDC_RP_CLIENT_ID`, `OIDC_RP_CLIENT_SECRET`, and Tenant ID URLs.
4. **`AURA_API_SECRET`**: Enter your 64-character pre-shared key (Must match the MDM Configuration Profile sent to Macs). Be careful not to include hidden newline characters if pasting from the terminal.

Save and exit (`Ctrl+O`, `Enter`, `Ctrl+X`).

## Step 6: Initialize the Database

Apply the database schema and verify everything is working. 

> **External Database Note:** If you are using an external database, this step will reach out over port `3306` to build the tables on your remote server. Ensure your Ubuntu server has outbound network access to the database host before running these commands.

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

# DISABLE systemd socket activation (Critical for Ubuntu 22.04+)
sudo systemctl disable --now ssh.socket
sudo systemctl enable --now ssh.service
sudo systemctl restart ssh
```

## Step 8: Apache & SSL Configuration

Configure Apache to serve the Web Dashboard on port `443` and the Agent API on port `8443`.

1. **Copy your SSL Certificates:** Ensure your `.crt`, `.key`, and chain files are placed in `/etc/ssl/certs/` and `/etc/ssl/private/`.

2. **Enable the API Port:** By default, Apache on Ubuntu only listens on 80 and 443. Add the custom API port:
   ```bash
   sudo sh -c 'echo "Listen 8443" >> /etc/apache2/ports.conf'
   ```

3. **Copy the VirtualHost Configuration:**
   ```bash
   sudo cp ~/aura-ras/server/root/etc/apache2/sites-available/aura-ras.conf /etc/apache2/sites-available/
   ```

4. **Update the VirtualHost with your domains:**
   Open the file and update `ServerName` and the `SSLCertificateFile` paths to match your actual domain and certificates.
   ```bash
   sudo nano /etc/apache2/sites-available/aura-ras.conf
   ```
   *(Ensure `WSGIPassAuthorization On` and `WSGIApplicationGroup %{GLOBAL}` are present in this file!)*

5. **Enable and Restart Apache:**
   ```bash
   sudo a2enmod ssl
   sudo a2ensite aura-ras.conf
   sudo a2dissite 000-default.conf
   sudo systemctl restart apache2
   ```

## Step 9: Firewall Validation (UFW)

Ensure the Uncomplicated Firewall (UFW) enforces the split traffic architecture. Choose the option below that fits your deployment.

**Option A: Open Architecture (Testing)**
Allows access to the dashboard from anywhere.
```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 22/tcp
sudo ufw allow 8443/tcp
sudo ufw allow 9922/tcp
sudo ufw reload
```

**Option B: Zero-Trust Architecture (Recommended for Production)**
Locks the Web Dashboard and Server SSH down strictly to authorized IT subnets, while keeping the background agent API ports open to the public internet so remote Macs can still connect.
```bash
# Define your authorized Administrator IT Subnets (Space-separated inside the parentheses)
ADMIN_SUBNETS=("192.168.1.0/24" "10.15.0.0/16" "172.16.5.0/24")

# 1. Lock down Dashboard & SSH to the authorized subnets
for SUBNET in "${ADMIN_SUBNETS[@]}"; do
    sudo ufw allow from "$SUBNET" to any port 443 proto tcp
    sudo ufw allow from "$SUBNET" to any port 80 proto tcp
    sudo ufw allow from "$SUBNET" to any port 22 proto tcp
done

#