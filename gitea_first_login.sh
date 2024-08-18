#!/bin/bash

if [ ! -f /var/lib/gitea/.first_login_complete ]; then

    clear # Clear the terminal for a clean start

    echo "----------------------------------------"
    echo "  ELSASSER CLOUD - Gitea Setup Wizard  "
    echo "----------------------------------------"

    step=1
    total_steps=6 # Adjusted for the additional step

    log_file="/tmp/gitea_setup.log"
    exec > >(tee -a "$log_file") 2>&1 # Redirect all output to log file and terminal

    # 1. Install Gitea (with enhanced architecture detection)
    echo "[$step/$total_steps] Installing Gitea..."
    arch=$(uname -m)
    case "$arch" in
        x86_64) gitea_arch="linux-amd64" ;;
        i386|i686) gitea_arch="linux-386" ;;
        armv7l) gitea_arch="linux-armv7" ;;
        aarch64) gitea_arch="linux-arm64" ;;
        *) 
            echo "Unsupported architecture: $arch"
            exit 1
            ;;
    esac

    # Manually specify the download URL (replace with the actual URL from the Gitea website)
    wget_url="https://dl.gitea.io/gitea/1.18.5/gitea-1.18.5-$gitea_arch" 

    # Download with verbose output (removed --max-redirect=0)
    wget -O /tmp/gitea "$wget_url" -v 
    if [ $? -ne 0 ]; then
        echo "Error downloading Gitea binary from $wget_url. Please check the URL and try again."
        exit 1
    fi

    chmod +x /tmp/gitea 
    mv /tmp/gitea /usr/local/bin/gitea 
    ((step++))

    # 2. Create 'git' user and directories
    echo "[$step/$total_steps] Creating Gitea user and directories..."
    useradd --system --shell /bin/bash --comment 'Gitea' git
    mkdir -p /var/lib/gitea/{custom,data,indexers,log,public,tmp} 
    chown -R git:git /var/lib/gitea
    chmod -R g+rwX /var/lib/gitea
    ((step++))

    # 3. Ask if SSL certificate is needed and get domain/email if so
    echo "[$step/$total_steps] SSL Certificate configuration"
    while true; do
        read -p "Do you want to request a Let's Encrypt SSL certificate? (y/n): " yn
        case $yn in
            [Yy]* ) 
                request_ssl=true; 
                read -p "Enter your domain name (e.g., git.example.com): " domain
                read -p "Enter your email address for Let's Encrypt: " email
                break;;
            [Nn]* ) 
                request_ssl=false; 
                domain="localhost" # Set a default domain if no SSL is requested
                break;;
            * ) echo "Please answer yes or no.";;
        esac
    done
    ((step++))

    if $request_ssl; then
        # 4. Request Let's Encrypt Certificate
        echo "[$step/$total_steps] Requesting SSL certificate..."
        certbot certonly --standalone -d "$domain" --agree-tos --email "$email" --non-interactive 
        ((step++))
    else
        echo "Skipping SSL certificate request."
    fi

    # 5. Create /etc/gitea directory and generate app.ini with gathered info
    echo "[$step/$total_steps] Configuring Gitea..."
    mkdir -p /etc/gitea
    chown -R git:git /etc/gitea
    chmod -R g+rwX /etc/gitea

    cat << EOF > /etc/gitea/app.ini
[server]
DOMAIN           = $domain
HTTP_PORT       = 3000              # Or the port you want to use
ROOT_URL         = %(PROTOCOL)s://%(DOMAIN)s:%(HTTP_PORT)s/

[database]
DB_TYPE          = sqlite3
PATH             = /var/lib/gitea/gitea.db 

[security]
INSTALL_LOCK     = true
SECRET_KEY       = <generate_a_strong_secret_key> 

$(if $request_ssl; then
    cat << HTTPS_CONFIG
[server.SSH_DOMAIN]
ENABLED            = true
DOMAIN             = $domain
PORT               = 22

[tls]
ENABLED            = true
CERT_FILE          = /etc/letsencrypt/live/$domain/fullchain.pem
KEY_FILE           = /etc/letsencrypt/live/$domain/privkey.pem
HTTPS_CONFIG
else 
    cat << NO_HTTPS_CONFIG
[server.SSH_DOMAIN]
ENABLED            = false
NO_HTTPS_CONFIG
fi )

# ... other sections and settings can be added as needed
EOF

    ((step++))

    # 6. Create Gitea systemd service file
    echo "[$step/$total_steps] Creating Gitea service..."
    cat << EOF > /etc/systemd/system/gitea.service
[Unit]
Description=Gitea (Git with a cup of tea)
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
Environment=USER=git HOME=/home/git GITEA_WORK_DIR=/var/lib/gitea

[Install]
WantedBy=multi-user.target
EOF
    ((step++))

    # 7. Enable and start Gitea service
    systemctl daemon-reload 
    systemctl enable gitea 
    systemctl start gitea 

    # 8. Set /etc/gitea to read-only
    chmod -R go-w /etc/gitea

    touch /var/lib/gitea/.first_login_complete

    echo "----------------------------------------"
    echo "  Gitea setup complete!                "
    if $request_ssl; then
        echo "  Access it at https://$domain         "
    else
        echo "  Access it at http://$domain         "
    fi
    echo "----------------------------------------"
fi
