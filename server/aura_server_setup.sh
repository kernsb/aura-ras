#!/usr/bin/env bash
# ==============================================================================
# AuraRAS Server Lifecycle Manager
# Supports: RHEL/Oracle Linux 9 & Ubuntu 22.04/24.04 LTS
# Usage: ./aura_server_setup.sh [--install | --upgrade]
# ==============================================================================

set -e # Exit immediately if a command exits with a non-zero status

# Color formatting
CYAN='\033[0;36m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# ------------------------------------------------------------------------------
# ARGUMENT PARSING
# ------------------------------------------------------------------------------
if [ $# -eq 0 ]; then
    echo -e "${RED}[ERROR] No arguments provided.${NC}"
    echo -e "Usage: $0 [--install | --upgrade]"
    exit 1
fi

MODE=""
case "$1" in
    --install)
        MODE="install"
        ;;
    --upgrade)
        MODE="upgrade"
        ;;
    --help)
        echo -e "Usage: $0 [--install | --upgrade]"
        exit 0
        ;;
    *)
        echo -e "${RED}[ERROR] Unknown argument: $1${NC}"
        echo -e "Usage: $0 [--install | --upgrade]"
        exit 1
        ;;
esac

echo -e "${CYAN}================================================================${NC}"
echo -e "${CYAN}             AuraRAS Server Lifecycle Manager                   ${NC}"
echo -e "${CYAN}================================================================${NC}\n"

# ------------------------------------------------------------------------------
# PHASE 1: Pre-Flight & OS Detection
# ------------------------------------------------------------------------------
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[ERROR] This script must be run as root (sudo).${NC}"
  exit 1
fi

echo -e "${GREEN}[*] Detecting Operating System...${NC}"
if grep -qiE "rhel|oracle|almalinux|rocky|centos" /etc/os-release; then
    OS_FAMILY="rhel"
    WEB_SERVICE="httpd"
    WEB_GROUP="apache"
    SSH_SERVICE="sshd"
    SSL_CERT_DEFAULT="/etc/pki/tls/certs/your_domain.crt"
    SSL_KEY_DEFAULT="/etc/pki/tls/private/your_domain.key"
    APACHE_CONF_DIR="/etc/httpd/conf.d"
    DEF_LOG_DIR="/var/log/httpd"
    echo -e "    Detected: RHEL-based System"
elif grep -qiE "ubuntu|debian" /etc/os-release; then
    OS_FAMILY="debian"
    WEB_SERVICE="apache2"
    WEB_GROUP="www-data"
    SSH_SERVICE="ssh"
    SSL_CERT_DEFAULT="/etc/ssl/certs/your_domain.crt"
    SSL_KEY_DEFAULT="/etc/ssl/private/your_domain.key"
    APACHE_CONF_DIR="/etc/apache2/sites-available"
    DEF_LOG_DIR="/var/log/apache2"
    echo -e "    Detected: Debian-based System"
else
    echo -e "${RED}[ERROR] Unsupported Operating System.${NC}"
    exit 1
fi

