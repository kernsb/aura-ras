# AuraRAS Server Prerequisites: Before You Start

Before beginning the installation and configuration of your AuraRAS production server, ensure you have all the following infrastructure, network access, and security assets ready.

## 1. Infrastructure Requirements

* **Operating System:** A clean, fresh installation of a Debian-based (e.g., Ubuntu Server 24.04 LTS) or RHEL-based (e.g., Oracle Linux 9, AlmaLinux 9, Rocky Linux 9) Linux server OS.

* **IP Address:** A static Public IP address assigned to the server.

* **DNS Record:** A dedicated DNS A-Record pointing to that IP address (e.g., `auraras.yourdomain.edu`).

## 2. Network & Firewall Port Allocations

Ensure your network edge firewall and routing rules allow the following traffic to and from the server. **Note the separation of the Dashboard and API ports for maximum security:**

| Protocol | Port | Direction | Purpose | 
| ----- | ----- | ----- | ----- | 
| TCP | 80 | Inbound | HTTP Web Traffic (Automatically redirects to secure 443) | 
| TCP | 443 | Inbound | HTTPS Web Dashboard (Restrict to authorized Admin IP subnets) | 
| TCP | 8443 | Inbound | Dedicated API port for macOS agents (Leave open to the internet) | 
| TCP | 9922 | Inbound | Dedicated AuraRAS Reverse SSH Tunnel ingress (Leave open to the internet) | 
| TCP | 22 | Inbound | Standard Server SSH (Restrict to authorized Admin IP subnets) | 
| TCP | 443 | Outbound | API communication to Jamf Pro and Microsoft Entra ID | 
| TCP | 3306 | Outbound | MySQL Database communication (**Only required if using an externally hosted database**) | 

## 3. Required Security Assets & Credentials

Gather the following credentials and files before running the setup scripts or beginning manual configuration:

* **SSL Certificate:** A valid SSL Certificate (`.crt`) and Private Key (`.key`) matching your DNS name. If using InCommon/Sectigo, you will also need the intermediate chain certificate.

* **Jamf Pro API Client:** A Client ID and Client Secret generated in Jamf Pro. The role must have permissions to read Computers, Extension Attributes, and LAPS passwords.

* **Entra ID App Registration:** An OIDC Client ID and Client Secret from Microsoft Azure/Entra ID for Single Sign-On, along with your Tenant ID.

* **AuraRAS Pre-Shared Key:** A cryptographically secure 64-character string generated for endpoint API authentication.

  * *You can easily generate this securely by running: `python3 -c "import secrets; print(secrets.token_urlsafe(48))"`*