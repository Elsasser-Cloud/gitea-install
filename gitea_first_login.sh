#!/bin/bash

# Define the lock file location
LOCK_FILE="/var/lock/gitea_install.lock"

# Check if the script has been run before
if [ -f "$LOCK_FILE" ]; then
    echo -e "\e[1;31mThe Gitea installation script has already been run and did not finish successfully. If you want to run it again, please delete the lock file:\e[0m"
    echo "sudo rm -f $LOCK_FILE"
    read -n 1 -s  # Wait for the user to press a key
    exit 1
fi

# Create the lock file to prevent re-execution
touch "$LOCK_FILE"

# Function to display a step
step() {
    echo -e "\n\e[1;34m[$1/$TOTAL_STEPS] $2...\e[0m"
}

# Function to display success message
success() {
    echo -e "\e[1;32m✔ $1\e[0m"
}

# Function to display error message and wait for user input
error() {
    echo -e "\e[1;31m✘ $1\e[0m"
    echo -e "\e[1;33mPress any key to return to the shell...\e[0m"
    read -n 1 -s  # Wait for the user to press a key
    exit 1
}

# Total number of steps in the installation process
TOTAL_STEPS=10
CURRENT_STEP=1

# Step 1: Detect system architecture
step $CURRENT_STEP "Detecting system architecture"
ARCH=$(uname -m)
case $ARCH in
    x86_64) GITEA_ARCH="amd64" ;;
    aarch64) GITEA_ARCH="arm64" ;;
    *) error "Unsupported architecture: $ARCH" ;;
esac
success "System architecture detected: $GITEA_ARCH"
CURRENT_STEP=$((CURRENT_STEP + 1))

# Step 2: Prompt for Gitea configurations
step $CURRENT_STEP "Collecting Gitea configuration details"
echo -e "\nPlease enter the domain for Gitea (e.g., gitea.example.com):"
read -r DOMAIN
echo -e "\nPlease enter the Gitea admin username:"
read -r ADMIN_USER
echo -e "\nPlease enter the Gitea admin email:"
read -r ADMIN_EMAIL
echo -e "\nPlease enter the Gitea admin password:"
read -r -s ADMIN_PASS
echo -e "\nDo you want to set up a Let's Encrypt SSL certificate for Gitea? (yes/no):"
read -r USE_LETS_ENCRYPT
echo -e "\nDo you want to automatically configure ufw for Gitea? (yes/no):"
read -r CONFIGURE_FIREWALL
success "Configuration details collected"
CURRENT_STEP=$((CURRENT_STEP + 1))

# Step 3: Update and install dependencies
step $CURRENT_STEP "Updating system and installing dependencies"
apt-get update -qq && apt-get upgrade -y -qq && apt-get install -y -qq git wget sqlite3 || error "Failed to install dependencies"
success "System updated and dependencies installed"
CURRENT_STEP=$((CURRENT_STEP + 1))

# Step 4: Create Gitea user and directories
step $CURRENT_STEP "Creating Gitea user and setting up directories"
useradd --system --create-home --home-dir /var/lib/gitea --shell /bin/bash --comment 'Gitea application' git || error "Failed to create Gitea user"
mkdir -p /etc/gitea /var/lib/gitea /var/log/gitea /var/lib/gitea/https || error "Failed to create directories"
chown -R git:git /etc/gitea /var/lib/gitea /var/log/gitea
chmod 750 /var/lib/gitea /var/log/gitea
success "Gitea user and directories set up"
CURRENT_STEP=$((CURRENT_STEP + 1))

# Step 5: Download and install Gitea binary
step $CURRENT_STEP "Downloading and installing Gitea binary"
GITEA_VERSION="1.18.0"
wget -q -O /usr/local/bin/gitea https://dl.gitea.io/gitea/${GITEA_VERSION}/gitea-${GITEA_VERSION}-linux-${GITEA_ARCH} || error "Failed to download Gitea"
chmod +x /usr/local/bin/gitea || error "Failed to make Gitea executable"
success "Gitea binary installed"
CURRENT_STEP=$((CURRENT_STEP + 1))

# Step 6: Create Gitea configuration file
step $CURRENT_STEP "Creating Gitea configuration file"
cat <<EOF > /etc/gitea/app.ini
APP_NAME = Gitea: Git with a cup of tea
RUN_USER = git
RUN_MODE = prod