# ==============================================================================
# UPGRADE MODE
# ==============================================================================
if [ "$MODE" == "upgrade" ]; then
    echo -e "\n${CYAN}--- Initiating AuraRAS Upgrade ---${NC}"
    
    # Read custom installation paths
    if [ -f "/etc/auraras/install.conf" ]; then
        source /etc/auraras/install.conf
    else
        APP_DIR="/var/www/aura-ras"
    fi

    if [ ! -d "$APP_DIR" ]; then
        echo -e "${RED}[ERROR] Existing installation not found at $APP_DIR.${NC}"
        echo -e "Please run with --install first."
        exit 1
    fi

    if [ ! -f "${APP_DIR}/aura_ras_server/local_settings.py" ]; then
        echo -e "\n${YELLOW}[WARNING] local_settings.py not found!${NC}"
        echo -e "To support structural updates without overwriting credentials,"
        echo -e "please move your secrets to ${APP_DIR}/aura_ras_server/local_settings.py"
        echo -e "before running this upgrade.\n"
        exit 1
    fi

    echo -e "${GREEN}[*] Upgrading target directory: ${APP_DIR}${NC}"

    echo -e "${GREEN}[*] Pulling latest codebase from GitHub...${NC}"
    rm -rf /tmp/aura-ras-upgrade
    git clone https://github.com/kernsb/aura-ras.git /tmp/aura-ras-upgrade -q
    
    # Sync over the new files, excluding the virtual environment, pycache, AND local_settings.py
    rsync -av --exclude='venv' --exclude='__pycache__' --exclude='local_settings.py' /tmp/aura-ras-upgrade/server/root/var/www/aura-ras/ ${APP_DIR}/ > /dev/null

    # Ensure management command directories exist for the telemetry auditor
    mkdir -p ${APP_DIR}/api/management/commands
    touch ${APP_DIR}/api/management/__init__.py
    touch ${APP_DIR}/api/management/commands/__init__.py
    
    chown -R aura-tunnel:${WEB_GROUP} ${APP_DIR}
    chmod -R 750 ${APP_DIR}

    echo -e "${GREEN}[*] Updating Python Dependencies...${NC}"
    sudo -u aura-tunnel -H bash -c "cd ${APP_DIR} && source venv/bin/activate && pip install --upgrade django mysqlclient mozilla-django-oidc cryptography requests -q"

    echo -e "${GREEN}[*] Applying Database Migrations (Adding ConnectionLogs)...${NC}"
    sudo -u aura-tunnel -H bash -c "cd ${APP_DIR} && source venv/bin/activate && python manage.py makemigrations api && python manage.py migrate"

    echo -e "${GREEN}[*] Configuring Telemetry Audit Cron Job...${NC}"
    CRON_FILE="/etc/cron.d/aura-audit"
    echo "* * * * * aura-tunnel cd ${APP_DIR} && ${APP_DIR}/venv/bin/python manage.py audit_telemetry >> /dev/null 2>&1" > $CRON_FILE
    chmod 644 $CRON_FILE

    echo -e "${GREEN}[*] Restarting Services...${NC}"
    systemctl restart ${WEB_SERVICE}
    systemctl restart ${SSH_SERVICE}

    rm -rf /tmp/aura-ras-upgrade
    echo -e "\n${GREEN}*** Upgrade Complete! ***${NC}\n"
    exit 0
fi

