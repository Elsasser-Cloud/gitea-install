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

    # Download with redirect handling and verbose output
    wget -O /tmp/gitea "$wget_url" -v 
    if [ $? -ne 0 ]; then
        if [ -f /tmp/gitea ]; then
            # Check if the downloaded file is HTML (indicating a redirect)
            if grep -q "<!DOCTYPE html>" /tmp/gitea; then
                echo "Download was redirected. Please check the URL and try again."
                exit 1
            fi
        else
            echo "Error downloading Gitea binary from $wget_url"
            exit 1
        fi
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

    # 3. Create Gitea systemd service file
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

    # 4. Ask if SSL certificate is needed
    echo "[$step/$total_steps] SSL Certificate configuration"
    while true; do
        read -p "Do you want to request a Let's Encrypt SSL certificate? (y/n): " yn
        case $yn in
            [Yy]* ) request_ssl=true; break;;
            [Nn]* ) request_ssl=false; break;;
            * ) echo "Please answer yes or no.";;
        esac
    done
    ((step++))

    if $request_ssl; then
        # 5. Get Domain and Email
        echo "[$step/$total_steps] Gathering information..."
        read -p "Enter your domain name (e.g., git.example.com): " domain
        read -p "Enter your email address for Let's Encrypt: " email
        ((step++))

        # 6. Request Let's Encrypt Certificate
        echo "[$step/$total_steps] Requesting SSL certificate..."
        certbot certonly --standalone -d "$domain" --agree-tos --email "$email" --non-interactive 
        ((step++))
    else
        echo "Skipping SSL certificate request."
        domain="localhost" # Set a default domain if no SSL is requested
    fi


    # 7. Configure Gitea 
    echo "[$step/$total_steps] Configuring Gitea..."
    # (a) Set Domain and SQLite in Gitea Configuration
    gitea_config=/etc/gitea/app.ini # Adjust if your Gitea config is elsewhere
    sed -i "s/DOMAIN = localhost/DOMAIN = $domain/g" "$gitea_config" 
    sed -i "s/DB_TYPE\s*=\s*mysql/DB_TYPE = sqlite3/g" "$gitea_config"
    sed -i "s/PATH\s*=\s*data\/gitea.db/PATH\s*=\s*\/var\/lib\/gitea\/gitea.db/g" "$gitea_config"

    if $request_ssl; then
        # (b) Configure HTTPS (Assuming Certbot places certs in /etc/letsencrypt/live/)
        sed -i "s/\# CERT_FILE = custom\/https-cert.pem/CERT_FILE = \/etc\/letsencrypt\/live\/$domain\/fullchain.pem/g" "$gitea_config"
        sed -i "s/\# KEY_FILE  = custom\/https-key.pem/KEY_FILE  = \/etc\/letsencrypt\/live\/$domain\/privkey.pem/g" "$gitea_config" 
    fi

    # 8. Enable and start Gitea service
    systemctl daemon-reload 
    systemctl enable gitea 
    systemctl start gitea 

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
