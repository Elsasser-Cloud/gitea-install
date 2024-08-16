#!/bin/bash

if [ ! -f /var/lib/gitea/.first_login_complete ]; then

    echo "Welcome! This is your first login. Let's set up Gitea."

    # 1. Install Gitea
    wget -O /tmp/gitea https://dl.gitea.io/gitea/$(curl -s https://dl.gitea.io/gitea/latest/ | grep -o 'gitea-[0-9.]*-linux-amd64' | head -n 1)
    chmod +x /tmp/gitea
    mv /tmp/gitea /usr/local/bin/gitea

    useradd --system --shell /bin/bash --comment 'Gitea' git
    mkdir -p /var/lib/gitea/{custom,data,indexers,log,public,tmp}
    chown -R git:git /var/lib/gitea
    chmod -R g+rwX /var/lib/gitea

    # (You might need to create a systemd unit file for Gitea; check its documentation)
    systemctl enable gitea
    systemctl start gitea

    # 2. Get Domain and Email
    read -p "Enter your domain name (e.g., git.example.com): " domain
    read -p "Enter your email address for Let's Encrypt: " email

    # 3. Request Let's Encrypt Certificate
    certbot certonly --standalone -d "$domain" --agree-tos --email "$email" --non-interactive

    # 4. Configure Gitea 

    # (a) Set Domain in Gitea Configuration
    gitea_config=/etc/gitea/app.ini # Adjust if your Gitea config is elsewhere
    sed -i "s/DOMAIN = localhost/DOMAIN = $domain/g" "$gitea_config"

    # (b) Configure HTTPS (Assuming Certbot places certs in /etc/letsencrypt/live/)
    sed -i "s/\# CERT_FILE = custom\/https-cert.pem/CERT_FILE = \/etc\/letsencrypt\/live\/$domain\/fullchain.pem/g" "$gitea_config"
    sed -i "s/\# KEY_FILE  = custom\/https-key.pem/KEY_FILE  = \/etc\/letsencrypt\/live\/$domain\/privkey.pem/g" "$gitea_config"

    # Restart Gitea to apply changes
    systemctl restart gitea

    touch /var/lib/gitea/.first_login_complete
    echo "Gitea setup complete! Access it at https://$domain"
fi