# ==============================================================================
# INSTALL MODE
# ==============================================================================
if [ "$MODE" == "install" ]; then
    echo -e "\n${CYAN}--- Configuration Interview ---${NC}"

    # 1. DNS Name
    read -p "Enter the Server DNS Name (e.g., auraras.yourdomain.edu): " SERVER_NAME

    # 2. File Paths
    echo -e "\n${YELLOW}[File System Configuration]${NC}"
    read -p "Enter Application Path (Default: /var/www/aura-ras): " APP_DIR
    APP_DIR=${APP_DIR:-/var/www/aura-ras}

    read -p "Enter Apache Log Path (Default: $DEF_LOG_DIR): " LOG_DIR
    LOG_DIR=${LOG_DIR:-$DEF_LOG_DIR}

    read -p "Enter Application Event Log Path (Default: /data/logs/aura-ras): " APP_LOG_DIR
    APP_LOG_DIR=${APP_LOG_DIR:-/data/logs/aura-ras}

    # 3. SSL Certificates
    echo -e "\n${YELLOW}[SSL Configuration]${NC}"
    read -p "Enter path to SSL Certificate [.crt] ($SSL_CERT_DEFAULT): " SSL_CERT
    SSL_CERT=${SSL_CERT:-$SSL_CERT_DEFAULT}

    read -p "Enter path to SSL Private Key [.key] ($SSL_KEY_DEFAULT): " SSL_KEY
    SSL_KEY=${SSL_KEY:-$SSL_KEY_DEFAULT}

    read -p "Enter path to SSL Chain/Intermediate (Leave blank if none): " SSL_CHAIN

    # Hard halt if certs are missing
    if [ ! -f "$SSL_CERT" ] || [ ! -f "$SSL_KEY" ]; then
        echo -e "\n${RED}[FATAL ERROR] SSL Certificates not found at specified paths!${NC}"
        echo -e "Please upload your certificates to the server and re-run this script."
        exit 1
    fi

    # 4. Entra ID / OIDC Configuration
    echo -e "\n${YELLOW}[Entra ID (OIDC) Configuration]${NC}"
    read -p "Enter Entra ID Tenant ID: " OIDC_TENANT
    read -p "Enter Entra ID Client ID: " OIDC_CLIENT_ID
    read -p "Enter Entra ID Client Secret: " OIDC_CLIENT_SECRET

    # 5. Database Configuration
    echo -e "\n${YELLOW}[Database Configuration]${NC}"
    echo "1) Local Database (Automated MariaDB/MySQL install)"
    echo "2) Remote/External Database (AWS RDS, Custom Cluster)"
    read -p "Select DB architecture (1 or 2): " DB_CHOICE

    if [ "$DB_CHOICE" == "1" ]; then
        DB_HOST="localhost"
        DB_PORT="3306"
        read -p "Do you want to (T)ype a database password or (G)enerate a secure one? (T/G): " DB_PASS_CHOICE
        if [[ "$DB_PASS_CHOICE" =~ ^[Gg]$ ]]; then
            DB_PASS=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 32)
            echo -e "    ${GREEN}Generated DB Password: $DB_PASS${NC}"
        else
            read -s -p "Enter desired DB Password: " DB_PASS
            echo ""
        fi
    else
        read -p "Enter Remote DB Host: " DB_HOST
        read -p "Enter Remote DB Port (Default: 3306): " DB_PORT
        DB_PORT=${DB_PORT:-3306}
        read -s -p "Enter Remote DB Password: " DB_PASS
        echo ""
    fi

    # 6. Firewall Configuration
    echo -e "\n${YELLOW}[Firewall Architecture]${NC}"
    echo "1) Open Architecture (Any IP can access Dashboard & SSH)"
    echo "2) Zero-Trust (Restrict Dashboard & SSH to Admin Subnets)"
    read -p "Select Firewall architecture (1 or 2): " FW_CHOICE

    if [ "$FW_CHOICE" == "2" ]; then
        read -p "Enter authorized Admin subnets (Space separated, e.g., 192.168.1.0/24 10.0.0.0/8): " ADMIN_SUBNETS
    fi

    # 7. Enterprise SSH Detection
    SSH_ALLOW_GROUPS=$(grep -i '^AllowGroups' /etc/ssh/sshd_config || true)
    if [ -n "$SSH_ALLOW_GROUPS" ]; then
        echo -e "\n${YELLOW}[Enterprise SSH Restrictions Detected]${NC}"
        echo -e "Your server restricts SSH access. Detected directive:"
        echo -e "${CYAN}    $SSH_ALLOW_GROUPS${NC}"
        echo -e "The 'aura-tunnel' user MUST belong to one of these groups to establish connections."
        read -p "Type the name of the group to add 'aura-tunnel' to: " TUNNEL_GROUP
    fi

    # 8. Generate Core Secrets
    echo -e "\n${GREEN}[*] Generating secure Application Keys...${NC}"
    DJANGO_SECRET=$(python3 -c "import secrets; print(secrets.token_urlsafe(50))")
    AURA_API_SECRET=$(python3 -c "import secrets; print(secrets.token_urlsafe(48))")

    echo -e "\n${CYAN}--- Beginning Automated Installation ---${NC}"

    echo -e "${GREEN}[*] Tracking Installation State...${NC}"
    mkdir -p /etc/auraras
    echo "APP_DIR=\"${APP_DIR}\"" > /etc/auraras/install.conf
    chmod 644 /etc/auraras/install.conf

    echo -e "${GREEN}[*] Installing System Packages...${NC}"
    export DEBIAN_FRONTEND=noninteractive
    if [ "$OS_FAMILY" == "rhel" ]; then
        dnf install epel-release -y -q
        if [ "$DB_CHOICE" == "1" ]; then
            dnf install git httpd mod_ssl python3-mod_wsgi python3-pip mariadb-server mariadb-connector-c-devel gcc python3-devel pkgconf-pkg-config policycoreutils-python-utils rsync -y -q
        else
            dnf install git httpd mod_ssl python3-mod_wsgi python3-pip mariadb-connector-c-devel gcc python3-devel pkgconf-pkg-config policycoreutils-python-utils rsync -y -q
        fi
    elif [ "$OS_FAMILY" == "debian" ]; then
        apt-get update -qq
        if [ "$DB_CHOICE" == "1" ]; then
            apt-get install git apache2 libapache2-mod-wsgi-py3 python3-venv python3-pip mysql-server default-libmysqlclient-dev pkg-config rsync -y -qq
        else
            apt-get install git apache2 libapache2-mod-wsgi-py3 python3-venv python3-pip default-libmysqlclient-dev pkg-config rsync -y -qq
        fi
    fi

    echo -e "${GREEN}[*] Creating aura-tunnel restricted user...${NC}"
    if ! id "aura-tunnel" &>/dev/null; then
        if [ "$OS_FAMILY" == "rhel" ]; then
            useradd --system --create-home --shell /usr/sbin/nologin aura-tunnel
        else
            adduser --system --group --disabled-password --shell /usr/sbin/nologin aura-tunnel
        fi
        mkdir -p /home/aura-tunnel/.ssh
        touch /home/aura-tunnel/.ssh/authorized_keys
        chown -R aura-tunnel:aura-tunnel /home/aura-tunnel/.ssh
        chmod 700 /home/aura-tunnel/.ssh
        chmod 600 /home/aura-tunnel/.ssh/authorized_keys
    fi

    # Apply the Enterprise SSH Group if one was provided during the interview
    if [ -n "$TUNNEL_GROUP" ]; then
        echo -e "${GREEN}[*] Adding aura-tunnel to enterprise SSH group: $TUNNEL_GROUP...${NC}"
        usermod -aG "$TUNNEL_GROUP" aura-tunnel
    fi

    if [ "$DB_CHOICE" == "1" ]; then
        echo -e "${GREEN}[*] Configuring Local Database...${NC}"
        if [ "$OS_FAMILY" == "rhel" ]; then
            systemctl enable --now mariadb
        else
            systemctl enable --now mysql
        fi
        mysql -e "CREATE DATABASE IF NOT EXISTS auraras_db;"
        mysql -e "CREATE USER IF NOT EXISTS 'auraras_user'@'localhost' IDENTIFIED BY '${DB_PASS}';"
        mysql -e "ALTER USER 'auraras_user'@'localhost' IDENTIFIED BY '${DB_PASS}';"
        mysql -e "GRANT ALL PRIVILEGES ON auraras_db.* TO 'auraras_user'@'localhost';"
        mysql -e "FLUSH PRIVILEGES;"
    fi

    echo -e "${GREEN}[*] Preparing Custom Directories...${NC}"
    mkdir -p "${APP_DIR}"
    mkdir -p "${LOG_DIR}"
    mkdir -p "${APP_LOG_DIR}"
    chown root:${WEB_GROUP} "${LOG_DIR}"
    chmod 775 "${LOG_DIR}"
    chown aura-tunnel:${WEB_GROUP} "${APP_LOG_DIR}"
    chmod 775 "${APP_LOG_DIR}"

    echo -e "${GREEN}[*] Deploying Codebase...${NC}"
    rm -rf /tmp/aura-ras
    git clone https://github.com/kernsb/aura-ras.git /tmp/aura-ras -q
    rsync -a /tmp/aura-ras/server/root/var/www/aura-ras/ ${APP_DIR}/
    
    mkdir -p ${APP_DIR}/api/management/commands
    touch ${APP_DIR}/api/management/__init__.py
    touch ${APP_DIR}/api/management/commands/__init__.py
    
    chown -R aura-tunnel:${WEB_GROUP} ${APP_DIR}
    chmod -R 750 ${APP_DIR}

    echo -e "${GREEN}[*] Setting up Python Environment...${NC}"
    sudo -u aura-tunnel -H bash -c "cd ${APP_DIR} && python3 -m venv venv && source venv/bin/activate && pip install django mysqlclient mozilla-django-oidc cryptography requests -q"

    echo -e "${GREEN}[*] Creating local_settings.py with your credentials...${NC}"
    cat << EOF > ${APP_DIR}/aura_ras_server/local_settings.py
