#!/bin/bash

# Detect system architecture
ARCH=$(uname -m)
if [[ $ARCH == "x86_64" ]]; then
    GITEA_ARCH="amd64"
elif [[ $ARCH == "aarch64" ]]; then
    GITEA_ARCH="arm64"
else
    echo "Unsupported architecture: $ARCH"
    exit 1
fi

# Prompt for Gitea configurations
echo "Please enter the domain for Gitea (e.g., gitea.example.com):"
read -r DOMAIN

echo "Please enter the Gitea admin username:"
read -r ADMIN_USER

echo "Please enter the Gitea admin email:"
read -r ADMIN_EMAIL

echo "Please enter the Gitea admin password:"
read -r -s ADMIN_PASS

# Prompt for Let's Encrypt SSL certificate setup
echo "Do you want to set up a Let's Encrypt SSL certificate for Gitea? (yes/no):"
read -r USE_LETS_ENCRYPT

# Update and install dependencies
apt-get update
apt-get upgrade -y
apt-get install -y git wget certbot sqlite3

# Create Gitea user
useradd --system --create-home --home-dir /var/lib/gitea --shell /bin/bash --comment 'Gitea application' git

# Create necessary directories
mkdir -p /etc/gitea /var/lib/gitea /var/log/gitea
chown -R git:git /etc/gitea /var/lib/gitea /var/log/gitea
chmod 750 /var/lib/gitea /var/log/gitea

# Download Gitea binary based on detected architecture
GITEA_VERSION="1.18.0"
wget -O /usr/local/bin/gitea https://dl.gitea.io/gitea/${GITEA_VERSION}/gitea-${GITEA_VERSION}-linux-${GITEA_ARCH}
chmod +x /usr/local/bin/gitea

# Create a minimized Gitea configuration file
cat <<EOF > /etc/gitea/app.ini
APP_NAME = Gitea: Git with a cup of tea
RUN_USER = git
RUN_MODE = prod

[server]
DOMAIN           = $DOMAIN
HTTP_PORT        = 80
ROOT_URL         = http://$DOMAIN/
PROTOCOL         = http

[database]
DB_TYPE  = sqlite3
PATH     = /var/lib/gitea/data/gitea.db

[security]
INSTALL_LOCK   = true
SECRET_KEY     = $(openssl rand -base64 32)
INTERNAL_TOKEN = $(openssl rand -base64 32)

[log]
MODE      = file
LEVEL     = Info
ROOT_PATH = /var/log/gitea
EOF

# Configure Gitea with SSL if chosen
if [[ $USE_LETS_ENCRYPT == "yes" ]]; then
    # Request Let's Encrypt certificate
    certbot certonly --standalone -d "$DOMAIN" --non-interactive --agree-tos -m "$ADMIN_EMAIL"

    SSL_CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
    SSL_KEY="/etc/letsencrypt/live/$DOMAIN/privkey.pem"

    # Update configuration to use HTTPS
    sed -i "s/HTTP_PORT        = 80/HTTP_PORT        = 443/" /etc/gitea/app.ini
    sed -i "s|PROTOCOL         = http|PROTOCOL         = https|" /etc/gitea/app.ini
    sed -i "s|ROOT_URL         = http://|ROOT_URL         = https://|" /etc/gitea/app.ini
    sed -i "s|# CERT_FILE        =|CERT_FILE        = $SSL_CERT|" /etc/gitea/app.ini
    sed -i "s|# KEY_FILE         =|KEY_FILE         = $SSL_KEY|" /etc/gitea/app.ini

    echo "Gitea configured to use HTTPS with Let's Encrypt certificate."
else
    echo "Gitea configured to use HTTP."
fi

# Ensure the app.ini file has the correct ownership and permissions
chown git:git /etc/gitea/app.ini
chmod 640 /etc/gitea/app.ini

# Create Gitea service file
cat <<EOF | tee /etc/systemd/system/gitea.service
[Unit]
Description=Gitea
After=syslog.target
After=network.target

[Service]
RestartSec=2s
Type=simple
User=git
Group=git
WorkingDirectory=/var/lib/gitea/
ExecStart=/usr/local/bin/gitea web --config /etc/gitea/app.ini
Restart=always
Environment=USER=git HOME=/var/lib/gitea GITEA_WORK_DIR=/var/lib/gitea
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd and start Gitea service
systemctl daemon-reload
systemctl enable gitea
systemctl start gitea

# Wait a few seconds for Gitea to initialize
sleep 10

# Create the admin user
/usr/local/bin/gitea admin user create --username "$ADMIN_USER" --password "$ADMIN_PASS" --email "$ADMIN_EMAIL" --admin --config /etc/gitea/app.ini

# Setup firewall (optional)
if [[ $USE_LETS_ENCRYPT == "yes" ]]; then
    ufw allow 443/tcp
else
    ufw allow 80/tcp
fi

# Display setup completion message
if [[ $USE_LETS_ENCRYPT == "yes" ]]; then
    echo "Gitea installation is complete. You can access it at https://$DOMAIN"
else
    echo "Gitea installation is complete. You can access it at http://$DOMAIN"
fi

echo "Admin user has been created with the provided credentials."
