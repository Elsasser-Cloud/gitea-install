#!/bin/bash

if [ ! -f /var/lib/gitea/.first_login_complete ]; then

    clear # Clear the terminal for a clean start

    echo "----------------------------------------"
    echo "  ELSASSER CLOUD - Gitea Setup Wizard  "
    echo "----------------------------------------"

    step=1
    total_steps=5 # Adjust if you add/remove steps

    # 1. Install Gitea
    echo "[$step/$total_steps] Installing Gitea..."
    wget -O /tmp/gitea https://dl.gitea.io/gitea/$(curl -s https://dl.gitea.io/gitea/latest/ | grep -o 'gitea-[0-9.]*-linux-amd64' | head -n 1) >/dev/null 2>&1
    chmod +x /tmp/gitea >/dev/null 2>&1
    mv /tmp/gitea /usr/local/bin/gitea >/dev/null 2>&1
    ((step++))

    # 2. Create 'git' user and directories
    echo "[$step/$total_steps] Creating Gitea user and directories..."
    useradd --system --shell /bin/bash --comment 'Gitea' git >/dev/null 2>&1 
    mkdir -p /var/lib/gitea/{custom,data,indexers,log,public,tmp} >/dev/null 2>&1
    chown -R git:git /var/lib/gitea >/dev/null 2>&1
    chmod -R g+rwX /var/lib/gitea >/dev/null 2>&1
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

    # 4. Get Domain and Email
    echo "[$step/$total_steps] Gathering information..."
    read -p "Enter your domain name (e.g., git.example.com): " domain
    read -p "Enter your email address for Let's Encrypt: " email
    ((step++))

    # 5. Request Let's Encrypt Certificate
    echo "[$step/$total_steps] Requesting SSL certificate..."
    certbot certonly --standalone -d "$domain" --agree-tos --email "$email" --non-interactive >/dev/null 2>&1
    ((step++))

    # 6. Configure Gitea 
    echo "[$step/$total_steps] Configuring Gitea..."
    # (a) Set Domain and SQLite in Gitea Configuration
    gitea_config=/etc/gitea/app.ini # Adjust if your Gitea config is elsewhere
    sed -i "s/DOMAIN = localhost/DOMAIN = $domain/g" "$gitea_config" >/dev/null 2>&1
    sed -i "s/DB_TYPE\s*=\s*mysql/DB_TYPE = sqlite3/g" "$gitea_config" >/dev/null 2>&1
    sed -i "s/PATH\s*=\s*data\/gitea.db/PATH\s*=\s*\/var\/lib\/gitea\/gitea.db/g" "$gitea_config" >/dev/null 2>&1

    # (b) Configure HTTPS (Assuming Certbot places certs in /etc/letsencrypt/live/)
    sed -i "s/\# CERT_FILE = custom\/https-cert.pem/CERT_FILE = \/etc\/letsencrypt\/live\/$domain\/fullchain.pem/g" "$gitea_config" >/dev/null 2>&1
    sed -i "s/\# KEY_FILE  = custom\/https-key.pem/KEY_FILE  = \/etc\/letsencrypt\/live\/$domain\/privkey.pem/g" "$gitea_config" >/dev/null 2>&1

    # 7. Enable and start Gitea service
    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable gitea >/dev/null 2>&1
    systemctl start gitea >/dev/null 2>&1

    touch /var/lib/gitea/.first_login_complete

    echo "----------------------------------------"
    echo "  Gitea setup complete!                "
    echo "  Access it at https://$domain         "
    echo "----------------------------------------"
fi