# --- AURA RAS LOCAL SECRETS ---
# This file overrides default settings and is ignored by Git.

SECRET_KEY = '${DJANGO_SECRET}'
DEFAULT_AUTO_FIELD = 'django.db.models.BigAutoField'
ALLOWED_HOSTS = ['localhost', '127.0.0.1', '${SERVER_NAME}']
APP_LOG_DIR = '${APP_LOG_DIR}'

OIDC_RP_CLIENT_ID = '${OIDC_CLIENT_ID}'
OIDC_RP_CLIENT_SECRET = '${OIDC_CLIENT_SECRET}'
AURA_API_SECRET = '${AURA_API_SECRET}'

DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.mysql',
        'NAME': 'auraras_db',
        'USER': 'auraras_user',
        'PASSWORD': '${DB_PASS}',
        'HOST': '${DB_HOST}',
        'PORT': '${DB_PORT}',
    }
}
EOF

    chown aura-tunnel:${WEB_GROUP} ${APP_DIR}/aura_ras_server/local_settings.py
    chmod 640 ${APP_DIR}/aura_ras_server/local_settings.py

    echo -e "${GREEN}[*] Initializing Database Schema...${NC}"
    sudo -u aura-tunnel -H bash -c "cd ${APP_DIR} && source venv/bin/activate && python manage.py makemigrations api && python manage.py migrate"

    echo -e "${GREEN}[*] Configuring Telemetry Audit Cron Job...${NC}"
    CRON_FILE="/etc/cron.d/aura-audit"
    echo "* * * * * aura-tunnel cd ${APP_DIR} && ${APP_DIR}/venv/bin/python manage.py audit_telemetry >> /dev/null 2>&1" > $CRON_FILE
    chmod 644 $CRON_FILE

    echo -e "${GREEN}[*] Configuring Reverse Tunnel SSH Daemon...${NC}"
    cp /tmp/aura-ras/server/root/etc/ssh/sshd_config.d/99-aura-ras.conf /etc/ssh/sshd_config.d/
    chown root:root /etc/ssh/sshd_config.d/99-aura-ras.conf
    chmod 644 /etc/ssh/sshd_config.d/99-aura-ras.conf
    if [ "$OS_FAMILY" == "debian" ]; then
        systemctl disable --now ssh.socket 2>/dev/null || true
        systemctl enable --now ssh.service
    fi
    systemctl restart ${SSH_SERVICE}

    echo -e "${GREEN}[*] Building Apache Configuration...${NC}"
    if [ "$OS_FAMILY" == "rhel" ]; then
        mv /etc/httpd/conf.d/ssl.conf /etc/httpd/conf.d/ssl.conf.bak 2>/dev/null || true
    elif [ "$OS_FAMILY" == "debian" ]; then
        sh -c 'grep -q "Listen 8443" /etc/apache2/ports.conf || echo "Listen 8443" >> /etc/apache2/ports.conf'
    fi

    CHAIN_DIRECTIVE=""
    if [ -n "$SSL_CHAIN" ] && [ -f "$SSL_CHAIN" ]; then
        CHAIN_DIRECTIVE="SSLCertificateChainFile ${SSL_CHAIN}"
    fi

    cat << EOF > ${APACHE_CONF_DIR}/aura-ras.conf