[server]
DOMAIN           = $DOMAIN
HTTP_PORT        = 80
ROOT_URL         = http://$DOMAIN/
PROTOCOL         = http
APP_DATA_PATH    = /var/lib/gitea/data

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

# Configure SSL if chosen
if [[ $USE_LETS_ENCRYPT == "yes" ]]; then
    step $CURRENT_STEP "Configuring SSL with Let's Encrypt"

    # Update the configuration values in app.ini
    sed -i "s/^PROTOCOL\s*=.*/PROTOCOL=https/" /etc/gitea/app.ini
    sed -i "s/^DOMAIN\s*=.*/DOMAIN=$DOMAIN/" /etc/gitea/app.ini
    sed -i "s/^HTTP_PORT\s*=.*/HTTP_PORT=443/" /etc/gitea/app.ini
    sed -i "s|^ROOT_URL\s*=.*|ROOT_URL=https://$DOMAIN/|" /etc/gitea/app.ini
    sed -i "s|^CERT_FILE\s*=.*|CERT_FILE=/var/lib/gitea/https/cert.pem|" /etc/gitea/app.ini
    sed -i "s|^KEY_FILE\s*=.*|KEY_FILE=/var/lib/gitea/https/key.pem|" /etc/gitea/app.ini

    # Add ACME settings
    sed -i "/\[server\]/a ENABLE_ACME=true" /etc/gitea/app.ini
    sed -i "/\[server\]/a ACME_ACCEPTTOS=true" /etc/gitea/app.ini
    sed -i "/\[server\]/a ACME_EMAIL=$ADMIN_EMAIL" /etc/gitea/app.ini
    sed -i "/\[server\]/a ACME_DIRECTORY=https://acme-v02.api.letsencrypt.org/directory" /etc/gitea/app.ini

    success "SSL configured with Let's Encrypt via ACME"
fi


chown git:git /etc/gitea/app.ini
chmod 640 /etc/gitea/app.ini
success "Gitea configuration file created"
CURRENT_STEP=$((CURRENT_STEP + 1))

# Step 7: Create Gitea service file
step $CURRENT_STEP "Setting up Gitea as a systemd service"
cat <<EOF > /etc/systemd/system/gitea.service
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

systemctl daemon-reload || error "Failed to reload systemd daemon"
systemctl enable gitea || error "Failed to enable Gitea service"
systemctl start gitea || error "Failed to start Gitea service"
success "Gitea service set up and started"
CURRENT_STEP=$((CURRENT_STEP + 1))

# Step 8: Create the admin user
step $CURRENT_STEP "Creating Gitea admin user"
sleep 10
sudo -u git /usr/local/bin/gitea admin user create --username "$ADMIN_USER" --password "$ADMIN_PASS" --email "$ADMIN_EMAIL" --admin --config /etc/gitea/app.ini

# Check if the admin user creation was successful
if [ $? -ne 0 ]; then
    error "Failed to create admin user"
fi

success "Admin user created"
CURRENT_STEP=$((CURRENT_STEP + 1))

# Step 9: Configure firewall (optional)
if [[ $CONFIGURE_FIREWALL == "yes" ]]; then
    step $CURRENT_STEP "Configuring firewall"
    if [[ $USE_LETS_ENCRYPT == "yes" ]]; then
        ufw allow 443/tcp || error "Failed to allow HTTPS traffic"
    else
        ufw allow 80/tcp || error "Failed to allow HTTP traffic"
    fi
    success "Firewall configured"
fi

# Completion message
echo -e "\n\e[1;32m✔ Gitea installation is complete.\e[0m"
if [[ $USE_LETS_ENCRYPT == "yes" ]]; then
    echo -e "\e[1;32mYou can access Gitea at: https://$DOMAIN\e[0m"
else
    echo -e "\e[1;32mYou can access Gitea at: http://$DOMAIN\e[0m"
fi

# Step 10: Remove the script itself
step $CURRENT_STEP "Cleaning up installation script"
rm -f "/etc/profile.d/gitea_first_login.sh" || error "Failed to remove the installation script"
rm $LOCK_FILE
success "Installation script removed. Goodbye!"
