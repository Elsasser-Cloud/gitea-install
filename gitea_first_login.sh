#!/bin/bash

# Constants
LOCK_FILE="/var/lock/gitea_install.lock"
GITEA_VERSION="1.18.0"
GITEA_BINARY_URL="https://dl.gitea.io/gitea/${GITEA_VERSION}/gitea-${GITEA_VERSION}-linux-${GITEA_ARCH}"
APP_DATA_PATH="/var/lib/gitea/data"
LOG_FILE="/var/log/gitea_install.log"
SCRIPT_PATH=$(realpath "$0")  # Get the absolute path of the script

# Create a log file and redirect stdout/stderr to it
exec > >(tee -i "$LOG_FILE") 2>&1

# Function to perform cleanup on script exit
cleanup() {
    echo "Cleaning up..."
    rm -f "$LOCK_FILE"
    rm -f "$SCRIPT_PATH"
}
trap cleanup EXIT

# Check for the lock file as soon as possible
if [ -f "$LOCK_FILE" ]; then
    echo -e "\e[1;31mThe installation script has already been run. If you want to run it again, please delete the lock file:\e[0m"
    echo "sudo rm -f $LOCK_FILE"
    exit 1
fi
touch "$LOCK_FILE"

# Functions

# Function to display a step
step() {
    echo -e "\n\e[1;34m[$1/$TOTAL_STEPS] $2...\e[0m"
}

# Function to display success message
success() {
    echo -e "\e[1;32m✔ $1\e[0m"
}

# Function to display error message
error() {
    echo -e "\e[1;31m✘ $1\e[0m"
    echo -e "\e[1;33mCheck the log at $LOG_FILE for details. Press any key to return to the shell...\e[0m"
    read -n 1 -s  # Wait for the user to press a key
    exit 1
}

# Function to detect system architecture
detect_architecture() {
    step $CURRENT_STEP "Detecting system architecture"
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) GITEA_ARCH="amd64" ;;
        aarch64) GITEA_ARCH="arm64" ;;
        *) error "Unsupported architecture: $ARCH" ;;
    esac
    success "System architecture detected: $GITEA_ARCH"
    CURRENT_STEP=$((CURRENT_STEP + 1))
}

# Function to collect Gitea configuration details
collect_config() {
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
    success "Configuration details collected"
    CURRENT_STEP=$((CURRENT_STEP + 1))
}

# Function to update system and install dependencies
install_dependencies() {
    step $CURRENT_STEP "Updating system and installing dependencies"
    if ! apt-get update -qq && apt-get upgrade -y -qq && apt-get install -y -qq git wget certbot sqlite3; then
        error "Failed to install dependencies"
    fi
    success "System updated and dependencies installed"
    CURRENT_STEP=$((CURRENT_STEP + 1))
}

# Function to create Gitea user and directories
setup_gitea_user() {
    step $CURRENT_STEP "Creating Gitea user and setting up directories"
    if ! useradd --system --create-home --home-dir /var/lib/gitea --shell /bin/bash --comment 'Gitea application' git; then
        error "Failed to create Gitea user"
    fi
    if ! mkdir -p /etc/gitea /var/lib/gitea /var/log/gitea; then
        error "Failed to create directories"
    fi
    chown -R git:git /etc/gitea /var/lib/gitea /var/log/gitea
    chmod 750 /var/lib/gitea /var/log/gitea
    success "Gitea user and directories set up"
    CURRENT_STEP=$((CURRENT_STEP + 1))
}

# Function to download and install Gitea binary
install_gitea() {
    step $CURRENT_STEP "Downloading and installing Gitea binary"
    if ! wget -q -O /usr/local/bin/gitea "$GITEA_BINARY_URL"; then
        error "Failed to download Gitea"
    fi
    if ! chmod +x /usr/local/bin/gitea; then
        error "Failed to make Gitea executable"
    fi
    success "Gitea binary installed"
    CURRENT_STEP=$((CURRENT_STEP + 1))
}

# Function to create Gitea configuration file
configure_gitea() {
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
APP_DATA_PATH    = $APP_DATA_PATH

[database]
DB_TYPE  = sqlite3
PATH     = $APP_DATA_PATH/gitea.db

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
        if ! certbot certonly --standalone -d "$DOMAIN" --non-interactive --agree-tos -m "$ADMIN_EMAIL"; then
            error "Failed to obtain SSL certificate"
        fi
        SSL_CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
        SSL_KEY="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
        sed -i "s/HTTP_PORT        = 80/HTTP_PORT        = 443/" /etc/gitea/app.ini
        sed -i "s|PROTOCOL         = http|PROTOCOL         = https|" /etc/gitea/app.ini
        sed -i "s|ROOT_URL         = http://|ROOT_URL         = https://|" /etc/gitea/app.ini
        sed -i "s|# CERT_FILE        =|CERT_FILE        = $SSL_CERT|" /etc/gitea/app.ini
        sed -i "s|# KEY_FILE         =|KEY_FILE         = $SSL_KEY|" /etc/gitea/app.ini
        success "SSL configured with Let's Encrypt"
    fi

    chown git:git /etc/gitea/app.ini
    chmod 640 /etc/gitea/app.ini
    success "Gitea configuration file created"
    CURRENT_STEP=$((CURRENT_STEP + 1))
}

# Function to create Gitea service file
setup_service() {
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

    if ! systemctl daemon-reload; then
        error "Failed to reload systemd daemon"
    fi
    if ! systemctl enable gitea; then
        error "Failed to enable Gitea service"
    fi
    if ! systemctl start gitea; then
        error "Failed to start Gitea service"
    fi
    success "Gitea service set up and started"
    CURRENT_STEP=$((CURRENT_STEP + 1))
}

# Function to create the admin user
create_admin_user() {
    step $CURRENT_STEP "Creating Gitea admin user"
    sleep 10
    if ! sudo -u git /usr/local/bin/gitea admin user create --username "$ADMIN_USER" --password "$ADMIN_PASS" --email "$ADMIN_EMAIL" --admin --config /etc/gitea/app.ini; then
        error "Failed to create admin user"
    fi
    success "Admin user created"
    CURRENT_STEP=$((CURRENT_STEP + 1))
}

# Function to configure the firewall
configure_firewall() {
    step $CURRENT_STEP "Configuring firewall"
    if [[ $USE_LETS_ENCRYPT == "yes" ]]; then
        if ! ufw allow 443/tcp; then
            error "Failed to allow HTTPS traffic"
        fi
    else
        if ! ufw allow 80/tcp; then
            error "Failed to allow HTTP traffic"
        fi
    fi
    success "Firewall configured"
}

# Main script execution
detect_architecture
collect_config
install_dependencies
setup_gitea_user
install_gitea
configure_gitea
setup_service
create_admin_user
configure_firewall

# Completion message
echo -e "\n\e[1;32m✔ Gitea installation is complete.\e[0m"
if [[ $USE_LETS_ENCRYPT == "yes" ]]; then
    echo -e "\e[1;32mYou can access Gitea at: https://$DOMAIN\e[0m"
else
    echo -e "\e[1;32mYou can access Gitea at: http://$DOMAIN\e[0m"
fi
echo -e "\e[1;32mAdmin user has been created with the provided credentials.\e[0m"

# Final cleanup: remove the script itself
cleanup