Listen 443
Listen 8443

<VirtualHost *:80>
    ServerName ${SERVER_NAME}
    Redirect permanent / https://${SERVER_NAME}/
</VirtualHost>

<VirtualHost *:443 *:8443>
    ServerName ${SERVER_NAME}
    DocumentRoot ${APP_DIR}

    SSLEngine on
    SSLCertificateFile      ${SSL_CERT}
    SSLCertificateKeyFile   ${SSL_KEY}
    ${CHAIN_DIRECTIVE}

    Alias /static/ ${APP_DIR}/static/
    <Directory ${APP_DIR}/static>
        Require all granted
    </Directory>

    WSGIDaemonProcess aura_ras_server python-home=${APP_DIR}/venv python-path=${APP_DIR} user=aura-tunnel group=${WEB_GROUP} threads=5
    WSGIProcessGroup aura_ras_server
    WSGIApplicationGroup %{GLOBAL}
    WSGIPassAuthorization On
    WSGIScriptAlias / ${APP_DIR}/aura_ras_server/wsgi.py

    <Directory ${APP_DIR}/aura_ras_server>
        <Files wsgi.py>
            Require all granted
        </Files>
    </Directory>

    ErrorLog ${LOG_DIR}/aura-ras_error.log
    CustomLog ${LOG_DIR}/aura-ras_access.log combined
</VirtualHost>
EOF

    if [ "$OS_FAMILY" == "debian" ]; then
        a2enmod ssl
        a2ensite aura-ras.conf
        a2dissite 000-default.conf 2>/dev/null || true
    fi
    systemctl enable --now ${WEB_SERVICE}
    systemctl restart ${WEB_SERVICE}

    if [ "$OS_FAMILY" == "rhel" ]; then
        echo -e "${GREEN}[*] Applying SELinux Contexts...${NC}"
        setsebool -P httpd_can_network_connect 1
        
        # Apply context to application path
        semanage fcontext -a -t httpd_sys_content_t "${APP_DIR}(/.*)?"
        restorecon -Rv "${APP_DIR}" > /dev/null
        
        # Apply specific log context if custom log directory was selected
        if [ "$LOG_DIR" != "/var/log/httpd" ]; then
            semanage fcontext -a -t httpd_log_t "${LOG_DIR}(/.*)?"
            restorecon -Rv "${LOG_DIR}" > /dev/null
        fi

        # Apply specific log context to the custom Application Logs directory
        if [ "$APP_LOG_DIR" != "/data/logs/aura-ras" ]; then
            semanage fcontext -a -t httpd_log_t "${APP_LOG_DIR}(/.*)?"
            restorecon -Rv "${APP_LOG_DIR}" > /dev/null
        fi

        # Authorized keys context
        semanage fcontext -a -t httpd_sys_rw_content_t "/home/aura-tunnel/.ssh(/.*)?"
        restorecon -Rv /home/aura-tunnel/.ssh > /dev/null
    fi

    echo -e "${GREEN}[*] Configuring Firewall...${NC}"
    if [ "$OS_FAMILY" == "rhel" ]; then
        if [ "$FW_CHOICE" == "2" ]; then
            for SUBNET in $ADMIN_SUBNETS; do
                firewall-cmd --permanent --add-rich-rule="rule family='ipv4' source address='$SUBNET' port port='443' protocol='tcp' accept"
                firewall-cmd --permanent --add-rich-rule="rule family='ipv4' source address='$SUBNET' port port='80' protocol='tcp' accept"
                firewall-cmd --permanent --add-rich-rule="rule family='ipv4' source address='$SUBNET' port port='22' protocol='tcp' accept"
            done
            firewall-cmd --permanent --remove-service=http 2>/dev/null || true
            firewall-cmd --permanent --remove-service=https 2>/dev/null || true
            firewall-cmd --permanent --remove-service=ssh 2>/dev/null || true
        else
            firewall-cmd --permanent --add-service=http
            firewall-cmd --permanent --add-service=https
            firewall-cmd --permanent --add-service=ssh
        fi
        firewall-cmd --permanent --add-port=8443/tcp
        firewall-cmd --permanent --add-port=9922/tcp
        firewall-cmd --reload
    elif [ "$OS_FAMILY" == "debian" ]; then
        if [ "$FW_CHOICE" == "2" ]; then
            for SUBNET in $ADMIN_SUBNETS; do
                ufw allow from "$SUBNET" to any port 443 proto tcp
                ufw allow from "$SUBNET" to any port 80 proto tcp
                ufw allow from "$SUBNET" to any port 22 proto tcp
            done
        else
            ufw allow 80/tcp
            ufw allow 443/tcp
            ufw allow 22/tcp
        fi
        ufw allow 8443/tcp
        ufw allow 9922/tcp
        ufw --force enable
        ufw reload
    fi

    # Clean up
    rm -rf /tmp/aura-ras

    # ------------------------------------------------------------------------------
    # PHASE 4: VAULT SUMMARY
    # ------------------------------------------------------------------------------
    echo -e "\n${CYAN}================================================================${NC}"
    echo -e "${GREEN}             AuraRAS Installation Complete!                     ${NC}"
    echo -e "${CYAN}================================================================${NC}"
    echo -e "Dashboard URL:    https://${SERVER_NAME}"
    echo -e "Install Path:     ${APP_DIR}"
    echo -e "Local Settings:   ${APP_DIR}/aura_ras_server/local_settings.py"
    echo -e "Apache Log Dir:   ${LOG_DIR}"
    echo -e "App Event Logs:   ${APP_LOG_DIR}"
    echo -e "\n${YELLOW}*** SECURE VAULT SUMMARY - SAVE THESE CREDENTIALS ***${NC}"
    echo -e "Database User:    auraras_user"
    echo -e "Database Pass:    ${DB_PASS}"
    echo -e "Django Secret:    ${DJANGO_SECRET}"
    echo -e "\n${RED}API Pre-Shared Key (Use this in your Jamf Config Profile!):${NC}"
    echo -e "${AURA_API_SECRET}"
    echo -e "${CYAN}================================================================${NC}\n"
fi